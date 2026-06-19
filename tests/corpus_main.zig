const builtin = @import("builtin");
const std = @import("std");
const discovery = @import("discovery.zig");
const execute = @import("execute.zig");
const reporting = @import("reporting.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const raw_args = try init.args.toSlice(allocator);
    const args = try allocator.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;
    if (args.len != 2) return error.InvalidArguments;

    const cases = try discovery.discoverCases(allocator);
    if (cases.len == 0) return error.NoCorpusCases;

    // Optional single-case filter: KIRA_CORPUS_FILTER=substring runs only cases
    // whose path contains the substring. Handy for iterating on one corpus case.
    const case_filter = init.environ.getAlloc(allocator, "KIRA_CORPUS_FILTER") catch null;
    const backends = try resolveBackends(allocator, init.environ);
    const phases = try resolvePhases(allocator, init.environ);
    const jobs = try buildJobs(allocator, cases, case_filter, backends, phases);
    const profile_enabled = try envFlag(allocator, init.environ, "KIRA_CORPUS_PROFILE");
    // Stability mode: native (llvm) cases build and link real binaries, which contend
    // on the toolchain when many run at once and can fail transiently under load. Stable
    // mode runs every job serially and retries a failing llvm job a few times so a
    // transient build/link hiccup does not fail the suite. Real (deterministic) failures
    // still fail after the retries are exhausted. Enable with KIRA_CORPUS_STABLE=1 or
    // `zig build test -Dstable-tests`.
    const stable = try envFlag(allocator, init.environ, "KIRA_CORPUS_STABLE");
    const worker_count = if (stable) @as(usize, @intCast(@min(jobs.len, 1))) else resolveWorkerCount(allocator, init.environ, jobs.len);
    const retries = resolveRetries(allocator, init.environ, stable);
    const options: execute.Options = .{
        .hybrid_runner_path = args[1],
        .profile = profile_enabled,
        .phases = phases,
    };

    const start = nowTimestamp();
    const results = try allocator.alloc(JobResult, jobs.len);
    for (results) |*result| result.* = .{};

    var shared = Shared{
        .jobs = jobs,
        .results = results,
        .options = options,
        .retries = retries,
    };

    if (worker_count <= 1 or jobs.len <= 1) {
        shared.runUntilDone();
    } else {
        const extra_workers = worker_count - 1;
        const threads = try allocator.alloc(std.Thread, extra_workers);
        for (threads) |*thread| thread.* = try std.Thread.spawn(.{}, workerMain, .{&shared});
        shared.runUntilDone();
        for (threads) |thread| thread.join();
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var failures = std.array_list.Managed(reporting.FailureRecord).init(allocator);
    for (results) |result| {
        passed += result.report.passed;
        failed += result.report.failed;
        for (result.report.failures) |failure| try failures.append(failure);
    }

    const suite_report: reporting.SuiteReport = .{
        .total = passed + failed,
        .passed = passed,
        .failed = failed,
        .failures = failures.items,
    };
    try reporting.writeJsonReportFile(allocator, suite_report);
    var human_report: std.Io.Writer.Allocating = .init(allocator);
    try reporting.writeHumanReport(allocator, &human_report.writer, suite_report);
    std.debug.print("{s}", .{try human_report.toOwnedSlice()});
    if (profile_enabled) {
        std.debug.print(
            "Corpus timing: wall={s}, workers={d}, jobs={d}\n",
            .{ try formatDuration(allocator, elapsedNs(start)), worker_count, jobs.len },
        );
    }

    for (results) |result| result.deinit();
    if (failed != 0) return error.CorpusFailures;
}

const Job = struct {
    case: discovery.Case,
    backend: discovery.Backend,
};

const JobResult = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    report: execute.JobReport = .{
        .passed = 0,
        .failed = 0,
        .failures = &.{},
    },

    fn deinit(self: JobResult) void {
        if (self.arena) |arena_ptr| {
            arena_ptr.deinit();
            std.heap.smp_allocator.destroy(arena_ptr);
        }
    }
};

const Shared = struct {
    jobs: []const Job,
    results: []JobResult,
    options: execute.Options,
    retries: usize = 0,
    next_index: std.atomic.Value(usize) = .init(0),

    fn runUntilDone(self: *Shared) void {
        while (true) {
            const index = self.next_index.fetchAdd(1, .monotonic);
            if (index >= self.jobs.len) break;
            self.runJob(index);
        }
    }

    fn runJob(self: *Shared, index: usize) void {
        const job = self.jobs[index];
        // Only native (llvm) jobs are retried: they build/link real binaries and so are
        // the only jobs subject to transient toolchain contention. vm/hybrid run in-process.
        const max_attempts: usize = if (job.backend == .llvm) self.retries + 1 else 1;
        var attempt: usize = 0;
        while (true) {
            attempt += 1;
            const arena_ptr = std.heap.smp_allocator.create(std.heap.ArenaAllocator) catch {
                self.results[index] = .{
                    .report = outOfMemoryReport(),
                };
                return;
            };
            arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            const allocator = arena_ptr.allocator();

            const report = execute.runBackendJob(allocator, job.case, job.backend, self.options) catch |err| blk: {
                const label = std.fmt.allocPrint(
                    allocator,
                    "{s} [{s}]",
                    .{ job.case.name, backendName(job.backend) },
                ) catch "internal";
                break :blk internalFailureReport(allocator, label, err);
            };

            // Retry a failing llvm job (transient build/link flake) until it passes or the
            // attempts are exhausted; a deterministic failure still fails after the retries.
            if (report.failed != 0 and attempt < max_attempts) {
                arena_ptr.deinit();
                std.heap.smp_allocator.destroy(arena_ptr);
                continue;
            }

            self.results[index] = .{
                .arena = arena_ptr,
                .report = report,
            };
            return;
        }
    }
};

fn internalFailureReport(allocator: std.mem.Allocator, label: []const u8, err: anyerror) execute.JobReport {
    const trace = std.fmt.allocPrint(allocator, "FAIL {s}: {s}\n", .{ label, @errorName(err) }) catch "FAIL <internal>: execution failed\n";
    const signature = std.fmt.allocPrint(allocator, "internal:{s}", .{@errorName(err)}) catch "internal";
    const failures = allocator.alloc(reporting.FailureRecord, 1) catch return outOfMemoryReport();
    failures[0] = .{
        .label = label,
        .error_name = @errorName(err),
        .signature = signature,
        .trace = trace,
    };
    return .{
        .passed = 0,
        .failed = 1,
        .failures = failures,
    };
}

fn outOfMemoryReport() execute.JobReport {
    const static_failures = struct {
        const items = [_]reporting.FailureRecord{.{
            .label = "<internal>",
            .error_name = "OutOfMemory",
            .signature = "internal:OutOfMemory",
            .trace = "FAIL <internal>: OutOfMemory\n",
        }};
    }.items;
    return .{
        .passed = 0,
        .failed = 1,
        .failures = &static_failures,
    };
}

fn workerMain(shared: *Shared) void {
    shared.runUntilDone();
}

fn buildJobs(
    allocator: std.mem.Allocator,
    cases: []const discovery.Case,
    case_filter: ?[]const u8,
    backends: []const discovery.Backend,
    phases: execute.PhaseSet,
) ![]Job {
    var jobs = std.array_list.Managed(Job).init(allocator);
    for (cases) |case| {
        if (case_filter) |filter| {
            if (filter.len != 0 and std.mem.indexOf(u8, case.name, filter) == null) continue;
        }
        if (!caseHasRunnableSelectedPhase(case, phases)) continue;
        for (case.expectation.backends) |backend| {
            if (!backendSelected(backends, backend)) continue;
            try jobs.append(.{
                .case = case,
                .backend = backend,
            });
        }
    }
    const owned = try jobs.toOwnedSlice();
    std.mem.sort(Job, owned, {}, lessJob);
    return owned;
}

fn lessJob(_: void, lhs: Job, rhs: Job) bool {
    const lhs_priority = backendPriority(lhs.backend);
    const rhs_priority = backendPriority(rhs.backend);
    if (lhs_priority != rhs_priority) return lhs_priority < rhs_priority;
    return std.mem.lessThan(u8, lhs.case.name, rhs.case.name);
}

fn backendPriority(backend: discovery.Backend) u8 {
    return switch (backend) {
        .llvm => 0,
        .hybrid => 1,
        .vm => 2,
    };
}

fn caseHasRunnableSelectedPhase(case: discovery.Case, phases: execute.PhaseSet) bool {
    if (phases.check and case.expectation.check.result != .blocked) return true;
    if (phases.build and case.expectation.build.result != .blocked) return true;
    if (phases.run and case.expectation.run.result != .blocked) return true;
    return false;
}

fn backendSelected(backends: []const discovery.Backend, backend: discovery.Backend) bool {
    for (backends) |selected| {
        if (selected == backend) return true;
    }
    return false;
}

fn resolveBackends(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const discovery.Backend {
    const raw = environ.getAlloc(allocator, "KIRA_CORPUS_BACKENDS") catch return allocator.dupe(discovery.Backend, &.{ .vm, .llvm, .hybrid });
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "all")) return allocator.dupe(discovery.Backend, &.{ .vm, .llvm, .hybrid });

    var parsed = std.array_list.Managed(discovery.Backend).init(allocator);
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        const backend: discovery.Backend = if (std.mem.eql(u8, part, "vm"))
            .vm
        else if (std.mem.eql(u8, part, "llvm"))
            .llvm
        else if (std.mem.eql(u8, part, "hybrid"))
            .hybrid
        else
            return error.InvalidBackendFilter;
        if (!backendSelected(parsed.items, backend)) try parsed.append(backend);
    }
    if (parsed.items.len == 0) return error.InvalidBackendFilter;
    return parsed.toOwnedSlice();
}

fn resolvePhases(allocator: std.mem.Allocator, environ: std.process.Environ) !execute.PhaseSet {
    const raw = environ.getAlloc(allocator, "KIRA_CORPUS_PHASES") catch return .all;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "all")) return .all;

    var phases = execute.PhaseSet{ .check = false, .build = false, .run = false };
    var parts = std.mem.splitAny(u8, trimmed, ", ");
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "check")) {
            phases.check = true;
        } else if (std.mem.eql(u8, part, "build")) {
            phases.build = true;
        } else if (std.mem.eql(u8, part, "run")) {
            phases.run = true;
        } else {
            return error.InvalidPhaseFilter;
        }
    }
    if (!phases.check and !phases.build and !phases.run) return error.InvalidPhaseFilter;
    return phases;
}

fn resolveWorkerCount(allocator: std.mem.Allocator, environ: std.process.Environ, job_count: usize) usize {
    if (job_count == 0) return 0;
    if (environ.getAlloc(allocator, "KIRA_CORPUS_JOBS")) |value| {
        defer allocator.free(value);
        if (std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t\r\n"), 10)) |parsed| {
            return clampWorkerCount(parsed, job_count);
        } else |_| {}
    } else |_| {}

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const cap = switch (builtin.os.tag) {
        .windows => @min(cpu_count, 4),
        else => @min(cpu_count, 8),
    };
    return clampWorkerCount(cap, job_count);
}

fn clampWorkerCount(count: usize, job_count: usize) usize {
    const resolved = if (count == 0) 1 else count;
    return @max(@min(resolved, job_count), 1);
}

// Number of EXTRA attempts for a failing llvm job. Defaults to 2 in stable mode, 0
// otherwise; KIRA_CORPUS_RETRIES overrides either way (capped to keep reruns bounded).
fn resolveRetries(allocator: std.mem.Allocator, environ: std.process.Environ, stable: bool) usize {
    var retries: usize = if (stable) 2 else 0;
    if (environ.getAlloc(allocator, "KIRA_CORPUS_RETRIES")) |value| {
        defer allocator.free(value);
        if (std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t\r\n"), 10)) |parsed| {
            retries = parsed;
        } else |_| {}
    } else |_| {}
    return @min(retries, 5);
}

fn envFlag(allocator: std.mem.Allocator, environ: std.process.Environ, name: []const u8) !bool {
    const value = environ.getAlloc(allocator, name) catch return false;
    defer allocator.free(value);
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "0")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) return false;
    return true;
}

fn backendName(backend: discovery.Backend) []const u8 {
    return switch (backend) {
        .vm => "vm",
        .llvm => "llvm",
        .hybrid => "hybrid",
    };
}

fn nowTimestamp() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
}

fn elapsedNs(start: std.Io.Clock.Timestamp) u64 {
    const duration_ns = start.durationTo(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake)).raw.toNanoseconds();
    return @intCast(@max(duration_ns, 0));
}

fn formatDuration(allocator: std.mem.Allocator, ns: u64) ![]const u8 {
    if (ns >= std.time.ns_per_ms) {
        const whole = ns / std.time.ns_per_ms;
        const tenths = (ns % std.time.ns_per_ms) / (std.time.ns_per_ms / 10);
        if (tenths == 0) return std.fmt.allocPrint(allocator, "{d}ms", .{whole});
        return std.fmt.allocPrint(allocator, "{d}.{d}ms", .{ whole, tenths });
    }
    if (ns >= std.time.ns_per_us) {
        return std.fmt.allocPrint(allocator, "{d}us", .{ns / std.time.ns_per_us});
    }
    return std.fmt.allocPrint(allocator, "{d}ns", .{ns});
}
