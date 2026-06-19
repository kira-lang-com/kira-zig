const builtin = @import("builtin");
const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const diagnostics = @import("kira_diagnostics");
const discovery = @import("discovery.zig");

// Minimal spin reader-writer lock. This stdlib exposes only `std.atomic.Mutex`
// (a spinlock) and an `Io`-bound `std.Io.RwLock`, neither of which fits a plain
// shared/exclusive guard, so the corpus runner carries its own. State: 0 = free,
// n>0 = n shared holders, -1 = one exclusive holder. Waiters yield rather than
// busy-spin so a thread blocked on a multi-second native build does not pin a core.
pub const RwLock = struct {
    state: std.atomic.Value(i32) = .init(0),

    pub fn lockShared(self: *RwLock) void {
        while (true) {
            const current = self.state.load(.monotonic);
            if (current >= 0 and self.state.cmpxchgWeak(current, current + 1, .acquire, .monotonic) == null) return;
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    pub fn unlockShared(self: *RwLock) void {
        _ = self.state.fetchSub(1, .release);
    }

    pub fn lock(self: *RwLock) void {
        while (self.state.cmpxchgWeak(0, -1, .acquire, .monotonic) != null) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *RwLock) void {
        self.state.store(0, .release);
    }
};

pub const PhaseSet = struct {
    check: bool = true,
    build: bool = true,
    run: bool = true,

    pub const all: PhaseSet = .{};
    pub const run_only: PhaseSet = .{ .check = false, .build = false, .run = true };

    pub fn includes(self: PhaseSet, phase: discovery.Phase) bool {
        return switch (phase) {
            .check => self.check,
            .build => self.build,
            .run => self.run,
        };
    }
};

pub const DiagnosticSummary = struct {
    code: []const u8,
    title: []const u8,
};

pub fn firstDiagnostic(items: []const diagnostics.Diagnostic) DiagnosticSummary {
    if (items.len == 0) return .{ .code = "<none>", .title = "<none>" };
    return .{
        .code = items[0].code orelse "<none>",
        .title = items[0].title,
    };
}

pub const TmpDir = struct {
    allocator: std.mem.Allocator,
    sub_path: []const u8,
    dir: std.Io.Dir,

    pub fn cleanup(self: *TmpDir) void {
        self.dir.close(std.Options.debug_io);
        std.Io.Dir.cwd().deleteTree(std.Options.debug_io, self.sub_path) catch {};
        self.allocator.free(self.sub_path);
    }
};

pub fn makeTmpDir(allocator: std.mem.Allocator) !TmpDir {
    var bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&bytes);
    const suffix = std.mem.readInt(u64, &bytes, .little);
    const sub_path = try std.fmt.allocPrint(allocator, ".zig-cache/corpus-{x}", .{suffix});
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, sub_path);
    const dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, sub_path, .{});
    return .{ .allocator = allocator, .sub_path = sub_path, .dir = dir };
}

pub fn inheritedProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .wasi, .emscripten, .freestanding, .other => .empty,
        else => .{ .block = .{ .slice = currentPosixEnvironBlock() } },
    };
}

fn currentPosixEnvironBlock() [:null]const ?[*:0]const u8 {
    if (!builtin.link_libc) return &.{};

    const environ = std.c.environ;
    var len: usize = 0;
    while (environ[len] != null) : (len += 1) {}
    return environ[0..len :null];
}

pub fn buildOutputPath(allocator: std.mem.Allocator, tmp: TmpDir, backend: discovery.Backend) ![]const u8 {
    return switch (backend) {
        .vm => makeBackendOutputPath(allocator, tmp, "vm", ".kbc"),
        .llvm => makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension()),
        .hybrid => makeBackendOutputPath(allocator, tmp, "hybrid", ".khm"),
    };
}

pub fn makeBackendOutputPath(
    allocator: std.mem.Allocator,
    tmp: TmpDir,
    backend_name: []const u8,
    extension: []const u8,
) ![]const u8 {
    try tmp.dir.createDirPath(std.Options.debug_io, backend_name);
    const backend_root = try tmp.dir.realPathFileAlloc(std.Options.debug_io, backend_name, allocator);
    const file_name = try std.fmt.allocPrint(allocator, "main{s}", .{extension});
    return std.fs.path.join(allocator, &.{ backend_root, file_name });
}

pub fn expectExitedZero(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.CommandFailed,
    }
}

pub fn matrixLabel(
    allocator: std.mem.Allocator,
    case_name: []const u8,
    backend: discovery.Backend,
    phase: discovery.Phase,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} [{s} {s}]", .{ case_name, backendName(backend), phaseName(phase) });
}

pub fn backendLabel(
    allocator: std.mem.Allocator,
    case_name: []const u8,
    backend: discovery.Backend,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} [{s}]", .{ case_name, backendName(backend) });
}

pub fn backendName(backend: discovery.Backend) []const u8 {
    return switch (backend) {
        .vm => "vm",
        .llvm => "llvm",
        .hybrid => "hybrid",
    };
}

pub fn phaseName(phase: discovery.Phase) []const u8 {
    return switch (phase) {
        .check => "check",
        .build => "build",
        .run => "run",
    };
}

pub fn expectedResultName(result: discovery.ExpectedResult) []const u8 {
    return switch (result) {
        .pass => "pass",
        .fail => "fail",
        .blocked => "blocked",
    };
}

pub fn stageName(stage: discovery.Stage) []const u8 {
    return switch (stage) {
        .lexer => "lexer",
        .parser => "parser",
        .graph => "graph",
        .semantics => "semantics",
        .ir => "ir",
        .backend_prepare => "backend_prepare",
    };
}

pub fn executionTarget(backend: discovery.Backend) build_def.ExecutionTarget {
    return switch (backend) {
        .vm => .vm,
        .llvm => .llvm_native,
        .hybrid => .hybrid,
    };
}

pub fn fromBuildStage(stage: build.FrontendStage) discovery.Stage {
    return switch (stage) {
        .lexer => .lexer,
        .parser => .parser,
        .graph => .graph,
        .semantics => .semantics,
        .ir => .ir,
        .backend_prepare => .backend_prepare,
    };
}

pub fn nowTimestamp() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
}

pub fn elapsedNs(start: std.Io.Clock.Timestamp) u64 {
    const duration_ns = start.durationTo(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake)).raw.toNanoseconds();
    return @intCast(@max(duration_ns, 0));
}

pub fn writeDuration(writer: *std.Io.Writer, ns: u64) !void {
    if (ns >= std.time.ns_per_ms) {
        const whole = ns / std.time.ns_per_ms;
        const tenths = (ns % std.time.ns_per_ms) / (std.time.ns_per_ms / 10);
        if (tenths == 0) {
            try writer.print("{d}ms", .{whole});
        } else {
            try writer.print("{d}.{d}ms", .{ whole, tenths });
        }
        return;
    }
    if (ns >= std.time.ns_per_us) {
        const whole = ns / std.time.ns_per_us;
        try writer.print("{d}us", .{whole});
        return;
    }
    try writer.print("{d}ns", .{ns});
}

pub fn cacheStatusName(status: build.CacheStatus) []const u8 {
    return switch (status) {
        .not_checked => "none",
        .hit => "hit",
        .miss => "miss",
        .stored => "stored",
    };
}

pub fn findExecutable(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .executable) return artifact;
    }
    return null;
}

pub fn runtimeCwdForCase(allocator: std.mem.Allocator, case: discovery.Case) ![]const u8 {
    const source_dir = std.fs.path.dirname(case.source_path) orelse ".";
    var current = try allocator.dupe(u8, source_dir);
    while (true) {
        if (dirHasProjectManifest(current)) return current;
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return current;
}

fn dirHasProjectManifest(path: []const u8) bool {
    return fileExistsAt(path, "kira.toml") or fileExistsAt(path, "project.toml") or fileExistsAt(path, "Kira.toml");
}

fn fileExistsAt(dir_path: []const u8, file_name: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{}) catch return false;
    defer dir.close(std.Options.debug_io);
    var file = dir.openFile(std.Options.debug_io, file_name, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}
