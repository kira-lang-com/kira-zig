//! DAP subset server — the editor-facing driver for Kira's debugger. Editors like
//! VS Code speak the Debug Adapter Protocol: newline-delimited HTTP-style
//! `Content-Length` frames carrying JSON request/response/event messages. This
//! module implements the framing (read/write over an injected `*std.Io.Reader` /
//! `*std.Io.Writer`) and the request→`DapHandler` dispatch for the subset Kira
//! supports, then emits the matching events.
//!
//! It is deliberately *not* bound to a concrete debug session: the session
//! implements the `DapHandler` vtable and returns the shared `debug_info` contract
//! types (`StopReason`, `Frame`, `LocalView`). That keeps this file backend-
//! agnostic — the same server drives a VM, native, or hybrid session identically,
//! which is the parity guarantee. Message *vocabulary* (argument decoding,
//! response/event body shapes) lives in `dap_messages.zig` (Core Law #5 split).
const std = @import("std");
const di = @import("../debug_info.zig");
const target = @import("../target.zig");
const msg = @import("dap_messages.zig");

pub const Capabilities = msg.Capabilities;
pub const Request = msg.Request;

/// Kira's debugger is single-threaded from DAP's point of view: one Kira program,
/// one logical thread. The protocol still requires a thread id on stop/continue.
pub const default_thread_id: i64 = 1;

pub const FrameError = error{
    /// A frame's `Content-Length` header was missing or unparseable.
    MissingContentLength,
    /// The stream ended partway through a message (after a header, before the body).
    UnexpectedEof,
};

// --- DapHandler: the session-implemented interface ---------------------------

/// The interface a debug session exposes to the DAP server. Every method maps to
/// a `DebugTarget`-level operation; the session owns the actual VM/native/hybrid
/// target and translates. Methods that produce owned data take a per-request
/// `arena` allocator — the server frees it after the response is written, so
/// handlers never need to track lifetimes.
pub const DapHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `initialize`: advertise supported features.
        initialize: *const fn (ctx: *anyopaque) Capabilities,
        /// `launch`: begin a debug session with the given launch arguments (raw
        /// JSON, since the shape is client/config-defined). No stop is emitted
        /// here; the first stop comes from `configurationDone`/`continue`.
        launch: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, arguments: ?std.json.Value) anyerror!void,
        /// `setBreakpoints`: replace all breakpoints in one source file, returning
        /// the verified verdict per requested line.
        setBreakpoints: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, source_path: []const u8, breakpoints: []const msg.SourceBreakpointInput) anyerror![]msg.VerifiedBreakpoint,
        /// `configurationDone`: the client has finished initial configuration.
        configurationDone: *const fn (ctx: *anyopaque) anyerror!void,
        /// `continue`: resume until the next stop.
        cont: *const fn (ctx: *anyopaque) anyerror!di.StopReason,
        /// `next`/`stepIn`/`stepOut`: one source-line step of the given kind.
        step: *const fn (ctx: *anyopaque, kind: target.StepKind) anyerror!di.StopReason,
        /// `stackTrace`: the current call stack, innermost frame first.
        stackTrace: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]di.Frame,
        /// `scopes`: variable scopes for a stack frame.
        scopes: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, frame_id: u32) anyerror![]msg.Scope,
        /// `variables`: the variables under a scope reference.
        variables: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, variables_reference: u32) anyerror![]di.LocalView,
        /// `evaluate`: evaluate an expression in a frame, returning its rendering.
        evaluate: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, frame_id: u32, expr: []const u8) anyerror![]const u8,
        /// `disconnect`: tear the session down.
        disconnect: *const fn (ctx: *anyopaque) void,
    };

    pub fn initialize(self: DapHandler) Capabilities {
        return self.vtable.initialize(self.ptr);
    }
    pub fn launch(self: DapHandler, arena: std.mem.Allocator, arguments: ?std.json.Value) !void {
        return self.vtable.launch(self.ptr, arena, arguments);
    }
    pub fn setBreakpoints(self: DapHandler, arena: std.mem.Allocator, source_path: []const u8, breakpoints: []const msg.SourceBreakpointInput) ![]msg.VerifiedBreakpoint {
        return self.vtable.setBreakpoints(self.ptr, arena, source_path, breakpoints);
    }
    pub fn configurationDone(self: DapHandler) !void {
        return self.vtable.configurationDone(self.ptr);
    }
    pub fn cont(self: DapHandler) !di.StopReason {
        return self.vtable.cont(self.ptr);
    }
    pub fn step(self: DapHandler, kind: target.StepKind) !di.StopReason {
        return self.vtable.step(self.ptr, kind);
    }
    pub fn stackTrace(self: DapHandler, arena: std.mem.Allocator) ![]di.Frame {
        return self.vtable.stackTrace(self.ptr, arena);
    }
    pub fn scopes(self: DapHandler, arena: std.mem.Allocator, frame_id: u32) ![]msg.Scope {
        return self.vtable.scopes(self.ptr, arena, frame_id);
    }
    pub fn variables(self: DapHandler, arena: std.mem.Allocator, variables_reference: u32) ![]di.LocalView {
        return self.vtable.variables(self.ptr, arena, variables_reference);
    }
    pub fn evaluate(self: DapHandler, arena: std.mem.Allocator, frame_id: u32, expr: []const u8) ![]const u8 {
        return self.vtable.evaluate(self.ptr, arena, frame_id, expr);
    }
    pub fn disconnect(self: DapHandler) void {
        self.vtable.disconnect(self.ptr);
    }
};

// --- Message framing ----------------------------------------------------------

/// Read one DAP message: consume `Content-Length` (and any other) headers up to
/// the blank line, then the exact body byte count. Returns the JSON body (owned by
/// `allocator`), or `null` at a clean end-of-stream between messages.
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var content_length: ?usize = null;
    var saw_header = false;
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Clean EOF *before* any header of this message: session over.
                if (!saw_header and content_length == null) return null;
                return error.UnexpectedEof;
            },
            else => return err,
        };
        saw_header = true;
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break; // blank line terminates the header block
        if (parseContentLength(trimmed)) |n| content_length = n;
    }
    const len = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return body;
}

/// Parse a `Content-Length: N` header line (case-insensitive key). Returns null for
/// any other header so the caller can ignore it.
fn parseContentLength(line: []const u8) ?usize {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    if (!std.ascii.eqlIgnoreCase(key, "Content-Length")) return null;
    const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
    return std.fmt.parseInt(usize, val, 10) catch null;
}

/// Write one DAP message: the `Content-Length` header, the blank line, the body,
/// then flush so the editor sees it immediately.
pub fn writeMessage(writer: *std.Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

// --- Server -------------------------------------------------------------------

const empty_body: struct {} = .{};

pub const Server = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    handler: DapHandler,
    /// Monotonic outgoing sequence number (DAP requires every message carry one).
    out_seq: i64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        handler: DapHandler,
    ) Server {
        return .{ .allocator = allocator, .reader = reader, .writer = writer, .handler = handler };
    }

    /// Serve messages until the client disconnects or the stream ends.
    pub fn run(self: *Server) !void {
        while (try self.serveOne()) {}
    }

    /// Read, dispatch, and respond to exactly one message. Returns false when the
    /// session should end (disconnect received or clean EOF).
    pub fn serveOne(self: *Server) !bool {
        const body = (try readMessage(self.allocator, self.reader)) orelse return false;
        defer self.allocator.free(body);

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
            // Unparseable frame: nothing to respond to sensibly. Keep serving.
            return true;
        };
        const req = msg.parseRequest(parsed.value) catch return true;
        return self.dispatch(arena, req);
    }

    fn dispatch(self: *Server, arena: std.mem.Allocator, req: Request) !bool {
        const cmd = req.command;
        if (eq(cmd, "initialize")) {
            try self.sendResponse(arena, req, self.handler.initialize());
            try self.sendEvent(arena, "initialized", empty_body);
        } else if (eq(cmd, "launch")) {
            try self.handler.launch(arena, req.arguments);
            try self.sendResponse(arena, req, empty_body);
        } else if (eq(cmd, "setBreakpoints")) {
            try self.handleSetBreakpoints(arena, req);
        } else if (eq(cmd, "configurationDone")) {
            try self.handler.configurationDone();
            try self.sendResponse(arena, req, empty_body);
        } else if (eq(cmd, "continue")) {
            try self.sendResponse(arena, req, .{ .allThreadsContinued = true });
            try self.sendEvent(arena, "continued", .{ .threadId = default_thread_id, .allThreadsContinued = true });
            try self.emitStop(arena, try self.handler.cont());
        } else if (eq(cmd, "next")) {
            try self.sendResponse(arena, req, empty_body);
            try self.emitStop(arena, try self.handler.step(.over));
        } else if (eq(cmd, "stepIn")) {
            try self.sendResponse(arena, req, empty_body);
            try self.emitStop(arena, try self.handler.step(.into));
        } else if (eq(cmd, "stepOut")) {
            try self.sendResponse(arena, req, empty_body);
            try self.emitStop(arena, try self.handler.step(.out));
        } else if (eq(cmd, "stackTrace")) {
            try self.handleStackTrace(arena, req);
        } else if (eq(cmd, "scopes")) {
            try self.handleScopes(arena, req);
        } else if (eq(cmd, "variables")) {
            try self.handleVariables(arena, req);
        } else if (eq(cmd, "evaluate")) {
            try self.handleEvaluate(arena, req);
        } else if (eq(cmd, "threads")) {
            // Single-thread protocol glue (no handler op): a conformant client
            // calls `threads` after every stop to populate its UI.
            const one = [_]ThreadWire{.{ .id = default_thread_id, .name = "main" }};
            try self.sendResponse(arena, req, .{ .threads = one[0..] });
        } else if (eq(cmd, "disconnect")) {
            self.handler.disconnect();
            try self.sendResponse(arena, req, empty_body);
            try self.sendEvent(arena, "terminated", empty_body);
            return false;
        } else {
            try self.sendErrorResponse(arena, req, "unsupported request");
        }
        return true;
    }

    // --- per-command handlers with owned-slice bodies -------------------------

    fn handleSetBreakpoints(self: *Server, arena: std.mem.Allocator, req: Request) !void {
        const args = req.arguments orelse {
            return self.sendErrorResponse(arena, req, "setBreakpoints requires arguments");
        };
        const path = msg.extractSourcePath(args) orelse "";
        const requested = try msg.extractBreakpointLines(arena, args);
        const verified = try self.handler.setBreakpoints(arena, path, requested);

        const wire = try arena.alloc(BreakpointWire, verified.len);
        for (verified, 0..) |bp, i| wire[i] = .{
            .id = bp.id,
            .verified = bp.verified,
            .line = bp.line,
            .message = bp.message,
        };
        try self.sendResponse(arena, req, .{ .breakpoints = wire });
    }

    fn handleStackTrace(self: *Server, arena: std.mem.Allocator, req: Request) !void {
        const frames = try self.handler.stackTrace(arena);
        const wire = try arena.alloc(FrameWire, frames.len);
        for (frames, 0..) |f, i| wire[i] = frameToWire(f);
        try self.sendResponse(arena, req, .{ .stackFrames = wire, .totalFrames = @as(i64, @intCast(frames.len)) });
    }

    fn handleScopes(self: *Server, arena: std.mem.Allocator, req: Request) !void {
        const frame_id = if (req.arguments) |a| (msg.getU32(a, "frameId") orelse 0) else 0;
        const scopes = try self.handler.scopes(arena, frame_id);
        const wire = try arena.alloc(ScopeWire, scopes.len);
        for (scopes, 0..) |s, i| wire[i] = .{
            .name = s.name,
            .variablesReference = s.variables_reference,
            .expensive = s.expensive,
        };
        try self.sendResponse(arena, req, .{ .scopes = wire });
    }

    fn handleVariables(self: *Server, arena: std.mem.Allocator, req: Request) !void {
        const ref = if (req.arguments) |a| (msg.getU32(a, "variablesReference") orelse 0) else 0;
        const locals = try self.handler.variables(arena, ref);
        const wire = try arena.alloc(VariableWire, locals.len);
        for (locals, 0..) |v, i| wire[i] = .{
            .name = v.name,
            .value = v.value,
            .@"type" = v.type_name,
            .variablesReference = 0,
        };
        try self.sendResponse(arena, req, .{ .variables = wire });
    }

    fn handleEvaluate(self: *Server, arena: std.mem.Allocator, req: Request) !void {
        const args = req.arguments orelse {
            return self.sendErrorResponse(arena, req, "evaluate requires arguments");
        };
        const expr = msg.getString(args, "expression") orelse "";
        const frame_id = msg.getU32(args, "frameId") orelse 0;
        const result = try self.handler.evaluate(arena, frame_id, expr);
        try self.sendResponse(arena, req, .{ .result = result, .variablesReference = 0 });
    }

    // --- stop → event translation --------------------------------------------

    /// Turn a `StopReason` into the DAP event(s) the client expects. Exit produces
    /// `exited` + `terminated`; every other reason produces a single `stopped`.
    fn emitStop(self: *Server, arena: std.mem.Allocator, stop: di.StopReason) !void {
        switch (stop) {
            .entry => try self.sendStopped(arena, "entry", null, null),
            .step => try self.sendStopped(arena, "step", null, null),
            .paused => try self.sendStopped(arena, "pause", null, null),
            .breakpoint => |id| try self.sendStopped(arena, "breakpoint", null, id),
            .watchpoint => |id| try self.sendStopped(arena, "data breakpoint", null, id),
            .trapped => |text| {
                try self.sendEvent(arena, "output", .{ .category = "stderr", .output = text });
                try self.sendStopped(arena, "exception", text, null);
            },
            .exited => |code| {
                try self.sendEvent(arena, "exited", .{ .exitCode = @as(i64, code) });
                try self.sendEvent(arena, "terminated", empty_body);
            },
        }
    }

    fn sendStopped(self: *Server, arena: std.mem.Allocator, reason: []const u8, text: ?[]const u8, hit_id: ?u32) !void {
        if (hit_id) |id| {
            const ids = [_]i64{@as(i64, id)};
            try self.sendEvent(arena, "stopped", .{
                .reason = reason,
                .threadId = default_thread_id,
                .allThreadsStopped = true,
                .hitBreakpointIds = ids[0..],
            });
        } else {
            try self.sendEvent(arena, "stopped", .{
                .reason = reason,
                .threadId = default_thread_id,
                .allThreadsStopped = true,
                .text = text,
            });
        }
    }

    // --- envelope writers -----------------------------------------------------

    fn sendResponse(self: *Server, arena: std.mem.Allocator, req: Request, body: anytype) !void {
        try self.send(arena, .{
            .seq = self.nextSeq(),
            .@"type" = "response",
            .request_seq = req.seq,
            .success = true,
            .command = req.command,
            .body = body,
        });
    }

    fn sendErrorResponse(self: *Server, arena: std.mem.Allocator, req: Request, message: []const u8) !void {
        try self.send(arena, .{
            .seq = self.nextSeq(),
            .@"type" = "response",
            .request_seq = req.seq,
            .success = false,
            .command = req.command,
            .message = message,
        });
    }

    fn sendEvent(self: *Server, arena: std.mem.Allocator, event: []const u8, body: anytype) !void {
        try self.send(arena, .{
            .seq = self.nextSeq(),
            .@"type" = "event",
            .event = event,
            .body = body,
        });
    }

    fn send(self: *Server, arena: std.mem.Allocator, envelope: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(arena, envelope, .{});
        try writeMessage(self.writer, json);
    }

    fn nextSeq(self: *Server) i64 {
        self.out_seq += 1;
        return self.out_seq;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- wire structs (JSON-serialized via std.json.Stringify) --------------------

const ThreadWire = struct { id: i64, name: []const u8 };

const SourceWire = struct { name: []const u8, path: []const u8 };

const FrameWire = struct {
    id: u32,
    name: []const u8,
    line: u32,
    column: u32,
    source: ?SourceWire,
};

const ScopeWire = struct {
    name: []const u8,
    variablesReference: u32,
    expensive: bool,
};

const VariableWire = struct {
    name: []const u8,
    value: []const u8,
    @"type": []const u8,
    variablesReference: u32,
};

const BreakpointWire = struct {
    id: u32,
    verified: bool,
    line: u32,
    message: []const u8,
};

fn frameToWire(f: di.Frame) FrameWire {
    if (f.position) |pos| {
        return .{
            .id = f.index,
            .name = f.function_name,
            .line = pos.line,
            .column = pos.column,
            .source = .{ .name = pos.file, .path = pos.file },
        };
    }
    return .{ .id = f.index, .name = f.function_name, .line = 0, .column = 0, .source = null };
}

// --- tests --------------------------------------------------------------------

// Framing/dispatch behavior lives in `dap_test.zig` (Core Law #5: keep this file
// focused). The one test kept here exercises a file-private helper.
test {
    _ = @import("dap_test.zig");
}

test "parseContentLength is case-insensitive and ignores other headers" {
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength("content-length: 42"));
    try std.testing.expectEqual(@as(?usize, 7), parseContentLength("Content-Length:7"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Type: application/json"));
}
