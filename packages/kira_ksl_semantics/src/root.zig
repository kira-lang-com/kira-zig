pub const ImportedModule = @import("analyzer.zig").ImportedModule;
pub const analyze = @import("analyzer.zig").analyze;

test {
    _ = @import("analyzer.zig");
}
