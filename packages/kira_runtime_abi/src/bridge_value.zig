const std = @import("std");
const value = @import("value.zig");

pub const BridgeValueTag = enum(u8) {
    void = @intFromEnum(value.ValueTag.void),
    integer = @intFromEnum(value.ValueTag.integer),
    float = @intFromEnum(value.ValueTag.float),
    string = @intFromEnum(value.ValueTag.string),
    boolean = @intFromEnum(value.ValueTag.boolean),
    raw_ptr = @intFromEnum(value.ValueTag.raw_ptr),
    _,
};

pub const BridgeString = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const BridgePayload = extern union {
    integer: i64,
    float: f64,
    string: BridgeString,
    boolean: u8,
    raw_ptr: usize,
};

pub const BridgeValue = extern struct {
    tag: BridgeValueTag,
    reserved: [7]u8 = [_]u8{0} ** 7,
    payload: BridgePayload = .{ .raw_ptr = 0 },
};

pub fn fromValue(v: value.Value) BridgeValue {
    return switch (v) {
        .void => .{ .tag = .void, .payload = .{ .raw_ptr = 0 } },
        .integer => |inner| .{ .tag = .integer, .payload = .{ .integer = inner } },
        .float => |inner| .{ .tag = .float, .payload = .{ .float = inner } },
        .string => |inner| .{ .tag = .string, .payload = .{ .string = .{
            .ptr = if (inner.len == 0) null else inner.ptr,
            .len = inner.len,
        } } },
        .boolean => |inner| .{ .tag = .boolean, .payload = .{ .boolean = if (inner) 1 else 0 } },
        .raw_ptr => |inner| .{ .tag = .raw_ptr, .payload = .{ .raw_ptr = inner } },
    };
}

pub fn toValue(v: BridgeValue) value.Value {
    return switch (v.tag) {
        .void => .{ .void = {} },
        .integer => .{ .integer = v.payload.integer },
        .float => .{ .float = v.payload.float },
        .string => .{ .string = if (v.payload.string.ptr) |ptr| ptr[0..v.payload.string.len] else "" },
        .boolean => .{ .boolean = v.payload.boolean != 0 },
        .raw_ptr => .{ .raw_ptr = v.payload.raw_ptr },
        _ => .{ .void = {} },
    };
}

test "round-trips bridge values" {
    const samples = [_]value.Value{
        .{ .void = {} },
        .{ .integer = 42 },
        .{ .float = 3.5 },
        .{ .string = "hello" },
        .{ .boolean = true },
        .{ .raw_ptr = 99 },
    };

    for (samples) |sample| {
        const lowered = fromValue(sample);
        const raised = toValue(lowered);
        switch (sample) {
            .void => try std.testing.expect(raised == .void),
            .integer => |inner| try std.testing.expectEqual(inner, raised.integer),
            .float => |inner| try std.testing.expectEqual(inner, raised.float),
            .string => |inner| try std.testing.expectEqualStrings(inner, raised.string),
            .boolean => |inner| try std.testing.expectEqual(inner, raised.boolean),
            .raw_ptr => |inner| try std.testing.expectEqual(inner, raised.raw_ptr),
        }
    }
}

test "invalid bridge tag degrades to void" {
    const invalid = BridgeValue{
        .tag = @enumFromInt(255),
        .payload = .{ .raw_ptr = 1234 },
    };
    const converted = toValue(invalid);
    try std.testing.expect(converted == .void);
}
