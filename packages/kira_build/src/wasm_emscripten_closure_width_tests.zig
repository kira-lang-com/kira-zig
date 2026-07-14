// wasm32-emscripten CLOSURE-TAG width regression tests (sibling of
// wasm_emscripten_width_tests.zig, split per Core Law #5).
//
// Family member: a Kira closure value is an i64 whose bit 63 tags a heap
// closure block ({ fn_id, capture_count, captures[] }). Struct fields of
// closure type used to be stored at POINTER width (fieldStorageType -> ptr_ty:
// 4 bytes on wasm32), so storing a capturing closure into a struct field
// truncated the tag away. The untagged block address then re-entered the
// call_value dispatcher, whose `is_direct` test (value <= u32 max) is
// degenerate on wasm32 — every truncated value looks like a direct function
// id. Two distinct end-to-end symptoms, one per test below:
//
//   1. The dispatcher's `default: unreachable` let LLVM assume the loaded id
//      must equal a known case, silently folding the call to the WRONG callee —
//      a handler installed through a mutating method appeared to be "lost" and
//      the default handler ran instead (the kira-graphics
//      `app.onFrame{}`/`app.onEvent{}` setter loss).
//   2. When the value stayed runtime-opaque (through nativeState + a C->Kira
//      native callback), the switch actually executed and trapped
//      `RuntimeError: unreachable` when the event handler closure was invoked
//      with a `borrow <value struct>` argument (the kira-graphics event
//      dispatch trap).
//
// Closure-typed fields are now full i64 slots (layout-identical on 64-bit
// targets), so the tag survives. Both tests run the real pipeline
// (compile -> LLVM wasm32 -> emscripten link -> node) and are skipped when
// emcc/node are unavailable.
const std = @import("std");
const build_def = @import("kira_build_definition");
const BuildSystem = @import("build_system.zig").BuildSystem;
const support = @import("wasm_emscripten_test_support.zig");

const firstArtifactWithExtension = support.firstArtifactWithExtension;
const ensureRuntimeToolingAvailable = support.ensureRuntimeToolingAvailable;
const inheritedProcessEnviron = support.inheritedProcessEnviron;

fn runNode(process_allocator: std.mem.Allocator, js_path: []const u8) !std.process.RunResult {
    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    return std.process.run(process_allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
}

test "wasm32 emscripten keeps a capturing closure installed into a struct field through a mutating method" {
    // Regression for symptom 1: `app.onEvent { ... }` (a struct method doing
    // `self.handler = body`) stored the capturing closure's clone into a 4-byte
    // field slot, dropping tag bit 63. The untagged block address flowed into
    // the dispatcher whose unreachable default let LLVM fold the handler call
    // to the DEFAULT handler — the installed closure silently never ran, while
    // the same program was correct on every 64-bit host. The program must
    // print the installed handler's marker (with its capture arithmetic
    // intact) and never the default's.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    try ensureRuntimeToolingAvailable(process_allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "out");
    // The closure MUST capture (`cap`): a non-capturing closure lowers to a
    // plain function id that fits 32 bits and never reproduced the loss.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\function defaultHandler(n: Int) {
        \\    print("DEFAULT-HANDLER")
        \\    return
        \\}
        \\
        \\struct App {
        \\    var eventHandler: (Int) -> Void = defaultHandler
        \\
        \\    function onEvent(body: (Int) -> Void) {
        \\        self.eventHandler = body
        \\        return
        \\    }
        \\}
        \\
        \\@Main
        \\@Native
        \\function main() {
        \\    let cap = 41
        \\    var app = App {}
        \\    app.onEvent { n in
        \\        print("INSTALLED-HANDLER")
        \\        print(n + cap)
        \\        return
        \\    }
        \\    let h = app.eventHandler
        \\    h(1)
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

    const result = try runNode(process_allocator, js_path);
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    // Exit 0, the INSTALLED handler ran with its capture intact (1 + 41 = 42),
    // and the default handler never ran.
    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "INSTALLED-HANDLER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "DEFAULT-HANDLER") == null);
}

test "wasm32 emscripten invokes a field-stored capturing closure with a borrow value-struct arg from a C callback (legacy manifest compat)" {
    // Regression for symptom 2 (the kira-graphics event-dispatch trap): the
    // app struct (with the closure field) rides through nativeState into a
    // C-invoked @Native callback, which recovers it, loads the handler field,
    // builds a VALUE struct event, and invokes the handler with `borrow Evt`.
    // With the truncated field slot this trapped `RuntimeError: unreachable`
    // in the call_value dispatcher AFTER the event was fully constructed. The
    // full chain must now run: C calls back into Kira, the installed capturing
    // closure receives the borrowed struct, reads its fields, and mutates
    // state recovered from another nativeState token.
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
        \\native_libraries = ["NativeLibs/kira_loop.toml"]
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_loop.toml",
        .data =
        \\[library]
        \\name = "kira_loop"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[build]
        \\sources = ["kira_loop.c"]
        \\
        \\[target.wasm32-emscripten-unknown]
        \\static_lib = "libkira_loop.a"
        ,
    });
    // Mimics the sokol sapp_run shape: C owns the loop, stores the Kira
    // callback + userdata, and dispatches an event back into Kira.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_loop.c",
        .data =
        \\typedef void (*kira_loop_event_fn)(int, void *);
        \\void kira_loop_run(kira_loop_event_fn event_cb, void *user_data) {
        \\    event_cb(5, user_data);
        \\}
        ,
    });
    // Evt mirrors GraphicsEvent's mix (enum/Int/Float/String/nested Bool
    // struct); the handler closure CAPTURES a nativeState token (a capturing
    // closure is a tagged block — a plain function default never reproduced
    // the trap).
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@FFI.Callback { abi: c; params: [I32, RawPtr]; result: Void; }
        \\struct kira_loop_event_callback {}
        \\
        \\@FFI.Extern { library: kira_loop; symbol: kira_loop_run; abi: c; }
        \\function kira_loop_run(event_cb: kira_loop_event_callback, user_data: RawPtr): Void;
        \\
        \\enum Kind {
        \\    None
        \\    Down
        \\}
        \\
        \\struct Mods {
        \\    let shift: Bool = false
        \\    let ctrl: Bool = false
        \\}
        \\
        \\struct Evt {
        \\    let kind: Kind = Kind.None
        \\    let code: Int = 0
        \\    let x: Float = 0.0
        \\    let text: String = ""
        \\    let mods: Mods = Mods {}
        \\}
        \\
        \\struct App {
        \\    var eventHandler: (borrow Evt) -> Void = defaultHandler
        \\}
        \\
        \\struct RtState {
        \\    var app: App
        \\}
        \\
        \\struct ProbeState {
        \\    var lastCode: Int = 0
        \\}
        \\
        \\function defaultHandler(e: borrow Evt) {
        \\    print("DEFAULT-HANDLER")
        \\    return
        \\}
        \\
        \\@Native
        \\function runtimeRun(app: borrow App) {
        \\    var runtimeState = nativeState(RtState { app: app })
        \\    kira_loop_run(kiraEventCb, nativeUserData(runtimeState))
        \\    return
        \\}
        \\
        \\@Native
        \\function kiraEventCb(kindRaw: I32, userData: RawPtr): Void {
        \\    var state = nativeRecover<RtState>(userData)
        \\    let onEvent: (borrow Evt) -> Void = state.app.eventHandler
        \\    var kind = Kind.None
        \\    if kindRaw == 5 {
        \\        kind = Kind.Down
        \\    }
        \\    var evt = Evt { kind: kind code: kindRaw x: 1.5 text: "k" }
        \\    print("cb:event-built")
        \\    onEvent(evt)
        \\    print("cb:handler-returned")
        \\    return
        \\}
        \\
        \\@Main
        \\@Native
        \\function main() {
        \\    let probeStorage = nativeState(ProbeState {})
        \\    let probeUser = nativeUserData(probeStorage)
        \\    let eventBody: (borrow Evt) -> Void = { e in
        \\        print("HANDLER-RAN")
        \\        var probe = nativeRecover<ProbeState>(probeUser)
        \\        probe.lastCode = e.code
        \\        print(probe.lastCode)
        \\        return
        \\    }
        \\    var app = App {
        \\        eventHandler: eventBody
        \\    }
        \\    runtimeRun(app)
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

    const result = try runNode(process_allocator, js_path);
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    // Exit 0 (no dispatcher `unreachable` trap after "cb:event-built"), the
    // INSTALLED handler ran with the borrowed struct's field value (code 5),
    // control returned to the callback, and the default handler never ran.
    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "HANDLER-RAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "5") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "cb:handler-returned") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "DEFAULT-HANDLER") == null);
}
