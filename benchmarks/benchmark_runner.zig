// Repo-native performance harness for Kira. Discovers each benchmark project under
// benchmarks/ (any subdirectory with a project.toml), runs it through the real
// compiler/runtime on every requested backend, and prints a wall-clock table.
//
// Usage (wired as `zig build bench`):
//   kira-benchmark <path-to-kira-cli>
//
// Backends measured:
//   - vm     : `kira run --backend vm`   (frontend + bytecode interpretation)
//   - llvm   : the generated native executable run directly (excludes compile time,
//              so the number is pure Kira-generated machine code)
//   - hybrid : `kira run --backend hybrid` when KIRA_BENCH_HYBRID=1 (off by default;
//              hybrid bridges every call through the VM and is slow on hot loops)
//
// Each measured command is run several times and the *minimum* wall time is kept
// (least perturbed by the OS). This proves Kira behavior end to end — it executes
// the real program and requires a clean exit; a crash or non-zero exit fails the
// harness rather than being silently timed as "fast".
const std = @import("std");

const Result = struct {
    name: []const u8,
    vm_ns: ?u64,
    llvm_ns: ?u64,
    hybrid_ns: ?u64,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("usage: kira-benchmark <kira-cli-path>\n", .{});
        return error.MissingCliPath;
    }
    const kira = args[1];

    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = init.environ });
    defer io_impl.deinit();
    const io = io_impl.io();

    const want_hybrid = blk: {
        const v = init.environ.getAlloc(allocator, "KIRA_BENCH_HYBRID") catch break :blk false;
        const t = std.mem.trim(u8, v, " \t\r\n");
        break :blk t.len > 0 and !std.mem.eql(u8, t, "0");
    };
    const repeats: usize = blk: {
        const v = init.environ.getAlloc(allocator, "KIRA_BENCH_REPEATS") catch break :blk 3;
        break :blk std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch 3;
    };

    var names = std.array_list.Managed([]const u8).init(allocator);
    try discoverBenchmarks(allocator, &names);
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var results = std.array_list.Managed(Result).init(allocator);
    for (names.items) |name| {
        const dir = try std.fmt.allocPrint(allocator, "benchmarks/{s}", .{name});

        // Build the native executable once (compile time excluded from the measurement).
        runOnce(allocator, io, &.{ kira, "run", "--backend", "llvm", dir }) catch {};
        const native_bin = try std.fmt.allocPrint(allocator, "benchmarks/{s}/generated/{s}.run", .{ name, name });

        const llvm_ns = timeMin(allocator, io, &.{native_bin}, repeats) catch null;
        const vm_ns = timeMin(allocator, io, &.{ kira, "run", "--backend", "vm", dir }, if (repeats > 2) 2 else repeats) catch null;
        const hybrid_ns: ?u64 = if (want_hybrid)
            timeMin(allocator, io, &.{ kira, "run", "--backend", "hybrid", dir }, 1) catch null
        else
            null;

        try results.append(.{ .name = name, .vm_ns = vm_ns, .llvm_ns = llvm_ns, .hybrid_ns = hybrid_ns });
    }

    printTable(results.items, want_hybrid);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn discoverBenchmarks(allocator: std.mem.Allocator, out: *std.array_list.Managed([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, "benchmarks", .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);
    var walker = dir.iterate();
    while (try walker.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .directory) continue;
        var sub = dir.openDir(std.Options.debug_io, entry.name, .{}) catch continue;
        defer sub.close(std.Options.debug_io);
        var manifest = sub.openFile(std.Options.debug_io, "project.toml", .{}) catch continue;
        manifest.close(std.Options.debug_io);
        try out.append(try allocator.dupe(u8, entry.name));
    }
}

// Run a command `repeats` times, returning the minimum wall time in ns. A non-zero
// exit or crash is a hard failure (the program must really run to be benchmarked).
fn timeMin(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, repeats: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < repeats) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
        const result = try std.process.run(allocator, io, .{ .argv = argv });
        const elapsed: u64 = @intCast(@max(start.durationTo(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake)).raw.toNanoseconds(), 0));
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.BenchmarkProcessFailed,
            else => return error.BenchmarkProcessCrashed,
        }
        if (elapsed < best) best = elapsed;
    }
    return best;
}

fn runOnce(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn printTable(results: []const Result, want_hybrid: bool) void {
    std.debug.print("\nKira benchmark suite (min wall time; llvm = generated executable, vm = `kira run --backend vm`)\n", .{});
    if (want_hybrid) {
        std.debug.print("{s:<22} {s:>12} {s:>12} {s:>12} {s:>10}\n", .{ "benchmark", "vm", "llvm", "hybrid", "vm/llvm" });
    } else {
        std.debug.print("{s:<22} {s:>12} {s:>12} {s:>10}\n", .{ "benchmark", "vm", "llvm", "vm/llvm" });
    }
    for (results) |r| {
        var vm_buf: [24]u8 = undefined;
        var llvm_buf: [24]u8 = undefined;
        var hy_buf: [24]u8 = undefined;
        var ratio_buf: [24]u8 = undefined;
        const vm_s = fmtMs(&vm_buf, r.vm_ns);
        const llvm_s = fmtMs(&llvm_buf, r.llvm_ns);
        const ratio_s = fmtRatio(&ratio_buf, r.vm_ns, r.llvm_ns);
        if (want_hybrid) {
            const hy_s = fmtMs(&hy_buf, r.hybrid_ns);
            std.debug.print("{s:<22} {s:>12} {s:>12} {s:>12} {s:>10}\n", .{ r.name, vm_s, llvm_s, hy_s, ratio_s });
        } else {
            std.debug.print("{s:<22} {s:>12} {s:>12} {s:>10}\n", .{ r.name, vm_s, llvm_s, ratio_s });
        }
    }
    std.debug.print("\n", .{});
}

fn fmtMs(buf: []u8, ns: ?u64) []const u8 {
    const v = ns orelse return "FAIL";
    const ms = @as(f64, @floatFromInt(v)) / 1.0e6;
    return std.fmt.bufPrint(buf, "{d:.2} ms", .{ms}) catch "?";
}

fn fmtRatio(buf: []u8, vm: ?u64, llvm: ?u64) []const u8 {
    const a = vm orelse return "-";
    const b = llvm orelse return "-";
    if (b == 0) return "-";
    const ratio = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
    return std.fmt.bufPrint(buf, "{d:.1}x", .{ratio}) catch "?";
}
