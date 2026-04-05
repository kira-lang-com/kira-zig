pub const ValueTag = enum(u8) {
    void,
    integer,
    string,
    boolean,
    raw_ptr,
};

pub const Value = union(ValueTag) {
    void: void,
    integer: i64,
    string: []const u8,
    boolean: bool,
    raw_ptr: usize,

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .void => try writer.writeAll("void"),
            .integer => |value| try writer.print("{d}", .{value}),
            .string => |value| try writer.writeAll(value),
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
            .raw_ptr => |value| try writer.print("0x{x}", .{value}),
        }
    }
};
