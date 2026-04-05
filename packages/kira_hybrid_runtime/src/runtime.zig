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
            .native => _ = try self.bridge.call(self.manifest.entry_function_id, &.{}),
            .inherited => unreachable,
        }
    }

    fn invokeRuntime(self: *HybridRuntime, context: anytype, function_id: u32, args: []const runtime_abi.BridgeValue, out_result: ?*runtime_abi.BridgeValue) !void {
        const runtime_args = try self.allocator.alloc(runtime_abi.Value, args.len);
        defer self.allocator.free(runtime_args);
        for (args, 0..) |arg, index| runtime_args[index] = runtime_abi.bridgeValueToValue(arg);

        const result = try self.vm.runFunctionById(&self.module, function_id, runtime_args, context.writer, .{
            .context = @as(?*anyopaque, @ptrCast(context)),
            .call_native = callNative(@TypeOf(context.*)),
        });
        if (out_result) |ptr| ptr.* = runtime_abi.bridgeValueFromValue(result);
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

fn callNative(comptime Context: type) *const fn (?*anyopaque, u32, []const runtime_abi.Value) anyerror!runtime_abi.Value {
    return struct {
        fn invoke(context: ?*anyopaque, function_id: u32, args: []const runtime_abi.Value) !runtime_abi.Value {
            const runtime_context: *Context = @ptrCast(@alignCast(context orelse return error.MissingHybridContext));
            return runtime_context.runtime.bridge.call(function_id, args);
        }
    }.invoke;
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

const DirectStdoutWriter = struct {
    pub fn writeAll(_: DirectStdoutWriter, bytes: []const u8) !void {
        try std.fs.File.stdout().writeAll(bytes);
    }

    pub fn writeByte(self: DirectStdoutWriter, byte: u8) !void {
        _ = self;
        if (@import("builtin").os.tag == .windows and byte == '\n') {
            try std.fs.File.stdout().writeAll("\r\n");
            return;
        }
        var buffer = [1]u8{byte};
        try std.fs.File.stdout().writeAll(&buffer);
    }

    pub fn print(self: DirectStdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [512]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buffer, fmt, args);
        try self.writeAll(rendered);
    }
};
