const std = @import("std");

pub const LineColumn = struct {
    line: usize,
    column: usize,
};

pub const LineMap = struct {
    line_starts: []usize,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !LineMap {
        var starts = std.array_list.Managed(usize).init(allocator);
        try starts.append(0);
        for (text, 0..) |byte, index| {
            if (byte == '\n' and index + 1 <= text.len) {
                try starts.append(index + 1);
            }
        }
        return .{ .line_starts = try starts.toOwnedSlice() };
    }

    pub fn deinit(self: LineMap, allocator: std.mem.Allocator) void {
        allocator.free(self.line_starts);
    }

    pub fn lineColumn(self: LineMap, offset: usize) LineColumn {
        const line_index = self.lineIndex(offset);
        const line_start = self.line_starts[line_index];
        return .{
            .line = line_index + 1,
            .column = offset - line_start + 1,
        };
    }

    pub fn lineIndex(self: LineMap, offset: usize) usize {
        var line_index: usize = 0;
        while (line_index + 1 < self.line_starts.len and self.line_starts[line_index + 1] <= offset) : (line_index += 1) {}
        return line_index;
    }

    pub fn lineBounds(self: LineMap, line_index: usize, text: []const u8) struct { start: usize, end: usize } {
        const start = self.line_starts[line_index];
        const raw_end = if (line_index + 1 < self.line_starts.len) self.line_starts[line_index + 1] else text.len;
        const end = if (raw_end > start and text[raw_end - 1] == '\n') raw_end - 1 else raw_end;
        return .{ .start = start, .end = end };
    }
};
