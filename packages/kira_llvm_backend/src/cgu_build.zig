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
    try runtime_utils.emitObjectFileViaClang(allocator, api, lowered.module_ref, object_path, request.target_selector);
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

    var reused: usize = 0;
    var rebuilt: usize = 0;

    // Support CGU (shared bodies + all extern declarations, no user bodies).
    {
        const digest = try hasher.hashSupport();
        try cache.markLive(digest);
        const object_path = try cache.objectPath(digest);
        if (cache.has(digest)) {
            reused += 1;
        } else {
            var empty = std.AutoHashMapUnmanaged(u32, void){};
            defer empty.deinit(allocator);
            try emitCgu(allocator, &api, request, triple, .{ .emit_bodies = &empty, .emit_support = true }, object_path);
            rebuilt += 1;
        }
        try objects.append(object_path);
    }

    // One CGU per lowered, non-extern user function.
    for (program.functions) |function_decl| {
        if (!capi.shouldLowerFunction(function_decl.execution, request.mode)) continue;
        if (function_decl.is_extern) continue;

        const digest = try hasher.hashFunction(function_decl);
        try cache.markLive(digest);
        const object_path = try cache.objectPath(digest);
        if (cache.has(digest)) {
            reused += 1;
        } else {
            var one = std.AutoHashMapUnmanaged(u32, void){};
            defer one.deinit(allocator);
            try one.put(allocator, function_decl.id, {});
            try emitCgu(allocator, &api, request, triple, .{ .emit_bodies = &one, .emit_support = false }, object_path);
            rebuilt += 1;
        }
        try objects.append(object_path);
    }

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
