//! Incremental native build: partition the program into a support codegen unit
//! (shared dtor/dispatcher bodies, host main, hybrid trampolines) plus one CGU
//! per user function, cache each object by its `cgu_hash` digest, and full-relink
//! the live set every build. A one-line body edit re-emits exactly one small
//! single-function object; everything else is a cache hit.
//!
//! Flag-gated behind `KIRA_INCREMENTAL` (default OFF) and restricted to native
//! executable builds; every other request falls back to the whole-program path.
//! See docs/incremental_native_codegen.md.

const std = @import("std");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
const native = @import("kira_native_lib_definition");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const cgu_hash = @import("cgu_hash.zig");
const cgu_cache = @import("cgu_cache.zig");
const runtime_utils = @import("backend_runtime_utils.zig");
const toolchain = @import("toolchain.zig");
const linker = @import("link.zig");

/// Whether the incremental path is requested. Default OFF: the whole-program
/// build stays the default until the split is proven at full corpus parity.
pub fn enabled() bool {
    const raw = std.c.getenv("KIRA_INCREMENTAL") orelse return false;
    const value = std.mem.span(raw);
    return value.len != 0 and value[0] != '0';
}

/// Whether this request is one the incremental path handles today: a native
/// executable link. Hybrid shared libraries and object-only requests fall back.
pub fn handles(request: backend_api.CompileRequest) bool {
    return request.mode == .llvm_native and request.emit.executable_path != null;
}

fn dropEnabled() bool {
    const raw = std.c.getenv("KIRA_CAPI_DROP") orelse return true;
    const value = std.mem.span(raw);
    return value.len != 0 and value[0] != '0';
}

/// Directory holding this project's incremental object cache. Placed next to the
/// whole-program object so it shares the build output tree and is cleaned with it.
fn incrementalRoot(allocator: std.mem.Allocator, object_path: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(object_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "incremental" });
}

/// One codegen unit queued for emission: the module plan and the cache object
/// path to write. Independent of every other item, so items emit concurrently.
const WorkItem = struct {
    plan: capi.ModulePlan,
    object_path: []const u8,
};

/// Emit every pending CGU, in parallel across CPU cores. Each worker uses its own
/// arena (backed by the page allocator) so no two threads share a mutable
/// allocator; the LLVM contexts are per-CGU and disjoint, `api`/`request`/`triple`
/// and the item slice are read-only, and clang runs as separate subprocesses — so
/// the only shared mutable state is the atomic work cursor and the first-error
/// slot. Returns the first emit error encountered, if any.
fn emitPending(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    request: backend_api.CompileRequest,
    triple: []const u8,
    items: []const WorkItem,
) !void {
    if (items.len == 0) return;

    // Register the native target once, single-threaded, before any worker builds a
    // TargetMachine. Then emit the first CGU on this thread as a warmup: the first
    // LLVMRunPasses call lazily initializes process-global pass/cl::opt state, which
    // must not race across the pool.
    ensureTargetsInitialized(api);
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        try emitCgu(arena.allocator(), api, request, triple, items[0].plan, items[0].object_path);
    }
    const rest = items[1..];
    if (rest.len == 0) return;

    var ctx = EmitCtx{ .api = api, .request = request, .triple = triple, .items = rest };

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const thread_count = @min(rest.len, @max(@as(usize, 1), cpu_count));

    if (thread_count <= 1) {
        ctx.work();
    } else {
        const threads = try allocator.alloc(std.Thread, thread_count);
        defer allocator.free(threads);
        var spawned: usize = 0;
        for (threads) |*t| {
            t.* = std.Thread.spawn(.{}, EmitCtx.work, .{&ctx}) catch break;
            spawned += 1;
        }
        // If not every thread spawned, run the remainder on this thread too so no
        // work item is dropped.
        if (spawned == 0) ctx.work();
        for (threads[0..spawned]) |t| t.join();
    }

    if (ctx.first_error) |err| return err;
}

const EmitCtx = struct {
    api: *const llvm.Api,
    request: backend_api.CompileRequest,
    triple: []const u8,
    items: []const WorkItem,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    err_lock: std.atomic.Mutex = .unlocked,
    first_error: ?anyerror = null,

    fn work(self: *EmitCtx) void {
        while (true) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.items.len) return;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            emitCgu(arena.allocator(), self.api, self.request, self.triple, self.items[index].plan, self.items[index].object_path) catch |err| {
                while (!self.err_lock.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
                defer self.err_lock.unlock();
                if (self.first_error == null) self.first_error = err;
            };
        }
    }
};

/// Build one CGU module per the plan and emit its object straight into the cache
/// at `object_path`, then dispose the module and its context.
fn emitCgu(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    request: backend_api.CompileRequest,
    triple: []const u8,
    plan: capi.ModulePlan,
    object_path: []const u8,
) !void {
    const lowered = try capi.buildModulePlanned(allocator, api, request, triple, plan);
    defer api.LLVMContextDispose(lowered.context);
    defer api.LLVMDisposeModule(lowered.module_ref);
    try emitObjectInProcess(allocator, api, lowered.module_ref, triple, object_path);
}

/// Register the native target once per process (idempotent). Must run before any
/// TargetMachine is created, and single-threaded — the registries it mutates are
/// process-global. Called from compileExecutable before the emit pool spawns.
var targets_ready = std.atomic.Value(bool).init(false);
fn ensureTargetsInitialized(api: *const llvm.Api) void {
    if (targets_ready.load(.acquire)) return;
    api.LLVMInitializeTargetInfo();
    api.LLVMInitializeTarget();
    api.LLVMInitializeTargetMC();
    api.LLVMInitializeAsmPrinter();
    targets_ready.store(true, .release);
}

/// Optimize `module` at -O2 and write a native object to `object_path`, entirely
/// in-process: no clang subprocess and no textual-IR round trip (the two costs
/// that made per-CGU emission slow). Each call builds its own TargetMachine so
/// concurrent emits share no mutable LLVM state beyond the process-global target
/// registry (initialized once, before the pool).
fn emitObjectInProcess(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    triple: []const u8,
    object_path: []const u8,
) !void {
    const triple_z = try allocator.dupeZ(u8, triple);
    defer allocator.free(triple_z);

    var target: llvm.c.LLVMTargetRef = undefined;
    var target_err: [*c]u8 = null;
    if (api.LLVMGetTargetFromTriple(triple_z.ptr, &target, &target_err) != 0) {
        defer if (target_err != null) api.LLVMDisposeMessage(target_err);
        if (target_err != null) std.debug.print("kira incremental: target lookup failed: {s}\n", .{std.mem.span(target_err)});
        return error.TargetLookupFailed;
    }

    const cpu = api.LLVMGetHostCPUName();
    const features = api.LLVMGetHostCPUFeatures();
    const machine = api.LLVMCreateTargetMachine(
        target,
        triple_z.ptr,
        cpu,
        features,
        llvm.c.LLVMCodeGenLevelDefault,
        llvm.c.LLVMRelocDefault,
        llvm.c.LLVMCodeModelDefault,
    ) orelse return error.TargetMachineCreationFailed;
    defer api.LLVMDisposeTargetMachine(machine);

    // Set the module's data layout from the target machine. The clang path got this
    // for free (clang stamps the target datalayout onto the IR it compiles); an
    // in-process module only had its triple set, so without this it would compute
    // struct offsets, sizes, and alignments against LLVM's default layout — a silent
    // miscompile that surfaces on layout-heavy code.
    const data_layout = api.LLVMCreateTargetDataLayout(machine);
    defer api.LLVMDisposeTargetData(data_layout);
    api.LLVMSetModuleDataLayout(module_ref, data_layout);

    // Middle-end -O2 (mem2reg, SROA, instcombine, inlining within the unit, ...):
    // the perf lever the clang path applied to the textual IR, now run directly on
    // the in-memory module.
    const options = api.LLVMCreatePassBuilderOptions();
    defer api.LLVMDisposePassBuilderOptions(options);
    if (api.LLVMRunPasses(module_ref, "default<O2>", machine, options)) |run_err| {
        const msg = api.LLVMGetErrorMessage(run_err);
        defer api.LLVMDisposeErrorMessage(msg);
        std.debug.print("kira incremental: opt passes failed: {s}\n", .{std.mem.span(msg)});
        return error.OptPassesFailed;
    }

    const path_z = try allocator.dupeZ(u8, object_path);
    defer allocator.free(path_z);
    var emit_err: [*c]u8 = null;
    if (api.LLVMTargetMachineEmitToFile(machine, module_ref, path_z.ptr, llvm.c.LLVMObjectFile, &emit_err) != 0) {
        defer if (emit_err != null) api.LLVMDisposeMessage(emit_err);
        if (emit_err != null) std.debug.print("kira incremental: object emission failed: {s}\n", .{std.mem.span(emit_err)});
        return error.ObjectEmissionFailed;
    }
}

/// Incremental native executable build. Mirrors backend.compileViaCApi's link
/// step but sources its objects from per-function + support CGUs, reusing cached
/// objects whose digest is unchanged.
pub fn compileExecutable(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    triple: []const u8,
) !backend_api.CompileResult {
    const executable_path = request.emit.executable_path.?;

    const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
    var api = try llvm.Api.open(llvm_toolchain);
    defer api.close();

    const program = request.program.programPtr();
    const config = cgu_hash.CguConfig{
        .triple = triple,
        .opt_flag = runtime_utils.nativeOptFlag(),
        .mode = request.mode,
        .drop_enabled = dropEnabled(),
    };

    const root = try incrementalRoot(allocator, request.emit.object_path);
    defer allocator.free(root);
    var cache = try cgu_cache.CguCache.open(allocator, root, config);
    defer cache.deinit();

    var hasher = try cgu_hash.CguHasher.init(allocator, program, config);
    defer hasher.deinit();

    // Objects to link, in order: support CGU first, then one per lowered function.
    var objects = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (objects.items) |path| allocator.free(path);
        objects.deinit();
    }

    // CGUs whose object is missing and must be emitted this build. Emitting shells
    // out to clang per unit, which is the dominant cost, so it is done in parallel
    // (below) rather than in this serial digest/bookkeeping pass. The emit-body sets
    // referenced by each plan are kept alive in `body_sets` until after the pool
    // joins.
    var pending = std.array_list.Managed(WorkItem).init(allocator);
    defer pending.deinit();
    var body_sets = std.array_list.Managed(*std.AutoHashMapUnmanaged(u32, void)).init(allocator);
    defer {
        for (body_sets.items) |set| {
            set.deinit(allocator);
            allocator.destroy(set);
        }
        body_sets.deinit();
    }

    var reused: usize = 0;

    // Enqueue helper: mark the digest live, record its object path for linking, and
    // queue an emit if the object is not already cached. `plan_bodies` is the
    // heap-owned set (kept in body_sets) the plan borrows, or null for support.
    // Support CGU (shared bodies + all extern declarations, no user bodies).
    {
        const digest = try hasher.hashSupport();
        try cache.markLive(digest);
        const object_path = try cache.objectPath(digest);
        try objects.append(object_path);
        if (cache.has(digest)) {
            reused += 1;
        } else {
            const empty = try allocator.create(std.AutoHashMapUnmanaged(u32, void));
            empty.* = .{};
            try body_sets.append(empty);
            try pending.append(.{ .plan = .{ .emit_bodies = empty, .emit_support = true }, .object_path = object_path });
        }
    }

    // One CGU per lowered, non-extern user function.
    for (program.functions) |function_decl| {
        if (!capi.shouldLowerFunction(function_decl.execution, request.mode)) continue;
        if (function_decl.is_extern) continue;

        const digest = try hasher.hashFunction(function_decl);
        try cache.markLive(digest);
        const object_path = try cache.objectPath(digest);
        try objects.append(object_path);
        if (cache.has(digest)) {
            reused += 1;
        } else {
            const one = try allocator.create(std.AutoHashMapUnmanaged(u32, void));
            one.* = .{};
            try one.put(allocator, function_decl.id, {});
            try body_sets.append(one);
            try pending.append(.{ .plan = .{ .emit_bodies = one, .emit_support = false }, .object_path = object_path });
        }
    }

    const rebuilt = pending.items.len;
    try emitPending(allocator, &api, request, triple, pending.items);

    // Runtime + dynamic-FFI helper objects, then full relink of the live set.
    const bridge_object = try linker.buildRuntimeHelpersObject(allocator, request.emit.object_path, false, request.target_selector);
    const dynamic_ffi_object = try linker.buildDynamicFfiHelpersObject(allocator, request.emit.object_path, false, request.target_selector);
    try objects.append(try allocator.dupe(u8, bridge_object));
    try objects.append(try allocator.dupe(u8, dynamic_ffi_object));

    try linker.linkExecutable(allocator, executable_path, objects.items, request.resolved_native_libraries, request.target_selector);

    // Reclaim objects for functions that were deleted, renamed, or changed.
    _ = cache.collectGarbage() catch 0;

    if (std.c.getenv("KIRA_INCREMENTAL_STATS") != null) {
        std.debug.print("kira incremental: {d} CGUs reused, {d} rebuilt\n", .{ reused, rebuilt });
    }

    var artifacts = std.array_list.Managed(backend_api.Artifact).init(allocator);
    try artifacts.append(.{ .kind = .executable, .path = try allocator.dupe(u8, executable_path) });
    return .{ .artifacts = try artifacts.toOwnedSlice() };
}
