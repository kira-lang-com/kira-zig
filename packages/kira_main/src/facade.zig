const std = @import("std");
const bytecode = @import("kira_bytecode");
const vm_runtime = @import("kira_vm_runtime");
const api = @import("api.zig");
const wrappers = @import("runtime_wrappers.zig");

pub const RuntimeFacade = struct {
    arena: std.heap.ArenaAllocator,
    vm: vm_runtime.Vm,
    module: ?bytecode.Module = null,
    last_error_buffer: [257]u8 = [_]u8{0} ** 257,

    pub fn create() !*RuntimeFacade {
        const runtime = try std.heap.c_allocator.create(RuntimeFacade);
        runtime.* = undefined;
        runtime.arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        runtime.vm = vm_runtime.Vm.init(runtime.arena.allocator());
        runtime.module = null;
        runtime.last_error_buffer = [_]u8{0} ** 257;
        return runtime;
    }

    pub fn destroy(self: *RuntimeFacade) void {
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }

    pub fn loadBytecodeModule(self: *RuntimeFacade, path: [*:0]const u8) !void {
        self.resetArena();
        self.module = try bytecode.Module.readFromFile(self.arena.allocator(), wrappers.cStringSlice(path));
        self.clearError();
    }

    pub fn runMain(self: *RuntimeFacade) !void {
        if (self.module == null) {
            self.setError("no bytecode module loaded");
            return error.RuntimeFailure;
        }
        var stdout_buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(std.Options.debug_io, &stdout_buffer);
        defer stdout.interface.flush() catch {};
        try self.vm.runMain(&self.module.?, &stdout.interface);
    }

    pub fn lastError(self: *RuntimeFacade) [*:0]const u8 {
        return @ptrCast(&self.last_error_buffer);
    }

    fn resetArena(self: *RuntimeFacade) void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        self.vm = vm_runtime.Vm.init(self.arena.allocator());
        self.module = null;
    }

    fn setError(self: *RuntimeFacade, message: []const u8) void {
        const length = @min(message.len, self.last_error_buffer.len - 1);
        @memcpy(self.last_error_buffer[0..length], message[0..length]);
        self.last_error_buffer[length] = 0;
    }

    fn clearError(self: *RuntimeFacade) void {
        self.last_error_buffer[0] = 0;
    }
};

pub export fn kira_runtime_create() callconv(.c) ?*RuntimeFacade {
    return RuntimeFacade.create() catch null;
}

pub export fn kira_runtime_destroy(runtime: ?*RuntimeFacade) callconv(.c) void {
    if (runtime) |value| value.destroy();
}

pub export fn kira_runtime_load_bytecode_module(runtime: ?*RuntimeFacade, path: ?[*:0]const u8) callconv(.c) api.KiraStatus {
    if (runtime == null or path == null) return .fail;
    runtime.?.loadBytecodeModule(path.?) catch |err| {
        runtime.?.setError(@errorName(err));
        return .fail;
    };
    return .ok;
}

pub export fn kira_runtime_run_main(runtime: ?*RuntimeFacade) callconv(.c) api.KiraStatus {
    if (runtime == null) return .fail;
    runtime.?.runMain() catch |err| {
        runtime.?.setError(@errorName(err));
        return .fail;
    };
    return .ok;
}

pub export fn kira_runtime_last_error(runtime: ?*RuntimeFacade) callconv(.c) ?[*:0]const u8 {
    if (runtime == null) return null;
    return runtime.?.lastError();
}

pub export fn kira_runtime_load_hybrid_module(_: ?*RuntimeFacade, _: ?[*:0]const u8) callconv(.c) api.KiraStatus {
    return .fail;
}

pub export fn kira_runtime_attach_native_library(_: ?*RuntimeFacade, _: ?[*:0]const u8) callconv(.c) api.KiraStatus {
    return .fail;
}
