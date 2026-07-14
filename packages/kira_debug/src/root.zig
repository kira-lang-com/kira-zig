//! kira_debug — Kira's source-level debugger core, backend-agnostic across VM,
//! native (hardware-assisted), and hybrid. This root wires the package's public
//! surface; behavior lives in focused submodules (Core Law #5).

// Contract / foundation modules (already landed, do not edit).
pub const debug_info = @import("debug_info.zig");
pub const target = @import("target.zig");
pub const hw_controller = @import("hw/controller.zig");

// Breakpoint / stepping / frame model.
pub const breakpoint = @import("breakpoint.zig");
pub const step = @import("step.zig");
pub const frame = @import("frame.zig");
pub const value_view = @import("value_view.zig");
pub const line_resolver = @import("line_resolver.zig");
pub const sync = @import("sync.zig");

// Expression evaluation.
pub const eval_types = @import("eval_types.zig");
pub const eval_parse = @import("eval_parse.zig");
pub const eval = @import("eval.zig");

// Backend targets. Each imports only its own backend's runtime; native_target
// selects the current-platform hw controller at comptime, so off-platform hw
// impls are never semantically analyzed on this host.
pub const vm_target = @import("vm_target.zig");
pub const native_target = @import("native_target.zig");
pub const hybrid_target = @import("hybrid_target.zig");

// Session orchestration + REPL + wire protocols.
pub const session = @import("session.zig");
pub const repl = @import("repl.zig");
pub const verbs = @import("protocol/verbs.zig");
pub const dap = @import("protocol/dap.zig");
pub const dap_messages = @import("protocol/dap_messages.zig");

// Re-export the most-used types at the package root for ergonomics.
pub const SourcePosition = debug_info.SourcePosition;
pub const SourceSpan = debug_info.SourceSpan;
pub const Frame = debug_info.Frame;
pub const LocalView = debug_info.LocalView;
pub const StopReason = debug_info.StopReason;
pub const BreakpointSpec = debug_info.BreakpointSpec;
pub const HwCapabilities = debug_info.HwCapabilities;
pub const WatchKind = debug_info.WatchKind;
pub const Backend = debug_info.Backend;
pub const DebugTarget = target.DebugTarget;
pub const StepKind = target.StepKind;
pub const TargetError = target.TargetError;
pub const HwBreakpointController = hw_controller.HwBreakpointController;

pub const DebugSession = session.DebugSession;
pub const BreakpointTable = breakpoint.BreakpointTable;
pub const StepController = step.StepController;
pub const Evaluator = eval.Evaluator;
pub const LineResolver = line_resolver.LineResolver;
pub const VmTarget = vm_target.VmTarget;
pub const NativeTarget = native_target.NativeTarget;
pub const HybridTarget = hybrid_target.HybridTarget;
pub const Repl = repl.Repl;
pub const DapHandler = dap.DapHandler;

test {
    const std = @import("std");
    // Force-analyze the portable surface. The hw controller vtable is included,
    // but the platform-specific hw impl files are intentionally NOT
    // refAllDecls'd here — they are reached only through native_target's
    // comptime platform switch, so off-platform impls stay unanalyzed.
    std.testing.refAllDecls(debug_info);
    std.testing.refAllDecls(target);
    std.testing.refAllDecls(hw_controller);
    std.testing.refAllDecls(breakpoint);
    std.testing.refAllDecls(step);
    std.testing.refAllDecls(frame);
    std.testing.refAllDecls(value_view);
    std.testing.refAllDecls(line_resolver);
    std.testing.refAllDecls(sync);
    std.testing.refAllDecls(eval_types);
    std.testing.refAllDecls(eval_parse);
    std.testing.refAllDecls(eval);
    std.testing.refAllDecls(vm_target);
    std.testing.refAllDecls(native_target);
    std.testing.refAllDecls(hybrid_target);
    std.testing.refAllDecls(session);
    std.testing.refAllDecls(repl);
    std.testing.refAllDecls(verbs);
    std.testing.refAllDecls(dap);
    std.testing.refAllDecls(dap_messages);
}
