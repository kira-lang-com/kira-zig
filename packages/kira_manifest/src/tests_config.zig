const std = @import("std");
const platform_config = @import("platform_config.zig");

/// Which portion of a `Test` / `FailTest` suite the runner exercises when a
/// package's manifest carries a `Tests { ... }` declaration.
///
/// * `.check` — compile/analyze every `Test` and `FailTest` without executing
///   `Test` bodies. `FailTest` cases still evaluate: they are compile-time
///   negative checks that assert a diagnostic outcome.
/// * `.run` — execute `Test` bodies (and evaluate `FailTest`s).
/// * `.both` — do the check pass and the run pass.
pub const TestPhase = enum {
    check,
    run,
    both,

    pub fn parse(value: []const u8) ?TestPhase {
        if (std.mem.eql(u8, value, "check") or std.mem.eql(u8, value, "Check")) return .check;
        if (std.mem.eql(u8, value, "run") or std.mem.eql(u8, value, "Run")) return .run;
        if (std.mem.eql(u8, value, "both") or std.mem.eql(u8, value, "Both")) return .both;
        return null;
    }

    pub fn label(self: TestPhase) []const u8 {
        return @tagName(self);
    }
};

/// The `Tests { backends: [...], phase: ... }` manifest declaration honored by
/// `kira test`. `backends` is the matrix the runner iterates (each must end
/// 0-failed); `phase` selects check/run/both. A `null` `TestsConfig` on a
/// `ProjectManifest` means the manifest omitted the field and the runner keeps
/// its historical single-backend behavior.
pub const TestsConfig = struct {
    backends: []const platform_config.Backend,
    phase: TestPhase = .run,
};
