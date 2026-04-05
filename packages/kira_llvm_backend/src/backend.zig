const std = @import("std");
const builtin = @import("builtin");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const backend_api = @import("kira_backend_api");
const build_options = @import("kira_llvm_build_options");
const llvm = @import("llvm_c.zig");
const toolchain = @import("toolchain.zig");
const linker = @import("link.zig");
const runtime_symbols = @import("runtime_symbols.zig");

pub fn compile(allocator: std.mem.Allocator, request: backend_api.CompileRequest) !backend_api.CompileResult {
    if (request.mode != .llvm_native and request.mode != .hybrid) return error.UnsupportedBackendMode;

    const triple = try hostTargetTriple(allocator);
    defer allocator.free(triple);

    if (builtin.os.tag == .macos) {
        return compileViaTextIr(allocator, request, triple);
    }

    const tc = try toolchain.Toolchain.discover(allocator);
    var api = try llvm.Api.open(tc);
    defer api.close();

    api.LLVMInitializeTargetInfo();
    api.LLVMInitializeTarget();
    api.LLVMInitializeTargetMC();
    api.LLVMInitializeAsmPrinter();
    if (api.LLVMInitializeAsmParser) |init| init();

    const target_machine = try createTargetMachine(allocator, &api, triple);
    defer api.LLVMDisposeTargetMachine(target_machine.machine);
    defer api.LLVMDisposeMessage(target_machine.cpu_features);
    defer api.LLVMDisposeMessage(target_machine.cpu_name);

    try ensureParentDir(request.emit.object_path);
    if (request.emit.executable_path) |path| try ensureParentDir(path);
    if (request.emit.shared_library_path) |path| try ensureParentDir(path);

    const lowered = try lowerProgram(allocator, &api, target_machine, request, triple);
    if (builtin.os.tag != .windows) {
        defer api.LLVMContextDispose(lowered.context);
        defer api.LLVMDisposeModule(lowered.module_ref);
    }

    try emitObjectFile(allocator, &api, target_machine.machine, lowered.module_ref, request.emit.object_path);

    var artifacts = std.array_list.Managed(backend_api.Artifact).init(allocator);
    try artifacts.append(.{
        .kind = .native_object,
        .path = try allocator.dupe(u8, request.emit.object_path),
    });

    if (request.emit.executable_path) |executable_path| {
        const bridge_object = try linker.buildRuntimeHelpersObject(allocator, request.emit.object_path);
        try linker.linkExecutable(allocator, executable_path, &.{ request.emit.object_path, bridge_object }, request.resolved_native_libraries);
        try artifacts.append(.{
            .kind = .executable,
            .path = try allocator.dupe(u8, executable_path),
        });
    }

    if (request.emit.shared_library_path) |library_path| {
        const bridge_object = try linker.buildRuntimeHelpersObject(allocator, request.emit.object_path);
        try linker.linkSharedLibrary(allocator, library_path, &.{ request.emit.object_path, bridge_object }, request.resolved_native_libraries);
        try artifacts.append(.{
            .kind = .native_library,
            .path = try allocator.dupe(u8, library_path),
        });
    }

    return .{ .artifacts = try artifacts.toOwnedSlice() };
}

fn compileViaTextIr(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    triple: []const u8,
) !backend_api.CompileResult {
    try ensureParentDir(request.emit.object_path);
    if (request.emit.executable_path) |path| try ensureParentDir(path);
    if (request.emit.shared_library_path) |path| try ensureParentDir(path);

    const ir_text = try buildTextLlvmIr(allocator, request, triple);
    defer allocator.free(ir_text);

    var owns_ir_path = false;
    const ir_path = if (request.emit.ir_path) |path|
        path
    else blk: {
        const temp_ir_path = try std.fmt.allocPrint(allocator, "{s}.ll", .{request.emit.object_path});
        owns_ir_path = true;
        break :blk temp_ir_path;
    };
    defer if (owns_ir_path) allocator.free(ir_path);

    try writeTextFile(ir_path, ir_text);
    try emitObjectFileFromIr(allocator, ir_path, request.emit.object_path);

    var artifacts = std.array_list.Managed(backend_api.Artifact).init(allocator);
    try artifacts.append(.{
        .kind = .native_object,
        .path = try allocator.dupe(u8, request.emit.object_path),
    });

    if (request.emit.executable_path) |executable_path| {
        const bridge_object = try linker.buildRuntimeHelpersObject(allocator, request.emit.object_path);
        try linker.linkExecutable(allocator, executable_path, &.{ request.emit.object_path, bridge_object }, request.resolved_native_libraries);
        try artifacts.append(.{
            .kind = .executable,
            .path = try allocator.dupe(u8, executable_path),
        });
    }

    if (request.emit.shared_library_path) |library_path| {
        const bridge_object = try linker.buildRuntimeHelpersObject(allocator, request.emit.object_path);
        try linker.linkSharedLibrary(allocator, library_path, &.{ request.emit.object_path, bridge_object }, request.resolved_native_libraries);
        try artifacts.append(.{
            .kind = .native_library,
            .path = try allocator.dupe(u8, library_path),
        });
    }

    return .{ .artifacts = try artifacts.toOwnedSlice() };
}

const TargetMachineInfo = struct {
    machine: llvm.c.LLVMTargetMachineRef,
    cpu_name: [*c]u8,
    cpu_features: [*c]u8,
};

fn createTargetMachine(allocator: std.mem.Allocator, api: *const llvm.Api, triple: []const u8) !TargetMachineInfo {
    const triple_z = try allocator.dupeZ(u8, triple);
    var target_ref: llvm.c.LLVMTargetRef = undefined;
    var target_error: [*c]u8 = null;
    if (api.LLVMGetTargetFromTriple(triple_z.ptr, &target_ref, &target_error) != 0) {
        defer if (target_error != null) api.LLVMDisposeMessage(target_error);
        return error.TargetLookupFailed;
    }

    const cpu_name = api.LLVMGetHostCPUName();
    const cpu_features = api.LLVMGetHostCPUFeatures();

    const machine = api.LLVMCreateTargetMachine(
        target_ref,
        triple_z.ptr,
        cpu_name,
        cpu_features,
        llvm.c.LLVMCodeGenLevelDefault,
        llvm.c.LLVMRelocDefault,
        llvm.c.LLVMCodeModelDefault,
    ) orelse return error.TargetMachineCreationFailed;

    return .{
        .machine = machine,
        .cpu_name = cpu_name,
        .cpu_features = cpu_features,
    };
}

const LoweredModule = struct {
    context: llvm.c.LLVMContextRef,
    module_ref: llvm.c.LLVMModuleRef,
};

const Types = struct {
    api: *const llvm.Api,
    context: llvm.c.LLVMContextRef,
    bool_ty: llvm.c.LLVMTypeRef,
    i8: llvm.c.LLVMTypeRef,
    i32: llvm.c.LLVMTypeRef,
    i64: llvm.c.LLVMTypeRef,
    usize_ty: llvm.c.LLVMTypeRef,
    void_ty: llvm.c.LLVMTypeRef,
    ptr_ty: llvm.c.LLVMTypeRef,
    string_ty: llvm.c.LLVMTypeRef,

    fn init(api: *const llvm.Api, context: llvm.c.LLVMContextRef) Types {
        const ptr_ty = api.LLVMPointerTypeInContext(context, 0);
        const usize_ty = api.LLVMInt64TypeInContext(context);
        var string_fields = [_]llvm.c.LLVMTypeRef{ ptr_ty, usize_ty };
        return .{
            .api = api,
            .context = context,
            .bool_ty = api.LLVMInt1TypeInContext(context),
            .i8 = api.LLVMInt8TypeInContext(context),
            .i32 = api.LLVMInt32TypeInContext(context),
            .i64 = api.LLVMInt64TypeInContext(context),
            .usize_ty = usize_ty,
            .void_ty = api.LLVMVoidTypeInContext(context),
            .ptr_ty = ptr_ty,
            .string_ty = api.LLVMStructTypeInContext(context, &string_fields, string_fields.len, 0),
        };
    }

    fn llvmType(self: Types, value_type: ir.ValueType) llvm.c.LLVMTypeRef {
        return switch (value_type.kind) {
            .void => self.void_ty,
            .integer => self.i64,
            .float => self.api.LLVMFloatTypeInContext(self.context),
            .string => self.string_ty,
            .boolean => self.bool_ty,
            .raw_ptr, .ffi_struct => self.usize_ty,
        };
    }

    fn voidFunctionType(self: Types) llvm.c.LLVMTypeRef {
        return self.api.LLVMFunctionType(self.void_ty, null, 0, 0);
    }
};

const RuntimeDecls = struct {
    print_i64_ty: llvm.c.LLVMTypeRef,
    print_i64_fn: llvm.c.LLVMValueRef,
    print_string_ty: llvm.c.LLVMTypeRef,
    print_string_fn: llvm.c.LLVMValueRef,
    call_runtime_ty: ?llvm.c.LLVMTypeRef,
    call_runtime_fn: ?llvm.c.LLVMValueRef,
};

fn declareRuntime(api: *const llvm.Api, module_ref: llvm.c.LLVMModuleRef, types: Types, mode: backend_api.BackendMode) RuntimeDecls {
    var int_args = [_]llvm.c.LLVMTypeRef{types.i64};
    const print_i64_ty = api.LLVMFunctionType(types.void_ty, &int_args, int_args.len, 0);

    var string_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.usize_ty };
    const print_string_ty = api.LLVMFunctionType(types.void_ty, &string_args, string_args.len, 0);

    var call_runtime_args = [_]llvm.c.LLVMTypeRef{types.i32};
    const call_runtime_ty = if (mode == .hybrid) api.LLVMFunctionType(types.void_ty, &call_runtime_args, call_runtime_args.len, 0) else null;

    return .{
        .print_i64_ty = print_i64_ty,
        .print_i64_fn = api.LLVMAddFunction(module_ref, runtime_symbols.print_i64, print_i64_ty),
        .print_string_ty = print_string_ty,
        .print_string_fn = api.LLVMAddFunction(module_ref, runtime_symbols.print_string, print_string_ty),
        .call_runtime_ty = call_runtime_ty,
        .call_runtime_fn = if (call_runtime_ty) |value| api.LLVMAddFunction(module_ref, runtime_symbols.call_runtime, value) else null,
    };
}

fn lowerProgram(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    target_machine: TargetMachineInfo,
    request: backend_api.CompileRequest,
    triple: []const u8,
) !LoweredModule {
    _ = target_machine;
    const context = api.LLVMContextCreate();
    const module_name = try allocator.dupeZ(u8, request.module_name);
    const module_ref = api.LLVMModuleCreateWithNameInContext(module_name.ptr, context);
    api.LLVMSetTarget(module_ref, try allocator.dupeZ(u8, triple));

    const builder = api.LLVMCreateBuilderInContext(context);
    defer api.LLVMDisposeBuilder(builder);

    const types = Types.init(api, context);
    const runtime_decls = declareRuntime(api, module_ref, types, request.mode);

    var functions = std.AutoHashMapUnmanaged(u32, llvm.c.LLVMValueRef){};
    defer functions.deinit(allocator);

    for (request.program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        const function_value = try declareFunction(allocator, api, module_ref, function_decl, request.mode, types);
        try functions.put(allocator, function_decl.id, function_value);
    }

    for (request.program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        const function_value = functions.get(function_decl.id) orelse return error.MissingFunctionDeclaration;
        try lowerFunction(allocator, api, builder, module_ref, types, runtime_decls, request, &functions, function_decl, function_value);
    }

    if (request.mode == .llvm_native) {
        const entry_decl = request.program.functions[request.program.entry_index];
        if (!shouldLowerFunction(entry_decl.execution, request.mode)) return error.RuntimeEntrypointInNativeBuild;
        const entry_function = functions.get(entry_decl.id) orelse return error.MissingFunctionDeclaration;
        try buildHostMain(api, builder, module_ref, types, entry_function);
    }

    try verifyModule(api, module_ref);
    return .{ .context = context, .module_ref = module_ref };
}

fn shouldLowerFunction(execution: runtime_abi.FunctionExecution, mode: backend_api.BackendMode) bool {
    return switch (mode) {
        .llvm_native => switch (execution) {
            .runtime => false,
            .inherited, .native => true,
        },
        .hybrid => execution == .native,
        .vm_bytecode => false,
    };
}

fn declareFunction(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    function_decl: ir.Function,
    mode: backend_api.BackendMode,
    types: Types,
) !llvm.c.LLVMValueRef {
    const function_ty = types.voidFunctionType();
    const name = try functionSymbolName(allocator, function_decl, mode);
    const function_value = api.LLVMAddFunction(module_ref, name.ptr, function_ty);
    if (mode == .hybrid and builtin.os.tag == .windows) {
        api.LLVMSetDLLStorageClass(function_value, llvm.c.LLVMDLLExportStorageClass);
    }
    return function_value;
}

fn functionSymbolName(allocator: std.mem.Allocator, function_decl: ir.Function, mode: backend_api.BackendMode) ![:0]u8 {
    if (function_decl.is_extern) {
        if (function_decl.foreign) |foreign| {
            return allocator.dupeZ(u8, foreign.symbol_name);
        }
    }
    return switch (mode) {
        .llvm_native => allocPrintZ(allocator, "kira_fn_{d}_{s}", .{ function_decl.id, function_decl.name }),
        .hybrid => allocPrintZ(allocator, "kira_native_impl_{d}", .{function_decl.id}),
        .vm_bytecode => unreachable,
    };
}

fn lowerFunction(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    module_ref: llvm.c.LLVMModuleRef,
    types: Types,
    runtime_decls: RuntimeDecls,
    request: backend_api.CompileRequest,
    functions: *const std.AutoHashMapUnmanaged(u32, llvm.c.LLVMValueRef),
    function_decl: ir.Function,
    function_value: llvm.c.LLVMValueRef,
) !void {
    const entry_block = api.LLVMAppendBasicBlockInContext(types.context, function_value, "entry");
    api.LLVMPositionBuilderAtEnd(builder, entry_block);

    const register_types = try inferRegisterTypes(allocator, function_decl);
    const register_values = try allocator.alloc(llvm.c.LLVMValueRef, function_decl.register_count);
    const locals = try allocator.alloc(llvm.c.LLVMValueRef, function_decl.local_count);

    for (function_decl.local_types, 0..) |local_type, index| {
        locals[index] = api.LLVMBuildAlloca(builder, types.llvmType(local_type), "local");
    }

    var string_counter: usize = 0;
    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int => |value| register_values[value.dst] = api.LLVMConstInt(types.i64, @bitCast(@as(u64, @intCast(value.value))), 1),
            .const_string => |value| {
                register_values[value.dst] = try buildStringConstant(allocator, api, module_ref, types, value.value, string_counter);
                string_counter += 1;
            },
            .const_bool => |value| register_values[value.dst] = api.LLVMConstInt(types.bool_ty, if (value.value) 1 else 0, 0),
            .const_null_ptr => |value| register_values[value.dst] = api.LLVMConstInt(types.usize_ty, 0, 0),
            .const_function => |_| return error.UnsupportedExecutableFeature,
            .add => |value| register_values[value.dst] = api.LLVMBuildAdd(builder, register_values[value.lhs], register_values[value.rhs], "add"),
            .store_local => |value| _ = api.LLVMBuildStore(builder, register_values[value.src], locals[value.local]),
            .load_local => |value| register_values[value.dst] = api.LLVMBuildLoad2(builder, types.llvmType(function_decl.local_types[value.local]), locals[value.local], "load"),
            .field_ptr, .load_indirect, .store_indirect, .copy_indirect => return error.UnsupportedExecutableFeature,
            .print => |value| try lowerPrint(api, builder, runtime_decls, register_types[value.src], register_values[value.src]),
            .call => |value| {
                if (value.args.len != 0 or value.dst != null) return error.UnsupportedExecutableFeature;
                try lowerCall(api, builder, types, runtime_decls, request.mode, request.program, functions, value.callee);
            },
            .ret => |value| {
                if (value.src != null) return error.UnsupportedExecutableFeature;
                _ = api.LLVMBuildRetVoid(builder);
                return;
            },
        }
    }

    _ = api.LLVMBuildRetVoid(builder);
}

fn lowerCall(
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    types: Types,
    runtime_decls: RuntimeDecls,
    mode: backend_api.BackendMode,
    program: *const ir.Program,
    functions: *const std.AutoHashMapUnmanaged(u32, llvm.c.LLVMValueRef),
    callee_id: u32,
) !void {
    const callee_execution = functionExecutionById(program.*, callee_id) orelse return error.UnknownFunction;
    switch (resolveExecution(callee_execution, mode)) {
        .native => {
            const callee_fn = functions.get(callee_id) orelse return error.MissingFunctionDeclaration;
            const fn_ty = types.voidFunctionType();
            _ = api.LLVMBuildCall2(builder, fn_ty, callee_fn, null, 0, "");
        },
        .runtime => {
            if (mode != .hybrid) return error.RuntimeCallInNativeBuild;
            var args = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i32, callee_id, 0)};
            _ = api.LLVMBuildCall2(builder, runtime_decls.call_runtime_ty.?, runtime_decls.call_runtime_fn.?, &args, args.len, "");
        },
        .inherited => unreachable,
    }
}

fn buildStringConstant(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    types: Types,
    value: []const u8,
    index: usize,
) !llvm.c.LLVMValueRef {
    const global_name = try allocPrintZ(allocator, ".kira.str.{d}", .{index});
    const array_ty = api.LLVMArrayType2(types.i8, value.len + 1);
    const global = api.LLVMAddGlobal(module_ref, array_ty, global_name.ptr);
    api.LLVMSetLinkage(global, llvm.c.LLVMPrivateLinkage);
    api.LLVMSetGlobalConstant(global, 1);
    api.LLVMSetInitializer(global, api.LLVMConstStringInContext2(types.context, value.ptr, value.len, 0));

    const zero = api.LLVMConstInt(types.i32, 0, 0);
    var indices = [_]llvm.c.LLVMValueRef{ zero, zero };
    const data_ptr = api.LLVMConstInBoundsGEP2(array_ty, global, &indices, indices.len);
    const length = api.LLVMConstInt(types.usize_ty, value.len, 0);
    var fields = [_]llvm.c.LLVMValueRef{ data_ptr, length };
    return api.LLVMConstNamedStruct(types.string_ty, &fields, fields.len);
}

fn lowerPrint(
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    runtime_decls: RuntimeDecls,
    value_type: ir.ValueType,
    value_ref: llvm.c.LLVMValueRef,
) !void {
    switch (value_type.kind) {
        .integer => {
            var args = [_]llvm.c.LLVMValueRef{value_ref};
            _ = api.LLVMBuildCall2(builder, runtime_decls.print_i64_ty, runtime_decls.print_i64_fn, &args, args.len, "");
        },
        .string => {
            const data_ptr = api.LLVMBuildExtractValue(builder, value_ref, 0, "str.ptr");
            const length = api.LLVMBuildExtractValue(builder, value_ref, 1, "str.len");
            var args = [_]llvm.c.LLVMValueRef{ data_ptr, length };
            _ = api.LLVMBuildCall2(builder, runtime_decls.print_string_ty, runtime_decls.print_string_fn, &args, args.len, "");
        },
        .void, .float, .boolean, .raw_ptr, .ffi_struct => return error.UnsupportedExecutableFeature,
    }
}

fn buildHostMain(
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    module_ref: llvm.c.LLVMModuleRef,
    types: Types,
    entry_function: llvm.c.LLVMValueRef,
) !void {
    const main_ty = api.LLVMFunctionType(types.i32, null, 0, 0);
    const main_fn = api.LLVMAddFunction(module_ref, "main", main_ty);
    const entry_block = api.LLVMAppendBasicBlockInContext(types.context, main_fn, "entry");
    api.LLVMPositionBuilderAtEnd(builder, entry_block);

    const entry_fn_ty = types.voidFunctionType();
    _ = api.LLVMBuildCall2(builder, entry_fn_ty, entry_function, null, 0, "");
    _ = api.LLVMBuildRet(builder, api.LLVMConstInt(types.i32, 0, 0));
}

fn verifyModule(api: *const llvm.Api, module_ref: llvm.c.LLVMModuleRef) !void {
    var error_message: [*c]u8 = null;
    if (api.LLVMVerifyModule(module_ref, llvm.c.LLVMReturnStatusAction, &error_message) != 0) {
        defer if (error_message != null) api.LLVMDisposeMessage(error_message);
        return error.InvalidLlvmModule;
    }
}

fn emitObjectFile(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    machine: llvm.c.LLVMTargetMachineRef,
    module_ref: llvm.c.LLVMModuleRef,
    object_path: []const u8,
) !void {
    if (builtin.os.tag == .macos) {
        return emitObjectFileViaZigCc(allocator, api, module_ref, object_path);
    }

    const object_path_z = try allocator.dupeZ(u8, object_path);
    var error_message: [*c]u8 = null;
    if (api.LLVMTargetMachineEmitToFile(machine, module_ref, object_path_z.ptr, llvm.c.LLVMObjectFile, &error_message) != 0) {
        defer if (error_message != null) api.LLVMDisposeMessage(error_message);
        return error.ObjectEmissionFailed;
    }
}

fn emitObjectFileFromIr(
    allocator: std.mem.Allocator,
    ir_path: []const u8,
    object_path: []const u8,
) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ build_options.zig_exe, "cc", "-c", "-o", object_path, ir_path },
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ObjectEmissionFailed;
    }
}

fn buildTextLlvmIr(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    triple: []const u8,
) ![]u8 {
    var globals = std.array_list.Managed([]const u8).init(allocator);
    defer freeStringList(allocator, &globals);

    var symbol_names = std.AutoHashMapUnmanaged(u32, []const u8){};
    defer freeSymbolNames(allocator, &symbol_names);

    for (request.program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        const name = try functionSymbolName(allocator, function_decl, request.mode);
        try symbol_names.put(allocator, function_decl.id, name);
    }

    var function_bodies = std.array_list.Managed([]const u8).init(allocator);
    defer freeStringList(allocator, &function_bodies);
    var function_decls = std.array_list.Managed([]const u8).init(allocator);
    defer freeStringList(allocator, &function_decls);

    var string_counter: usize = 0;
    for (request.program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        if (function_decl.is_extern) {
            try function_decls.append(try buildTextExternDecl(allocator, request, &symbol_names, function_decl));
        } else {
            const body = try buildTextFunctionBody(allocator, request, &symbol_names, &globals, function_decl, string_counter);
            string_counter += countStringConstants(function_decl);
            try function_bodies.append(body);
        }
    }

    if (request.mode == .llvm_native) {
        const entry_decl = request.program.functions[request.program.entry_index];
        if (!shouldLowerFunction(entry_decl.execution, request.mode)) return error.RuntimeEntrypointInNativeBuild;
        const entry_function_name = symbol_names.get(entry_decl.id) orelse return error.MissingFunctionDeclaration;
        const main_body = try buildTextMainBody(allocator, entry_function_name);
        try function_bodies.append(main_body);
    }

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var writer = output.writer();
    try writer.print("; ModuleID = \"{s}\"\n", .{request.module_name});
    try writer.print("source_filename = \"{s}\"\n", .{request.module_name});
    try writer.print("target triple = \"{s}\"\n\n", .{triple});
    try appendTypeDefinitions(allocator, &writer, request.program);
    try writer.writeAll("%kira.string = type { ptr, i64 }\n\n");
    if (request.mode == .hybrid) {
        try writer.writeAll("%kira.bridge.value = type { i8, [7 x i8], i64, i64 }\n\n");
    }

    try writer.writeAll("declare void @\"kira_native_print_i64\"(i64)\n");
    try writer.writeAll("declare void @\"kira_native_print_string\"(ptr, i64)\n");
    if (request.mode == .hybrid) {
        try writer.writeAll("declare void @\"kira_hybrid_call_runtime\"(i32, ptr, i32, ptr)\n");
    }
    for (function_decls.items) |decl| {
        try writer.writeAll(decl);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');

    if (function_bodies.items.len > 0) try writer.writeByte('\n');

    for (globals.items) |global_def| {
        try writer.writeAll(global_def);
        try writer.writeByte('\n');
    }

    if (globals.items.len > 0 and function_bodies.items.len > 0) {
        try writer.writeByte('\n');
    }

    for (function_bodies.items) |body| {
        try writer.writeAll(body);
        try writer.writeByte('\n');
    }

    if (request.mode == .hybrid) {
        for (request.program.functions) |function_decl| {
            if (!shouldLowerFunction(function_decl.execution, request.mode) or function_decl.is_extern) continue;
            try writer.writeAll(try buildHybridBridgeWrapper(allocator, &symbol_names, function_decl));
            try writer.writeByte('\n');
        }
    }

    return output.toOwnedSlice();
}

fn buildTextFunctionBody(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    globals: *std.array_list.Managed([]const u8),
    function_decl: ir.Function,
    string_counter: usize,
) ![]const u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();

    var writer = body.writer();
    const function_name = symbol_names.get(function_decl.id) orelse return error.MissingFunctionDeclaration;
    try writer.writeAll("define ");
    try writer.writeAll(llvmValueTypeText(function_decl.return_type));
    try writer.writeByte(' ');
    try writeLlvmSymbol(writer, function_name);
    try writer.writeByte('(');
    for (function_decl.param_types, 0..) |param_type, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(llvmValueTypeText(param_type));
        try writer.writeAll(" %arg");
        try writer.print("{d}", .{index});
    }
    try writer.writeAll(") {\nentry:\n");

    const register_types = try inferRegisterTypes(allocator, request.program.*, function_decl);
    defer allocator.free(register_types);

    const string_state = try allocator.alloc(usize, 1);
    defer allocator.free(string_state);
    string_state[0] = string_counter;
    var temp_counter: usize = 0;

    for (function_decl.local_types, 0..) |local_type, index| {
        const storage_type = try llvmLocalStorageTypeText(allocator, request.program, local_type);
        try writer.writeAll("  %local");
        try writer.print("{d}", .{index});
        try writer.writeAll(" = alloca ");
        try writer.writeAll(storage_type);
        try writer.writeAll("\n");
        if (local_type.kind == .ffi_struct) {
            try writer.print("  store {s} zeroinitializer, ptr %local{d}\n", .{ storage_type, index });
        }
    }
    for (function_decl.param_types, 0..) |param_type, index| {
        try writer.writeAll("  store ");
        try writer.writeAll(llvmValueTypeText(param_type));
        try writer.writeAll(" %arg");
        try writer.print("{d}", .{index});
        try writer.writeAll(", ptr %local");
        try writer.print("{d}\n", .{index});
    }

    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = add i64 0, ");
                try writer.print("{d}\n", .{value.value});
            },
            .const_string => |value| {
                const string_index = string_state[0];
                string_state[0] += 1;
                try appendStringGlobals(allocator, globals, string_index, value.value);

                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = load %kira.string, ptr @kira_str_");
                try writer.print("{d}", .{string_index});
                try writer.writeAll("\n");
            },
            .const_bool => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = add i1 0, ");
                try writer.writeAll(if (value.value) "1\n" else "0\n");
            },
            .const_null_ptr => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = add i64 0, 0\n");
            },
            .const_function => |value| {
                const callee_decl = functionById(request.program.*, value.function_id) orelse return error.UnknownFunction;
                const callee_name = symbol_names.get(callee_decl.id) orelse return error.MissingFunctionDeclaration;
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = ptrtoint ptr ");
                try writeLlvmSymbol(writer, callee_name);
                try writer.writeAll(" to i64\n");
            },
            .add => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = add i64 %r");
                try writer.print("{d}", .{value.lhs});
                try writer.writeAll(", %r");
                try writer.print("{d}\n", .{value.rhs});
            },
            .store_local => |value| {
                try writer.writeAll("  store ");
                try writer.writeAll(llvmValueTypeText(register_types[value.src]));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.src});
                try writer.writeAll(", ptr %local");
                try writer.print("{d}\n", .{value.local});
            },
            .load_local => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                if (function_decl.local_types[value.local].kind == .ffi_struct) {
                    try writer.writeAll(" = ptrtoint ptr %local");
                    try writer.print("{d}", .{value.local});
                    try writer.writeAll(" to i64\n");
                } else {
                    try writer.writeAll(" = load ");
                    try writer.writeAll(llvmValueTypeText(function_decl.local_types[value.local]));
                    try writer.writeAll(", ptr %local");
                    try writer.print("{d}\n", .{value.local});
                }
            },
            .field_ptr => |value| {
                const field_index_value = fieldIndex(request.program, value.owner_type_name, value.field_name) orelse return error.UnknownFunction;
                const owner_type = fieldType(request.program, value.owner_type_name, value.field_name) orelse return error.UnknownFunction;
                _ = owner_type;
                const struct_type_name = typeRefName(value.owner_type_name);
                try writer.print("  %field.base.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.base });
                try writer.writeAll("  %field.ptr.");
                try writer.print("{d}", .{value.dst});
                try writer.print(" = getelementptr inbounds {s}, ptr %field.base.{d}, i32 0, i32 {d}\n", .{ struct_type_name, value.dst, field_index_value });
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = ptrtoint ptr %field.ptr.");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" to i64\n");
            },
            .load_indirect => |value| {
                const abi_type = try llvmIndirectLoadTypeText(allocator, request.program, value.ty);
                try writer.print("  %load.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.ptr });
                switch (value.ty.kind) {
                    .integer => {
                        try writer.print("  %load.raw.{d} = load {s}, ptr %load.ptr.{d}\n", .{ value.dst, abi_type, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        if (std.mem.eql(u8, abi_type, "i8") or std.mem.eql(u8, abi_type, "i16") or std.mem.eql(u8, abi_type, "i32")) {
                            try writer.print(" = sext {s} %load.raw.{d} to i64\n", .{ abi_type, value.dst });
                        } else {
                            try writer.print(" = load i64, ptr %load.ptr.{d}\n", .{value.dst});
                        }
                    },
                    .boolean => {
                        try writer.print("  %load.raw.{d} = load i8, ptr %load.ptr.{d}\n", .{ value.dst, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = trunc i8 %load.raw.{d} to i1\n", .{value.dst});
                    },
                    .raw_ptr => {
                        try writer.print("  %load.rawptr.{d} = load ptr, ptr %load.ptr.{d}\n", .{ value.dst, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = ptrtoint ptr %load.rawptr.{d} to i64\n", .{value.dst});
                    },
                    .ffi_struct => {
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = add i64 %r{d}, 0\n", .{value.ptr});
                    },
                    else => return error.UnsupportedExecutableFeature,
                }
            },
            .store_indirect => |value| {
                const abi_type = try llvmIndirectLoadTypeText(allocator, request.program, value.ty);
                try writer.print("  %store.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src, value.ptr });
                switch (value.ty.kind) {
                    .integer => {
                        if (std.mem.eql(u8, abi_type, "i64")) {
                            try writer.print("  store i64 %r{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        } else {
                            try writer.print("  %store.cast.{d} = trunc i64 %r{d} to {s}\n", .{ value.src, value.src, abi_type });
                            try writer.print("  store {s} %store.cast.{d}, ptr %store.ptr.{d}\n", .{ abi_type, value.src, value.src });
                        }
                    },
                    .boolean => {
                        try writer.print("  %store.bool.{d} = zext i1 %r{d} to i8\n", .{ value.src, value.src });
                        try writer.print("  store i8 %store.bool.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                    },
                    .raw_ptr => {
                        if (value.ty.name != null and std.mem.eql(u8, value.ty.name.?, "CString") and register_types[value.src].kind == .string) {
                            try writer.print("  %store.cstr.{d} = extractvalue %kira.string %r{d}, 0\n", .{ value.src, value.src });
                            try writer.print("  store ptr %store.cstr.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        } else {
                            try writer.print("  %store.rawptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src, value.src });
                            try writer.print("  store ptr %store.rawptr.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        }
                    },
                    else => return error.UnsupportedExecutableFeature,
                }
            },
            .copy_indirect => |value| {
                const struct_type_name = typeRefName(value.type_name);
                try writer.print("  %copy.dst.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst_ptr, value.dst_ptr });
                try writer.print("  %copy.src.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src_ptr, value.src_ptr });
                try writer.print("  %copy.val.{d} = load {s}, ptr %copy.src.{d}\n", .{ value.dst_ptr, struct_type_name, value.src_ptr });
                try writer.print("  store {s} %copy.val.{d}, ptr %copy.dst.{d}\n", .{ struct_type_name, value.dst_ptr, value.dst_ptr });
            },
            .print => |value| {
                try writePrintInstruction(writer, register_types[value.src], value.src, &temp_counter);
            },
            .call => |value| {
                try writeCallInstruction(writer, request, symbol_names, request.program, register_types, value);
            },
            .ret => |value| {
                if (value.src) |src| {
                    try writer.writeAll("  ret ");
                    try writer.writeAll(llvmValueTypeText(function_decl.return_type));
                    try writer.writeAll(" %r");
                    try writer.print("{d}", .{src});
                    try writer.writeAll("\n}\n");
                } else {
                    try writer.writeAll("  ret void\n}\n");
                }
                return body.toOwnedSlice();
            },
        }
    }

    try writer.writeAll("  ret void\n}\n");
    return body.toOwnedSlice();
}

fn buildTextMainBody(
    allocator: std.mem.Allocator,
    entry_function_name: []const u8,
) ![]const u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();

    var writer = body.writer();
    try writer.writeAll("define i32 @main() {\nentry:\n");
    try writer.writeAll("  call void ");
    try writeLlvmSymbol(writer, entry_function_name);
    try writer.writeAll("()\n  ret i32 0\n}\n");
    return body.toOwnedSlice();
}

fn writeCallInstruction(
    writer: anytype,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    program: *const ir.Program,
    register_types: []const ir.ValueType,
    call_inst: ir.Call,
) !void {
    const callee_id = call_inst.callee;
    const callee_decl = functionById(program.*, callee_id) orelse return error.UnknownFunction;
    const callee_execution = functionExecutionById(request.program.*, callee_id) orelse return error.UnknownFunction;
    switch (resolveExecution(callee_execution, request.mode)) {
        .native => {
            const callee_name = symbol_names.get(callee_id) orelse return error.MissingFunctionDeclaration;
            if (callee_decl.is_extern) {
                for (call_inst.args, 0..) |arg, index| {
                    const param_type = callee_decl.param_types[index];
                    switch (param_type.kind) {
                        .raw_ptr => {
                            if (register_types[arg].kind == .string and param_type.name != null and std.mem.eql(u8, param_type.name.?, "CString")) {
                                try writer.print("  %call.arg.{d}.{d} = extractvalue %kira.string %r{d}, 0\n", .{ callee_id, index, arg });
                            } else {
                                try writer.print("  %call.arg.{d}.{d} = inttoptr i64 %r{d} to ptr\n", .{ callee_id, index, arg });
                            }
                        },
                        .integer => {
                            const abi_type = integerAbiTypeName(param_type.name);
                            if (!std.mem.eql(u8, abi_type, "i64")) {
                                try writer.print("  %call.arg.{d}.{d} = trunc i64 %r{d} to {s}\n", .{ callee_id, index, arg, abi_type });
                            }
                        },
                        .ffi_struct => {
                            const struct_type_name = typeRefName(param_type.name orelse return error.UnsupportedExecutableFeature);
                            try writer.print("  %call.arg.ptr.{d}.{d} = inttoptr i64 %r{d} to ptr\n", .{ callee_id, index, arg });
                            try writer.print("  %call.arg.{d}.{d} = load {s}, ptr %call.arg.ptr.{d}.{d}\n", .{
                                callee_id, index, struct_type_name, callee_id, index,
                            });
                        },
                        else => {},
                    }
                }
            }
            if (call_inst.dst) |dst| {
                if (callee_decl.is_extern and callee_decl.return_type.kind == .raw_ptr) {
                    try writer.writeAll("  %call.ptr.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = call ptr ");
                } else if (callee_decl.is_extern and callee_decl.return_type.kind == .ffi_struct) {
                    try writer.writeAll("  %call.struct.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = call ");
                } else {
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = call ");
                }
            } else {
                try writer.writeAll("  call ");
            }
            if (!(callee_decl.is_extern and (callee_decl.return_type.kind == .raw_ptr) and call_inst.dst != null)) {
                try writer.writeAll(llvmCallTypeText(callee_decl.return_type, callee_decl.is_extern));
                try writer.writeByte(' ');
            }
            try writeLlvmSymbol(writer, callee_name);
            try writer.writeByte('(');
            for (call_inst.args, 0..) |arg, index| {
                if (index != 0) try writer.writeAll(", ");
                const param_type = callee_decl.param_types[index];
                try writer.writeAll(llvmCallTypeText(param_type, callee_decl.is_extern));
                try writer.writeByte(' ');
                if (callee_decl.is_extern) {
                    switch (param_type.kind) {
                        .raw_ptr, .ffi_struct => {
                            try writer.writeAll("%call.arg.");
                            try writer.print("{d}.{d}", .{ callee_id, index });
                        },
                        .integer => {
                            const abi_type = integerAbiTypeName(param_type.name);
                            if (std.mem.eql(u8, abi_type, "i64")) {
                                try writer.writeAll("%r");
                                try writer.print("{d}", .{arg});
                            } else {
                                try writer.writeAll("%call.arg.");
                                try writer.print("{d}.{d}", .{ callee_id, index });
                            }
                        },
                        else => {
                            try writer.writeAll("%r");
                            try writer.print("{d}", .{arg});
                        },
                    }
                } else {
                    try writer.writeAll("%r");
                    try writer.print("{d}", .{arg});
                }
            }
            try writer.writeAll(")\n");
            if (callee_decl.is_extern and callee_decl.return_type.kind == .raw_ptr) {
                if (call_inst.dst) |dst| {
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = ptrtoint ptr %call.ptr.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" to i64\n");
                }
            } else if (callee_decl.is_extern and callee_decl.return_type.kind == .ffi_struct) {
                if (call_inst.dst) |dst| {
                    const struct_type_name = typeRefName(callee_decl.return_type.name orelse return error.UnsupportedExecutableFeature);
                    try writer.print("  %call.ret.ptr.{d} = alloca {s}\n", .{ dst, struct_type_name });
                    try writer.print("  store {s} %call.struct.{d}, ptr %call.ret.ptr.{d}\n", .{ struct_type_name, dst, dst });
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = ptrtoint ptr %call.ret.ptr.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" to i64\n");
                }
            } else if (callee_decl.is_extern and callee_decl.return_type.kind == .integer and call_inst.dst != null) {
                const abi_type = integerAbiTypeName(callee_decl.return_type.name);
                if (!std.mem.eql(u8, abi_type, "i64")) {
                    const dst = call_inst.dst.?;
                    try writer.print("  %r{d}.sext = sext {s} %r{d} to i64\n", .{ dst, abi_type, dst });
                    try writer.print("  %r{d} = add i64 %r{d}.sext, 0\n", .{ dst, dst });
                }
            }
        },
        .runtime => {
            if (request.mode != .hybrid) return error.RuntimeCallInNativeBuild;
            if (call_inst.args.len > 0) {
                try writer.print("  %rt.args.{d} = alloca [{d} x %kira.bridge.value]\n", .{ callee_id, call_inst.args.len });
                for (call_inst.args, 0..) |arg, index| {
                    try writer.print("  %rt.slot.{d}.{d} = getelementptr inbounds [{d} x %kira.bridge.value], ptr %rt.args.{d}, i64 0, i64 {d}\n", .{
                        callee_id, index, call_inst.args.len, callee_id, index,
                    });
                    try writer.print("  %rt.pack.{d}.{d}.0 = insertvalue %kira.bridge.value zeroinitializer, i8 {d}, 0\n", .{
                        callee_id, index, bridgeTagValue(register_types[arg]),
                    });
                    switch (register_types[arg].kind) {
                        .integer, .raw_ptr => {
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %r{d}, 2\n", .{
                                callee_id, index, callee_id, index, arg,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.1, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .boolean => {
                            try writer.print("  %rt.bool.{d}.{d} = zext i1 %r{d} to i64\n", .{ callee_id, index, arg });
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %rt.bool.{d}.{d}, 2\n", .{
                                callee_id, index, callee_id, index, callee_id, index,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.1, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .string => {
                            try writer.print("  %rt.str.ptr.{d}.{d} = extractvalue %kira.string %r{d}, 0\n", .{ callee_id, index, arg });
                            try writer.print("  %rt.str.ptrint.{d}.{d} = ptrtoint ptr %rt.str.ptr.{d}.{d} to i64\n", .{
                                callee_id, index, callee_id, index,
                            });
                            try writer.print("  %rt.str.len.{d}.{d} = extractvalue %kira.string %r{d}, 1\n", .{ callee_id, index, arg });
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %rt.str.ptrint.{d}.{d}, 2\n", .{
                                callee_id, index, callee_id, index, callee_id, index,
                            });
                            try writer.print("  %rt.pack.{d}.{d}.2 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.1, i64 %rt.str.len.{d}.{d}, 3\n", .{
                                callee_id, index, callee_id, index, callee_id, index,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.2, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .void, .float, .ffi_struct => return error.UnsupportedExecutableFeature,
                    }
                }
            }
            try writer.print("  %rt.result.{d} = alloca %kira.bridge.value\n", .{callee_id});
            try writer.writeAll("  call void @\"kira_hybrid_call_runtime\"(i32 ");
            try writer.print("{d}", .{callee_id});
            try writer.writeAll(", ptr ");
            if (call_inst.args.len == 0) {
                try writer.writeAll("null");
            } else {
                try writer.print("%rt.args.{d}", .{callee_id});
            }
            try writer.writeAll(", i32 ");
            try writer.print("{d}", .{call_inst.args.len});
            try writer.writeAll(", ptr ");
            try writer.print("%rt.result.{d}", .{callee_id});
            try writer.writeAll(")\n");
            if (call_inst.dst) |dst| {
                try writer.print("  %rt.result.load.{d} = load %kira.bridge.value, ptr %rt.result.{d}\n", .{ callee_id, callee_id });
                switch (callee_decl.return_type.kind) {
                    .integer, .raw_ptr => {
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(" = extractvalue %kira.bridge.value %rt.result.load.{d}, 2\n", .{callee_id});
                    },
                    .boolean => {
                        try writer.print("  %rt.result.word.{d} = extractvalue %kira.bridge.value %rt.result.load.{d}, 2\n", .{ callee_id, callee_id });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(" = trunc i64 %rt.result.word.{d} to i1\n", .{callee_id});
                    },
                    .string => {
                        try writer.print("  %rt.result.ptrint.{d} = extractvalue %kira.bridge.value %rt.result.load.{d}, 2\n", .{ callee_id, callee_id });
                        try writer.print("  %rt.result.len.{d} = extractvalue %kira.bridge.value %rt.result.load.{d}, 3\n", .{ callee_id, callee_id });
                        try writer.print("  %rt.result.ptr.{d} = inttoptr i64 %rt.result.ptrint.{d} to ptr\n", .{ callee_id, callee_id });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(".0 = insertvalue %kira.string zeroinitializer, ptr %rt.result.ptr.{d}, 0\n", .{callee_id});
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(" = insertvalue %kira.string %r{d}.0, i64 %rt.result.len.{d}, 1\n", .{ dst, callee_id });
                    },
                    .void, .float, .ffi_struct => {},
                }
            }
        },
        .inherited => unreachable,
    }
}

fn writePrintInstruction(writer: anytype, value_type: ir.ValueType, src: u32, temp_counter: *usize) !void {
    switch (value_type.kind) {
        .integer => {
            try writer.writeAll("  call void @\"kira_native_print_i64\"(i64 %r");
            try writer.print("{d}", .{src});
            try writer.writeAll(")\n");
        },
        .string => {
            const temp_index = temp_counter.*;
            temp_counter.* += 1;

            try writer.writeAll("  %str.ptr.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = extractvalue %kira.string %r");
            try writer.print("{d}", .{src});
            try writer.writeAll(", 0\n");
            try writer.writeAll("  %str.len.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = extractvalue %kira.string %r");
            try writer.print("{d}", .{src});
            try writer.writeAll(", 1\n");
            try writer.writeAll("  call void @\"kira_native_print_string\"(ptr %str.ptr.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(", i64 %str.len.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(")\n");
        },
        .void, .float, .boolean, .raw_ptr, .ffi_struct => return error.UnsupportedExecutableFeature,
    }
}

fn appendStringGlobals(
    allocator: std.mem.Allocator,
    globals: *std.array_list.Managed([]const u8),
    index: usize,
    value: []const u8,
) !void {
    const data_name = try std.fmt.allocPrint(allocator, "kira_str_{d}_data", .{index});
    defer allocator.free(data_name);
    const struct_name = try std.fmt.allocPrint(allocator, "kira_str_{d}", .{index});
    defer allocator.free(struct_name);

    var data_line = std.array_list.Managed(u8).init(allocator);
    errdefer data_line.deinit();
    var data_writer = data_line.writer();
    try data_writer.print("@{s} = private unnamed_addr constant [{d} x i8] c\"", .{ data_name, value.len + 1 });
    try writeLlvmStringLiteral(data_writer, value);
    try data_writer.writeAll("\\00\"\n");
    try globals.append(try data_line.toOwnedSlice());

    var struct_line = std.array_list.Managed(u8).init(allocator);
    errdefer struct_line.deinit();
    var struct_writer = struct_line.writer();
    try struct_writer.print("@{s} = private unnamed_addr constant %kira.string {{ ptr getelementptr inbounds ([{d} x i8], ptr @{s}, i64 0, i64 0), i64 {d} }}\n", .{
        struct_name,
        value.len + 1,
        data_name,
        value.len,
    });
    try globals.append(try struct_line.toOwnedSlice());
}

fn writeLlvmSymbol(writer: anytype, symbol: []const u8) !void {
    try writer.writeAll("@\"");
    try writeLlvmEscapedBytes(writer, symbol);
    try writer.writeByte('"');
}

fn writeLlvmStringLiteral(writer: anytype, bytes: []const u8) !void {
    try writeLlvmEscapedBytes(writer, bytes);
}

fn writeLlvmEscapedBytes(writer: anytype, bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte >= 0x20 and byte <= 0x7e and byte != '\\' and byte != '"') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('\\');
            try writer.writeByte(hexDigit(byte >> 4));
            try writer.writeByte(hexDigit(byte & 0x0f));
        }
    }
}

fn hexDigit(value: u8) u8 {
    const index: usize = @intCast(value & 0x0f);
    return "0123456789ABCDEF"[index];
}

fn appendTypeDefinitions(allocator: std.mem.Allocator, writer: anytype, program: *const ir.Program) !void {
    for (program.types) |type_decl| {
        const ffi_info = type_decl.ffi orelse continue;
        if (ffi_info != .ffi_struct) continue;
        try writer.writeAll(typeRefName(type_decl.name));
        try writer.writeAll(" = type { ");
        for (type_decl.fields, 0..) |field_decl, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.writeAll(try llvmFieldAbiTypeText(allocator, program, field_decl.ty));
        }
        try writer.writeAll(" }\n");
    }
    if (program.types.len > 0) try writer.writeByte('\n');
}

fn typeRefName(name: []const u8) []const u8 {
    return switch (name.len) {
        0 => "%t.anon",
        else => std.fmt.allocPrint(std.heap.page_allocator, "%t.{s}", .{name}) catch "%t.invalid",
    };
}

fn findTypeDecl(program: *const ir.Program, name: []const u8) ?ir.TypeDecl {
    for (program.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

fn llvmFieldAbiTypeText(allocator: std.mem.Allocator, program: *const ir.Program, value_type: ir.ValueType) ![]const u8 {
    switch (value_type.kind) {
        .void => return allocator.dupe(u8, "void"),
        .string => return allocator.dupe(u8, "%kira.string"),
        .boolean => return allocator.dupe(u8, "i8"),
        .raw_ptr => {
            if (value_type.name) |name| {
                if (findTypeDecl(program, name)) |type_decl| {
                    if (type_decl.ffi) |ffi_info| {
                        return switch (ffi_info) {
                            .array => |info| std.fmt.allocPrint(allocator, "[{d} x {s}]", .{ info.count, try llvmFieldAbiTypeText(allocator, program, info.element) }),
                            .alias => |info| llvmFieldAbiTypeText(allocator, program, info.target),
                            else => allocator.dupe(u8, "ptr"),
                        };
                    }
                }
            }
            return allocator.dupe(u8, "ptr");
        },
        .integer => return allocator.dupe(u8, integerAbiTypeName(value_type.name)),
        .float => return allocator.dupe(u8, floatAbiTypeName(value_type.name)),
        .ffi_struct => return allocator.dupe(u8, typeRefName(value_type.name orelse return error.UnsupportedExecutableFeature)),
    }
}

fn integerAbiTypeName(name: ?[]const u8) []const u8 {
    const value = name orelse "I64";
    if (std.mem.eql(u8, value, "I8") or std.mem.eql(u8, value, "U8")) return "i8";
    if (std.mem.eql(u8, value, "I16") or std.mem.eql(u8, value, "U16")) return "i16";
    if (std.mem.eql(u8, value, "I32") or std.mem.eql(u8, value, "U32")) return "i32";
    return "i64";
}

fn floatAbiTypeName(name: ?[]const u8) []const u8 {
    if (name) |value| {
        if (std.mem.eql(u8, value, "F64")) return "double";
    }
    return "float";
}

fn llvmValueTypeText(value_type: ir.ValueType) []const u8 {
    return switch (value_type.kind) {
        .void => "void",
        .integer => "i64",
        .float => "float",
        .string => "%kira.string",
        .boolean => "i1",
        .raw_ptr, .ffi_struct => "i64",
    };
}

fn llvmCallTypeText(value_type: ir.ValueType, is_extern: bool) []const u8 {
    if (!is_extern) return llvmValueTypeText(value_type);
    return switch (value_type.kind) {
        .raw_ptr => "ptr",
        .integer => integerAbiTypeName(value_type.name),
        .float => floatAbiTypeName(value_type.name),
        .boolean => "i1",
        .ffi_struct => typeRefName(value_type.name orelse "anon"),
        else => llvmValueTypeText(value_type),
    };
}

fn llvmLocalStorageTypeText(allocator: std.mem.Allocator, program: *const ir.Program, value_type: ir.ValueType) ![]const u8 {
    return switch (value_type.kind) {
        .ffi_struct => llvmFieldAbiTypeText(allocator, program, value_type),
        else => allocator.dupe(u8, llvmValueTypeText(value_type)),
    };
}

fn isPointerLikeValueType(value_type: ir.ValueType) bool {
    return value_type.kind == .raw_ptr or value_type.kind == .ffi_struct;
}

fn fieldIndex(program: *const ir.Program, owner_type_name: []const u8, field_name: []const u8) ?usize {
    const type_decl = findTypeDecl(program, owner_type_name) orelse return null;
    for (type_decl.fields, 0..) |field_decl, index| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return index;
    }
    return null;
}

fn fieldType(program: *const ir.Program, owner_type_name: []const u8, field_name: []const u8) ?ir.ValueType {
    const type_decl = findTypeDecl(program, owner_type_name) orelse return null;
    for (type_decl.fields) |field_decl| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return field_decl.ty;
    }
    return null;
}

fn llvmIndirectLoadTypeText(allocator: std.mem.Allocator, program: *const ir.Program, value_type: ir.ValueType) ![]const u8 {
    return switch (value_type.kind) {
        .integer, .float, .boolean, .raw_ptr, .ffi_struct => llvmFieldAbiTypeText(allocator, program, value_type),
        else => allocator.dupe(u8, llvmValueTypeText(value_type)),
    };
}

fn llvmFieldStoreValuePrefix(writer: anytype, dst_reg: u32) !void {
    try writer.writeAll("  %r");
    try writer.print("{d}", .{dst_reg});
    try writer.writeAll(" = ");
}

fn countStringConstants(function_decl: ir.Function) usize {
    var count: usize = 0;
    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_string => count += 1,
            else => {},
        }
    }
    return count;
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

fn freeSymbolNames(allocator: std.mem.Allocator, symbols: *std.AutoHashMapUnmanaged(u32, []const u8)) void {
    var iterator = symbols.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
    symbols.deinit(allocator);
}

fn writeTextFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        return;
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = data,
    });
}

fn emitObjectFileViaZigCc(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    object_path: []const u8,
) !void {
    const ir_text_z = api.LLVMPrintModuleToString(module_ref);
    defer api.LLVMDisposeMessage(ir_text_z);

    const ir_text = std.mem.span(ir_text_z);
    const ir_path = try std.fmt.allocPrint(allocator, "{s}.ll", .{object_path});
    defer allocator.free(ir_path);
    defer std.fs.cwd().deleteFile(ir_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = ir_path,
        .data = ir_text,
    });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ build_options.zig_exe, "cc", "-c", "-x", "ir", "-o", object_path, ir_path },
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ObjectEmissionFailed;
    }
}

fn inferRegisterTypes(allocator: std.mem.Allocator, program: ir.Program, function_decl: ir.Function) ![]ir.ValueType {
    const register_types = try allocator.alloc(ir.ValueType, function_decl.register_count);
    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int => |value| register_types[value.dst] = .{ .kind = .integer, .name = "I64" },
            .const_string => |value| register_types[value.dst] = .{ .kind = .string },
            .const_bool => |value| register_types[value.dst] = .{ .kind = .boolean },
            .const_null_ptr => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = "RawPtr" },
            .const_function => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = "RawPtr" },
            .add => |value| register_types[value.dst] = .{ .kind = .integer, .name = "I64" },
            .store_local => {},
            .load_local => |value| register_types[value.dst] = function_decl.local_types[value.local],
            .field_ptr => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = value.owner_type_name },
            .load_indirect => |value| register_types[value.dst] = value.ty,
            .store_indirect, .copy_indirect => {},
            .print => {},
            .call => |value| if (value.dst) |dst| {
                const callee_decl = functionById(program, value.callee) orelse return error.UnknownFunction;
                register_types[dst] = callee_decl.return_type;
            },
            .ret => {},
        }
    }
    return register_types;
}

fn functionExecutionById(program: ir.Program, function_id: u32) ?runtime_abi.FunctionExecution {
    for (program.functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl.execution;
    }
    return null;
}

fn functionById(program: ir.Program, function_id: u32) ?ir.Function {
    for (program.functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl;
    }
    return null;
}

fn buildTextExternDecl(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    function_decl: ir.Function,
) ![]const u8 {
    _ = request;
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    var writer = output.writer();
    try writer.writeAll("declare ");
    try writer.writeAll(llvmCallTypeText(function_decl.return_type, true));
    try writer.writeByte(' ');
    try writeLlvmSymbol(writer, symbol_names.get(function_decl.id) orelse return error.MissingFunctionDeclaration);
    try writer.writeByte('(');
    for (function_decl.param_types, 0..) |param_type, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(llvmCallTypeText(param_type, true));
    }
    try writer.writeAll(")\n");
    return output.toOwnedSlice();
}

fn buildHybridBridgeWrapper(
    allocator: std.mem.Allocator,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    function_decl: ir.Function,
) ![]const u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    var writer = output.writer();

    const export_name = try std.fmt.allocPrint(allocator, "kira_native_fn_{d}", .{function_decl.id});
    defer allocator.free(export_name);
    const impl_name = symbol_names.get(function_decl.id) orelse return error.MissingFunctionDeclaration;

    try writer.writeAll("define void ");
    try writeLlvmSymbol(writer, export_name);
    try writer.writeAll("(ptr %args, i32 %arg_count, ptr %out_result) {\nentry:\n");

    for (function_decl.param_types, 0..) |param_type, index| {
        try writer.writeAll("  %bridge.slot.");
        try writer.print("{d}", .{index});
        try writer.print(" = getelementptr inbounds %kira.bridge.value, ptr %args, i64 {d}\n", .{index});
        try writer.writeAll("  %bridge.load.");
        try writer.print("{d}", .{index});
        try writer.writeAll(" = load %kira.bridge.value, ptr %bridge.slot.");
        try writer.print("{d}\n", .{index});
        switch (param_type.kind) {
            .integer, .raw_ptr => {
                try writer.writeAll("  %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 2\n");
            },
            .boolean => {
                try writer.writeAll("  %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 2\n");
                try writer.writeAll("  %bridge.bool.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = trunc i64 %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" to i1\n");
            },
            .string => {
                try writer.writeAll("  %bridge.ptrint.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 2\n");
                try writer.writeAll("  %bridge.len.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 3\n");
                try writer.writeAll("  %bridge.ptr.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = inttoptr i64 %bridge.ptrint.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" to ptr\n");
                try writer.writeAll("  %bridge.str.init.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = insertvalue %kira.string zeroinitializer, ptr %bridge.ptr.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 0\n");
                try writer.writeAll("  %bridge.str.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = insertvalue %kira.string %bridge.str.init.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", i64 %bridge.len.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 1\n");
            },
            .void, .float, .ffi_struct => {},
        }
    }

    if (function_decl.return_type.kind == .void) {
        try writer.writeAll("  call void ");
    } else {
        try writer.writeAll("  %bridge.call = call ");
        try writer.writeAll(llvmValueTypeText(function_decl.return_type));
        try writer.writeByte(' ');
    }
    try writeLlvmSymbol(writer, impl_name);
    try writer.writeByte('(');
    for (function_decl.param_types, 0..) |param_type, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(llvmValueTypeText(param_type));
        try writer.writeByte(' ');
        switch (param_type.kind) {
            .integer, .raw_ptr => {
                try writer.writeAll("%bridge.word0.");
                try writer.print("{d}", .{index});
            },
            .boolean => {
                try writer.writeAll("%bridge.bool.");
                try writer.print("{d}", .{index});
            },
            .string => {
                try writer.writeAll("%bridge.str.");
                try writer.print("{d}", .{index});
            },
            .void, .float, .ffi_struct => try writer.writeAll("undef"),
        }
    }
    try writer.writeAll(")\n");

    try writer.writeAll("  %bridge.out.0 = insertvalue %kira.bridge.value zeroinitializer, i8 ");
    try writer.print("{d}", .{bridgeTagValue(function_decl.return_type)});
    try writer.writeAll(", 0\n");
    switch (function_decl.return_type.kind) {
        .void => {
            try writer.writeAll("  store %kira.bridge.value %bridge.out.0, ptr %out_result\n");
        },
        .integer, .raw_ptr => {
            try writer.writeAll("  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.call, 2\n");
            try writer.writeAll("  store %kira.bridge.value %bridge.out.1, ptr %out_result\n");
        },
        .boolean => {
            try writer.writeAll("  %bridge.ret.bool = zext i1 %bridge.call to i64\n");
            try writer.writeAll("  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.ret.bool, 2\n");
            try writer.writeAll("  store %kira.bridge.value %bridge.out.1, ptr %out_result\n");
        },
        .float => {
            try writer.writeAll("  store %kira.bridge.value %bridge.out.0, ptr %out_result\n");
        },
        .string => {
            try writer.writeAll("  %bridge.ret.ptr = extractvalue %kira.string %bridge.call, 0\n");
            try writer.writeAll("  %bridge.ret.ptrint = ptrtoint ptr %bridge.ret.ptr to i64\n");
            try writer.writeAll("  %bridge.ret.len = extractvalue %kira.string %bridge.call, 1\n");
            try writer.writeAll("  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.ret.ptrint, 2\n");
            try writer.writeAll("  %bridge.out.2 = insertvalue %kira.bridge.value %bridge.out.1, i64 %bridge.ret.len, 3\n");
            try writer.writeAll("  store %kira.bridge.value %bridge.out.2, ptr %out_result\n");
        },
        .ffi_struct => {
            try writer.writeAll("  store %kira.bridge.value %bridge.out.0, ptr %out_result\n");
        },
    }
    try writer.writeAll("  ret void\n}\n");
    return output.toOwnedSlice();
}

fn bridgeTagValue(value_type: ir.ValueType) u8 {
    return switch (value_type.kind) {
        .void => 0,
        .integer => 1,
        .float => 1,
        .string => 2,
        .boolean => 3,
        .raw_ptr, .ffi_struct => 4,
    };
}

fn resolveExecution(execution: runtime_abi.FunctionExecution, mode: backend_api.BackendMode) runtime_abi.FunctionExecution {
    return switch (execution) {
        .inherited => switch (mode) {
            .llvm_native => .native,
            .hybrid => .runtime,
            .vm_bytecode => .runtime,
        },
        else => execution,
    };
}

fn hostTargetTriple(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, if (builtin.abi == .gnu) "x86_64-pc-windows-gnu" else "x86_64-pc-windows-msvc"),
            else => error.UnsupportedTarget,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, "x86_64-pc-linux-gnu"),
            else => error.UnsupportedTarget,
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => allocator.dupe(u8, "arm64-apple-macosx"),
            else => error.UnsupportedTarget,
        },
        else => error.UnsupportedTarget,
    };
}

fn ensureParentDir(path: []const u8) !void {
    const maybe_dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(maybe_dir);
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    return allocator.dupeZ(u8, rendered);
}
