//! `DebugSession` — the debugger orchestrator. It ties a backend-agnostic
//! `DebugTarget` (VM / native / hybrid) to the shared `BreakpointTable` and the
//! expression `Evaluator`, and exposes one clean API that both the interactive
//! REPL and the DAP editor server drive. Because every operation flows through the
//! `DebugTarget` vtable, the same session logic serves all backends identically —
//! that is the parity guarantee.
//!
//! Division of labour (see the sibling module docs): the *target* drives the
//! `StepController` state machine and uses the `LineResolver` to turn byte-offset
//! spans into `Frame.position`s and to resolve line breakpoints to concrete
//! backend locations. The *session* owns the user-facing id space (its
//! `BreakpointTable` ids are what clients see), evaluates conditional-breakpoint
//! predicates, and translates the target's raw stop handles back into those ids.
//!
//! Id model: `setBreakpoint` registers the spec in the table (minting a monotonic
//! session id), arms it on the target, and stores the target's returned handle as
//! the entry's `resolved_location`. When the target reports a stop carrying that
//! same handle, the session finds the owning entry by handle and reports the stop
//! under the session id the client knows.
const std = @import("std");

const di = @import("debug_info.zig");
const target_mod = @import("target.zig");
const breakpoint = @import("breakpoint.zig");
const eval = @import("eval.zig");
const dap = @import("protocol/dap.zig");
const msg = @import("protocol/dap_messages.zig");
const frame_mod = @import("frame.zig");
const line_resolver = @import("line_resolver.zig");
const repl = @import("repl.zig");

const DebugTarget = target_mod.DebugTarget;
const StepKind = target_mod.StepKind;
const BreakpointTable = breakpoint.BreakpointTable;
const Evaluator = eval.Evaluator;
const LineResolver = line_resolver.LineResolver;

const LocalView = di.LocalView;
const StopReason = di.StopReason;
const BreakpointSpec = di.BreakpointSpec;
const Frame = di.Frame;

const DapHandler = dap.DapHandler;

// ---------------------------------------------------------------------------
// Conditional-breakpoint / expression lookup plumbing
// ---------------------------------------------------------------------------

// The `Evaluator`'s `LookupFn` is a bare function pointer with no context slot, so
// the identifier resolver reads the stopped frame's locals from thread-local state
// the session sets immediately before each evaluation. This is safe because a
// session is single-threaded (it serializes all target access) and the slice is
// restored on every path out via `defer`.
threadlocal var active_locals: []const LocalView = &.{};

fn lookupActiveLocal(name: []const u8) ?LocalView {
    for (active_locals) |lv| {
        if (std.mem.eql(u8, lv.name, name)) return lv;
    }
    return null;
}

/// Render an evaluated `Value` into a human string owned by `a`. `.str` results are
/// already `a`-owned copies from `Evaluator.eval`, so they pass through directly.
fn renderValue(a: std.mem.Allocator, v: eval.Value) ![]const u8 {
    return switch (v) {
        .int => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .bool => |b| try a.dupe(u8, if (b) "true" else "false"),
        .str => |s| s,
        .unknown => try a.dupe(u8, "<unknown>"),
    };
}

// ---------------------------------------------------------------------------
// DebugSession
// ---------------------------------------------------------------------------

pub const DebugSession = struct {
    allocator: std.mem.Allocator,
    /// The backend this session drives. The session owns it and deinits it.
    target: DebugTarget,
    /// The canonical, client-visible breakpoint registry.
    table: BreakpointTable,
    /// False until the first `run`; the first resume `start`s, later ones `cont`.
    started: bool,
    /// Lazily caches source-file text for the REPL's source windows/`list`.
    resolver: LineResolver,
    /// Stable storage for the most recently requested source provider. The REPL
    /// uses the returned `LineProvider` synchronously within one command, so a
    /// single reusable slot (backed by the resolver's owned text) suffices and
    /// keeps the provider's `ctx` pointer valid without per-call allocation.
    source_slot: frame_mod.SourceTextProvider,

    /// Construct a session over `target`. The session takes ownership of `target`
    /// and tears it down in `deinit`.
    pub fn init(allocator: std.mem.Allocator, target: DebugTarget) DebugSession {
        return .{
            .allocator = allocator,
            .target = target,
            .table = BreakpointTable.init(allocator),
            .started = false,
            .resolver = LineResolver.init(allocator),
            .source_slot = undefined,
        };
    }

    /// Free the breakpoint table, source cache, and tear down the owned target.
    pub fn deinit(self: *DebugSession) void {
        self.table.deinit();
        self.resolver.deinit();
        self.target.deinit();
    }

    // --- breakpoints ----------------------------------------------------------

    /// Register `spec` (with an optional condition), arm it on the target, and
    /// record the target's handle so hits on it map back to this id. Returns the
    /// session breakpoint id. On a target failure the table entry is rolled back.
    pub fn setBreakpoint(self: *DebugSession, spec: BreakpointSpec, condition: ?[]const u8) !u32 {
        const id = try self.table.add(spec, condition);
        errdefer self.table.remove(id) catch {};

        const handle = try self.target.setBreakpoint(spec);
        self.table.markResolved(id, handle);
        return id;
    }

    /// Remove breakpoint `id`: disarm it on the target (best-effort) and drop the
    /// table entry. Returns `error.NotFound` for an unknown id.
    pub fn removeBreakpoint(self: *DebugSession, id: u32) !void {
        const entry = self.table.get(id) orelse return error.NotFound;
        if (entry.resolved_location) |loc| {
            self.target.clearBreakpoint(@intCast(loc)) catch {};
        }
        try self.table.remove(id);
    }

    // --- execution ------------------------------------------------------------

    /// Start (first call) or continue (later calls) the target, then keep running
    /// until it stops for a reason the user should see. On a breakpoint/watchpoint
    /// stop the hit count is incremented and any condition is evaluated; a
    /// condition that evaluates false silently auto-continues. Non-breakpoint stops
    /// (step, exit, pause, trap) are returned immediately.
    pub fn run(self: *DebugSession) !StopReason {
        var stop = try self.resumeTarget();
        while (true) {
            const handle: u32 = switch (stop) {
                .breakpoint => |h| h,
                .watchpoint => |h| h,
                else => return stop,
            };
            const entry = self.entryByHandle(handle) orelse return stop;
            self.table.recordHit(entry.id);
            if (self.conditionHolds(entry)) {
                return switch (stop) {
                    .breakpoint => .{ .breakpoint = entry.id },
                    .watchpoint => .{ .watchpoint = entry.id },
                    else => stop,
                };
            }
            // Condition false: this hit does not concern the user; keep going.
            stop = try self.target.cont();
        }
    }

    /// Perform one source-line/instruction step of `kind`, delegating the state
    /// machine to the target. A step that lands on a registered breakpoint has its
    /// handle translated to the session id.
    pub fn step(self: *DebugSession, kind: StepKind) !StopReason {
        return self.translateStop(try self.target.step(kind));
    }

    // --- inspection -----------------------------------------------------------

    /// The current call stack, innermost frame first. Slice owned by the session
    /// allocator; the caller frees it.
    pub fn backtrace(self: *DebugSession) ![]Frame {
        return self.target.backtrace(self.allocator);
    }

    /// The locals/parameters visible in `frame_index`. Slice owned by the session
    /// allocator; the caller frees it.
    pub fn locals(self: *DebugSession, frame_index: u32) ![]LocalView {
        return self.target.locals(self.allocator, frame_index);
    }

    /// Evaluate `expr` in `frame_index` and render the result to a string owned by
    /// the session allocator. Uses the shared debugger `Evaluator` over the frame's
    /// locals so every backend evaluates identically; a bad expression renders as a
    /// diagnostic string rather than propagating.
    pub fn evaluate(self: *DebugSession, frame_index: u32, expr: []const u8) ![]const u8 {
        return self.evaluateIn(self.allocator, frame_index, expr);
    }

    /// A `DapHandler` view of this session for driving the DAP server. Valid for
    /// the lifetime of the session.
    pub fn handler(self: *DebugSession) DapHandler {
        return .{ .ptr = self, .vtable = &dap_vtable };
    }

    /// A `repl.Session` view of this session for driving the interactive terminal
    /// REPL. Valid for the lifetime of the session.
    pub fn replSession(self: *DebugSession) repl.Session {
        return .{ .ptr = self, .vtable = &repl_vtable };
    }

    // --- internals ------------------------------------------------------------

    fn resumeTarget(self: *DebugSession) !StopReason {
        // Contract: `start` begins execution and returns the FIRST stop (an armed
        // breakpoint, program end, or trap); subsequent resumes use `cont`.
        if (self.started) return self.target.cont();
        self.started = true;
        return self.target.start();
    }

    /// Translate a target stop's raw handle into the owning session breakpoint id,
    /// leaving non-breakpoint stops (and unknown handles) untouched.
    fn translateStop(self: *DebugSession, stop: StopReason) StopReason {
        return switch (stop) {
            .breakpoint => |h| if (self.entryByHandle(h)) |e| .{ .breakpoint = e.id } else stop,
            .watchpoint => |h| if (self.entryByHandle(h)) |e| .{ .watchpoint = e.id } else stop,
            else => stop,
        };
    }

    fn entryByHandle(self: *DebugSession, handle: u32) ?*breakpoint.Entry {
        for (self.table.list()) |*entry| {
            if (entry.resolved_location) |loc| {
                if (loc == @as(u64, handle)) return entry;
            }
        }
        return null;
    }

    /// Whether `entry`'s condition permits stopping. Unconditional breakpoints
    /// always hold. A condition is evaluated against frame 0's locals; if locals
    /// are unavailable or the predicate cannot be evaluated we conservatively stop
    /// (return true) rather than silently skipping the breakpoint.
    fn conditionHolds(self: *DebugSession, entry: *const breakpoint.Entry) bool {
        const cond = entry.condition orelse return true;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const frame_locals = self.target.locals(a, 0) catch return true;
        const prev = active_locals;
        active_locals = frame_locals;
        defer active_locals = prev;

        return Evaluator.evalCondition(a, cond, lookupActiveLocal) catch true;
    }

    fn evaluateIn(self: *DebugSession, a: std.mem.Allocator, frame_index: u32, expr: []const u8) ![]const u8 {
        const frame_locals = try self.target.locals(a, frame_index);
        // The rendered result is an independent `a`-owned copy, so the locals
        // slice can be released here. This matters on the non-arena `evaluate`
        // path (`a == self.allocator`); for the arena-backed DAP/REPL callers it
        // is a harmless no-op.
        defer a.free(frame_locals);
        const prev = active_locals;
        active_locals = frame_locals;
        defer active_locals = prev;

        const v = Evaluator.eval(a, expr, lookupActiveLocal) catch |err| {
            return std.fmt.allocPrint(a, "<eval error: {s}>", .{@errorName(err)});
        };
        return renderValue(a, v);
    }

    /// Remove every line breakpoint anchored to `file` (used by DAP `setBreakpoints`,
    /// which replaces a file's breakpoints wholesale). Ids are collected first so the
    /// table is not mutated mid-iteration.
    fn clearFileBreakpoints(self: *DebugSession, a: std.mem.Allocator, file: []const u8) !void {
        var ids: std.ArrayList(u32) = .empty;
        for (self.table.list()) |entry| {
            switch (entry.spec) {
                .line => |l| if (std.mem.eql(u8, l.file, file)) try ids.append(a, entry.id),
                else => {},
            }
        }
        for (ids.items) |id| self.removeBreakpoint(id) catch {};
    }
};

// ---------------------------------------------------------------------------
// repl.Session vtable — the interactive terminal REPL drives the session through
// this adapter, mirroring the DAP handler so both front-ends share one session.
// ---------------------------------------------------------------------------

const repl_vtable = repl.Session.VTable{
    .addBreakpoint = replAddBreakpoint,
    .deleteBreakpoint = replDeleteBreakpoint,
    .cont = replCont,
    .step = replStep,
    .backtrace = replBacktrace,
    .locals = replLocals,
    .evaluate = replEvaluate,
    .sourceProvider = replSourceProvider,
};

fn replAddBreakpoint(ctx: *anyopaque, spec: BreakpointSpec, condition: ?[]const u8) anyerror!u32 {
    return fromCtx(ctx).setBreakpoint(spec, condition);
}

fn replDeleteBreakpoint(ctx: *anyopaque, id: u32) anyerror!void {
    return fromCtx(ctx).removeBreakpoint(id);
}

fn replCont(ctx: *anyopaque) anyerror!StopReason {
    return fromCtx(ctx).run();
}

fn replStep(ctx: *anyopaque, kind: StepKind) anyerror!StopReason {
    return fromCtx(ctx).step(kind);
}

fn replBacktrace(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]Frame {
    return fromCtx(ctx).target.backtrace(allocator);
}

fn replLocals(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]LocalView {
    return fromCtx(ctx).target.locals(allocator, frame_index);
}

fn replEvaluate(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8 {
    return fromCtx(ctx).evaluateIn(allocator, frame_index, expr);
}

fn replSourceProvider(ctx: *anyopaque, file: []const u8) ?frame_mod.LineProvider {
    const self = fromCtx(ctx);
    const sf = (self.resolver.loadFile(file) catch return null) orelse return null;
    // Copy the loaded text/line-map into the session's stable slot; the returned
    // provider points at that slot, valid for the REPL's synchronous use.
    self.source_slot = frame_mod.SourceTextProvider.fromSourceFile(sf);
    return self.source_slot.provider();
}

// ---------------------------------------------------------------------------
// DapHandler vtable — each entry delegates to a public/internal session method
// ---------------------------------------------------------------------------

const dap_vtable = DapHandler.VTable{
    .initialize = dapInitialize,
    .launch = dapLaunch,
    .setBreakpoints = dapSetBreakpoints,
    .configurationDone = dapConfigurationDone,
    .cont = dapCont,
    .step = dapStep,
    .stackTrace = dapStackTrace,
    .scopes = dapScopes,
    .variables = dapVariables,
    .evaluate = dapEvaluate,
    .disconnect = dapDisconnect,
};

fn fromCtx(ptr: *anyopaque) *DebugSession {
    return @ptrCast(@alignCast(ptr));
}

fn dapInitialize(ctx: *anyopaque) msg.Capabilities {
    _ = ctx;
    // We honor conditional breakpoints and a terminate request; everything else in
    // the subset stays at its conservative default so a client never sends a
    // request the session would reject.
    return .{ .supportsConditionalBreakpoints = true };
}

fn dapLaunch(ctx: *anyopaque, arena: std.mem.Allocator, arguments: ?std.json.Value) anyerror!void {
    // Launch arguments are client/config-defined; the session needs no state from
    // them here (the target is already constructed). The first stop comes from a
    // later `configurationDone`/`continue`.
    _ = ctx;
    _ = arena;
    _ = arguments;
}

fn dapSetBreakpoints(
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    source_path: []const u8,
    breakpoints: []const msg.SourceBreakpointInput,
) anyerror![]msg.VerifiedBreakpoint {
    const self = fromCtx(ctx);
    // DAP semantics: this request is the full breakpoint set for the file.
    try self.clearFileBreakpoints(arena, source_path);

    const out = try arena.alloc(msg.VerifiedBreakpoint, breakpoints.len);
    for (breakpoints, 0..) |bp, i| {
        const id = self.setBreakpoint(
            .{ .line = .{ .file = source_path, .line = bp.line } },
            bp.condition,
        ) catch {
            out[i] = .{ .id = 0, .verified = false, .line = bp.line, .message = "could not resolve breakpoint location" };
            continue;
        };
        out[i] = .{ .id = id, .verified = true, .line = bp.line };
    }
    return out;
}

fn dapConfigurationDone(ctx: *anyopaque) anyerror!void {
    _ = ctx;
}

fn dapCont(ctx: *anyopaque) anyerror!StopReason {
    return fromCtx(ctx).run();
}

fn dapStep(ctx: *anyopaque, kind: StepKind) anyerror!StopReason {
    return fromCtx(ctx).step(kind);
}

fn dapStackTrace(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]Frame {
    return fromCtx(ctx).target.backtrace(arena);
}

fn dapScopes(ctx: *anyopaque, arena: std.mem.Allocator, frame_id: u32) anyerror![]msg.Scope {
    _ = ctx;
    // One "Locals" scope per frame. The variables reference is `frame_id + 1` so
    // that reference 0 (DAP's "no children") never collides with frame 0.
    const out = try arena.alloc(msg.Scope, 1);
    out[0] = .{ .name = "Locals", .variables_reference = frame_id + 1, .expensive = false };
    return out;
}

fn dapVariables(ctx: *anyopaque, arena: std.mem.Allocator, variables_reference: u32) anyerror![]LocalView {
    if (variables_reference == 0) return &.{};
    return fromCtx(ctx).target.locals(arena, variables_reference - 1);
}

fn dapEvaluate(ctx: *anyopaque, arena: std.mem.Allocator, frame_id: u32, expr: []const u8) anyerror![]const u8 {
    return fromCtx(ctx).evaluateIn(arena, frame_id, expr);
}

fn dapDisconnect(ctx: *anyopaque) void {
    // Tear-down proper is `deinit`; a disconnect just re-arms the start/continue
    // state so a subsequent session over the same target begins cleanly.
    fromCtx(ctx).started = false;
}

// ---------------------------------------------------------------------------
// Tests — the scriptable fake `DebugTarget` double and the behavioral cases it
// drives (setBreakpoint arm/disarm, start-vs-continue, conditional
// auto-continue, step delegation, id translation, and the DAP handler) live in
// `session_test.zig`, mirroring the `dap.zig`/`dap_test.zig` split so this
// implementation file stays under the Core Law #5 size cap.
// ---------------------------------------------------------------------------

test {
    _ = @import("session_test.zig");
}
