const core = @import("kira_core");

pub const SymbolLink = struct {
    library_id: core.LibraryId,
    symbol_id: core.SymbolId,
    exported_name: []const u8,
};
