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
const builtin = @import("builtin");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
const native = @import("kira_native_lib_definition");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const calls = @import("backend_capi_calls.zig");
const cgu_hash = @import("cgu_hash.zig");
const cgu_cache = @import("cgu_cache.zig");
const emscripten = @import("emscripten.zig");
const runtime_utils = @import("backend_runtime_utils.zig");
const toolchain = @import("toolchain.zig");
const linker = @import("link.zig");

fn nowNs() i128 {
    return std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.toNanoseconds();
}

/// Whether the incremental native path is used. Default ON for native executable
/// links: warm one-function rebuilds re-emit only the changed function's object
/// and relink (~4.75s on the editor vs ~12s whole-program). Set KIRA_INCREMENTAL=0
/// to force the whole-program path — recommended for cold/one-shot builds (CI,
/// clean checkouts), where splitting into per-function objects is ~2x slower.
pub fn enabled() bool {
    const raw = std.c.getenv("KIRA_INCREMENTAL") orelse return true;
    const value = std.mem.span(raw);
    return value.len != 0 and value[0] != '0';
}

/// Whether this request is one the incremental path handles today: a HOST native
/// executable link. Hybrid shared libraries and object-only requests fall back —
/// and so does wasm32-emscripten, which reaches the backend with `.mode =
/// .llvm_native` but an Emscripten target selector: the in-process emit initializes
/// and creates only the host TargetMachine, so a wasm CGU would fail target lookup.
pub fn handles(request: backend_api.CompileRequest) bool {
    return request.mode == .llvm_native and
        request.emit.executable_path != null and
        !emscripten.isSelector(request.target_selector) and
        isHostTarget(request.target_selector);
}

/// The in-process incremental emitter registers only the HOST LLVM backend
/// (toolchain `initSymbols()` keys on `builtin.cpu.arch`) and builds target
/// machines with `LLVMGetHostCPUName()`/features. An explicit cross-arch or
/// cross-OS native selector (e.g. an arm64 iOS-simulator build from an x86_64
/// host) must therefore fall back to the whole-program clang-driver path, which
/// handles cross targets. A null selector is a plain host build and stays on
/// the incremental path.
fn isHostTarget(target_selector: ?native.TargetSelector) bool {
    const value = target_selector orelse return true;
    const arch = std.meta.stringToEnum(std.Target.Cpu.Arch, value.architecture) orelse return false;
    if (arch != builtin.cpu.arch) return false;
    const os = std.meta.stringToEnum(std.Target.Os.Tag, value.operating_system) orelse return false;
    return os == builtin.os.tag;
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

/// A host TargetMachine plus its data layout. Building one is not free
/// (target lookup, host CPU/feature detection, machine construction), so each
/// emit worker builds ONE and reuses it across all the CGUs it codegens rather
/// than per CGU. A TargetMachine is designed to lower many modules sequentially;
/// reuse is safe as long as it is not shared across threads — hence one per
/// worker, never one shared.
const Machine = struct {
    machine: llvm.c.LLVMTargetMachineRef,
    data_layout: llvm.c.LLVMTargetDataRef,

    fn create(api: *const llvm.Api, triple: []const u8) !Machine {
        const triple_z = try std.heap.page_allocator.dupeZ(u8, triple);
        defer std.heap.page_allocator.free(triple_z);

        var target: llvm.c.LLVMTargetRef = undefined;
        var target_err: [*c]u8 = null;
        if (api.LLVMGetTargetFromTriple(triple_z.ptr, &target, &target_err) != 0) {
            defer if (target_err != null) api.LLVMDisposeMessage(target_err);
            if (target_err != null) std.debug.print("kira incremental: target lookup failed: {s}\n", .{std.mem.span(target_err)});
            return error.TargetLookupFailed;
        }

        const machine = api.LLVMCreateTargetMachine(
            target,
            triple_z.ptr,
            api.LLVMGetHostCPUName(),
            api.LLVMGetHostCPUFeatures(),
            llvm.c.LLVMCodeGenLevelDefault,
            llvm.c.LLVMRelocDefault,
            llvm.c.LLVMCodeModelDefault,
        ) orelse return error.TargetMachineCreationFailed;

        return .{ .machine = machine, .data_layout = api.LLVMCreateTargetDataLayout(machine) };
    }

    fn deinit(self: Machine, api: *const llvm.Api) void {
        api.LLVMDisposeTargetData(self.data_layout);
        api.LLVMDisposeTargetMachine(self.machine);
    }
};

/// Emit every pending CGU, in parallel across CPU cores. Each worker uses its own
/// arena (backed by the page allocator) and its own TargetMachine, so no two
/// threads share mutable state; the LLVM contexts are per-CGU and disjoint, and
/// `api`/`request`/`triple` and the item slice are read-only — the only shared
/// mutable state is the atomic work cursor and the first-error slot. Returns the
/// first emit error encountered, if any.
fn emitPending(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    request: backend_api.CompileRequest,
    triple: []const u8,
    passes: [*:0]const u8,
    items: []const WorkItem,
) !void {
    if (items.len == 0) return;

    // Register the native target once, single-threaded, before any worker builds a
    // TargetMachine. Then emit the first CGU on this thread as a warmup: the first
    // LLVMRunPasses call lazily initializes process-global pass/cl::opt state, which
    // must not race across the pool.
    ensureTargetsInitialized(api);
    {
        const machine = try Machine.create(api, triple);
        defer machine.deinit(api);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        try emitCgu(arena.allocator(), api, machine, request, triple, passes, items[0].plan, items[0].object_path);
    }
    const rest = items[1..];
    if (rest.len == 0) return;

    var ctx = EmitCtx{ .api = api, .request = request, .triple = triple, .passes = passes, .items = rest };

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
    passes: [*:0]const u8,
    items: []const WorkItem,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    err_lock: std.atomic.Mutex = .unlocked,
    first_error: ?anyerror = null,

    fn recordError(self: *EmitCtx, err: anyerror) void {
        while (!self.err_lock.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.err_lock.unlock();
        if (self.first_error == null) self.first_error = err;
    }

    fn work(self: *EmitCtx) void {
        // One TargetMachine per worker, reused across every CGU this thread emits.
        const machine = Machine.create(self.api, self.triple) catch |err| return self.recordError(err);
        defer machine.deinit(self.api);
        while (true) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.items.len) return;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            emitCgu(arena.allocator(), self.api, machine, self.request, self.triple, self.passes, self.items[index].plan, self.items[index].object_path) catch |err| self.recordError(err);
        }
    }
};

/// Build one CGU module per the plan and emit its object straight into the cache
/// at `object_path` using the worker's `machine`, then dispose the module and its
/// context.
fn emitCgu(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    machine: Machine,
    request: backend_api.CompileRequest,
    triple: []const u8,
    passes: [*:0]const u8,
    plan: capi.ModulePlan,
    object_path: []const u8,
) !void {
    const lowered = try capi.buildModulePlanned(allocator, api, request, triple, plan);
    defer api.LLVMContextDispose(lowered.context);
    defer api.LLVMDisposeModule(lowered.module_ref);
    try emitObjectInProcess(allocator, api, machine, lowered.module_ref, object_path, passes);
}

/// Register the native target. The LLVMInitialize* calls are idempotent, so this
/// runs unconditionally at the start of every build rather than caching a
/// process-global "done" flag: each build opens its own LLVM `Api`, and a cached
/// flag could report "ready" while a freshly (re)loaded library has an empty target
/// registry — leaving GetTargetFromTriple with "no available targets". Must run
/// single-threaded, before the emit pool: the registries it mutates are global and
/// the registration itself is not thread-safe.
fn ensureTargetsInitialized(api: *const llvm.Api) void {
    api.LLVMInitializeTargetInfo();
    api.LLVMInitializeTarget();
    api.LLVMInitializeTargetMC();
    api.LLVMInitializeAsmPrinter();
}

/// The new-PM pipeline string for a clang-style opt flag, so incremental emission
/// honors KIRA_NATIVE_OPT the same way the whole-program clang path does (a build
/// cached under `-O0` must not silently ship `-O2` code). KIRA_CGU_PASSES overrides
/// entirely, for diagnostics.
fn passPipeline(opt_flag: []const u8) [*:0]const u8 {
    if (std.c.getenv("KIRA_CGU_PASSES")) |p| return p;
    if (std.mem.eql(u8, opt_flag, "-O0")) return "default<O0>";
    if (std.mem.eql(u8, opt_flag, "-O1")) return "default<O1>";
    if (std.mem.eql(u8, opt_flag, "-O3")) return "default<O3>";
    if (std.mem.eql(u8, opt_flag, "-Os")) return "default<Os>";
    if (std.mem.eql(u8, opt_flag, "-Oz")) return "default<Oz>";
    return "default<O2>";
}

/// Optimize `module` with the `passes` pipeline and write a native object for
/// `object_path` using the worker's shared `machine`, entirely in-process: no clang
/// subprocess and no textual-IR round trip (the two costs that made per-CGU emission
/// slow). The object is written to a sibling temp file and renamed into place only
/// on success — an interrupted or failed emit must not leave a truncated `.o` that
/// the cache (which only checks existence) would reuse.
fn emitObjectInProcess(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    machine: Machine,
    module_ref: llvm.c.LLVMModuleRef,
    object_path: []const u8,
    passes: [*:0]const u8,
) !void {
    // Set the module's data layout from the target machine. The clang path got this
    // for free (clang stamps the target datalayout onto the IR it compiles); an
    // in-process module only had its triple set, so without this it would compute
    // struct offsets, sizes, and alignments against LLVM's default layout — a silent
    // miscompile that surfaces on layout-heavy code.
    api.LLVMSetModuleDataLayout(module_ref, machine.data_layout);

    // Middle-end optimization (mem2reg, SROA, instcombine, inlining within the unit,
    // ...): the perf lever the clang path applied to the textual IR, run directly on
    // the in-memory module at the requested opt level.
    const options = api.LLVMCreatePassBuilderOptions();
    defer api.LLVMDisposePassBuilderOptions(options);
    if (api.LLVMRunPasses(module_ref, passes, machine.machine, options)) |run_err| {
        const msg = api.LLVMGetErrorMessage(run_err);
        defer api.LLVMDisposeErrorMessage(msg);
        std.debug.print("kira incremental: opt passes failed: {s}\n", .{std.mem.span(msg)});
        return error.OptPassesFailed;
    }

    // Emit to a sibling temp file, then atomically rename into place. The temp name
    // is derived from the content-addressed object path (unique per CGU), so
    // concurrent workers never collide. On any failure the temp is removed and
    // `object_path` is never created, so the cache never sees a partial object.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{object_path});
    defer allocator.free(tmp_path);
    const tmp_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(tmp_z);

    var emit_err: [*c]u8 = null;
    if (api.LLVMTargetMachineEmitToFile(machine.machine, module_ref, tmp_z.ptr, llvm.c.LLVMObjectFile, &emit_err) != 0) {
        defer if (emit_err != null) api.LLVMDisposeMessage(emit_err);
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_path) catch {};
        if (emit_err != null) std.debug.print("kira incremental: object emission failed: {s}\n", .{std.mem.span(emit_err)});
        return error.ObjectEmissionFailed;
    }

    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), object_path, std.Options.debug_io) catch |err| {
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_path) catch {};
        return err;
    };
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
    // The EFFECTIVE optimization pipeline (honors KIRA_NATIVE_OPT and the
    // KIRA_CGU_PASSES override) keys both the cache and the emit, so changing either
    // env var invalidates cached objects instead of reusing ones built with a
    // different pipeline.
    const passes = passPipeline(runtime_utils.nativeOptFlag());
    const config = cgu_hash.CguConfig{
        .triple = triple,
        .opt_flag = std.mem.span(passes),
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
            // emit_bodies is exactly this function (emitting a callee's body too would
            // duplicate its definition). declare_functions is everything the body can
            // look up during lowering — itself plus direct, callback, and virtual/family
            // callees — so the module declares only what it references, not the program.
            const bodies = try allocator.create(std.AutoHashMapUnmanaged(u32, void));
            bodies.* = .{};
            try bodies.put(allocator, function_decl.id, {});
            try body_sets.append(bodies);

            const decls = try allocator.create(std.AutoHashMapUnmanaged(u32, void));
            decls.* = .{};
            try calls.collectBodyFunctionRefs(allocator, program, function_decl, decls);
            try body_sets.append(decls);

            try pending.append(.{ .plan = .{ .emit_bodies = bodies, .declare_functions = decls, .emit_support = false }, .object_path = object_path });
        }
    }

    const rebuilt = pending.items.len;
    const stats = std.c.getenv("KIRA_INCREMENTAL_STATS") != null;
    const emit_start = nowNs();
    try emitPending(allocator, &api, request, triple, passes, pending.items);
    const emit_ns = nowNs() - emit_start;

    // The CGU objects so far (support + per-function) are the Kira module's code.
    // Relocatable-link them into the whole-program `object_path` so a native build
    // still reports a `native_object` artifact and the build cache — which stores and
    // restores that `.o` — keeps working under incremental.
    const cgu_object_count = objects.items.len;
    try linker.combineObjects(allocator, request.emit.object_path, objects.items[0..cgu_object_count], request.target_selector);

    // Runtime + dynamic-FFI helper objects, then full relink of the live set.
    const link_start = nowNs();
    const bridge_object = try linker.buildRuntimeHelpersObject(allocator, request.emit.object_path, false, request.target_selector);
    const dynamic_ffi_object = try linker.buildDynamicFfiHelpersObject(allocator, request.emit.object_path, false, request.target_selector);
    try objects.append(try allocator.dupe(u8, bridge_object));
    try objects.append(try allocator.dupe(u8, dynamic_ffi_object));

    try linker.linkExecutable(allocator, executable_path, objects.items, request.resolved_native_libraries, request.target_selector);
    const link_ns = nowNs() - link_start;

    // Reclaim objects for functions that were deleted, renamed, or changed.
    _ = cache.collectGarbage() catch |err| blk: {
        // Don't fail the build on GC trouble, but don't hide it either: an
        // unbounded object cache (permissions, disk) needs an operator signal.
        if (stats) std.debug.print("kira incremental: garbage collection failed: {s}\n", .{@errorName(err)});
        break :blk 0;
    };

    if (stats) {
        std.debug.print("kira incremental: {d} CGUs reused, {d} rebuilt; emit {d}ms, link {d}ms\n", .{ reused, rebuilt, @divTrunc(emit_ns, std.time.ns_per_ms), @divTrunc(link_ns, std.time.ns_per_ms) });
    }

    var artifacts = std.array_list.Managed(backend_api.Artifact).init(allocator);
    try artifacts.append(.{ .kind = .native_object, .path = try allocator.dupe(u8, request.emit.object_path) });
    try artifacts.append(.{ .kind = .executable, .path = try allocator.dupe(u8, executable_path) });
    return .{ .artifacts = try artifacts.toOwnedSlice() };
}
