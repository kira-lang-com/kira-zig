pub const tokenize = @import("lexer.zig").tokenize;
pub const parse = @import("parser.zig").parse;

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
}
