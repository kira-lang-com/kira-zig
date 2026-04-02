pub const hir = @import("hir.zig");
pub const symbols = @import("symbols.zig");
pub const types = @import("types.zig");
pub const scopes = @import("scopes.zig");

pub const Program = hir.Program;
pub const Function = hir.Function;
pub const Statement = hir.Statement;
pub const Expr = hir.Expr;
pub const FunctionExecution = @import("kira_runtime_abi").FunctionExecution;
pub const LocalSymbol = symbols.LocalSymbol;
pub const Type = types.Type;
pub const Scope = scopes.Scope;
pub const LocalBinding = scopes.LocalBinding;
