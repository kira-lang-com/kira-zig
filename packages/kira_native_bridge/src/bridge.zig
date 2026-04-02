const std = @import("std");
const hybrid = @import("kira_hybrid_definition");
const symbol_resolver = @import("symbol_resolver.zig");
const trampoline = @import("trampoline.zig");

pub const RuntimeInvoker = *const fn (?*anyopaque, u32) anyerror!void;
const InstallRuntimeInvokerFn = *const fn (*const fn (u32) callconv(.c) void) callconv(.c) void;

var active_runtime_context: ?*anyopaque = null;
var active_runtime_invoker: ?RuntimeInvoker = null;

pub const NativeBridge = struct {
    allocator: std.mem.Allocator,
    library: ?std.DynLib = null,
    trampolines: std.AutoHashMapUnmanaged(u32, trampoline.Trampoline) = .{},

    pub fn init(allocator: std.mem.Allocator) NativeBridge {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NativeBridge) void {
        self.trampolines.deinit(self.allocator);
        if (self.library) |*library| library.close();
    }

    pub fn bind(self: *NativeBridge, library_path: []const u8, descriptors: []const hybrid.BridgeDescriptor) !void {
        var library = try std.DynLib.open(library_path);
        errdefer library.close();

        for (descriptors) |descriptor| {
            const symbol_name_z = try self.allocator.dupeZ(u8, descriptor.symbol_name);
            const invoke = try symbol_resolver.resolveSymbol(&library, symbol_name_z);
            try self.trampolines.put(self.allocator, descriptor.function_id.value, .{
                .function_id = descriptor.function_id.value,
                .symbol_name = descriptor.symbol_name,
                .invoke = invoke,
            });
        }

        const install_invoker = library.lookup(InstallRuntimeInvokerFn, "kira_hybrid_install_runtime_invoker") orelse return error.MissingRuntimeInvokerInstaller;
        install_invoker(kira_hybrid_host_call_runtime);

        self.library = library;
    }

    pub fn call(self: *NativeBridge, function_id: u32) !void {
        const tramp = self.trampolines.get(function_id) orelse return error.MissingNativeTrampoline;
        tramp.invoke();
    }
};

pub fn installRuntimeInvoker(context: ?*anyopaque, invoker: RuntimeInvoker) void {
    active_runtime_context = context;
    active_runtime_invoker = invoker;
}

pub fn clearRuntimeInvoker() void {
    active_runtime_context = null;
    active_runtime_invoker = null;
}

pub export fn kira_hybrid_host_call_runtime(function_id: u32) callconv(.c) void {
    const invoker = active_runtime_invoker orelse @panic("hybrid runtime invoker not installed");
    invoker(active_runtime_context, function_id) catch |err| {
        std.debug.panic("hybrid runtime call failed: {s}", .{@errorName(err)});
    };
}
