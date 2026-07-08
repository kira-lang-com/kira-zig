// LLVM C-API backend.
//
// This is the successor to the textual-IR "writer" backend. Instead of emitting
// LLVM IR as formatted strings (where SSA register numbers, basic-block
// dominance, and ownership cleanup all have to be tracked by hand and are easy
// to get subtly wrong), this backend drives the LLVM C API directly: it holds
// real `LLVMValueRef`/`LLVMBasicBlockRef` handles, lets LLVM manage SSA, and
// runs the verifier on the in-memory module before emission.
//
// Coverage today is the scalar + control-flow + direct-call core (the compute
// surface of the language). Aggregates (structs, arrays, enums, closures,
// native state, FFI) are not lowered here yet and report a precise
// `error.UnsupportedExecutableFeature` so the caller can fall back to the text
// backend during the migration. The goal is to grow this to full parity and
// then retire the writer.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const backend_api = @import("kira_backend_api");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const runtime_symbols = @import("runtime_symbols.zig");
const codegen = @import("backend_capi_codegen.zig");
const dispatch = @import("backend_capi_dispatch.zig");
const drop = @import("backend_capi_drop.zig");
const closure_dtors = @import("backend_capi_closure_dtors.zig");
const enum_dtors = @import("backend_capi_enum_dtors.zig");
const dynamic_dtors = @import("backend_capi_dynamic_dtors.zig");
const ffi = @import("backend_capi_ffi.zig");

const functionExecutionById = utils.functionExecutionById;
const functionById = utils.functionById;
const resolveExecution = utils.resolveExecution;
const inferRegisterTypes = utils.inferRegisterTypes;
const allocPrintZ = utils.allocPrintZ;

pub const Lowered = struct {
    context: llvm.c.LLVMContextRef,
    module_ref: llvm.c.LLVMModuleRef,
};

fn dropEnabled() bool {
    // Owned-value drop elaboration is now ON by default (the C-API backend is the default
    // codegen path and must free owned values like the retired text writer did). Set
    // KIRA_CAPI_DROP=0 to opt out during the transition.
    const raw = std.c.getenv("KIRA_CAPI_DROP") orelse return true;
    const value = std.mem.span(raw);
    return value.len != 0 and value[0] != '0';
}

pub fn shouldLowerFunction(execution: runtime_abi.FunctionExecution, mode: backend_api.BackendMode) bool {
    return switch (mode) {
        .llvm_native => switch (execution) {
            .runtime => false,
            .inherited, .native => true,
        },
        .hybrid => execution == .native,
        .vm_bytecode => false,
    };
}

fn functionSymbolName(allocator: std.mem.Allocator, function_decl: ir.Function, mode: backend_api.BackendMode) ![:0]u8 {
    if (function_decl.is_extern) {
        if (function_decl.foreign) |foreign| return allocator.dupeZ(u8, foreign.symbol_name);
    }
    return switch (mode) {
        .llvm_native => allocPrintZ(allocator, "kira_fn_{d}_{s}", .{ function_decl.id, function_decl.name }),
        .hybrid => allocPrintZ(allocator, "kira_native_impl_{d}", .{function_decl.id}),
        .vm_bytecode => unreachable,
    };
}

// LLVM type + runtime-declaration scaffolding lives in backend_capi_types.zig
// (Core Law #5 split); re-export the public surface so callers keep using
// `capi.Types` / `capi.RuntimeDecls`.
const capi_types = @import("backend_capi_types.zig");
pub const Types = capi_types.Types;
pub const RuntimeDecls = capi_types.RuntimeDecls;

// Which parts of the program a single LLVM module should DEFINE. All modules
// DECLARE the full scaffold (runtime externs, struct types, dtor/dispatcher
// symbols, every user function) so that any body can reference any symbol; the
// plan only controls which BODIES are emitted and which functions/dispatchers are
// declared, so the emitted objects partition the program with no duplicate defs.
//
//   - Whole-program (default `.{}`): every user-function body + all support
//     bodies. This is the original, unchanged codegen path.
//   - Support CGU: `.{ .emit_bodies = <empty>, .emit_support = true }` — the
//     shared dtor/dispatcher bodies, host main, hybrid trampolines, no user bodies.
//   - Per-function CGU: `.{ .emit_bodies = {id}, .declare_functions = {id ∪
//     callees}, .emit_support = false }` — one user-function body; helpers referenced
//     as externs resolved against the support CGU at link time.
pub const ModulePlan = struct {
    /// User-function ids whose bodies to emit. `null` = every lowerable function
    /// (whole-program). An empty set emits no user bodies (support CGU).
    emit_bodies: ?*const std.AutoHashMapUnmanaged(u32, void) = null,
    /// Emit the shared support definitions (dtor/closure/enum/dynamic bodies,
    /// call_value dispatcher bodies, host main, hybrid trampolines). When false,
    /// those symbols are only declared, to be linked against the support CGU.
    emit_support: bool = true,
    /// User-function ids to DECLARE in this module. `null` declares every lowerable
    /// function (whole-program and the support CGU). A per-function CGU passes exactly
    /// the functions its body can look up during lowering (from
    /// `backend_capi_calls.collectBodyFunctionRefs`), so each module declares
    /// O(refs) functions instead of the whole program.
    declare_functions: ?*const std.AutoHashMapUnmanaged(u32, void) = null,

    fn emitsBody(self: ModulePlan, id: u32) bool {
        const set = self.emit_bodies orelse return true;
        return set.contains(id);
    }

    fn declares(self: ModulePlan, id: u32) bool {
        const set = self.declare_functions orelse return true;
        return set.contains(id);
    }
};

pub fn buildModule(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    request: backend_api.CompileRequest,
    triple: []const u8,
) !Lowered {
    return buildModulePlanned(allocator, api, request, triple, .{});
}

pub fn buildModulePlanned(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    request: backend_api.CompileRequest,
    triple: []const u8,
    plan: ModulePlan,
) !Lowered {
    const context = api.LLVMContextCreate();
    const module_name = try allocator.dupeZ(u8, request.module_name);
    defer allocator.free(module_name);
    const module_ref = api.LLVMModuleCreateWithNameInContext(module_name.ptr, context);
    const triple_z = try allocator.dupeZ(u8, triple);
    defer allocator.free(triple_z);
    api.LLVMSetTarget(module_ref, triple_z.ptr);

    const builder = api.LLVMCreateBuilderInContext(context);
    defer api.LLVMDisposeBuilder(builder);

    const types = Types.init(api, context);
    const runtime_decls = RuntimeDecls.declare(api, module_ref, types, request.mode);

    var struct_types = std.StringHashMapUnmanaged(llvm.c.LLVMTypeRef){};
    defer struct_types.deinit(allocator);
    try buildStructTypes(allocator, api, types, request.program.programPtr(), &struct_types);

    // The per-type destructor/clone helpers are always generated: the clone helpers
    // (kira_clone_contents_<T>) implement affine deep-copy in copy_indirect, which is the
    // DEFAULT value semantics for pure-Kira value structs regardless of drop. Owned-value
    // FREEING (the cleanup-slot driver, scope-exit drops) stays opt-in behind
    // KIRA_CAPI_DROP while it is validated; with drop off, the destroy helpers are simply
    // never called, so generating them is free of behavior change or double-free risk.
    const drop_enabled = dropEnabled();
    // Support CGU defines the dtor bodies; per-function CGUs only declare them.
    var dtors: drop.Destructors = try drop.build(allocator, api, module_ref, types, &struct_types, request.program.programPtr(), runtime_decls, request.mode, !plan.emit_support);
    defer dtors.deinit(allocator);

    // Shared helper BODIES belong to the support CGU only. Per-function CGUs
    // reference these symbols (already declared in `dtors`) as externs.
    if (plan.emit_support) {
        // Per-closure typed capture teardown/clone: build the kira_capi_closure_release /
        // kira_capi_closure_clone bodies (their declarations live in dtors) and, on the
        // native path with drop on, install the release as the kira_destroy_closure hook
        // via a global constructor so every owned-closure drop point frees captures too.
        {
            const shapes = try closure_dtors.collectShapes(allocator, request.program.programPtr());
            defer closure_dtors.freeShapes(allocator, shapes);
            try closure_dtors.build(
                allocator,
                api,
                module_ref,
                types,
                request.program.programPtr(),
                runtime_decls,
                &dtors,
                shapes,
                request.mode == .llvm_native and drop_enabled,
            );
        }

        // Typed enum destroy/clone bodies (string-payload boxes; declarations live
        // in dtors.enum_map, empty in hybrid).
        try enum_dtors.build(api, types, request.program.programPtr(), runtime_decls, &dtors);

        // Runtime-typed dynamic dispatchers for type-erased values and native-state
        // interiors (declarations live in dtors; referenced only on the native path).
        try dynamic_dtors.build(api, types, request.program.programPtr(), runtime_decls, &dtors);
    }

    // Declare one dispatcher function per distinct call_value signature; bodies are
    // generated after the concrete functions are declared.
    // Support CGU declares every dispatcher (its bodies live here); a per-function
    // CGU declares only the dispatchers its own emitted body calls.
    const dispatcher_sigs = try dispatch.collectCallValueDispatchersFiltered(
        allocator,
        request.program.programPtr().*,
        if (plan.emit_support) null else plan.emit_bodies,
    );
    defer allocator.free(dispatcher_sigs);
    var dispatchers = std.AutoHashMapUnmanaged(u64, dispatch.DispatcherDecl){};
    defer dispatchers.deinit(allocator);
    for (dispatcher_sigs) |sig| {
        const params = try allocator.alloc(llvm.c.LLVMTypeRef, sig.param_types.len + 1);
        defer allocator.free(params);
        params[0] = types.i64;
        for (sig.param_types, 0..) |pt, i| params[i + 1] = types.llvmType(pt);
        const fn_ty = api.LLVMFunctionType(types.llvmType(sig.return_type), params.ptr, @intCast(params.len), 0);
        const name = try dispatch.dispatcherSymbolName(allocator, sig.hash);
        defer allocator.free(name);
        const fn_value = api.LLVMAddFunction(module_ref, name.ptr, fn_ty);
        try dispatchers.put(allocator, sig.hash, .{ .fn_ty = fn_ty, .fn_value = fn_value });
    }

    var functions = std.AutoHashMapUnmanaged(u32, llvm.c.LLVMValueRef){};
    defer functions.deinit(allocator);

    // Distinct C symbols already declared as extern LLVM globals, keyed by symbol name.
    // Several `@FFI.Extern` declarations may bind the SAME C symbol with different Kira
    // signatures (the canonical case is `objc_msgSend`, which a from-scratch Metal/Cocoa
    // backend calls with many argument/return shapes). LLVM permits only one global per
    // symbol name; declaring the symbol twice makes LLVM rename the second to
    // `objc_msgSend.1`, which then fails to link. We declare each distinct C symbol once
    // and share that global across every Kira function that binds it. This is sound
    // because extern call sites supply their own per-callsite function type via
    // LLVMBuildCall2 (see backend_capi_ffi.lowerExternCall), independent of the global's
    // nominal type.
    var extern_symbols = std.StringHashMapUnmanaged(llvm.c.LLVMValueRef){};
    defer {
        var key_it = extern_symbols.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        extern_symbols.deinit(allocator);
    }

    for (request.program.programPtr().functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        // Per-function CGUs declare only the functions their body can reference
        // (collectBodyFunctionRefs); the support/whole-program module declares all.
        if (!plan.declares(function_decl.id)) continue;
        // Extern functions are real C symbols: declare them with their C ABI signature so
        // call sites (lowered through backend_capi_ffi) match the declaration.
        const function_ty = if (function_decl.is_extern)
            try ffi.externFunctionType(allocator, api, types, &struct_types, request.program.programPtr(), function_decl)
        else
            try types.functionType(allocator, function_decl);
        const name = try functionSymbolName(allocator, function_decl, request.mode);
        defer allocator.free(name);
        const function_value = if (function_decl.is_extern) blk: {
            if (extern_symbols.get(name)) |existing| break :blk existing;
            const declared = api.LLVMAddFunction(module_ref, name.ptr, function_ty);
            // Memory-returned struct: mark the hidden out-pointer param as sret so
            // LLVM uses the ABI's indirect-result register (x8 on arm64).
            if (ffi.usesSret(request.program.programPtr(), function_decl.return_type)) {
                if (function_decl.return_type.name) |ret_name| {
                    if (struct_types.get(ret_name)) |ret_struct_ty| {
                        ffi.addSretAttribute(api, context, ret_struct_ty, declared, false);
                    }
                }
            }
            try extern_symbols.put(allocator, try allocator.dupe(u8, name), declared);
            break :blk declared;
        } else api.LLVMAddFunction(module_ref, name.ptr, function_ty);
        if (request.mode == .hybrid and builtin.os.tag == .windows) {
            api.LLVMSetDLLStorageClass(function_value, llvm.c.LLVMDLLExportStorageClass);
        }
        try functions.put(allocator, function_decl.id, function_value);
    }

    for (request.program.programPtr().functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        if (function_decl.is_extern) continue;
        // Per-function CGUs emit only their own body; every other function stays a
        // declaration here and is resolved from its own object at link time.
        if (!plan.emitsBody(function_decl.id)) continue;
        const function_value = functions.get(function_decl.id) orelse return error.MissingFunctionDeclaration;
        var fc = codegen.FunctionCodegen{
            .allocator = allocator,
            .api = api,
            .builder = builder,
            .module_ref = module_ref,
            .types = types,
            .runtime_decls = runtime_decls,
            .struct_types = &struct_types,
            .dispatchers = &dispatchers,
            .dtors = &dtors,
            .drop_enabled = drop_enabled,
            .request = request,
            .functions = &functions,
            .function_decl = function_decl,
            .function_value = function_value,
        };
        try fc.lower();
    }

    // Dispatcher bodies, hybrid trampolines, and the host main are shared support
    // definitions: emitted once in the support CGU, declared-only elsewhere.
    if (plan.emit_support) {
        // Generate the dispatcher bodies now that all concrete functions exist.
        for (dispatcher_sigs) |sig| {
            const decl = dispatchers.get(sig.hash).?;
            try dispatch.buildDispatcher(allocator, api, builder, types, request, &functions, runtime_decls, &struct_types, sig, decl.fn_value);
        }

        // Hybrid mode: emit the kira_native_fn_{id} trampoline the VM calls for each
        // native function, wrapping the kira_native_impl_{id} body.
        if (request.mode == .hybrid) {
            for (request.program.programPtr().functions) |function_decl| {
                if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
                if (function_decl.is_extern) continue;
                const impl_fn = functions.get(function_decl.id) orelse return error.MissingFunctionDeclaration;
                const impl_ty = try types.functionType(allocator, function_decl);
                try dispatch.buildHybridTrampoline(allocator, api, builder, module_ref, types, &struct_types, runtime_decls.malloc, function_decl, impl_fn, impl_ty);
            }
        }

        if (request.mode == .llvm_native) {
            const entry_decl = request.program.programPtr().functions[request.program.programPtr().entry_index];
            if (!shouldLowerFunction(entry_decl.execution, request.mode)) return error.RuntimeEntrypointInNativeBuild;
            const entry_value = functions.get(entry_decl.id) orelse return error.MissingFunctionDeclaration;
            try buildHostMain(allocator, api, builder, module_ref, types, entry_decl, entry_value);
        }
    }

    if (std.c.getenv("KIRA_CAPI_DUMP") != null) {
        const text = api.LLVMPrintModuleToString(module_ref);
        defer api.LLVMDisposeMessage(text);
        std.debug.print("{s}\n", .{std.mem.span(text)});
    }
    try verifyModule(api, module_ref);
    return .{ .context = context, .module_ref = module_ref };
}

// Build a named LLVM struct type for every Kira struct/class declaration, mirroring
// backend_utils.appendTypeDefinitions. Two passes (create-named then set-body) so
// that fields referencing other (or the same) struct types resolve.
fn buildStructTypes(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    types: Types,
    program: *const ir.Program,
    out: *std.StringHashMapUnmanaged(llvm.c.LLVMTypeRef),
) !void {
    for (program.types) |type_decl| {
        if (type_decl.ffi) |ffi_info| {
            if (ffi_info != .ffi_struct) continue;
        }
        const name_z = try allocPrintZ(allocator, "t.{s}", .{type_decl.name});
        defer allocator.free(name_z);
        const struct_ty = api.LLVMStructCreateNamed(types.context, name_z.ptr);
        try out.put(allocator, type_decl.name, struct_ty);
    }
    for (program.types) |type_decl| {
        if (type_decl.ffi) |ffi_info| {
            if (ffi_info != .ffi_struct) continue;
        }
        const struct_ty = out.get(type_decl.name).?;
        if (type_decl.fields.len == 0) {
            var one = [_]llvm.c.LLVMTypeRef{types.i8};
            api.LLVMStructSetBody(struct_ty, &one, one.len, 0);
            continue;
        }
        const elements = try allocator.alloc(llvm.c.LLVMTypeRef, type_decl.fields.len);
        defer allocator.free(elements);
        for (type_decl.fields, 0..) |field_decl, index| {
            elements[index] = try fieldStorageType(types, out.*, program, field_decl.ty);
        }
        api.LLVMStructSetBody(struct_ty, elements.ptr, @intCast(elements.len), 0);
    }
}

// In-struct storage type for a field, mirroring backend_utils.llvmFieldAbiTypeText:
// bool is stored as i8 (i1 in registers), arrays/pointers/constructs as a raw ptr,
// nested ffi_struct fields are stored inline by value, strings as %kira.string.
pub fn fieldStorageType(
    types: Types,
    struct_types: std.StringHashMapUnmanaged(llvm.c.LLVMTypeRef),
    program: *const ir.Program,
    value_type: ir.ValueType,
) !llvm.c.LLVMTypeRef {
    return switch (value_type.kind) {
        .void => error.UnsupportedExecutableFeature,
        .string => types.string_ty,
        .boolean => types.i8,
        .integer => intStorageType(types, value_type.name),
        .float => if (value_type.name != null and std.mem.eql(u8, value_type.name.?, "F32")) types.float_ty else types.double_ty,
        .array => types.ptr_ty,
        .construct_any, .raw_ptr, .enum_instance => blk: {
            // An inline fixed FFI array (`@FFI.Array`) is laid out as `[count x element]`
            // and an FFI alias forwards to its target, mirroring the text backend's
            // llvmFieldAbiTypeText so the two backends agree on C struct layout.
            if (value_type.name) |name| {
                if (utils.findTypeDecl(program, name)) |type_decl| {
                    if (type_decl.ffi) |ffi_info| {
                        switch (ffi_info) {
                            .array => |info| {
                                const element_ty = try fieldStorageType(types, struct_types, program, info.element);
                                break :blk types.api.LLVMArrayType2(element_ty, info.count);
                            },
                            .alias => |info| break :blk try fieldStorageType(types, struct_types, program, info.target),
                            else => {},
                        }
                    }
                }
            }
            break :blk types.ptr_ty;
        },
        .ffi_struct => struct_types.get(value_type.name orelse return error.UnsupportedExecutableFeature) orelse error.UnsupportedExecutableFeature,
    };
}

fn intStorageType(types: Types, name: ?[]const u8) llvm.c.LLVMTypeRef {
    const n = name orelse return types.i64;
    if (std.mem.eql(u8, n, "I8") or std.mem.eql(u8, n, "U8")) return types.i8;
    if (std.mem.eql(u8, n, "I16") or std.mem.eql(u8, n, "U16")) return types.i16;
    if (std.mem.eql(u8, n, "I32") or std.mem.eql(u8, n, "U32")) return types.i32;
    return types.i64;
}

fn buildHostMain(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    module_ref: llvm.c.LLVMModuleRef,
    types: Types,
    entry_decl: ir.Function,
    entry_value: llvm.c.LLVMValueRef,
) !void {
    const main_ty = api.LLVMFunctionType(types.i32, null, 0, 0);
    const main_fn = api.LLVMAddFunction(module_ref, "main", main_ty);
    const entry_block = api.LLVMAppendBasicBlockInContext(types.context, main_fn, "entry");
    api.LLVMPositionBuilderAtEnd(builder, entry_block);
    const entry_fn_ty = try Types.functionType(types, allocator, entry_decl);
    _ = api.LLVMBuildCall2(builder, entry_fn_ty, entry_value, null, 0, "");
    _ = api.LLVMBuildRet(builder, api.LLVMConstInt(types.i32, 0, 0));
}

fn verifyModule(api: *const llvm.Api, module_ref: llvm.c.LLVMModuleRef) !void {
    var error_message: [*c]u8 = null;
    if (api.LLVMVerifyModule(module_ref, llvm.c.LLVMReturnStatusAction, &error_message) != 0) {
        defer if (error_message != null) api.LLVMDisposeMessage(error_message);
        if (error_message != null) std.debug.print("kira capi backend: invalid module:\n{s}\n", .{std.mem.span(error_message)});
        return error.InvalidLlvmModule;
    }
}
