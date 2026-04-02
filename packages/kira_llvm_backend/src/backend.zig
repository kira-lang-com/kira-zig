const std = @import("std");
const builtin = @import("builtin");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const backend_api = @import("kira_backend_api");
const llvm = @import("llvm_c.zig");
const toolchain = @import("toolchain.zig");
const linker = @import("link.zig");
const runtime_symbols = @import("runtime_symbols.zig");

pub fn compile(allocator: std.mem.Allocator, request: backend_api.CompileRequest) !backend_api.CompileResult {
    if (request.mode != .llvm_native and request.mode != .hybrid) return error.UnsupportedBackendMode;

    const tc = try toolchain.Toolchain.discover(allocator);
    var api = try llvm.Api.open(tc);
    defer api.close();

    api.LLVMInitializeTargetInfo();
    api.LLVMInitializeTarget();
    api.LLVMInitializeTargetMC();
    api.LLVMInitializeAsmPrinter();
    if (api.LLVMInitializeAsmParser) |init| init();

    const triple = try hostTargetTriple(allocator);
    const target_machine = try createTargetMachine(allocator, &api, triple);
    defer api.LLVMDisposeTargetMachine(target_machine.machine);
    defer api.LLVMDisposeTargetData(target_machine.data_layout);

    try ensureParentDir(request.emit.object_path);
    if (request.emit.executable_path) |path| try ensureParentDir(path);
    if (request.emit.shared_library_path) |path| try ensureParentDir(path);

    const lowered = try lowerProgram(allocator, &api, target_machine, request, triple);
    if (builtin.os.tag != .windows) {
        defer api.LLVMDisposeModule(lowered.module_ref);
        defer api.LLVMContextDispose(lowered.context);
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

const TargetMachineInfo = struct {
    machine: llvm.c.LLVMTargetMachineRef,
    data_layout: llvm.c.LLVMTargetDataRef,
};

fn createTargetMachine(allocator: std.mem.Allocator, api: *const llvm.Api, triple: []const u8) !TargetMachineInfo {
    const triple_z = try allocator.dupeZ(u8, triple);
    var target_ref: llvm.c.LLVMTargetRef = undefined;
    var target_error: [*c]u8 = null;
    if (api.LLVMGetTargetFromTriple(triple_z.ptr, &target_ref, &target_error) != 0) {
        defer if (target_error != null) api.LLVMDisposeMessage(target_error);
        if (target_error != null) std.debug.print("{s}\n", .{std.mem.span(target_error)});
        return error.TargetLookupFailed;
    }

    const cpu_name = api.LLVMGetHostCPUName();
    defer api.LLVMDisposeMessage(cpu_name);
    const cpu_features = api.LLVMGetHostCPUFeatures();
    defer api.LLVMDisposeMessage(cpu_features);

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
        .data_layout = api.LLVMCreateTargetDataLayout(machine),
    };
}

const LoweredModule = struct {
    context: llvm.c.LLVMContextRef,
    module_ref: llvm.c.LLVMModuleRef,
};

const Types = struct {
    api: *const llvm.Api,
    context: llvm.c.LLVMContextRef,
    data_layout: llvm.c.LLVMTargetDataRef,
    i8: llvm.c.LLVMTypeRef,
    i32: llvm.c.LLVMTypeRef,
    i64: llvm.c.LLVMTypeRef,
    usize_ty: llvm.c.LLVMTypeRef,
    void_ty: llvm.c.LLVMTypeRef,
    ptr_ty: llvm.c.LLVMTypeRef,
    string_ty: llvm.c.LLVMTypeRef,

    fn init(api: *const llvm.Api, context: llvm.c.LLVMContextRef, data_layout: llvm.c.LLVMTargetDataRef) Types {
        const ptr_ty = api.LLVMPointerTypeInContext(context, 0);
        const usize_ty = api.LLVMIntPtrTypeInContext(context, data_layout);
        var string_fields = [_]llvm.c.LLVMTypeRef{ ptr_ty, usize_ty };
        return .{
            .api = api,
            .context = context,
            .data_layout = data_layout,
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
        return switch (value_type) {
            .integer => self.i64,
            .string => self.string_ty,
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
    if (request.mode == .hybrid) {
        for (request.program.functions) |function_decl| {
            if (function_decl.execution == .inherited) return error.HybridBuildRequiresExplicitExecution;
        }
    }

    const context = api.LLVMContextCreate();
    const module_name = try allocator.dupeZ(u8, request.module_name);
    const module_ref = api.LLVMModuleCreateWithNameInContext(module_name.ptr, context);
    api.LLVMSetModuleDataLayout(module_ref, target_machine.data_layout);
    api.LLVMSetTarget(module_ref, try allocator.dupeZ(u8, triple));

    const builder = api.LLVMCreateBuilderInContext(context);
    defer api.LLVMDisposeBuilder(builder);

    const types = Types.init(api, context, target_machine.data_layout);
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
    return switch (mode) {
        .llvm_native => allocPrintZ(allocator, "kira_fn_{d}_{s}", .{ function_decl.id, function_decl.name }),
        .hybrid => allocPrintZ(allocator, "kira_native_fn_{d}", .{function_decl.id}),
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
            .add => |value| register_values[value.dst] = api.LLVMBuildAdd(builder, register_values[value.lhs], register_values[value.rhs], "add"),
            .store_local => |value| _ = api.LLVMBuildStore(builder, register_values[value.src], locals[value.local]),
            .load_local => |value| register_values[value.dst] = api.LLVMBuildLoad2(builder, types.llvmType(function_decl.local_types[value.local]), locals[value.local], "load"),
            .print => |value| try lowerPrint(api, builder, runtime_decls, register_types[value.src], register_values[value.src]),
            .call => |value| try lowerCall(api, builder, types, runtime_decls, request.mode, request.program, functions, value.callee),
            .ret_void => {
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
    switch (value_type) {
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
        if (error_message != null) std.debug.print("{s}\n", .{std.mem.span(error_message)});
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
    const object_path_z = try allocator.dupeZ(u8, object_path);
    var error_message: [*c]u8 = null;
    if (api.LLVMTargetMachineEmitToFile(machine, module_ref, object_path_z.ptr, llvm.c.LLVMObjectFile, &error_message) != 0) {
        defer if (error_message != null) api.LLVMDisposeMessage(error_message);
        if (error_message != null) std.debug.print("{s}\n", .{std.mem.span(error_message)});
        return error.ObjectEmissionFailed;
    }
}

fn inferRegisterTypes(allocator: std.mem.Allocator, function_decl: ir.Function) ![]ir.ValueType {
    const register_types = try allocator.alloc(ir.ValueType, function_decl.register_count);
    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int => |value| register_types[value.dst] = .integer,
            .const_string => |value| register_types[value.dst] = .string,
            .add => |value| register_types[value.dst] = .integer,
            .store_local => {},
            .load_local => |value| register_types[value.dst] = function_decl.local_types[value.local],
            .print => {},
            .call => {},
            .ret_void => {},
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

fn resolveExecution(execution: runtime_abi.FunctionExecution, mode: backend_api.BackendMode) runtime_abi.FunctionExecution {
    return switch (execution) {
        .inherited => switch (mode) {
            .llvm_native => .native,
            .hybrid => .inherited,
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
