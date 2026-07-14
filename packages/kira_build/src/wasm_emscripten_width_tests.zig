// wasm32-emscripten C-ABI WIDTH regression tests (Core Law #5 split from
// wasm_emscripten_tests.zig, which keeps the general build/run pipeline tests).
//
// Family: on wasm32, pointers and size_t are 32-bit while Kira's register ABI is
// i64 — every spot where the backend crossed that boundary with a hardcoded
// 64-bit assumption produced a distinct runtime trap. Each test below pins one
// fixed member of the family end-to-end (compile -> LLVM wasm32 lowering ->
// emscripten link -> node execution -> real assertion), and is skipped when
// emcc/node are unavailable.
const std = @import("std");
const build_def = @import("kira_build_definition");
const BuildSystem = @import("build_system.zig").BuildSystem;
const support = @import("wasm_emscripten_test_support.zig");

const firstArtifactWithExtension = support.firstArtifactWithExtension;
const hasArtifact = support.hasArtifact;
const replaceExtension = support.replaceExtension;
const ensureRuntimeToolingAvailable = support.ensureRuntimeToolingAvailable;
const inheritedProcessEnviron = support.inheritedProcessEnviron;

test "wasm32 emscripten marshals a String to a CString extern without a size-width trap (legacy manifest compat)" {
    // Regression for the wasm32 (32-bit size_t/pointer) C-ABI width bug: the LLVM
    // backend used to declare malloc/memcpy/strlen/kira_struct_alloc with 64-bit
    // size params, so the String->CString marshal path (malloc a NUL buffer, memcpy
    // the bytes) linked against the wasm libc's 32-bit `memcpy`/`malloc` with a
    // `function signature mismatch` and trapped `RuntimeError: unreachable` under
    // node. Passing a String literal to a `CString` extern that returns strlen must
    // now run correctly and exit 0.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    try ensureRuntimeToolingAvailable(process_allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "App/NativeLibs");
    try tmp.dir.createDirPath(std.testing.io, "out");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/kira.toml",
        .data =
        \\[package]
        \\name = "App"
        \\version = "0.1.0"
        \\kind = "app"
        \\kira = "0.1.0"
        \\native_libraries = ["NativeLibs/kira_probe.toml"]
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_probe.toml",
        .data =
        \\[library]
        \\name = "kira_probe"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[build]
        \\sources = ["kira_probe.c"]
        \\
        \\[target.wasm32-emscripten-unknown]
        \\static_lib = "libkira_probe.a"
        ,
    });
    // Returns strlen of the marshalled CString: proves the Kira String bytes and
    // NUL terminator crossed the C boundary intact (a truncated/garbage size would
    // return the wrong length or trap).
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_probe.c",
        .data =
        \\#include <string.h>
        \\int kira_len_probe(const char *s) { return (int)strlen(s); }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/kira_probe.kira",
        .data =
        \\@FFI.Extern { library: kira_probe; symbol: kira_len_probe; abi: c; }
        \\function kira_len_probe(s: CString): I32;
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\@Native
        \\function main() {
        \\    let n: I32 = kira_len_probe("hello, wasm")
        \\    print(n)
        \\    return
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", allocator);
    const output_root = try tmp.dir.realPathFileAlloc(std.testing.io, "out", allocator);
    const output_path = try std.fs.path.join(allocator, &.{ output_root, "main.js" });

    var system = BuildSystem.init(allocator);
    system.use_cache = false;
    const outcome = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = build_def.BuildTarget{ .execution = .wasm32_emscripten },
    });

    try std.testing.expect(!outcome.failed());
    const js_path = firstArtifactWithExtension(outcome.artifacts, ".js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(firstArtifactWithExtension(outcome.artifacts, ".wasm") != null);

    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(process_allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    // Exit 0 (no `unreachable` trap) AND the correct strlen("hello, wasm") == 11.
    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "11") != null);
}

test "wasm32 emscripten deep-clones an array of owning structs without a call_indirect trap" {
    // Regression for the wasm32 (32-bit pointer) element-callback signature bug: the
    // backend passes kira_clone_<T> as the `void *(*clone_elem)(void *)` argument of
    // kira_array_clone. On wasm32 that helper is an `(i64)->i64` function, a DISTINCT wasm
    // value type from the `(i32)->i32` the runtime's `call_indirect` declares for the
    // callback, so cloning an array of heap-owning structs (a value-semantics read of an
    // array struct field) trapped `RuntimeError: null function or function signature
    // mismatch`. The backend now hands a `(ptr)->ptr` C-ABI adapter thunk over the helper,
    // so the deep clone runs and the program prints the element count and exits 0.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    try ensureRuntimeToolingAvailable(process_allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "out");
    // A struct with a String field owns a heap buffer, so its array elements get a real
    // per-element clone callback (kira_clone_Item) rather than a primitive memcpy — the
    // exact path that materialised the trapping `(i64)->i64` function pointer. Reading the
    // owned `[Item]` field out of `bag` deep-clones it via kira_array_clone.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\struct Item {
        \\    var label: String = ""
        \\}
        \\
        \\struct Bag {
        \\    var items: [Item] = []
        \\}
        \\
        \\@Main
        \\@Native
        \\function main() {
        \\    var bag: Bag = Bag { items: [Item { label: "alpha" }, Item { label: "beta" }] }
        \\    var copy: [Item] = bag.items
        \\    print(copy.count)
        \\    return
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", allocator);
    const output_root = try tmp.dir.realPathFileAlloc(std.testing.io, "out", allocator);
    const output_path = try std.fs.path.join(allocator, &.{ output_root, "main.js" });

    var system = BuildSystem.init(allocator);
    system.use_cache = false;
    const outcome = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = build_def.BuildTarget{ .execution = .wasm32_emscripten },
    });

    try std.testing.expect(!outcome.failed());
    const js_path = firstArtifactWithExtension(outcome.artifacts, ".js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(firstArtifactWithExtension(outcome.artifacts, ".wasm") != null);

    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(process_allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    // Exit 0 (no call_indirect trap) AND the cloned array reports both elements.
    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2") != null);
}

test "wasm32 emscripten invokes a Kira @Native callback from C without a signature-mismatch trap" {
    // Regression for the wasm32 (32-bit pointer / i32-int) callback C-ABI bug: a Kira
    // @Native function handed to C as a callback function pointer (the sokol sapp_desc
    // init/frame/event callback pattern) is emitted with the i64 register ABI — every
    // pointer AND sub-i64 integer parameter is an i64. On wasm32 the C side calls the
    // callback through a `call_indirect` typed to the C signature (`void*` and `int`
    // are i32), a DISTINCT wasm value type from i64, so it trapped `RuntimeError:
    // function signature mismatch`. (64-bit targets coincide because i64 == pointer
    // width, which is why native worked and only the browser/wasm graphics path broke.)
    // The backend now hands C the address of a per-signature C-ABI adapter thunk
    // (backend_capi_wasm_native_cb) that narrows the pointer/i32 arguments and widens
    // them back to the callee's i64 registers, so the round-trip runs and prints 42.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    try ensureRuntimeToolingAvailable(process_allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "App/NativeLibs");
    try tmp.dir.createDirPath(std.testing.io, "out");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/package.kira",
        .data =
        \\Package App {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.App
        \\    let nativeLibraries = [
        \\        NativeLibrary {
        \\            name: "kira_wcb",
        \\            linkMode: LinkMode.Static,
        \\            sources: ["NativeLibs/kira_wcb.c"]
        \\        }
        \\    ]
        \\}
        ,
    });
    // The C callback type is `int (*)(void*, int)` — both params are i32 on wasm32.
    // Invoking the Kira callee through this pointer is the exact `call_indirect` the
    // signature-mismatch trap fired on before the adapter thunk existed.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_wcb.c",
        .data =
        \\typedef int (*kira_wcb_fn)(void*, int);
        \\int kira_wcb_invoke(kira_wcb_fn cb, void* ud, int value) { return cb(ud, value); }
        ,
    });
    // A callback whose params mix a pointer (RawPtr -> void* -> i32) and a 32-bit int
    // (I32 -> int -> i32): both are i64 in the Kira register ABI, so both must be
    // narrowed at the wasm32 C boundary. I64 params would NOT reproduce the trap.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/kira_wcb.kira",
        .data =
        \\@FFI.Callback { abi: c; params: [RawPtr, I32]; result: I32; }
        \\struct kira_wcb_callback {}
        \\
        \\@FFI.Extern { library: kira_wcb; symbol: kira_wcb_invoke; abi: c; }
        \\function kira_wcb_invoke(callback: kira_wcb_callback, user_data: RawPtr, value: I32): I32;
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\@Native
        \\function main() {
        \\    let result: I32 = kira_wcb_invoke(bump, 0, 41)
        \\    print(result)
        \\    return
        \\}
        \\
        \\@Native
        \\function bump(user_data: RawPtr, value: I32): I32 {
        \\    return value + 1
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", allocator);
    const output_root = try tmp.dir.realPathFileAlloc(std.testing.io, "out", allocator);
    const output_path = try std.fs.path.join(allocator, &.{ output_root, "main.js" });

    var system = BuildSystem.init(allocator);
    system.use_cache = false;
    const outcome = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = build_def.BuildTarget{ .execution = .wasm32_emscripten },
    });

    try std.testing.expect(!outcome.failed());
    const js_path = firstArtifactWithExtension(outcome.artifacts, ".js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(firstArtifactWithExtension(outcome.artifacts, ".wasm") != null);

    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(process_allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    // Exit 0 (no signature-mismatch trap) AND the callback ran with the right args:
    // bump(0, 41) == 42.
    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "42") != null);
}

test "wasm32 emscripten deep-clones a struct with a RawPtr field without a clone_contents OOM trap" {
    // Regression for the wasm32 (32-bit pointer) clone_contents/release_contents
    // width bug that OOM-aborted UI Foundation apps in the browser. A struct's
    // RawPtr / Any field is stored at pointer width (fieldStorageType -> ptr_ty:
    // 4 bytes on wasm32), but the generated kira_clone_contents_<T> loaded it as a
    // 64-bit i64. On wasm32 that over-read pulled the adjacent field's bytes into
    // the high word, and the tag-safe closure clone tests bit 63 to decide whether
    // a value is a heap closure block. An adjacent field with its high bit set
    // (here `flags = I32 min`) flipped bit 63, so a plain RawPtr handle was mistaken
    // for a closure: kira_capi_closure_clone read a bogus capture `count` from the
    // handle and malloc'd 16 + count*24 bytes — multi-GB — aborting the module
    // ("Cannot enlarge memory arrays"). This is the exact
    // kira_clone_contents_KiraGraphicsFoundationBackend OOM seen in the browser.
    // The field is now loaded/stored at ptr_ty width and widened to the i64 tag
    // representation, so the handle's high bits are clean-zero and the tag-safe
    // clone passes it through untouched.
    //
    // The native helper hands back a 16-byte buffer whose word at offset 8 is a
    // huge "count" — under the OLD code the mis-read handle would malloc that many
    // capture slots and trap; the fixed code never mis-reads it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    try ensureRuntimeToolingAvailable(process_allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "App/NativeLibs");
    try tmp.dir.createDirPath(std.testing.io, "out");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/package.kira",
        .data =
        \\Package App {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.App
        \\    let nativeLibraries = [
        \\        NativeLibrary {
        \\            name: "kira_hnd",
        \\            linkMode: LinkMode.Static,
        \\            sources: ["NativeLibs/kira_hnd.c"]
        \\        }
        \\    ]
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_hnd.c",
        .data =
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\// 16-byte handle whose word at offset 8 is a huge "capture count": if the
        \\// buggy clone mis-reads this RawPtr field as a tagged closure block it will
        \\// malloc 16 + count*24 bytes and abort. The width-correct load never does.
        \\void* kira_hnd_make(void) {
        \\    uint64_t* p = (uint64_t*)malloc(16);
        \\    p[0] = 0;
        \\    p[1] = 0x0000000010000000ULL;
        \\    return (void*)p;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/kira_hnd.kira",
        .data =
        \\@FFI.Extern { library: kira_hnd; symbol: kira_hnd_make; abi: c; }
        \\function kira_hnd_make(): RawPtr;
        ,
    });
    // `handle` is a RawPtr (raw_ptr field, ptr-width storage); `flags` is an I32
    // with its high bit set, laid out immediately after `handle`, so the OLD 64-bit
    // over-read of `handle` lands `flags`'s high bit in tag bit 63. The owning
    // `items` array makes the value-copy a real deep clone (clone_contents runs).
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\struct Backend {
        \\    var handle: RawPtr
        \\    var flags: I32
        \\    var items: [I32]
        \\}
        \\
        \\@Main
        \\@Native
        \\function main() {
        \\    var b: Backend = Backend { handle: kira_hnd_make(), flags: -2147483648, items: [1, 2] }
        \\    var copy: Backend = b
        \\    print(copy.items.count)
        \\    return
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", allocator);
    const output_root = try tmp.dir.realPathFileAlloc(std.testing.io, "out", allocator);
    const output_path = try std.fs.path.join(allocator, &.{ output_root, "main.js" });

    var system = BuildSystem.init(allocator);
    system.use_cache = false;
    const outcome = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = build_def.BuildTarget{ .execution = .wasm32_emscripten },
    });

    try std.testing.expect(!outcome.failed());
    const js_path = firstArtifactWithExtension(outcome.artifacts, ".js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(firstArtifactWithExtension(outcome.artifacts, ".wasm") != null);

    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(process_allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    // Exit 0 (no "Cannot enlarge memory" OOM abort) AND the deep clone reports both
    // elements — the RawPtr handle field was passed through, not mis-cloned.
    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2") != null);
}
