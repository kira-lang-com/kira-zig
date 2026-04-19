pub const token = @import("token.zig");
pub const ast = @import("ast.zig");

pub const Token = token.Token;
pub const TokenKind = token.TokenKind;
pub const Module = ast.Module;

test {
    _ = @import("token.zig");
    _ = @import("ast.zig");
}
