//! Shared debugger value types — the contract every kira_debug module and every
//! DebugTarget backend (VM, native, hybrid) agrees on. Kept dependency-light so
//! any module can import it without cycles.
const std = @import("std");
const source = @import("kira_source");

/// A resolved source position: 1-based line/column into a known file. This is
/// what the UI shows and what breakpoints resolve against. Byte offsets from the
/// compiler's line tables are converted to this via `LineMap` at debug time.
pub const SourcePosition = struct {
    file: []const u8,
    line: u32,
    column: u32,

    pub fn format(self: SourcePosition, writer: *std.Io.Writer) !void {
        try writer.print("{s}:{d}:{d}", .{ self.file, self.line, self.column });
    }
};

/// A byte-offset span tagged with its source file — the raw form carried by the
/// bytecode line table and IR `locations`. Resolve to `SourcePosition` with a
/// `LineMap` built from the file's text.
pub const SourceSpan = struct {
    file: []const u8,
    start: u32,
    end: u32,

    pub fn isUnknown(self: SourceSpan) bool {
        return self.start == 0 and self.end == 0;
    }
};

/// Which backend a stopped frame is executing in. Hybrid sessions mix both.
pub const Backend = enum { vm, native };

/// A single call frame, unified across VM and native. `function_id` is the id
/// shared by the VM module and the hybrid manifest; `position` is null when no
/// line info is available (synthesized frames, stripped native code).
pub const Frame = struct {
    index: u32,
    backend: Backend,
    function_id: u32,
    function_name: []const u8,
    position: ?SourcePosition = null,
    /// Backend-specific instruction cursor: VM pc, or native PC/address.
    program_counter: u64 = 0,
};

/// A named, typed, rendered local/parameter for the variables view. `value` is
/// a human string produced read-only (never mutating or dropping the runtime
/// slot — see value_view.zig). `type_name` may be empty when unknown.
pub const LocalView = struct {
    name: []const u8,
    type_name: []const u8 = "",
    value: []const u8,
    slot: u32,
};

/// Why the target stopped. Drives the REPL/DAP "stopped" event.
pub const StopReason = union(enum) {
    /// Program has not started / already finished.
    entry,
    exited: i32,
    /// A breakpoint with this id was hit.
    breakpoint: u32,
    /// A data watchpoint with this id fired.
    watchpoint: u32,
    /// A single source-line/instruction step completed.
    step,
    /// A signal / debug exception with no owning breakpoint (e.g. manual pause).
    paused,
    /// The target trapped (fault, assertion). `message` is diagnostic text.
    trapped: []const u8,
};

/// Access kind for data watchpoints (hardware WVR/WCR, DR7 R/W, or software).
pub const WatchKind = enum { read, write, read_write };

/// What a breakpoint is anchored to. Line breakpoints are resolved to a concrete
/// backend location (VM pc / native address) when armed.
pub const BreakpointSpec = union(enum) {
    line: struct { file: []const u8, line: u32 },
    function: []const u8,
    address: u64,
    watch: struct { expr: []const u8, kind: WatchKind },
};

/// Hardware-debug capability advertised by a `HwBreakpointController` for the
/// current os/arch. `0` counts mean "no hardware path — use software fallback".
pub const HwCapabilities = struct {
    max_exec_breakpoints: u8,
    max_watchpoints: u8,
    max_watch_bytes: u16,
    single_step: bool,
    /// True when the platform has no hardware debug facility at all (e.g. wasm);
    /// the session must degrade to software instrumentation with a diagnostic.
    software_only: bool = false,

    pub fn none() HwCapabilities {
        return .{ .max_exec_breakpoints = 0, .max_watchpoints = 0, .max_watch_bytes = 0, .single_step = false, .software_only = true };
    }
};

test "SourceSpan.isUnknown flags the zero sentinel" {
    try std.testing.expect((SourceSpan{ .file = "a", .start = 0, .end = 0 }).isUnknown());
    try std.testing.expect(!(SourceSpan{ .file = "a", .start = 1, .end = 2 }).isUnknown());
}
