const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try verify(arena.allocator(), false);
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
    // runtime_native_newly_appended_aggregate_stress was removed in b5f8cf8 when
    // check-time aliasing rejection (KSEM107/KSEM118) outlawed the pattern it
    // exercised; large_graphics_descriptor_stress is its move-based successor.
    try requireBackends(allocator, &failures, "tests/pass/run/large_graphics_descriptor_stress/expect.toml", &.{"hybrid"});
    try requireBackends(allocator, &failures, "tests/pass/run/native_runtime_struct_callback_bridge/expect.toml", &.{"hybrid"});

    try requireContains(allocator, &failures, "packages/kira_vm_runtime/src/vm.zig", "pub fn managedObjectCount", "VM exposes runtime heap accounting");
    // The heap-cleanup assertions moved out of vm.zig when the oversized VM files
    // were split (Core Law #5); they now live in the extracted test modules.
    try requireContains(allocator, &failures, "packages/kira_vm_runtime/src/vm_execution_tests.zig", "try std.testing.expectEqual(@as(usize, 0), vm.heap.count())", "VM tests assert heap cleanup");
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

    // Foundation C-helper leak fixes (measured with macOS `leaks --atExit` on
    // tests/pass/run/foundation_fs_argparser_leak_regression). Each guard below,
    // if removed, reintroduces a per-call native leak.
    try requireBackends(allocator, &failures, "tests/pass/run/foundation_fs_argparser_leak_regression/app/expect.toml", &.{ "hybrid", "llvm" });

    // Unconditional array-ownership free (the KIRA_ARRAY_OWNERSHIP_FREE gate is
    // gone). Each guard below pins one clone/move rule whose removal reintroduces
    // a measured native crash with kira_array_release freeing:
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_free_state_moveout_return_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireContains(allocator, &failures, "packages/kira_native_bridge/src/runtime_helpers.c", "ARRAY_RELEASE_FREE", "kira_array_release frees unconditionally on the native path");

    // Strings-are-deep-values ownership model (leak class #1: CString→String
    // coercions, concat results, and aggregate-held strings never dropped). Each
    // guard pins one rule whose removal reintroduces a leak or a use-after-free /
    // double free (see backend_capi_drop.zig's string_buf comment for the model).
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_string_deep_value_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", "kira_capi_string_clone", "the string buffer deep-copy primitive exists");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", "rc.strfield", "struct destructors free owned string field buffers (native)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", "cc.strfield", "struct clones deep-copy string field buffers");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_aggregate.zig", "store.str.old", "string field stores drop the replaced buffer before the clone");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_drop_slots.zig", "drop.cstr.slot", "CString→String coercion buffers are tracked for scope-exit free");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_codegen.zig", "cloneStringOnRead", "aggregate string reads clone (readers never alias aggregate buffers)");
    try requireContains(allocator, &failures, "packages/kira_native_bridge/src/runtime_helpers.c", "kira_bridge_clone_string_element", "kira_array_clone deep-copies STRING-tag element buffers");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_aggregate.zig", "state.struct.clone", "native-state boxing deep-clones nested ffi_struct fields (FlatAcc use-after-free)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_codegen.zig", "load.move.field", "field move-outs null the source storage (collectRemoved use-after-free)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_codegen.zig", "ret.arr.clone", "borrowed array returns deep-clone (editorContentPathSegments use-after-free)");
    try requireContains(allocator, &failures, "packages/kira_semantics/src/lower_exprs_types.zig", "lowered_value.field.moved = true", "checker move facts reach HIR field reads");
    try requireContains(allocator, &failures, "foundation/NativeLibs/FS/fs.c", "buffer != fs_empty_string", "fs_free_buffer frees by sentinel identity, not content (empty-file reads leaked their heap buffer)");
    try requireContains(allocator, &failures, "foundation/app/FileSystem.kira", "fs_free_buffer(raw)", "File.readAll frees the fs_read_all_text_from_handle buffer after copying it");
    try requireContains(allocator, &failures, "foundation/app/Kira/ArgumentParserNative.kira", "kap_free_string(value)", "argument option/inline-value wrappers free the kap_* C string after copying it");

    // Closures-are-deep-values ownership model (leak class #2: closure blocks and
    // their captures never freed — kira_destroy_closure used to free nothing but
    // the block, and struct fields / array elements never released blocks at all).
    // Each guard pins one rule whose removal reintroduces a per-rebuild leak or a
    // double free (see backend_capi_closure_dtors.zig for the model).
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_closure_block_churn_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_closure_struct_field_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_closure_array_elements_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_closure_struct_array_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_closure_dtors.zig", "kira_capi_closure_release", "the per-closure typed capture teardown dispatcher exists");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", "rc.closfield", "struct destructors free owned closure fields (tag-safe, native)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", "cc.closfield", "struct clones deep-copy closure fields");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_aggregate.zig", "store.clos.old", "closure field stores drop the replaced block before the clone (self-store guarded)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_codegen.zig", "ret.clos.clone", "borrowed closure returns deep-clone (returned closures are always fresh owned blocks)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_calls.zig", "call.clos.clone", "borrowed closures passed to owned params deep-clone (array-element double-free)");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_closure_dtors.zig", "llvm.global_ctors", "the release hook is installed by a global constructor (dylib artifacts included)");

    // Typed enum payload teardown (leak class #4: the string-payload box and its
    // buffer were shared by the shallow kira_enum_clone and never freed). Typed
    // destroy is sound only because every clone site selects typed-or-generic
    // through the same enum_map (deep-cloned everywhere iff deep-destroyed
    // everywhere) — see backend_capi_enum_dtors.zig.
    try requireBackends(allocator, &failures, "tests/pass/run/ownership_enum_string_payload_free_parity/expect.toml", &.{ "vm", "llvm", "hybrid" });
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_enum_dtors.zig", "kira_destroy_enum_", "typed enum destructors free string-payload boxes");
    try requireContains(allocator, &failures, "packages/kira_llvm_backend/src/backend_capi_destructors.zig", "enumCloneFn", "every enum clone site dispatches typed-or-generic through the shared enum_map");
    try requireContains(allocator, &failures, "tests/pass/run/ownership_enum_string_payload_free_parity/expect.toml", "check_leaks = true", "enum payload case runs under the harness leak check");

    // The corpus harness can prove leak-freedom on the native binary; these cases
    // opt in (tests/leak_check.zig, expect.toml `check_leaks = true`).
    try requireContains(allocator, &failures, "tests/pass/run/ownership_closure_block_churn_parity/expect.toml", "check_leaks = true", "closure churn case runs under the harness leak check");
    try requireContains(allocator, &failures, "tests/pass/run/ownership_string_deep_value_parity/expect.toml", "check_leaks = true", "string deep-value case runs under the harness leak check");
    try requireContains(allocator, &failures, "tests/leak_check.zig", "leaks", "the harness leak checker exists");

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
