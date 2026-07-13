//! `NativeTarget` — a `DebugTarget` over a launched-and-attached native inferior,
//! driven by a hardware `HwBreakpointController`.
//!
//! Composition (see the module headers of the helpers for the deep detail):
//!   * `native_target_launch.launchStopped` starts the target binary *stopped*
//!     (Linux: fork + SIGSTOP-before-exec; macOS: `posix_spawn` START_SUSPENDED).
//!   * The `HwBreakpointController` for the build target is chosen at comptime by
//!     `hw/controller.currentPlatform()` and `attach`ed to that pid. When the OS
//!     refuses cross-process control (no macOS debugger entitlement, restricted
//!     Linux ptrace scope) `attach`/arm surface `PermissionDenied`, which this
//!     target reports as `TargetError.HardwareUnavailable` — never a fake attach.
//!   * `native_target_dwarf` maps `file:line`/`function` -> address (to arm) and
//!     address -> `SourcePosition` (to annotate frames) by shelling out to the
//!     Kira toolchain's `llvm-dwarfdump`/`llvm-nm`.
//!   * `native_target_unwind` walks the frame-pointer chain into a `[]Frame`.
//!   * `step.StepController` drives source-line stepping identically to the VM
//!     backend (the parity guarantee); `eval.Evaluator` powers `evaluate`.
//!
//! Scope of this first cut (per the task contract):
//!   * **Fully working:** launch + attach, function-name / raw-address / source-
//!     line (`.debug_line`) breakpoints, instruction + source-line stepping
//!     (`into`/`over`/`out`), frame-pointer backtrace with DWARF source positions,
//!     register + memory reads, expression `evaluate` over literals.
//!   * **Documented limitation — source-line *locals*:** parsing DWARF
//!     `.debug_info` variable/location lists is a large subsystem deferred to a
//!     follow-up. `locals` returns `TargetError.Unsupported` (honest: the UI shows
//!     "locals unavailable" rather than a fabricated or empty-looking list), and
//!     `evaluate` therefore resolves literals/arithmetic but reports unknown
//!     identifiers for locals it cannot yet see. Breakpoints, stepping, and
//!     backtrace do NOT depend on this.
//!   * **Documented limitation — PIE load bias:** `load_bias` is 0; a position-
//!     independent image slid by the loader resolves positions to null rather than
//!     to a wrong line. Computing the slide (`/proc/pid/maps` / dyld image list)
//!     is a follow-up. Hardware execution breakpoints program CPU debug registers
//!     by address, so they still arm correctly across `exec` for a non-PIE image.
//!   * **Watchpoints** need an expression -> data-address mapping that also
//!     depends on the deferred variable DWARF, so `.watch` specs report
//!     `TargetError.Unsupported` rather than arming at a guessed address.

const std = @import("std");
const builtin = @import("builtin");
const di = @import("debug_info.zig");
const target_mod = @import("target.zig");
const ctrl = @import("hw/controller.zig");
const launch = @import("native_target_launch.zig");
const dwarf = @import("native_target_dwarf.zig");
const unwind = @import("native_target_unwind.zig");
const step_mod = @import("step.zig");
const eval = @import("eval.zig");

const DebugTarget = target_mod.DebugTarget;
const StepKind = target_mod.StepKind;
const TargetError = target_mod.TargetError;
const HwBreakpointController = ctrl.HwBreakpointController;
const HwStop = ctrl.HwStop;
const HwError = ctrl.HwError;
const LineTable = dwarf.LineTable;
const Symbols = dwarf.Symbols;

/// Comptime-selected concrete controller for the build target. Only the matched
/// import is analyzed, so per-os files that reference OS APIs never leak into a
/// foreign build.
const selected_platform = ctrl.currentPlatform();
const Impl = switch (selected_platform) {
    .darwin_arm64 => @import("hw/darwin_arm64.zig").DarwinArm64,
    .darwin_x86_64 => @import("hw/darwin_x86_64.zig").DarwinX86_64,
    .linux_arm64 => @import("hw/linux_arm64.zig").LinuxArm64Controller,
    .linux_x86_64 => @import("hw/linux_x86_64.zig").LinuxX86Controller,
    .windows => @import("hw/windows.zig").WindowsController,
    .software => @import("hw/software_trap.zig").SoftwareTrapController,
};

/// A safety cap on single-steps per source-line step: a pathological loop must
/// stop the debugger, not hang it. Reaching it returns an honest `step` stop.
const max_step_instructions: usize = 1_000_000;

/// One registered breakpoint: the resolved runtime address to arm at, plus the
/// controller slot once armed (null while pending — armed at `start`).
const Breakpoint = struct {
    id: u32,
    addr: u64,
    slot: ?u8 = null,
    watch: bool = false,
};

pub const NativeTarget = struct {
    allocator: std.mem.Allocator,
    /// Duplicated argv; `argv[0]` is the binary path (also used for DWARF/symbols).
    argv: []const []const u8,
    impl: Impl,

    started: bool = false,
    finished: bool = false,
    attached: bool = false,
    exit_code: i32 = 0,
    /// Set by the launcher: the inferior is stopped *before* its own entry and a
    /// first continue runs it through `exec`. Hardware breakpoints armed at
    /// static addresses survive that transition.
    needs_run_to_entry: bool = false,
    /// PIE slide subtracted from runtime PCs before DWARF lookup (see header).
    load_bias: u64 = 0,

    line_table: ?LineTable = null,
    line_table_loaded: bool = false,
    symbols: ?Symbols = null,
    symbols_loaded: bool = false,
    /// Owned copy of the LLVM tool directory (bin dir of the toolchain that built
    /// the inferior), searched first for `llvm-dwarfdump`/`llvm-nm`. Null when the
    /// caller could not resolve it; discovery then falls back to env + `PATH`.
    tool_dir: ?[]const u8 = null,

    breakpoints: std.array_list.Managed(Breakpoint),
    next_id: u32 = 1,

    /// Backing storage for a `StopReason.trapped` diagnostic string.
    stop_msg: [96]u8 = undefined,

    /// Construct a target for `argv` (argv[0] is the executable). Nothing is
    /// launched until `start`; DWARF/symbol tables load lazily on first use.
    pub fn init(allocator: std.mem.Allocator, argv: []const []const u8) !NativeTarget {
        return initWithToolDir(allocator, argv, null);
    }

    /// Like `init`, but records the LLVM tool directory the CLI resolved for this
    /// build so DWARF/symbol lookups find the managed toolchain (which is not on
    /// `PATH`). `tool_dir` is duplicated; pass null to rely on env + `PATH`.
    pub fn initWithToolDir(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        tool_dir: ?[]const u8,
    ) !NativeTarget {
        const owned = try dupeArgv(allocator, argv);
        errdefer {
            for (owned) |s| allocator.free(s);
            allocator.free(owned);
        }
        const owned_tool_dir = if (tool_dir) |dir| try allocator.dupe(u8, dir) else null;
        return .{
            .allocator = allocator,
            .argv = owned,
            .impl = makeImpl(allocator),
            .breakpoints = std.array_list.Managed(Breakpoint).init(allocator),
            .tool_dir = owned_tool_dir,
        };
    }

    /// The backend-agnostic handle the debug session drives.
    pub fn target(self: *NativeTarget) DebugTarget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn hw(self: *NativeTarget) HwBreakpointController {
        return self.impl.controller();
    }

    fn binary(self: *NativeTarget) []const u8 {
        return self.argv[0];
    }

    // ---- lazy DWARF loading --------------------------------------------------

    fn ensureLineTable(self: *NativeTarget) ?LineTable {
        if (!self.line_table_loaded) {
            self.line_table = dwarf.loadLineTable(self.allocator, self.binary(), self.tool_dir);
            self.line_table_loaded = true;
        }
        return self.line_table;
    }

    fn ensureSymbols(self: *NativeTarget) ?Symbols {
        if (!self.symbols_loaded) {
            self.symbols = dwarf.loadSymbols(self.allocator, self.binary(), self.tool_dir);
            self.symbols_loaded = true;
        }
        return self.symbols;
    }

    // ---- breakpoints ---------------------------------------------------------

    fn setBreakpoint(self: *NativeTarget, spec: di.BreakpointSpec) !u32 {
        // A watchpoint needs an expression->data-address map from variable DWARF
        // we do not parse yet; refuse honestly rather than watch a guessed address.
        if (spec == .watch) return TargetError.Unsupported;

        const addr = resolveSpec(spec, self.ensureLineTable(), self.ensureSymbols(), self.load_bias) orelse
            return TargetError.NotFound;

        var bp = Breakpoint{ .id = self.next_id, .addr = addr };
        // If the inferior is already live and stopped, arm immediately; otherwise
        // it is armed for us when `start` attaches.
        if (self.attached) {
            bp.slot = self.hw().armExec(addr) catch |err| return mapHwError(err);
        }
        try self.breakpoints.append(bp);
        self.next_id += 1;
        return bp.id;
    }

    fn clearBreakpoint(self: *NativeTarget, id: u32) !void {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.id != id) continue;
            if (bp.slot) |slot| {
                self.hw().disarm(slot) catch |err| return mapHwError(err);
            }
            _ = self.breakpoints.orderedRemove(i);
            return;
        }
        return TargetError.NotFound;
    }

    fn armPending(self: *NativeTarget) !void {
        for (self.breakpoints.items) |*bp| {
            if (bp.slot != null) continue;
            bp.slot = self.hw().armExec(bp.addr) catch |err| return mapHwError(err);
        }
    }

    fn slotToId(self: *NativeTarget, slot: u8) ?u32 {
        for (self.breakpoints.items) |bp| {
            if (bp.slot) |s| {
                if (s == slot) return bp.id;
            }
        }
        return null;
    }

    // ---- execution -----------------------------------------------------------

    fn start(self: *NativeTarget) !di.StopReason {
        if (self.started) {
            if (self.finished) return .{ .exited = self.exit_code };
            return .paused;
        }

        const launched = launch.launchStopped(self.allocator, self.argv) catch |err| switch (err) {
            launch.LaunchError.Unsupported => return TargetError.Unsupported,
            else => return err,
        };
        self.needs_run_to_entry = launched.needs_run_to_entry;

        // If attach or arming fails (commonly a missing debugger entitlement on
        // macOS -> HardwareUnavailable), the child was spawned *stopped* and would
        // otherwise linger as an orphan — kill it before surfacing the error.
        errdefer if (comptime builtin.os.tag != .windows) std.posix.kill(launched.pid, std.posix.SIG.KILL) catch {};

        self.hw().attach(launched.pid) catch |err| return mapHwError(err);
        self.attached = true;

        // Arm every breakpoint set before start. Hardware execution breakpoints
        // live in CPU debug registers keyed by address, so arming here is valid
        // even on the Linux pre-exec stop: the first `cont` runs through `exec`
        // and the register fires when execution reaches the (non-PIE) address.
        try self.armPending();

        self.started = true;
        // Matches the VM backend: `start` begins the session and reports `entry`;
        // the session's next resume drives `cont` to the first real stop.
        return .entry;
    }

    fn cont(self: *NativeTarget) !di.StopReason {
        if (!self.attached) return TargetError.NotStopped;
        if (self.finished) return .{ .exited = self.exit_code };
        const hs = self.hw().cont() catch |err| return mapHwError(err);
        return self.applyStop(hs);
    }

    fn step(self: *NativeTarget, kind: StepKind) !di.StopReason {
        if (!self.attached) return TargetError.NotStopped;
        if (self.finished) return .{ .exited = self.exit_code };

        const layout = unwind.layoutFor(selected_platform);
        const origin = unwind.cursor(self.hw(), layout, self.ensureLineTable(), self.load_bias);
        var controller = step_mod.StepController.begin(kind, origin.depth, origin.position);

        var iters: usize = 0;
        while (iters < max_step_instructions) : (iters += 1) {
            const hs = self.hw().singleStep() catch |err| return mapHwError(err);
            switch (hs) {
                .exited => |code| {
                    self.finished = true;
                    self.exit_code = code;
                    return .{ .exited = code };
                },
                .exec => |slot| {
                    // Single-stepped onto an armed breakpoint: surface it.
                    if (self.slotToId(slot)) |id| return .{ .breakpoint = id };
                },
                .watch => |w| {
                    if (self.slotToId(w.slot)) |id| return .{ .watchpoint = id };
                },
                .signal => |s| return self.trapped(s),
                .step => {},
            }
            const cur = unwind.cursor(self.hw(), layout, self.ensureLineTable(), self.load_bias);
            if (controller.onInstruction(cur.depth, cur.position) == .stop) return .step;
        }
        // Safety cap hit: stop honestly rather than spin forever.
        return .step;
    }

    /// Map a `HwStop` from `cont` into a `StopReason`, recording terminal state.
    fn applyStop(self: *NativeTarget, hs: HwStop) di.StopReason {
        switch (hs) {
            .exited => |code| {
                self.finished = true;
                self.exit_code = code;
                return .{ .exited = code };
            },
            .exec => |slot| return if (self.slotToId(slot)) |id| .{ .breakpoint = id } else .paused,
            .watch => |w| return if (self.slotToId(w.slot)) |id| .{ .watchpoint = id } else .paused,
            .step => return .step,
            .signal => |s| return self.trapped(s),
        }
    }

    fn trapped(self: *NativeTarget, signal: u32) di.StopReason {
        const msg = std.fmt.bufPrint(&self.stop_msg, "signal {d}", .{signal}) catch "signal";
        return .{ .trapped = msg };
    }

    // ---- inspection ----------------------------------------------------------

    fn backtrace(self: *NativeTarget, allocator: std.mem.Allocator) ![]di.Frame {
        if (!self.attached) return TargetError.NotStopped;
        const layout = unwind.layoutFor(selected_platform);
        return unwind.unwindFrames(
            allocator,
            self.hw(),
            layout,
            self.ensureLineTable(),
            self.ensureSymbols(),
            self.load_bias,
            unwind.max_unwind_frames,
        );
    }

    fn locals(self: *NativeTarget, allocator: std.mem.Allocator, frame_index: u32) ![]di.LocalView {
        _ = self;
        _ = allocator;
        _ = frame_index;
        // Documented limitation: DWARF `.debug_info` variable/location parsing is a
        // deferred follow-up. Report it honestly so nothing depends on a fabricated
        // or misleadingly-empty locals list.
        return TargetError.Unsupported;
    }

    fn evaluate(self: *NativeTarget, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) ![]const u8 {
        _ = self;
        _ = frame_index;
        // Locals are not yet resolvable (see `locals`), so identifiers report as
        // unknown; literals/arithmetic evaluate normally. A bad expression renders
        // to a diagnostic string rather than propagating (matches the session).
        const value = eval.Evaluator.eval(allocator, expr, emptyLookup) catch |err| {
            return std.fmt.allocPrint(allocator, "<error: {s}>", .{@errorName(err)});
        };
        return renderValue(allocator, value);
    }

    fn readMemory(self: *NativeTarget, addr: u64, buf: []u8) !void {
        if (!self.attached) return TargetError.NotStopped;
        self.hw().readMemory(addr, buf) catch |err| return mapHwError(err);
    }

    pub fn deinit(self: *NativeTarget) void {
        self.hw().deinit();
        if (self.line_table) |*lt| lt.deinit();
        if (self.symbols) |*s| s.deinit();
        self.breakpoints.deinit();
        for (self.argv) |s| self.allocator.free(s);
        self.allocator.free(self.argv);
        if (self.tool_dir) |dir| self.allocator.free(dir);
    }
};

// ---------------------------------------------------------------------------
// Free helpers (pure where possible, for host-independent unit tests).
// ---------------------------------------------------------------------------

/// Construct the comptime-selected controller, threading each impl's distinct
/// `init` signature. The `comptime` conditions prune the untaken branches so a
/// mismatched-arity `init` on a foreign platform is never analyzed.
fn makeImpl(allocator: std.mem.Allocator) Impl {
    if (comptime selected_platform == .darwin_x86_64) return Impl.init(allocator);
    if (comptime selected_platform == .software)
        return Impl.init(.software_only, @import("hw/software_trap.zig").selfProcessHandle());
    return Impl.init();
}

fn dupeArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |s| allocator.free(s);
    for (argv, 0..) |s, i| {
        out[i] = try allocator.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

/// Resolve a breakpoint spec to a runtime arming address. `.function` and `.line`
/// resolve against the on-disk symbol/line tables and add `load_bias`; `.address`
/// is already a runtime address. `.watch` is unsupported here (see `setBreakpoint`).
fn resolveSpec(spec: di.BreakpointSpec, line_table: ?LineTable, symbols: ?Symbols, load_bias: u64) ?u64 {
    return switch (spec) {
        .function => |name| {
            const syms = symbols orelse return null;
            const static = syms.address(name) orelse return null;
            return static + load_bias;
        },
        .line => |loc| {
            const lt = line_table orelse return null;
            const static = lt.lineToAddress(loc.file, loc.line) orelse return null;
            return static + load_bias;
        },
        .address => |a| a,
        .watch => null,
    };
}

fn mapHwError(err: anyerror) anyerror {
    return switch (err) {
        HwError.PermissionDenied, HwError.SlotsExhausted => TargetError.HardwareUnavailable,
        HwError.Unsupported => TargetError.Unsupported,
        HwError.NotStopped => TargetError.NotStopped,
        else => err,
    };
}

fn emptyLookup(name: []const u8) ?di.LocalView {
    _ = name;
    return null;
}

/// Render an evaluator `Value` to a caller-owned string.
fn renderValue(allocator: std.mem.Allocator, value: eval.Value) ![]const u8 {
    return switch (value) {
        .int => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        // `.str` is already allocator-owned by `Evaluator.eval`.
        .str => |s| s,
        .unknown => allocator.dupe(u8, "<unknown>"),
    };
}

// ---------------------------------------------------------------------------
// VTable trampolines.
// ---------------------------------------------------------------------------

const vtable = DebugTarget.VTable{
    .start = vtStart,
    .cont = vtCont,
    .step = vtStep,
    .setBreakpoint = vtSetBreakpoint,
    .clearBreakpoint = vtClearBreakpoint,
    .backtrace = vtBacktrace,
    .locals = vtLocals,
    .evaluate = vtEvaluate,
    .readMemory = vtReadMemory,
    .deinit = vtDeinit,
};

fn cast(ctx: *anyopaque) *NativeTarget {
    return @ptrCast(@alignCast(ctx));
}

fn vtStart(ctx: *anyopaque) anyerror!di.StopReason {
    return cast(ctx).start();
}
fn vtCont(ctx: *anyopaque) anyerror!di.StopReason {
    return cast(ctx).cont();
}
fn vtStep(ctx: *anyopaque, kind: StepKind) anyerror!di.StopReason {
    return cast(ctx).step(kind);
}
fn vtSetBreakpoint(ctx: *anyopaque, spec: di.BreakpointSpec) anyerror!u32 {
    return cast(ctx).setBreakpoint(spec);
}
fn vtClearBreakpoint(ctx: *anyopaque, id: u32) anyerror!void {
    return cast(ctx).clearBreakpoint(id);
}
fn vtBacktrace(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]di.Frame {
    return cast(ctx).backtrace(allocator);
}
fn vtLocals(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]di.LocalView {
    return cast(ctx).locals(allocator, frame_index);
}
fn vtEvaluate(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8 {
    return cast(ctx).evaluate(allocator, frame_index, expr);
}
fn vtReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
    return cast(ctx).readMemory(addr, buf);
}
fn vtDeinit(ctx: *anyopaque) void {
    cast(ctx).deinit();
}

// ---------------------------------------------------------------------------
// Tests — pure routing/mapping logic (no inferior launched; host-independent).
// Real launch+attach behavior is exercised by the integration stage's native
// debug corpus, which needs a live process and (on macOS) the debugger
// entitlement.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "resolveSpec routes function and line through the on-disk tables" {
    var syms = try dwarf.parseSymbols(testing.allocator,
        \\0000000100003f9c T _main
        \\0000000100003fb0 t _helper
        \\
    );
    defer syms.deinit();

    // Function by (Mach-O underscored) name, with a load bias applied.
    try testing.expectEqual(@as(?u64, 0x100003f9c + 0x1000), resolveSpec(
        .{ .function = "main" },
        null,
        syms,
        0x1000,
    ));
    // A raw address passes through unchanged (already runtime).
    try testing.expectEqual(@as(?u64, 0xdead), resolveSpec(.{ .address = 0xdead }, null, syms, 0x1000));
    // Watch is not resolvable here.
    try testing.expectEqual(@as(?u64, null), resolveSpec(
        .{ .watch = .{ .expr = "x", .kind = .write } },
        null,
        syms,
        0,
    ));
    // Unknown function -> null.
    try testing.expectEqual(@as(?u64, null), resolveSpec(.{ .function = "nope" }, null, syms, 0));
}

test "resolveSpec resolves a source line via .debug_line" {
    const sample =
        \\debug_line[0x00000000]
        \\file_names[  0]:
        \\           name: "main.kira"
        \\Address            Line   Column File   ISA Discriminator OpIndex Flags
        \\------------------ ------ ------ ------ --- ------------- ------- -------
        \\0x0000000100003f9c     10      0      0   0             0       0  is_stmt
        \\0x0000000100003fa4     11      5      0   0             0       0  is_stmt
        \\
    ;
    var lt = try dwarf.parseLineTable(testing.allocator, sample);
    defer lt.deinit();
    try testing.expectEqual(@as(?u64, 0x100003fa4), resolveSpec(
        .{ .line = .{ .file = "src/main.kira", .line = 11 } },
        lt,
        null,
        0,
    ));
}

test "mapHwError folds hardware refusals into target errors" {
    try testing.expectEqual(TargetError.HardwareUnavailable, mapHwError(HwError.PermissionDenied));
    try testing.expectEqual(TargetError.HardwareUnavailable, mapHwError(HwError.SlotsExhausted));
    try testing.expectEqual(TargetError.Unsupported, mapHwError(HwError.Unsupported));
    try testing.expectEqual(TargetError.NotStopped, mapHwError(HwError.NotStopped));
}

test "renderValue formats each evaluator value kind" {
    const a = testing.allocator;
    const i = try renderValue(a, .{ .int = -7 });
    defer a.free(i);
    try testing.expectEqualStrings("-7", i);
    const b = try renderValue(a, .{ .bool = true });
    defer a.free(b);
    try testing.expectEqualStrings("true", b);
    const u = try renderValue(a, .unknown);
    defer a.free(u);
    try testing.expectEqualStrings("<unknown>", u);
}

test "evaluate resolves literals and reports unknown identifiers honestly" {
    const a = testing.allocator;
    var t = try NativeTarget.init(a, &.{"/nonexistent/bin"});
    defer t.deinit();
    const ok = try t.evaluate(a, 0, "2 + 3 * 4");
    defer a.free(ok);
    try testing.expectEqualStrings("14", ok);

    // An identifier has no resolvable local yet -> rendered diagnostic, not a crash.
    const bad = try t.evaluate(a, 0, "x");
    defer a.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "error") != null);
}

test "init dupes argv and locals reports the documented limitation" {
    const a = testing.allocator;
    var t = try NativeTarget.init(a, &.{ "/bin/echo", "hi" });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.argv.len);
    try testing.expectEqualStrings("/bin/echo", t.argv[0]);
    // Locals are honestly unsupported in the first cut.
    try testing.expectError(TargetError.Unsupported, t.locals(a, 0));
}
