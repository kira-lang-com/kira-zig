pub const Span = struct {
    start: usize,
    end: usize,
    source_path: ?[]const u8 = null,

    threadlocal var default_source_path: ?[]const u8 = null;

    pub fn init(start: usize, end: usize) Span {
        return .{
            .start = start,
            .end = end,
            .source_path = default_source_path,
        };
    }

    pub fn withSource(start: usize, end: usize, source_path: []const u8) Span {
        return .{
            .start = start,
            .end = end,
            .source_path = source_path,
        };
    }

    pub fn setDefaultSourcePath(source_path: ?[]const u8) ?[]const u8 {
        const previous = default_source_path;
        default_source_path = source_path;
        return previous;
    }

    pub fn slice(self: Span, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }
};
