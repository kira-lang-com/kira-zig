//! DAP wire vocabulary — the request-argument and response/event body structs of
//! the Debug Adapter Protocol subset Kira speaks, plus the small `std.json.Value`
//! accessor helpers `dap.zig` uses to read incoming request arguments.
//!
//! This module is *data only*: no I/O, no dispatch. The framing/dispatch loop and
//! the `DapHandler` interface live in `dap.zig` (Core Law #5 split). Handler-facing
//! result types intentionally reuse the shared `debug_info` contract where one
//! exists (`Frame`, `LocalView`, `StopReason`) and add DAP-specific shapes only
//! where the protocol needs a distinct field set (verified breakpoints, scopes).
const std = @import("std");

/// `initialize` response body — the capabilities Kira's adapter advertises to the
/// editor. Only flags for features actually wired in the subset are set true; the
/// rest default false so a client never sends a request we would reject.
pub const Capabilities = struct {
    supportsConfigurationDoneRequest: bool = true,
    supportsEvaluateForHovers: bool = false,
    supportsStepInTargetsRequest: bool = false,
    supportsFunctionBreakpoints: bool = false,
    supportsConditionalBreakpoints: bool = false,
    supportsSetVariable: bool = false,
    supportsRestartRequest: bool = false,
    supportsTerminateRequest: bool = true,
};

/// One requested source breakpoint from a `setBreakpoints` request. `column` is
/// optional; line stepping and resolution key on line only (see step.zig).
pub const SourceBreakpointInput = struct {
    line: u32,
    column: ?u32 = null,
};

/// The handler's verdict on one requested breakpoint, returned from
/// `setBreakpoints`. `verified` is false when the line could not be resolved to a
/// concrete backend location; `message` optionally explains why.
pub const VerifiedBreakpoint = struct {
    id: u32,
    verified: bool,
    line: u32,
    message: []const u8 = "",
};

/// A variables scope for a stack frame (DAP `scopes` response). `variables_reference`
/// is the opaque handle the client passes back to `variables`.
pub const Scope = struct {
    name: []const u8,
    variables_reference: u32,
    expensive: bool = false,
};

/// A parsed incoming DAP message envelope. `arguments` is left as a raw json value
/// because each command's argument shape differs; `dap.zig` decodes it per command
/// using the accessor helpers below.
pub const Request = struct {
    seq: i64,
    command: []const u8,
    arguments: ?std.json.Value,
};

pub const ParseError = error{
    /// The message was not a JSON object, or lacked a string `command` field.
    MalformedRequest,
};

/// Decode a top-level DAP message value into a `Request`. Does not validate the
/// `type` field beyond requiring a `command`; a client that mislabels a request is
/// still dispatched by command, which is the field that actually matters.
pub fn parseRequest(root: std.json.Value) ParseError!Request {
    if (root != .object) return error.MalformedRequest;
    const command = getString(root, "command") orelse return error.MalformedRequest;
    return .{
        .seq = getInteger(root, "seq") orelse 0,
        .command = command,
        .arguments = root.object.get("arguments"),
    };
}

// --- std.json.Value accessors -------------------------------------------------
// Small, null-returning readers so dispatch code stays free of `switch (value)`
// noise. All treat a missing key or wrong type as "absent" (null / default).

/// The value at `key` in an object value, or null if `value` is not an object or
/// has no such key.
pub fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

/// The string at `key`, or null if absent / not a string.
pub fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    return if (field == .string) field.string else null;
}

/// The integer at `key`, or null if absent / not an integer.
pub fn getInteger(value: std.json.Value, key: []const u8) ?i64 {
    const field = getField(value, key) orelse return null;
    return if (field == .integer) field.integer else null;
}

/// The integer at `key` clamped into a `u32` (negatives and absent → null). DAP
/// line/column/reference fields are non-negative; this is the safe cast site.
pub fn getU32(value: std.json.Value, key: []const u8) ?u32 {
    const n = getInteger(value, key) orelse return null;
    if (n < 0 or n > std.math.maxInt(u32)) return null;
    return @intCast(n);
}

/// The array at `key`, or null if absent / not an array.
pub fn getArray(value: std.json.Value, key: []const u8) ?std.json.Array {
    const field = getField(value, key) orelse return null;
    return if (field == .array) field.array else null;
}

/// Extract the requested breakpoint lines from a `setBreakpoints` arguments value.
/// DAP allows either `breakpoints: [{line}]` (preferred) or the legacy
/// `lines: [n]`; both are honored. Returns an owned slice allocated from `arena`.
pub fn extractBreakpointLines(
    arena: std.mem.Allocator,
    arguments: std.json.Value,
) ![]SourceBreakpointInput {
    var out: std.ArrayList(SourceBreakpointInput) = .empty;
    if (getArray(arguments, "breakpoints")) |bps| {
        for (bps.items) |item| {
            if (item != .object) continue;
            const line = getU32(item, "line") orelse continue;
            try out.append(arena, .{ .line = line, .column = getU32(item, "column") });
        }
    } else if (getArray(arguments, "lines")) |lines| {
        for (lines.items) |item| {
            if (item != .integer) continue;
            if (item.integer < 0 or item.integer > std.math.maxInt(u32)) continue;
            try out.append(arena, .{ .line = @intCast(item.integer) });
        }
    }
    return out.toOwnedSlice(arena);
}

/// The `source.path` string from a request that carries a `source` object, or null.
pub fn extractSourcePath(arguments: std.json.Value) ?[]const u8 {
    const source = getField(arguments, "source") orelse return null;
    return getString(source, "path");
}

test "parseRequest reads command, seq, arguments" {
    const alloc = std.testing.allocator;
    const text =
        \\{"seq":7,"type":"request","command":"initialize","arguments":{"clientID":"vscode"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const req = try parseRequest(parsed.value);
    try std.testing.expectEqualStrings("initialize", req.command);
    try std.testing.expectEqual(@as(i64, 7), req.seq);
    try std.testing.expect(req.arguments != null);
    try std.testing.expectEqualStrings("vscode", getString(req.arguments.?, "clientID").?);
}

test "parseRequest rejects a non-object root" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "[1,2,3]", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.MalformedRequest, parseRequest(parsed.value));
}

test "extractBreakpointLines honors breakpoints[] then lines[]" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a =
        \\{"source":{"path":"/x/main.kira"},"breakpoints":[{"line":3},{"line":9,"column":2}]}
    ;
    var pa = try std.json.parseFromSlice(std.json.Value, alloc, a, .{});
    defer pa.deinit();
    const lines_a = try extractBreakpointLines(arena, pa.value);
    try std.testing.expectEqual(@as(usize, 2), lines_a.len);
    try std.testing.expectEqual(@as(u32, 3), lines_a[0].line);
    try std.testing.expectEqual(@as(u32, 9), lines_a[1].line);
    try std.testing.expectEqual(@as(?u32, 2), lines_a[1].column);
    try std.testing.expectEqualStrings("/x/main.kira", extractSourcePath(pa.value).?);

    const b =
        \\{"lines":[4,11]}
    ;
    var pb = try std.json.parseFromSlice(std.json.Value, alloc, b, .{});
    defer pb.deinit();
    const lines_b = try extractBreakpointLines(arena, pb.value);
    try std.testing.expectEqual(@as(usize, 2), lines_b.len);
    try std.testing.expectEqual(@as(u32, 11), lines_b[1].line);
}
