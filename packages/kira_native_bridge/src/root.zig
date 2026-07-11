pub const NativeBridge = @import("bridge.zig").NativeBridge;
pub const RuntimeInvoker = @import("bridge.zig").RuntimeInvoker;
pub const installRuntimeInvoker = @import("bridge.zig").installRuntimeInvoker;
pub const clearRuntimeInvoker = @import("bridge.zig").clearRuntimeInvoker;
pub const installClosureDestroy = @import("bridge.zig").installClosureDestroy;
pub const Trampoline = @import("trampoline.zig").Trampoline;
pub const resolveSymbol = @import("symbol_resolver.zig").resolveSymbol;
pub const graphics_loader = @import("graphics_loader.zig");
pub const async_runtime = @import("async_runtime.zig");

test {
    _ = @import("graphics_loader.zig");
    _ = @import("async_runtime.zig");
}
