pub const analyze = @import("analyzer.zig").analyze;
pub const analyzeWithImports = @import("analyzer.zig").analyzeWithImports;
pub const ImportedGlobals = @import("analyzer.zig").ImportedGlobals;

test {
    _ = @import("analyzer.zig");
}
