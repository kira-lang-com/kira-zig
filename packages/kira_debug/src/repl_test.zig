//! Behavioral tests for the interactive REPL (`repl.zig`). A scripted command
//! sequence is fed through an injected fixed reader into `Repl.run`, driving a
//! `FakeSession` backed by a fake target (scripted stops, fixed frames, in-memory
//! source), and the rendered output is asserted to contain the expected stop,
//! backtrace, locals, and evaluation lines. Kept in its own file so `repl.zig`
//! stays a focused module (Core Law #5); pulled in via `repl.zig`'s `test`.
const std = @import("std");
const di = @import("debug_info.zig");
const target = @import("target.zig");
const frame_mod = @import("frame.zig");
const source = @import("kira_source");
const repl = @import("repl.zig");

const Session = repl.Session;
const StepKind = target.StepKind;

const script_source =
    \\fn main() {
    \\    let total = 0
    \\    let x = compute()
    \\    print(x)
    \\    total = total + x
    \\    return total
    \\}
    \\fn compute() { return 42 }
    \\
;

/// A fake session backed by a fake target: it records the breakpoints the REPL
/// adds/deletes, advances a "current line" on continue/step, and serves a fixed
/// two-frame stack plus in-memory source. No real backend — enough to prove the
/// REPL parses commands, calls the right method, and renders the results.
const FakeSession = struct {
    stp: frame_mod.SourceTextProvider,
    current_line: u32 = 0,
    next_id: u32 = 1,
    added: u32 = 0,
    deleted: ?u32 = null,
    last_condition: ?[]const u8 = null,
    last_watch: ?[]const u8 = null,

    fn session(self: *FakeSession) Session {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Session.VTable = .{
        .addBreakpoint = addBreakpoint,
        .deleteBreakpoint = deleteBreakpoint,
        .cont = cont,
        .step = step,
        .backtrace = backtrace,
        .locals = locals,
        .evaluate = evaluate,
        .sourceProvider = sourceProvider,
    };

    fn cast(ctx: *anyopaque) *FakeSession {
        return @ptrCast(@alignCast(ctx));
    }

    fn addBreakpoint(ctx: *anyopaque, spec: di.BreakpointSpec, condition: ?[]const u8) anyerror!u32 {
        const self = cast(ctx);
        switch (spec) {
            .watch => |w| self.last_watch = w.expr,
            else => {},
        }
        if (condition) |c| self.last_condition = c;
        const id = self.next_id;
        self.next_id += 1;
        self.added += 1;
        return id;
    }

    fn deleteBreakpoint(ctx: *anyopaque, id: u32) anyerror!void {
        cast(ctx).deleted = id;
    }

    fn cont(ctx: *anyopaque) anyerror!di.StopReason {
        const self = cast(ctx);
        self.current_line = 3;
        return .{ .breakpoint = 1 };
    }

    fn step(ctx: *anyopaque, kind: StepKind) anyerror!di.StopReason {
        const self = cast(ctx);
        _ = kind;
        self.current_line = 4;
        return .step;
    }

    fn backtrace(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]di.Frame {
        const self = cast(ctx);
        const frames = try allocator.alloc(di.Frame, 2);
        frames[0] = .{
            .index = 0,
            .backend = .vm,
            .function_id = 1,
            .function_name = "compute",
            .position = .{ .file = "main.kira", .line = self.current_line, .column = 5 },
            .program_counter = 0x10,
        };
        frames[1] = .{
            .index = 1,
            .backend = .vm,
            .function_id = 2,
            .function_name = "main",
            .position = .{ .file = "main.kira", .line = 8, .column = 1 },
            .program_counter = 0x20,
        };
        return frames;
    }

    fn locals(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]di.LocalView {
        _ = ctx;
        _ = frame_index;
        const out = try allocator.alloc(di.LocalView, 1);
        out[0] = .{ .name = "x", .type_name = "i32", .value = "10", .slot = 0 };
        return out;
    }

    fn evaluate(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8 {
        _ = ctx;
        _ = frame_index;
        _ = expr;
        return allocator.dupe(u8, "42");
    }

    fn sourceProvider(ctx: *anyopaque, file: []const u8) ?frame_mod.LineProvider {
        const self = cast(ctx);
        if (!std.mem.eql(u8, file, "main.kira")) return null;
        return self.stp.provider();
    }
};

fn runScript(alloc: std.mem.Allocator, fake: *FakeSession, script: []u8) ![]const u8 {
    var reader_state = std.Io.Reader.fixed(script);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try repl.Repl.run(alloc, fake.session(), &reader_state, &out.writer);
    // Caller owns the allocating writer's buffer via toOwnedSlice.
    return out.toOwnedSlice();
}

test "REPL drives a scripted session and renders stop/backtrace/locals" {
    const alloc = std.testing.allocator;

    var line_map = try source.LineMap.init(alloc, script_source);
    defer line_map.deinit(alloc);
    var fake = FakeSession{ .stp = frame_mod.SourceTextProvider.fromText(script_source, line_map) };

    var script =
        \\break main.kira:3
        \\break main.kira:5 if x > 0
        \\watch total
        \\continue
        \\backtrace
        \\frame 1
        \\locals
        \\print x + 1
        \\step
        \\list
        \\delete 1
        \\boguscmd
        \\quit
        \\
    .*;

    const out = try runScript(alloc, &fake, &script);
    defer alloc.free(out);

    const contains = struct {
        fn f(haystack: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, haystack, needle) != null;
        }
    }.f;

    // Breakpoint / watchpoint registration echoes.
    try std.testing.expect(contains(out, "Breakpoint #1 set at main.kira:3"));
    try std.testing.expect(contains(out, "Breakpoint #2 set at main.kira:5 if x > 0"));
    try std.testing.expect(contains(out, "Watchpoint #3 set on total"));
    try std.testing.expectEqualStrings("x > 0", fake.last_condition.?);
    try std.testing.expectEqualStrings("total", fake.last_watch.?);

    // Stop rendering: summary line + marked source context.
    try std.testing.expect(contains(out, "Stopped at breakpoint #1 in compute at main.kira:3:5"));
    try std.testing.expect(contains(out, ">    3 |"));

    // Backtrace across both frames.
    try std.testing.expect(contains(out, "#0 compute at main.kira:3:5 [vm]"));
    try std.testing.expect(contains(out, "#1 main at main.kira:8:1 [vm]"));

    // Locals and evaluate.
    try std.testing.expect(contains(out, "x: i32 = 10"));
    try std.testing.expect(contains(out, "x + 1 = 42"));

    // Step advances the source line; unknown command is reported, not fatal.
    try std.testing.expect(contains(out, "Stopped after step in compute at main.kira:4:5"));
    try std.testing.expect(contains(out, ">    4 |"));
    try std.testing.expect(contains(out, "unknown command: boguscmd"));

    // Delete reached the session.
    try std.testing.expectEqual(@as(?u32, 1), fake.deleted);
}

test "REPL reports program exit and tolerates malformed input" {
    const alloc = std.testing.allocator;

    var line_map = try source.LineMap.init(alloc, script_source);
    defer line_map.deinit(alloc);
    var fake = FakeSession{ .stp = frame_mod.SourceTextProvider.fromText(script_source, line_map) };

    // No trailing quit: the loop must end cleanly at EOF. Malformed commands
    // (bad line, missing args) must not crash.
    var script =
        \\break notaloc
        \\break main.kira:xx
        \\delete abc
        \\print
        \\help
        \\
    .*;

    const out = try runScript(alloc, &fake, &script);
    defer alloc.free(out);

    const contains = struct {
        fn f(haystack: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, haystack, needle) != null;
        }
    }.f;

    try std.testing.expect(contains(out, "usage: break FILE:LINE"));
    try std.testing.expect(contains(out, "bad line number: xx"));
    try std.testing.expect(contains(out, "usage: delete ID"));
    try std.testing.expect(contains(out, "usage: print EXPR"));
    try std.testing.expect(contains(out, "Commands:"));
    // Nothing was successfully added despite the malformed break lines.
    try std.testing.expectEqual(@as(u32, 0), fake.added);
}
