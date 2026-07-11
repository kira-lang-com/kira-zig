pub const HybridRuntime = @import("runtime.zig").HybridRuntime;
pub const loadHybridModule = @import("loader.zig").loadHybridModule;
pub const bindHybridSymbols = @import("binder.zig").bindHybridSymbols;
/// Live hot swap: in-place module replacement in a running HybridRuntime.
pub const hot_swap = @import("hot_swap.zig");

test {
    _ = @import("hot_swap.zig");
}
