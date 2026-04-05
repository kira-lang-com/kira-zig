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
    defer if (owns_ir_path) {
        std.fs.cwd().deleteFile(ir_path) catch {};
        allocator.free(ir_path);
    };

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

    var string_counter: usize = 0;
    for (request.program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        const body = try buildTextFunctionBody(allocator, request, &symbol_names, &globals, function_decl, string_counter);
        string_counter += countStringConstants(function_decl);
        try function_bodies.append(body);
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
    try writer.writeAll("%kira.string = type { ptr, i64 }\n\n");

    try writer.writeAll("declare void @\"kira_native_print_i64\"(i64)\n");
    try writer.writeAll("declare void @\"kira_native_print_string\"(ptr, i64)\n");
    if (request.mode == .hybrid) {
        try writer.writeAll("declare void @\"kira_hybrid_call_runtime\"(i32)\n");
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
    try writer.writeAll("define void ");
    try writeLlvmSymbol(writer, function_name);
    try writer.writeAll("() {\nentry:\n");

    const register_types = try inferRegisterTypes(allocator, function_decl);
    defer allocator.free(register_types);

    const string_state = try allocator.alloc(usize, 1);
    defer allocator.free(string_state);
    string_state[0] = string_counter;
    var temp_counter: usize = 0;

    for (function_decl.local_types, 0..) |local_type, index| {
        try writer.writeAll("  %local");
        try writer.print("{d}", .{index});
        try writer.writeAll(" = alloca ");
        try writer.writeAll(llvmValueTypeText(local_type));
        try writer.writeAll("\n");
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
                try writer.writeAll(" = load ");
                try writer.writeAll(llvmValueTypeText(function_decl.local_types[value.local]));
                try writer.writeAll(", ptr %local");
                try writer.print("{d}\n", .{value.local});
            },
            .print => |value| {
                try writePrintInstruction(writer, register_types[value.src], value.src, &temp_counter);
            },
            .call => |value| {
                try writeCallInstruction(writer, request, symbol_names, value.callee);
            },
            .ret_void => {
                try writer.writeAll("  ret void\n}\n");
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
    callee_id: u32,
) !void {
    const callee_execution = functionExecutionById(request.program.*, callee_id) orelse return error.UnknownFunction;
    switch (resolveExecution(callee_execution, request.mode)) {
        .native => {
            const callee_name = symbol_names.get(callee_id) orelse return error.MissingFunctionDeclaration;
            try writer.writeAll("  call void ");
            try writeLlvmSymbol(writer, callee_name);
            try writer.writeAll("()\n");
        },
        .runtime => {
            if (request.mode != .hybrid) return error.RuntimeCallInNativeBuild;
            try writer.writeAll("  call void @\"kira_hybrid_call_runtime\"(i32 ");
            try writer.print("{d}", .{callee_id});
            try writer.writeAll(")\n");
        },
        .inherited => unreachable,
    }
}

fn writePrintInstruction(writer: anytype, value_type: ir.ValueType, src: u32, temp_counter: *usize) !void {
    switch (value_type) {
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

fn llvmValueTypeText(value_type: ir.ValueType) []const u8 {
    return switch (value_type) {
        .integer => "i64",
        .string => "%kira.string",
    };
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
