pub const ValueTag = enum(u8) {
    void,
    integer,
    string,
};

pub const Value = union(ValueTag) {
    void: void,
    integer: i64,
    string: []const u8,

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .void => try writer.writeAll("void"),
            .integer => |value| try writer.print("{d}", .{value}),
            .string => |value| try writer.writeAll(value),
        }
    }
};
