const std = @import("std");
const bytecode = @import("kira_bytecode");
const hybrid = @import("kira_hybrid_definition");
const native_bridge = @import("kira_native_bridge");
const runtime_abi = @import("kira_runtime_abi");
const binder = @import("binder.zig");
const vm_runtime = @import("kira_vm_runtime");

pub const HybridRuntime = struct {
    allocator: std.mem.Allocator,
    manifest: hybrid.HybridModuleManifest,
    module: bytecode.Module,
    vm: vm_runtime.Vm,
    bridge: native_bridge.NativeBridge,

    pub fn init(allocator: std.mem.Allocator, manifest: hybrid.HybridModuleManifest) !HybridRuntime {
        var bridge = native_bridge.NativeBridge.init(allocator);
        const descriptors = try buildRuntimeDescriptors(allocator, manifest);
        try binder.bindHybridSymbols(&bridge, manifest.native_library_path, descriptors);

        return .{
            .allocator = allocator,
            .manifest = manifest,
            .module = try bytecode.Module.readFromFile(allocator, manifest.bytecode_path),
            .vm = vm_runtime.Vm.init(allocator),
            .bridge = bridge,
        };
    }

    pub fn deinit(self: *HybridRuntime) void {
        self.vm.deinit();
        self.bridge.deinit();
    }

    pub fn run(self: *HybridRuntime) !void {
        try self.runWithWriter(DirectStdoutWriter{});
    }

    pub fn runWithWriter(self: *HybridRuntime, writer: anytype) !void {
        const Context = RuntimeContext(@TypeOf(writer));
        var runtime_context = Context{
            .runtime = self,
            .writer = writer,
        };
        native_bridge.installRuntimeInvoker(&runtime_context, runtimeInvoke(Context));
        defer native_bridge.clearRuntimeInvoker();

        switch (self.manifest.entry_execution) {
            .runtime => try self.invokeRuntime(&runtime_context, self.manifest.entry_function_id, &.{}, null),
            .native => _ = try callNativeFunction(self, self.manifest.entry_function_id, &.{}),
            .inherited => unreachable,
        }
    }

    fn invokeRuntime(self: *HybridRuntime, context: anytype, function_id: u32, args: []const runtime_abi.BridgeValue, out_result: ?*runtime_abi.BridgeValue) !void {
        const function_decl = self.module.findFunctionById(function_id) orelse return error.UnknownFunction;
        runtime_abi.emitExecutionTrace("CALLBACK", "ENTER", "native->runtime fn={s}({d}) args={d}", .{
            function_decl.name,
            function_id,
            args.len,
        });
        const runtime_args = try self.allocator.alloc(runtime_abi.Value, args.len);
        defer self.allocator.free(runtime_args);
        const native_arg_ptrs = try self.allocator.alloc(usize, args.len);
        defer self.allocator.free(native_arg_ptrs);
        @memset(native_arg_ptrs, 0);
        for (args, 0..) |arg, index| {
            runtime_args[index] = runtime_abi.bridgeValueToValue(arg);
            if (index >= function_decl.param_count) continue;
            const local_ty = function_decl.local_types[index];
            if (local_ty.kind != .ffi_struct or runtime_args[index] != .raw_ptr or runtime_args[index].raw_ptr == 0) continue;
            native_arg_ptrs[index] = runtime_args[index].raw_ptr;
            runtime_args[index] = .{ .raw_ptr = try self.vm.materializeNativeStruct(
                &self.module,
                local_ty.name orelse return error.RuntimeFailure,
                runtime_args[index].raw_ptr,
            ) };
        }

        const result = try self.vm.runFunctionById(&self.module, function_decl.id, runtime_args, context.writer, .{
            .context = @as(?*anyopaque, @ptrCast(context)),
            .call_native = nativeCallHook(@TypeOf(context.*)),
            .resolve_function = resolveFunctionHook(@TypeOf(context.*)),
            .copy_struct_args_by_value = false,
        });
        for (native_arg_ptrs, 0..) |native_ptr, index| {
            if (native_ptr == 0) continue;
            const local_ty = function_decl.local_types[index];
            try self.vm.writeStructToNativeLayout(
                &self.module,
                local_ty.name orelse return error.RuntimeFailure,
                runtime_args[index].raw_ptr,
                native_ptr,
            );
            self.vm.releaseManagedValue(runtime_args[index]);
        }

        var bridge_result = runtime_abi.bridgeValueFromValue(result);
        try self.vm.pinNativeBoundaryValue(result);
        if (function_decl.return_type.kind == .ffi_struct and result == .raw_ptr and result.raw_ptr != 0) {
            bridge_result = runtime_abi.bridgeValueFromValue(.{ .raw_ptr = try self.vm.lowerStructToNativeLayout(
                &self.module,
                function_decl.return_type.name orelse return error.RuntimeFailure,
                result.raw_ptr,
            ) });
        }
        if (out_result) |ptr| ptr.* = bridge_result;
        self.vm.releaseManagedValue(result);
        runtime_abi.emitExecutionTrace("CALLBACK", "RETURN", "runtime->native fn={s}({d}) tag={s}", .{
            function_decl.name,
            function_id,
            @tagName(bridge_result.tag),
        });
    }

    fn resolveFunctionPointer(self: *HybridRuntime, function_id: u32) !usize {
        const function_decl = findFunction(self.manifest.functions, function_id) orelse return error.UnknownFunction;
        if (function_decl.execution != .native or function_decl.exported_name == null) return error.UnsupportedExecutableFeature;
        return self.bridge.resolveImplementationPointer(function_id);
    }
};

fn RuntimeContext(comptime Writer: type) type {
    return struct {
        runtime: *HybridRuntime,
        writer: Writer,
    };
}

fn runtimeInvoke(comptime Context: type) *const fn (?*anyopaque, u32, []const runtime_abi.BridgeValue, *runtime_abi.BridgeValue) anyerror!void {
    return struct {
        fn invoke(context: ?*anyopaque, function_id: u32, args: []const runtime_abi.BridgeValue, out_result: *runtime_abi.BridgeValue) !void {
            const runtime_context: *Context = @ptrCast(@alignCast(context orelse return error.MissingHybridContext));
            try runtime_context.runtime.invokeRuntime(runtime_context, function_id, args, out_result);
        }
    }.invoke;
}

fn nativeCallHook(comptime Context: type) *const fn (?*anyopaque, u32, []const runtime_abi.Value) anyerror!runtime_abi.Value {
    return struct {
        fn invoke(context: ?*anyopaque, function_id: u32, args: []const runtime_abi.Value) !runtime_abi.Value {
            const runtime_context: *Context = @ptrCast(@alignCast(context orelse return error.MissingHybridContext));
            return callNative(runtime_context.runtime, function_id, args);
        }
    }.invoke;
}

fn resolveFunctionHook(comptime Context: type) *const fn (?*anyopaque, u32) anyerror!usize {
    return struct {
        fn resolve(context: ?*anyopaque, function_id: u32) !usize {
            const runtime_context: *Context = @ptrCast(@alignCast(context orelse return error.MissingHybridContext));
            return runtime_context.runtime.resolveFunctionPointer(function_id);
        }
    }.resolve;
}

fn buildRuntimeDescriptors(allocator: std.mem.Allocator, manifest: hybrid.HybridModuleManifest) ![]hybrid.BridgeDescriptor {
    var descriptors = std.array_list.Managed(hybrid.BridgeDescriptor).init(allocator);
    for (manifest.functions) |function_decl| {
        if (function_decl.execution != .native) continue;
        if (function_decl.exported_name == null) continue;
        try descriptors.append(.{
            .bridge_id = .init(function_decl.id),
            .function_id = .init(function_decl.id),
            .symbol_name = function_decl.exported_name.?,
            .source_execution = .runtime,
            .target_execution = .native,
            .calling_convention = .kira_hybrid,
        });
    }
    return descriptors.toOwnedSlice();
}

fn findFunction(functions: []const hybrid.FunctionManifest, function_id: u32) ?hybrid.FunctionManifest {
    for (functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl;
    }
    return null;
}

fn callNative(self: *HybridRuntime, function_id: u32, args: []const runtime_abi.Value) !runtime_abi.Value {
    try self.vm.beginNativeBoundary();
    defer self.vm.endNativeBoundary();

    const function_decl = findFunction(self.manifest.functions, function_id) orelse return error.UnknownFunction;
    const lowered_args = try self.allocator.alloc(runtime_abi.Value, args.len);
    defer self.allocator.free(lowered_args);
    const native_arg_ptrs = try self.allocator.alloc(usize, args.len);
    defer self.allocator.free(native_arg_ptrs);
    @memset(native_arg_ptrs, 0);

    for (args, 0..) |arg, index| {
        try self.vm.pinNativeBoundaryValue(arg);
        lowered_args[index] = arg;
        if (index >= function_decl.param_types.len) continue;
        const param_type = function_decl.param_types[index];
        if (param_type.kind != .ffi_struct or arg != .raw_ptr or arg.raw_ptr == 0) continue;
        native_arg_ptrs[index] = try self.vm.lowerStructToNativeLayout(
            &self.module,
            param_type.name orelse return error.RuntimeFailure,
            arg.raw_ptr,
        );
        lowered_args[index] = .{ .raw_ptr = native_arg_ptrs[index] };
    }

    const result = try self.bridge.call(function_id, lowered_args);
    self.vm.retainManagedValue(result);
    for (native_arg_ptrs, 0..) |native_ptr, index| {
        if (native_ptr == 0) continue;
        const param_type = function_decl.param_types[index];
        try self.vm.syncStructFromNativeLayout(
            &self.module,
            param_type.name orelse return error.RuntimeFailure,
            args[index].raw_ptr,
            native_ptr,
        );
    }

    return result;
}

fn callNativeFunction(self: *HybridRuntime, function_id: u32, args: []const runtime_abi.Value) !runtime_abi.Value {
    try self.vm.beginNativeBoundary();
    defer self.vm.endNativeBoundary();

    const result = try self.bridge.call(function_id, args);
    self.vm.retainManagedValue(result);
    return result;
}

const DirectStdoutWriter = struct {
    pub fn writeAll(_: DirectStdoutWriter, bytes: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stdout().writer(std.Options.debug_io, &buffer);
        defer writer.interface.flush() catch {};
        try writer.interface.writeAll(bytes);
    }

    pub fn writeByte(self: DirectStdoutWriter, byte: u8) !void {
        _ = self;
        if (@import("builtin").os.tag == .windows and byte == '\n') {
            try DirectStdoutWriter.writeAll(.{}, "\r\n");
            return;
        }
        var buffer = [1]u8{byte};
        try DirectStdoutWriter.writeAll(.{}, &buffer);
    }

    pub fn print(self: DirectStdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [512]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buffer, fmt, args);
        try self.writeAll(rendered);
    }
};
