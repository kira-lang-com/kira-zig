//! repl — the interactive terminal front-end for Kira's debugger. It reads
//! command lines from an injected `*std.Io.Reader`, drives a backend-agnostic
//! `Session`, and renders results to an injected `*std.Io.Writer` using the pure
//! formatters in `frame.zig`. Reader/writer are injected (never `std.io`
//! globals) so the whole loop is unit-testable against a scripted input and a
//! fake session — same parity guarantee the DAP server keeps: one REPL drives a
//! VM, native, or hybrid session identically.
//!
//! `Session` is a small vtable the REPL needs, deliberately narrower than the
//! full debug session: add/delete breakpoints (with an optional condition),
//! resume/step, backtrace, locals, evaluate, and a source-line provider for the
//! stopped-source view. The integration stage implements it by wrapping the real
//! `DebugTarget` + breakpoint registry; tests implement it with a fake target.
//!
//! Parsing is intentionally small and total: an unknown or malformed command
//! prints a helpful message and never crashes or aborts the loop. Only a genuine
//! I/O failure on the reader/writer ends the session.
const std = @import("std");
const di = @import("debug_info.zig");
const target = @import("target.zig");
const frame_mod = @import("frame.zig");

const StepKind = target.StepKind;

/// The backend-agnostic operations the REPL invokes. A method that produces
/// owned data takes a per-command `allocator` (the REPL passes an arena that it
/// frees after the command renders, so implementations never track lifetimes).
/// Every method may fail; the REPL reports the error and keeps the prompt alive.
pub const Session = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Register a breakpoint/watchpoint; `condition` is an optional guard
        /// expression (from `break FILE:LINE if COND`). Returns its new id.
        addBreakpoint: *const fn (ctx: *anyopaque, spec: di.BreakpointSpec, condition: ?[]const u8) anyerror!u32,
        /// Remove a breakpoint/watchpoint by id.
        deleteBreakpoint: *const fn (ctx: *anyopaque, id: u32) anyerror!void,
        /// Resume until the next stop.
        cont: *const fn (ctx: *anyopaque) anyerror!di.StopReason,
        /// One step of the given kind (into/over/out/instruction).
        step: *const fn (ctx: *anyopaque, kind: StepKind) anyerror!di.StopReason,
        /// Current call stack, innermost frame first.
        backtrace: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]di.Frame,
        /// Locals/parameters visible in `frame_index`.
        locals: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]di.LocalView,
        /// Evaluate `expr` in `frame_index`, returning its rendering.
        evaluate: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8,
        /// A source-line provider for `file`, or null when its text is unavailable.
        sourceProvider: *const fn (ctx: *anyopaque, file: []const u8) ?frame_mod.LineProvider,
    };

    pub fn addBreakpoint(self: Session, spec: di.BreakpointSpec, condition: ?[]const u8) !u32 {
        return self.vtable.addBreakpoint(self.ptr, spec, condition);
    }
    pub fn deleteBreakpoint(self: Session, id: u32) !void {
        return self.vtable.deleteBreakpoint(self.ptr, id);
    }
    pub fn cont(self: Session) !di.StopReason {
        return self.vtable.cont(self.ptr);
    }
    pub fn step(self: Session, kind: StepKind) !di.StopReason {
        return self.vtable.step(self.ptr, kind);
    }
    pub fn backtrace(self: Session, allocator: std.mem.Allocator) ![]di.Frame {
        return self.vtable.backtrace(self.ptr, allocator);
    }
    pub fn locals(self: Session, allocator: std.mem.Allocator, frame_index: u32) ![]di.LocalView {
        return self.vtable.locals(self.ptr, allocator, frame_index);
    }
    pub fn evaluate(self: Session, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) ![]const u8 {
        return self.vtable.evaluate(self.ptr, allocator, frame_index, expr);
    }
    pub fn sourceProvider(self: Session, file: []const u8) ?frame_mod.LineProvider {
        return self.vtable.sourceProvider(self.ptr, file);
    }
};

/// Radius (lines each side) of the source window shown on a stop and by `list`.
const stop_radius: u32 = 2;
const list_radius: u32 = 5;

const prompt = "(kdbg) ";

const help_text =
    \\Commands:
    \\  break FILE:LINE [if COND] | b   set a breakpoint (optional condition)
    \\  watch EXPR                      set a data watchpoint on EXPR
    \\  delete ID                       remove breakpoint/watchpoint ID
    \\  continue | c                    resume until the next stop
    \\  step | s                        step one line, into calls
    \\  next | n                        step one line, over calls
    \\  finish | fin                    run until the current function returns
    \\  stepi | si                      step one backend instruction
    \\  backtrace | bt                  print the call stack
    \\  frame N                         select stack frame N
    \\  locals                          list locals in the selected frame
    \\  print EXPR | p                  evaluate EXPR in the selected frame
    \\  list | l                        show source around the selected frame
    \\  help                            show this help
    \\  quit | q                        leave the debugger
    \\
;

/// The interactive debugger REPL. `run` owns the read→dispatch→render loop; all
/// per-command state lives in a private `Loop`.
pub const Repl = struct {
    /// Drive the REPL until the input stream ends or `quit` is entered. `reader`
    /// and `writer` are injected so callers wire stdin/stdout (or test buffers).
    /// `allocator` backs a short-lived arena per command for owned results.
    pub fn run(
        allocator: std.mem.Allocator,
        session: Session,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) !void {
        var loop = Loop{
            .allocator = allocator,
            .session = session,
            .writer = writer,
            .current_frame = 0,
        };

        try writer.writeAll("Kira debugger. Type 'help' for commands.\n");
        while (true) {
            try writer.writeAll(prompt);
            try writer.flush();

            const raw = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    try writer.print("input error: {s}\n", .{@errorName(err)});
                    try writer.flush();
                    break;
                },
            };
            const line = std.mem.trim(u8, raw, " \t\r\n");
            if (line.len == 0) continue;

            const quit = try loop.handle(line);
            try writer.flush();
            if (quit) break;
        }
    }
};

/// Per-session mutable state and command handlers. Separated from `Repl` so the
/// public surface stays a single `run` entry point.
const Loop = struct {
    allocator: std.mem.Allocator,
    session: Session,
    writer: *std.Io.Writer,
    /// The stack frame subsequent `locals`/`print`/`list` operate on. Reset to 0
    /// (innermost) on every fresh stop.
    current_frame: u32,

    /// Parse and execute one non-empty command line. Returns true when the user
    /// asked to quit. Only writer I/O failures propagate; every session-level or
    /// parse error is rendered inline and swallowed so the loop survives.
    fn handle(self: *Loop, line: []const u8) !bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const split = splitFirst(line);
        const cmd = split.head;
        const rest = split.rest;

        if (eqAny(cmd, &.{ "quit", "q" })) return true;
        if (eqAny(cmd, &.{ "help", "h" })) {
            try self.writer.writeAll(help_text);
        } else if (eqAny(cmd, &.{ "break", "b" })) {
            try self.cmdBreak(rest);
        } else if (eqAny(cmd, &.{"watch"})) {
            try self.cmdWatch(rest);
        } else if (eqAny(cmd, &.{ "delete", "d" })) {
            try self.cmdDelete(rest);
        } else if (eqAny(cmd, &.{ "continue", "c" })) {
            const reason = self.session.cont() catch |e| {
                try self.reportErr(e);
                return false;
            };
            try self.resume_(arena, reason);
        } else if (eqAny(cmd, &.{ "step", "s" })) {
            try self.stepBy(arena, .into);
        } else if (eqAny(cmd, &.{ "next", "n" })) {
            try self.stepBy(arena, .over);
        } else if (eqAny(cmd, &.{ "finish", "fin" })) {
            try self.stepBy(arena, .out);
        } else if (eqAny(cmd, &.{ "stepi", "si" })) {
            try self.stepBy(arena, .instruction);
        } else if (eqAny(cmd, &.{ "backtrace", "bt" })) {
            try self.cmdBacktrace(arena);
        } else if (eqAny(cmd, &.{"frame"})) {
            try self.cmdFrame(arena, rest);
        } else if (eqAny(cmd, &.{"locals"})) {
            try self.cmdLocals(arena);
        } else if (eqAny(cmd, &.{ "print", "p" })) {
            try self.cmdPrint(arena, rest);
        } else if (eqAny(cmd, &.{ "list", "l" })) {
            try self.cmdList(arena);
        } else {
            try self.writer.print("unknown command: {s} (type 'help')\n", .{cmd});
        }
        return false;
    }

    // --- breakpoint commands --------------------------------------------------

    fn cmdBreak(self: *Loop, rest: []const u8) !void {
        if (rest.len == 0) {
            try self.writer.writeAll("usage: break FILE:LINE [if COND]\n");
            return;
        }
        // Split off an optional `if COND` guard.
        var loc = rest;
        var cond: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, " if ")) |i| {
            loc = std.mem.trim(u8, rest[0..i], " \t");
            const c = std.mem.trim(u8, rest[i + 4 ..], " \t");
            if (c.len > 0) cond = c;
        }
        const colon = std.mem.lastIndexOfScalar(u8, loc, ':') orelse {
            try self.writer.writeAll("usage: break FILE:LINE [if COND]\n");
            return;
        };
        const file = std.mem.trim(u8, loc[0..colon], " \t");
        const line_text = std.mem.trim(u8, loc[colon + 1 ..], " \t");
        const line_no = std.fmt.parseInt(u32, line_text, 10) catch {
            try self.writer.print("bad line number: {s}\n", .{line_text});
            return;
        };
        if (file.len == 0) {
            try self.writer.writeAll("usage: break FILE:LINE [if COND]\n");
            return;
        }
        const spec = di.BreakpointSpec{ .line = .{ .file = file, .line = line_no } };
        const id = self.session.addBreakpoint(spec, cond) catch |e| return self.reportErr(e);
        if (cond) |c| {
            try self.writer.print("Breakpoint #{d} set at {s}:{d} if {s}\n", .{ id, file, line_no, c });
        } else {
            try self.writer.print("Breakpoint #{d} set at {s}:{d}\n", .{ id, file, line_no });
        }
    }

    fn cmdWatch(self: *Loop, rest: []const u8) !void {
        const expr = std.mem.trim(u8, rest, " \t");
        if (expr.len == 0) {
            try self.writer.writeAll("usage: watch EXPR\n");
            return;
        }
        const spec = di.BreakpointSpec{ .watch = .{ .expr = expr, .kind = .write } };
        const id = self.session.addBreakpoint(spec, null) catch |e| return self.reportErr(e);
        try self.writer.print("Watchpoint #{d} set on {s}\n", .{ id, expr });
    }

    fn cmdDelete(self: *Loop, rest: []const u8) !void {
        const id_text = std.mem.trim(u8, rest, " \t");
        const id = std.fmt.parseInt(u32, id_text, 10) catch {
            try self.writer.writeAll("usage: delete ID\n");
            return;
        };
        self.session.deleteBreakpoint(id) catch |e| return self.reportErr(e);
        try self.writer.print("Deleted #{d}\n", .{id});
    }

    // --- execution commands ---------------------------------------------------

    fn stepBy(self: *Loop, arena: std.mem.Allocator, kind: StepKind) !void {
        const reason = self.session.step(kind) catch |e| return self.reportErr(e);
        try self.resume_(arena, reason);
    }

    /// Render a stop: the one-line summary (with the innermost frame) followed by
    /// a source-context window. Program exit/entry render a summary only. Resets
    /// the selected frame to the innermost.
    fn resume_(self: *Loop, arena: std.mem.Allocator, reason: di.StopReason) !void {
        self.current_frame = 0;
        switch (reason) {
            .exited, .entry => {
                try frame_mod.formatStop(self.writer, reason, null);
                return;
            },
            else => {},
        }
        const frames = self.session.backtrace(arena) catch |e| {
            try frame_mod.formatStop(self.writer, reason, null);
            return self.reportErr(e);
        };
        const top: ?di.Frame = if (frames.len > 0) frames[0] else null;
        try frame_mod.formatStop(self.writer, reason, top);
        if (top) |f| {
            if (f.position) |pos| try self.renderSource(pos, stop_radius);
        }
    }

    // --- inspection commands --------------------------------------------------

    fn cmdBacktrace(self: *Loop, arena: std.mem.Allocator) !void {
        const frames = self.session.backtrace(arena) catch |e| return self.reportErr(e);
        if (frames.len == 0) {
            try self.writer.writeAll("(no stack)\n");
            return;
        }
        try frame_mod.formatBacktrace(self.writer, frames);
    }

    fn cmdFrame(self: *Loop, arena: std.mem.Allocator, rest: []const u8) !void {
        const n_text = std.mem.trim(u8, rest, " \t");
        const n = std.fmt.parseInt(u32, n_text, 10) catch {
            try self.writer.writeAll("usage: frame N\n");
            return;
        };
        const frames = self.session.backtrace(arena) catch |e| return self.reportErr(e);
        if (n >= frames.len) {
            try self.writer.print("no such frame #{d}\n", .{n});
            return;
        }
        self.current_frame = n;
        try frame_mod.formatBacktrace(self.writer, frames[n .. n + 1]);
        if (frames[n].position) |pos| try self.renderSource(pos, stop_radius);
    }

    fn cmdLocals(self: *Loop, arena: std.mem.Allocator) !void {
        const locals = self.session.locals(arena, self.current_frame) catch |e| return self.reportErr(e);
        if (locals.len == 0) {
            try self.writer.writeAll("(no locals)\n");
            return;
        }
        for (locals) |lv| {
            if (lv.type_name.len > 0) {
                try self.writer.print("  {s}: {s} = {s}\n", .{ lv.name, lv.type_name, lv.value });
            } else {
                try self.writer.print("  {s} = {s}\n", .{ lv.name, lv.value });
            }
        }
    }

    fn cmdPrint(self: *Loop, arena: std.mem.Allocator, rest: []const u8) !void {
        const expr = std.mem.trim(u8, rest, " \t");
        if (expr.len == 0) {
            try self.writer.writeAll("usage: print EXPR\n");
            return;
        }
        const value = self.session.evaluate(arena, self.current_frame, expr) catch |e| return self.reportErr(e);
        try self.writer.print("{s} = {s}\n", .{ expr, value });
    }

    fn cmdList(self: *Loop, arena: std.mem.Allocator) !void {
        const frames = self.session.backtrace(arena) catch |e| return self.reportErr(e);
        if (self.current_frame >= frames.len) {
            try self.writer.writeAll("(no frame)\n");
            return;
        }
        if (frames[self.current_frame].position) |pos| {
            try self.renderSource(pos, list_radius);
        } else {
            try self.writer.writeAll("(no source for this frame)\n");
        }
    }

    // --- helpers --------------------------------------------------------------

    fn renderSource(self: *Loop, pos: di.SourcePosition, radius: u32) !void {
        if (self.session.sourceProvider(pos.file)) |provider| {
            try frame_mod.formatStoppedSource(self.writer, provider, pos, radius);
        }
    }

    fn reportErr(self: *Loop, err: anyerror) !void {
        try self.writer.print("error: {s}\n", .{@errorName(err)});
    }
};

/// Split a line into its first whitespace-delimited word and the trimmed remainder.
fn splitFirst(line: []const u8) struct { head: []const u8, rest: []const u8 } {
    const t = std.mem.trim(u8, line, " \t");
    const sp = std.mem.indexOfAny(u8, t, " \t") orelse return .{ .head = t, .rest = "" };
    return .{ .head = t[0..sp], .rest = std.mem.trim(u8, t[sp..], " \t") };
}

/// True when `word` equals any of `options`.
fn eqAny(word: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.mem.eql(u8, word, o)) return true;
    }
    return false;
}

test {
    _ = @import("repl_test.zig");
}
