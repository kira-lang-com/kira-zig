const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try verify(arena.allocator(), true);
}

test "memory validation coverage is wired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try verify(arena.allocator(), false);
}

fn verify(allocator: std.mem.Allocator, print_success: bool) !void {
    var failures = std.array_list.Managed([]const u8).init(allocator);

    try requireBackends(allocator, &failures, "tests/pass/run/ownership_borrow_param_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_explicit_move_ok/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_temporary_move_ok/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_closure_capture_copy_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/fail/semantics/ownership_closure_capture_noncopy/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/fail/semantics/ownership_closure_capture_array_noncopy/expect.toml", &.{ "vm", "llvm", "hybrid" });
    // Native-leak ownership regressions (driven by the layout/render render-loop classes).
    // Each leaked on the native backend before the affine-ownership fixes and must agree
    // across vm/llvm/hybrid.
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_array_struct_elements_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_struct_param_move_into_array_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_enum_struct_field_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_array_field_readback_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_borrow_mut_struct_field_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_enum_argument_into_field_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/array_append_loop_no_stack_growth/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/retained_tree_aggregate_defaults_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/runtime_native_newly_appended_aggregate_stress/expect.toml", &.{"hybrid"});
    try requireBackends(allocator, &failures, "tests/pass/run/native_runtime_struct_callback_bridge/expect.toml", &.{"hybrid"});

    try requireContains(allocator, &failures, "packages/kira_vm_runtime/src/vm.zig", "pub fn managedObjectCount", "VM exposes runtime heap accounting");
    try requireContains(allocator, &failures, "packages/kira_vm_runtime/src/vm.zig", "try std.testing.expectEqual(@as(usize, 0), vm.heap.count())", "VM tests assert heap cleanup");
    try requireContains(allocator, &failures, "packages/kira_vm_runtime/src/ownership.zig", "pub fn count(self: *const Heap) usize", "heap exposes object count");
    try requireContains(allocator, &failures, "packages/kira_vm_runtime/src/ownership.zig", "try std.testing.expectEqual(@as(usize, 0), heap.count())", "heap unit tests assert cleanup");
    try requireContains(allocator, &failures, "packages/kira_hybrid_runtime/src/runtime.zig", "pending_callback_return_values", "hybrid callback return cleanup is tracked");
    try requireContains(allocator, &failures, "packages/kira_hybrid_runtime/src/runtime.zig", "dropManagedValue", "hybrid runtime drops materialized VM values");

    // Native affine-ownership invariants for the render-loop leak fixes. Each guards a
    // distinct ownership rule whose removal reintroduces a measured leak / double free.
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", "kira_enum_clone", "structs own their enum fields (deep clone on copy)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", ".enum_instance => {", "struct destructor frees enum fields");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_aggregate.zig", "store.arr.work", "array field self-store is a no-op (no orphaning clone)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_calls.zig", "moveOrCloneToHeap", "owned struct args are moved (heap-stable) into the callee");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_ffi.zig", "cstr_temps", "transient String->CString extern buffers are freed after the call");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_calls.zig", ".enum_instance", "enum arguments stay owned by the caller (Copy across the call boundary)");

    // Performance-regression invariants. These guard fixes whose removal does not break
    // correctness on small inputs but reintroduces a native crash (stack overflow) or a
    // large per-operation slowdown under allocation-heavy / render-loop workloads.
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_codegen.zig", "pub fn entryAlloca", "loop-body scratch slots are hoisted to the entry block (no per-iteration stack growth)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_aggregate.zig", "fc.entryAlloca(fc.types.bridge_ty, \"array.append.slot\")", "array append scratch slot uses the entry-block alloca");
    try requireContains(allocator, &failures, "packages/kira_native_bridge/src/runtime_helpers.c", "Memoize the environment lookup", "trace gate caches getenv instead of calling it per runtime op");

    if (failures.items.len != 0) {
        for (failures.items) |failure| std.debug.print("memory validation failed: {s}\n", .{failure});
        return error.MemoryValidationFailed;
    }
    if (print_success) {
        std.debug.print("memory validation checks passed\n", .{});
    }
}

fn requireBackends(
    allocator: std.mem.Allocator,
    failures: *std.array_list.Managed([]const u8),
    path: []const u8,
    backends: []const []const u8,
) !void {
    const text = readFile(allocator, path) catch |err| {
        try addFailure(allocator, failures, "{s} cannot be read: {s}", .{ path, @errorName(err) });
        return;
    };
    defer allocator.free(text);
    for (backends) |backend| {
        if (std.mem.indexOf(u8, text, backend) == null) {
            try addFailure(allocator, failures, "{s} does not include backend `{s}`", .{ path, backend });
        }
    }
}

fn requireContains(
    allocator: std.mem.Allocator,
    failures: *std.array_list.Managed([]const u8),
    path: []const u8,
    token: []const u8,
    description: []const u8,
) !void {
    const text = readFile(allocator, path) catch |err| {
        try addFailure(allocator, failures, "{s} cannot be read for {s}: {s}", .{ path, description, @errorName(err) });
        return;
    };
    defer allocator.free(text);
    if (!std.mem.containsAtLeast(u8, text, 1, token)) {
        try addFailure(allocator, failures, "{s} missing token for {s}", .{ path, description });
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(16 * 1024 * 1024));
}

fn addFailure(allocator: std.mem.Allocator, failures: *std.array_list.Managed([]const u8), comptime fmt: []const u8, args: anytype) !void {
    try failures.append(try std.fmt.allocPrint(allocator, fmt, args));
}
