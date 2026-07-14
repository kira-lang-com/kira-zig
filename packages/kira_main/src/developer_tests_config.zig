const std = @import("std");
const api = @import("api.zig");
const build_def = @import("kira_build_definition");
const manifest = @import("kira_manifest");

/// Which portion of a suite a `kira test` run exercises. Mirrors
/// `kira_manifest.TestPhase` but is local to the runner so developer.zig does
/// not depend on the manifest enum directly.
pub const Phase = enum { check, run, both };

pub const BackendEntry = struct {
    /// The developer-facade backend passed to the per-leaf executor.
    backend: api.KiraDeveloperBackend,
    /// Human-readable label for the per-backend tally header (e.g. "vm").
    label: []const u8,
};

/// The resolved backend matrix + phase for a `kira test` invocation.
pub const Plan = struct {
    backends: []const BackendEntry,
    phase: Phase,
    /// True when the plan came from a manifest `Tests { ... }` declaration (so
    /// per-backend tallies are printed). False for the historical single-backend
    /// behavior, where the runner prints a single combined tally as before.
    from_manifest: bool,
};

/// Decide the backend matrix + phase for `kira test`.
///
/// * An explicit `--backend` (`explicit_backend != .default`) always overrides
///   to that single backend. The phase then comes from the manifest's `Tests`
///   declaration if present, else `.run`.
/// * Otherwise, if the manifest declares `Tests { backends, phase }`, iterate
///   that backend matrix with that phase.
/// * Otherwise fall back to the historical behavior: a single `.default`
///   backend, `.run` phase, no per-backend tally header.
pub fn resolvePlan(
    allocator: std.mem.Allocator,
    project: ?manifest.ProjectManifest,
    explicit_backend: api.KiraDeveloperBackend,
) !Plan {
    if (explicit_backend != .default) {
        const entries = try allocator.alloc(BackendEntry, 1);
        entries[0] = backendEntry(explicit_backend);
        return .{ .backends = entries, .phase = phaseFromManifest(project), .from_manifest = false };
    }

    if (project) |p| {
        if (p.tests) |tests| {
            if (tests.backends.len != 0) {
                var list = std.array_list.Managed(BackendEntry).init(allocator);
                for (tests.backends) |backend| {
                    try list.append(.{ .backend = mapManifestBackend(backend), .label = @tagName(backend) });
                }
                return .{ .backends = try list.toOwnedSlice(), .phase = mapPhase(tests.phase), .from_manifest = true };
            }
        }
    }

    return legacyPlan(allocator);
}

/// Map a developer-facade backend to the `ExecutionTarget` used for compiling a
/// leaf during the Check phase (`.default` compiles for the VM).
pub fn checkTarget(backend: api.KiraDeveloperBackend) build_def.ExecutionTarget {
    return switch (backend) {
        .default, .vm => .vm,
        .llvm => .llvm_native,
        .hybrid => .hybrid,
        .wasm32_emscripten => .wasm32_emscripten,
    };
}

pub fn runsCheck(phase: Phase) bool {
    return phase == .check or phase == .both;
}

pub fn runsExecute(phase: Phase) bool {
    return phase == .run or phase == .both;
}

fn legacyPlan(allocator: std.mem.Allocator) !Plan {
    const entries = try allocator.alloc(BackendEntry, 1);
    entries[0] = .{ .backend = .default, .label = "default" };
    return .{ .backends = entries, .phase = .run, .from_manifest = false };
}

fn backendEntry(backend: api.KiraDeveloperBackend) BackendEntry {
    return .{ .backend = backend, .label = @tagName(backend) };
}

fn mapManifestBackend(backend: manifest.Backend) api.KiraDeveloperBackend {
    return switch (backend) {
        .vm => .vm,
        .llvm => .llvm,
        .hybrid => .hybrid,
    };
}

fn mapPhase(phase: manifest.TestPhase) Phase {
    return switch (phase) {
        .check => .check,
        .run => .run,
        .both => .both,
    };
}

fn phaseFromManifest(project: ?manifest.ProjectManifest) Phase {
    if (project) |p| {
        if (p.tests) |tests| return mapPhase(tests.phase);
    }
    return .run;
}

test "explicit backend overrides to single" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = try resolvePlan(arena.allocator(), null, .llvm);
    try std.testing.expectEqual(@as(usize, 1), plan.backends.len);
    try std.testing.expectEqual(api.KiraDeveloperBackend.llvm, plan.backends[0].backend);
    try std.testing.expect(!plan.from_manifest);
}

test "manifest Tests drives the matrix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var project = manifest.ProjectManifest{ .name = "X", .version = "0.1.0" };
    project.tests = .{ .backends = &.{ .vm, .hybrid }, .phase = .both };
    const plan = try resolvePlan(arena.allocator(), project, .default);
    try std.testing.expectEqual(@as(usize, 2), plan.backends.len);
    try std.testing.expectEqual(Phase.both, plan.phase);
    try std.testing.expect(plan.from_manifest);
}

test "no manifest Tests falls back to legacy single default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = try resolvePlan(arena.allocator(), null, .default);
    try std.testing.expectEqual(@as(usize, 1), plan.backends.len);
    try std.testing.expectEqual(api.KiraDeveloperBackend.default, plan.backends[0].backend);
    try std.testing.expectEqual(Phase.run, plan.phase);
}
