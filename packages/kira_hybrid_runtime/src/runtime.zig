const std = @import("std");
const bytecode = @import("kira_bytecode");
const hybrid = @import("kira_hybrid_definition");
const runtime_abi = @import("kira_runtime_abi");
const vm_runtime = @import("kira_vm_runtime");
const native_bridge = @import("kira_native_bridge");
const binder = @import("binder.zig");

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
        native_bridge.installRuntimeInvoker(self, runtimeInvoke);
        defer native_bridge.clearRuntimeInvoker();

        switch (self.manifest.entry_execution) {
            .runtime => try self.invokeRuntime(self.manifest.entry_function_id),
            .native => try self.bridge.call(self.manifest.entry_function_id),
            .inherited => unreachable,
        }
    }

    pub fn invokeRuntime(self: *HybridRuntime, function_id: u32) !void {
        const writer = DirectStdoutWriter{};
        try self.vm.runFunctionById(&self.module, function_id, writer, .{
            .context = self,
            .call_native = callNative,
        });
    }
};

fn runtimeInvoke(context: ?*anyopaque, function_id: u32) !void {
    const runtime: *HybridRuntime = @ptrCast(@alignCast(context orelse return error.MissingHybridContext));
    return runtime.invokeRuntime(function_id);
}

fn callNative(context: ?*anyopaque, function_id: u32) !void {
    const runtime: *HybridRuntime = @ptrCast(@alignCast(context orelse return error.MissingHybridContext));
    return runtime.bridge.call(function_id);
}

fn buildRuntimeDescriptors(allocator: std.mem.Allocator, manifest: hybrid.HybridModuleManifest) ![]hybrid.BridgeDescriptor {
    var descriptors = std.array_list.Managed(hybrid.BridgeDescriptor).init(allocator);
    for (manifest.functions) |function_decl| {
        if (function_decl.execution != .native) continue;
        try descriptors.append(.{
            .bridge_id = .init(function_decl.id),
            .function_id = .init(function_decl.id),
            .symbol_name = function_decl.exported_name orelse return error.MissingNativeExportName,
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
