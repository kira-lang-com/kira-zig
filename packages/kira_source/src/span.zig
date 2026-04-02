pub const Span = struct {
    start: usize,
    end: usize,

    pub fn init(start: usize, end: usize) Span {
        return .{ .start = start, .end = end };
    }

    pub fn slice(self: Span, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }
};
