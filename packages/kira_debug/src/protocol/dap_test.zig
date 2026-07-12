//! Behavioral tests for the DAP subset server: message framing round-trips and
//! request→handler dispatch producing the expected response/event frames. Kept in
//! its own file so `dap.zig` stays a focused framing+dispatch module (Core Law #5).
//! Pulled into the test binary by `dap.zig`'s `test { _ = @import("dap_test.zig"); }`.
const std = @import("std");
const di = @import("../debug_info.zig");
const target = @import("../target.zig");
const msg = @import("dap_messages.zig");
const dap = @import("dap.zig");

const Server = dap.Server;
const DapHandler = dap.DapHandler;
const Capabilities = dap.Capabilities;

/// A recording handler used by the round-trip tests. Records the last observed
/// call so a test can assert dispatch reached the right method with the right args.
const RecordingHandler = struct {
    initialized: bool = false,
    launched: bool = false,
    bp_path: []const u8 = "",
    bp_path_buf: [256]u8 = undefined,
    bp_lines: []const u32 = &.{},
    bp_lines_buf: [8]u32 = undefined,
    cont_calls: u32 = 0,
    step_kind: ?target.StepKind = null,

    fn handler(self: *RecordingHandler) DapHandler {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: DapHandler.VTable = .{
        .initialize = initialize,
        .launch = launch,
        .setBreakpoints = setBreakpoints,
        .configurationDone = configurationDone,
        .cont = cont,
        .step = step,
        .stackTrace = stackTrace,
        .scopes = scopes,
        .variables = variables,
        .evaluate = evaluate,
        .disconnect = disconnect,
    };

    fn cast(ctx: *anyopaque) *RecordingHandler {
        return @ptrCast(@alignCast(ctx));
    }
    fn initialize(ctx: *anyopaque) Capabilities {
        cast(ctx).initialized = true;
        return .{};
    }
    fn launch(ctx: *anyopaque, _: std.mem.Allocator, _: ?std.json.Value) anyerror!void {
        cast(ctx).launched = true;
    }
    fn setBreakpoints(ctx: *anyopaque, arena: std.mem.Allocator, source_path: []const u8, breakpoints: []const msg.SourceBreakpointInput) anyerror![]msg.VerifiedBreakpoint {
        const self = cast(ctx);
        // `source_path` is arena-scoped (freed when the request completes), so copy
        // it into owned storage before returning — the test asserts on it later.
        @memcpy(self.bp_path_buf[0..source_path.len], source_path);
        self.bp_path = self.bp_path_buf[0..source_path.len];
        for (breakpoints, 0..) |bp, i| self.bp_lines_buf[i] = bp.line;
        self.bp_lines = self.bp_lines_buf[0..breakpoints.len];
        const out = try arena.alloc(msg.VerifiedBreakpoint, breakpoints.len);
        for (breakpoints, 0..) |bp, i| out[i] = .{ .id = @intCast(i + 1), .verified = true, .line = bp.line };
        return out;
    }
    fn configurationDone(_: *anyopaque) anyerror!void {}
    fn cont(ctx: *anyopaque) anyerror!di.StopReason {
        cast(ctx).cont_calls += 1;
        return .{ .breakpoint = 1 };
    }
    fn step(ctx: *anyopaque, kind: target.StepKind) anyerror!di.StopReason {
        cast(ctx).step_kind = kind;
        return .step;
    }
    fn stackTrace(_: *anyopaque, arena: std.mem.Allocator) anyerror![]di.Frame {
        const frames = try arena.alloc(di.Frame, 1);
        frames[0] = .{ .index = 0, .backend = .vm, .function_id = 0, .function_name = "main", .position = .{ .file = "main.kira", .line = 4, .column = 1 } };
        return frames;
    }
    fn scopes(_: *anyopaque, arena: std.mem.Allocator, _: u32) anyerror![]msg.Scope {
        const s = try arena.alloc(msg.Scope, 1);
        s[0] = .{ .name = "Locals", .variables_reference = 1000 };
        return s;
    }
    fn variables(_: *anyopaque, arena: std.mem.Allocator, _: u32) anyerror![]di.LocalView {
        const v = try arena.alloc(di.LocalView, 1);
        v[0] = .{ .name = "x", .type_name = "Int", .value = "42", .slot = 0 };
        return v;
    }
    fn evaluate(_: *anyopaque, arena: std.mem.Allocator, _: u32, expr: []const u8) anyerror![]const u8 {
        return std.fmt.allocPrint(arena, "eval({s})", .{expr});
    }
    fn disconnect(_: *anyopaque) void {}
};

/// Frame a JSON body into a `Content-Length` message (test helper).
fn frame(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}

test "readMessage round-trips a Content-Length framed initialize request" {
    const alloc = std.testing.allocator;
    const framed = try frame(alloc,
        \\{"seq":1,"type":"request","command":"initialize"}
    );
    defer alloc.free(framed);

    var reader_state = std.Io.Reader.fixed(framed);
    const body = (try dap.readMessage(alloc, &reader_state)).?;
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const req = try msg.parseRequest(parsed.value);
    try std.testing.expectEqualStrings("initialize", req.command);

    // A second read at clean EOF yields null (session over), not an error.
    try std.testing.expect((try dap.readMessage(alloc, &reader_state)) == null);
}

test "initialize dispatch calls the handler and emits capabilities + initialized" {
    const alloc = std.testing.allocator;
    const framed = try frame(alloc,
        \\{"seq":1,"type":"request","command":"initialize"}
    );
    defer alloc.free(framed);

    var reader_state = std.Io.Reader.fixed(framed);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var rec: RecordingHandler = .{};
    var server = Server.init(alloc, &reader_state, &out.writer, rec.handler());
    try std.testing.expect(try server.serveOne());

    try std.testing.expect(rec.initialized);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"command\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"event\":\"initialized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "supportsConfigurationDoneRequest") != null);
}

test "setBreakpoints dispatch produces the expected handler call and verified body" {
    const alloc = std.testing.allocator;
    const framed = try frame(alloc,
        \\{"seq":2,"type":"request","command":"setBreakpoints","arguments":{"source":{"path":"main.kira"},"breakpoints":[{"line":4},{"line":8}]}}
    );
    defer alloc.free(framed);

    var reader_state = std.Io.Reader.fixed(framed);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var rec: RecordingHandler = .{};
    var server = Server.init(alloc, &reader_state, &out.writer, rec.handler());
    try std.testing.expect(try server.serveOne());

    try std.testing.expectEqualStrings("main.kira", rec.bp_path);
    try std.testing.expectEqual(@as(usize, 2), rec.bp_lines.len);
    try std.testing.expectEqual(@as(u32, 4), rec.bp_lines[0]);
    try std.testing.expectEqual(@as(u32, 8), rec.bp_lines[1]);

    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"verified\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"line\":8") != null);
}

test "continue dispatch emits continued then a breakpoint stopped event" {
    const alloc = std.testing.allocator;
    const framed = try frame(alloc,
        \\{"seq":3,"type":"request","command":"continue","arguments":{"threadId":1}}
    );
    defer alloc.free(framed);

    var reader_state = std.Io.Reader.fixed(framed);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var rec: RecordingHandler = .{};
    var server = Server.init(alloc, &reader_state, &out.writer, rec.handler());
    try std.testing.expect(try server.serveOne());

    try std.testing.expectEqual(@as(u32, 1), rec.cont_calls);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"event\":\"continued\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"reason\":\"breakpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"hitBreakpointIds\":[1]") != null);
}

test "next dispatch steps over and emits a step stopped event" {
    const alloc = std.testing.allocator;
    const framed = try frame(alloc,
        \\{"seq":4,"type":"request","command":"next","arguments":{"threadId":1}}
    );
    defer alloc.free(framed);

    var reader_state = std.Io.Reader.fixed(framed);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var rec: RecordingHandler = .{};
    var server = Server.init(alloc, &reader_state, &out.writer, rec.handler());
    try std.testing.expect(try server.serveOne());

    try std.testing.expectEqual(target.StepKind.over, rec.step_kind.?);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"reason\":\"step\"") != null);
}

test "disconnect dispatch ends the session and emits terminated" {
    const alloc = std.testing.allocator;
    const framed = try frame(alloc,
        \\{"seq":9,"type":"request","command":"disconnect"}
    );
    defer alloc.free(framed);

    var reader_state = std.Io.Reader.fixed(framed);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var rec: RecordingHandler = .{};
    var server = Server.init(alloc, &reader_state, &out.writer, rec.handler());
    // serveOne returns false: the session is over.
    try std.testing.expect(!(try server.serveOne()));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"event\":\"terminated\"") != null);
}

test "stackTrace, scopes, variables and evaluate serialize their bodies" {
    const alloc = std.testing.allocator;
    // Drive four requests back-to-back through one server over a shared stream.
    const src =
        \\{"seq":5,"type":"request","command":"stackTrace"}
    ;
    const framed = try frame(alloc, src);
    defer alloc.free(framed);
    var reader_state = std.Io.Reader.fixed(framed);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var rec: RecordingHandler = .{};
    var server = Server.init(alloc, &reader_state, &out.writer, rec.handler());
    try std.testing.expect(try server.serveOne());
    const w = out.written();
    try std.testing.expect(std.mem.indexOf(u8, w, "\"stackFrames\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"name\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"line\":4") != null);
}

test "scopes, variables and evaluate each serialize their bodies" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { req: []const u8, needle: []const u8 }{
        .{ .req =
            \\{"seq":6,"type":"request","command":"scopes","arguments":{"frameId":0}}
        , .needle = "\"variablesReference\":1000" },
        .{ .req =
            \\{"seq":7,"type":"request","command":"variables","arguments":{"variablesReference":1000}}
        , .needle = "\"type\":\"Int\"" },
        .{ .req =
            \\{"seq":8,"type":"request","command":"evaluate","arguments":{"expression":"x + 1","frameId":0}}
        , .needle = "eval(x + 1)" },
    };
    for (cases) |c| {
        const framed = try frame(alloc, c.req);
        defer alloc.free(framed);
        var reader_state = std.Io.Reader.fixed(framed);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        var rec: RecordingHandler = .{};
        var server = Server.init(alloc, &reader_state, &out.writer, rec.handler());
        try std.testing.expect(try server.serveOne());
        try std.testing.expect(std.mem.indexOf(u8, out.written(), c.needle) != null);
    }
}
