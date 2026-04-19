pub const Program = @import("ir.zig").Program;
pub const ImportedModule = @import("ir.zig").ImportedModule;
pub const TypeDecl = @import("ir.zig").TypeDecl;
pub const FieldDecl = @import("ir.zig").FieldDecl;
pub const StructLayout = @import("ir.zig").StructLayout;
pub const FieldLayout = @import("ir.zig").FieldLayout;
pub const ShaderDecl = @import("ir.zig").ShaderDecl;
pub const OptionDecl = @import("ir.zig").OptionDecl;
pub const GroupDecl = @import("ir.zig").GroupDecl;
pub const ResourceDecl = @import("ir.zig").ResourceDecl;
pub const Threads = @import("ir.zig").Threads;
pub const StageDecl = @import("ir.zig").StageDecl;
pub const FunctionDecl = @import("ir.zig").FunctionDecl;
pub const ParamDecl = @import("ir.zig").ParamDecl;
pub const Block = @import("ir.zig").Block;
pub const Statement = @import("ir.zig").Statement;
pub const LetStatement = @import("ir.zig").LetStatement;
pub const AssignStatement = @import("ir.zig").AssignStatement;
pub const ExprStatement = @import("ir.zig").ExprStatement;
pub const ReturnStatement = @import("ir.zig").ReturnStatement;
pub const IfStatement = @import("ir.zig").IfStatement;
pub const Expr = @import("ir.zig").Expr;
pub const Callee = @import("ir.zig").Callee;
pub const NameRef = @import("ir.zig").NameRef;
pub const ConstValue = @import("ir.zig").ConstValue;
pub const Intrinsic = @import("ir.zig").Intrinsic;

test {
    _ = @import("ir.zig");
}
