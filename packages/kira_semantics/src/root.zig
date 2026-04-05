pub const analyze = @import("analyzer.zig").analyze;
pub const analyzeWithImports = @import("analyzer.zig").analyzeWithImports;
pub const ImportedGlobals = @import("analyzer.zig").ImportedGlobals;
pub const ImportedFunction = @import("imported_globals.zig").ImportedFunction;
pub const ImportedType = @import("imported_globals.zig").ImportedType;
pub const ImportedField = @import("imported_globals.zig").ImportedField;
pub const ResolvedType = @import("kira_semantics_model").ResolvedType;
pub const LoweringContext = @import("lower_shared.zig").Context;
pub const typeFromSyntax = @import("lower_shared.zig").typeFromSyntax;
pub const resolveForeignFunction = @import("lower_shared.zig").resolveForeignFunction;
pub const resolveNamedTypeInfo = @import("lower_shared.zig").resolveNamedTypeInfo;

test {
    _ = @import("analyzer.zig");
}
