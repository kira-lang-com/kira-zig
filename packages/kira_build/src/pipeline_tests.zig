const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const package_manager = @import("kira_package_manager");
const pipeline = @import("pipeline.zig");

test "check and build stop points share imported graph diagnostics (legacy manifest compat)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/project.toml",
        .data =
        \\[project]
        \\name = "App"
        \\version = "0.1.0"
        \\
        \\[defaults]
        \\execution_mode = "vm"
        \\build_target = "host"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/support.kira",
        .data = "function helper( { return; }\n",
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", arena.allocator());
    const checked = try pipeline.checkFileForBackend(arena.allocator(), source_path, .vm);
    const built = try pipeline.compileFileForBackend(arena.allocator(), source_path, .vm, &.{});

    try std.testing.expectEqual(pipeline.FrontendStage.graph, checked.failure_stage.?);
    try std.testing.expectEqual(pipeline.FrontendStage.graph, built.failure_stage.?);
    try std.testing.expectEqualStrings(checked.diagnostics[0].code.?, built.diagnostics[0].code.?);
    try std.testing.expectEqualStrings(checked.diagnostics[0].title, built.diagnostics[0].title);
}

test "check reaches backend preparation for selected backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    nativeHelper();
        \\    return;
        \\}
        \\
        \\@Native
        \\function nativeHelper() {
        \\    return;
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", arena.allocator());
    const result = try pipeline.checkFileForBackend(arena.allocator(), source_path, .vm);

    // The VM is the reference interpreter: @Native bodies are ordinary Kira and
    // compile as runtime functions on the VM backend (the annotation is a
    // native-compilation hint, not a VM-compatibility gate).
    try std.testing.expect(!result.failed());
}

test "built-in Foundation resolves before installed package conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/App/app");
    try tmp.dir.createDirPath(std.testing.io, "Workspace/ConflictFoundation");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/App/package.kira",
        .data =
        \\Package App {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.App
        \\    let defaults = Defaults { executionMode: Backend.Vm, buildTarget: BuildTarget.Host }
        \\    let dependencies = [
        \\        Dependency { name: "Foundation", path: "../ConflictFoundation" }
        \\    ]
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/App/app/main.kira",
        .data =
        \\import Foundation
        \\
        \\@Main
        \\function main() {
        \\    Foundation.printLine("ok");
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/ConflictFoundation/package.kira",
        .data =
        \\Package Foundation {
        \\    let version = "9.9.9"
        \\    let kind = PackageKind.Library
        \\    let moduleRoot = "Foundation"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/ConflictFoundation/Foundation.kira",
        .data = "function broken( { return; }\n",
    });

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/App", arena.allocator());
    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/App/app/main.kira", arena.allocator());

    var package_diags = std.array_list.Managed(diagnostics.Diagnostic).init(arena.allocator());
    _ = try package_manager.syncProject(arena.allocator(), app_root, "0.1.0", .{}, &package_diags);

    const result = try pipeline.checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "path dependency rooted at repo root resolves module file from app directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/KiraUI/app");
    try tmp.dir.createDirPath(std.testing.io, "Workspace/CardExample/app");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/KiraUI/package.kira",
        .data =
        \\Package KiraUI {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.Library
        \\    let moduleRoot = "KiraUI"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/KiraUI/app/kiraui.kira",
        .data =
        \\function hello() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/CardExample/package.kira",
        .data =
        \\Package CardExample {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.App
        \\    let defaults = Defaults { executionMode: Backend.Vm, buildTarget: BuildTarget.Host }
        \\    let dependencies = [
        \\        Dependency { name: "KiraUI", path: "../KiraUI" }
        \\    ]
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/CardExample/app/main.kira",
        .data =
        \\import KiraUI
        \\
        \\@Main
        \\function main() {
        \\    hello();
        \\    return;
        \\}
        ,
    });

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/CardExample", arena.allocator());
    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/CardExample/app/main.kira", arena.allocator());
    var package_diags = std.array_list.Managed(diagnostics.Diagnostic).init(arena.allocator());
    _ = try package_manager.syncProject(arena.allocator(), app_root, "0.1.0", .{}, &package_diags);

    const result = try pipeline.checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "ksl builtin resolves shaders from package root while main lives in app directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/App/app");
    try tmp.dir.createDirPath(std.testing.io, "Workspace/App/Shaders");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/App/package.kira",
        .data =
        \\Package App {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.App
        \\    let defaults = Defaults { executionMode: Backend.Vm, buildTarget: BuildTarget.Host }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/App/app/main.kira",
        .data =
        \\struct KslArtifact {
        \\    var shaderName: String = ""
        \\    var vertexEntry: String = ""
        \\    var fragmentEntry: String = ""
        \\    var computeEntry: String = ""
        \\    var combinedMsl: String = ""
        \\    var vertexMsl: String = ""
        \\    var fragmentMsl: String = ""
        \\    var computeMsl: String = ""
        \\    var vertexHlsl: String = ""
        \\    var fragmentHlsl: String = ""
        \\    var vertexGlsl: String = ""
        \\    var fragmentGlsl: String = ""
        \\    var vertexWgsl: String = ""
        \\    var fragmentWgsl: String = ""
        \\    var uniformReflection: String = ""
        \\}
        \\
        \\@Main
        \\function main() {
        \\    let shader = ksl!("Shaders/Tri.ksl")
        \\    let ignored = shader.shaderName.count
        \\    let ignoredWgsl = shader.vertexWgsl.count + shader.fragmentWgsl.count
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/App/Shaders/Tri.ksl",
        .data =
        \\type VertexIn {
        \\    let position: Float2
        \\}
        \\
        \\type VertexOut {
        \\    @builtin(position)
        \\    let clip_position: Float4
        \\
        \\    let color: Float4
        \\}
        \\
        \\type FragmentOut {
        \\    let color: Float4
        \\}
        \\
        \\shader BasicTriangle {
        \\    vertex {
        \\        input VertexIn
        \\        output VertexOut
        \\
        \\        function entry(vertexInput: VertexIn) -> VertexOut {
        \\            let result: VertexOut
        \\            result.clip_position = Float4(vertexInput.position, 0.0, 1.0)
        \\            result.color = Float4(1.0, 0.95, 0.85, 1.0)
        \\            return result
        \\        }
        \\    }
        \\
        \\    fragment {
        \\        input VertexOut
        \\        output FragmentOut
        \\
        \\        function entry(fragmentInput: VertexOut) -> FragmentOut {
        \\            let result: FragmentOut
        \\            result.color = fragmentInput.color
        \\            return result
        \\        }
        \\    }
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/App/app/main.kira", arena.allocator());
    const result = try pipeline.checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "current package app files share one namespace without importing sibling files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/UILibrary/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UILibrary/package.kira",
        .data =
        \\Package UILibrary {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.Library
        \\    let moduleRoot = "UI"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UILibrary/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    header()
        \\    footer()
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UILibrary/app/UI.kira",
        .data =
        \\function header() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UILibrary/app/Footer.kira",
        .data =
        \\function footer() {
        \\    return;
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/UILibrary/app/main.kira", arena.allocator());
    const result = try pipeline.checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "compile frontend deduplicates mixed-separator paths while walking current package namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/callbacks/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/callbacks/package.kira",
        .data =
        \\Package callbacks {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.App
        \\    let defaults = Defaults { executionMode: Backend.Llvm, buildTarget: BuildTarget.Host }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/callbacks/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    hello()
        \\    return
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/callbacks/app/callbacks.kira",
        .data =
        \\function hello() {
        \\    return
        \\}
        ,
    });

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/callbacks/app", arena.allocator());
    const mixed_source_path = try std.fmt.allocPrint(arena.allocator(), "{s}/main.kira", .{app_root});
    const result = try pipeline.compileFileToIr(arena.allocator(), mixed_source_path);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.ir_program != null);
}

test "lowerProgram accepts imported type constant accessors used by widget code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/UI/app");
    try tmp.dir.createDirPath(std.testing.io, "Workspace/App/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UI/package.kira",
        .data =
        \\Package UI {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.Library
        \\    let moduleRoot = "UI"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UI/app/UI.kira",
        .data =
        \\struct FoundationUiContext { let id: Int = 0 }
        \\struct FoundationView { let id: Int = 0 }
        \\
        \\struct Color {
        \\    let r: Float = 0.0
        \\    let Purple: Color {
        \\        return Color { r: 1.0 }
        \\    }
        \\    let Cyan: Color {
        \\        return Color { r: 2.0 }
        \\    }
        \\}
        \\
        \\construct Widget {
        \\    @Required let body: Widget
        \\    function lower(context: borrow FoundationUiContext) -> FoundationView {
        \\        return body.lower(context)
        \\    }
        \\}
        \\
        \\Widget Text(text: String) {
        \\    function lower(context: borrow FoundationUiContext) -> FoundationView {
        \\        let ignored = text.count + context.id
        \\        return FoundationView { id: 1 }
        \\    }
        \\}
        \\
        \\function lowerAll(context: borrow FoundationUiContext, children: borrow [any Widget]) -> FoundationView {
        \\    var index = 0
        \\    var last = FoundationView {}
        \\    while index < children.count {
        \\        last = children[index].lower(context)
        \\        index = index + 1
        \\    }
        \\    return last
        \\}
        \\
        \\Widget VStack() {
        \\    @Content let children: [Widget]
        \\    function lower(context: borrow FoundationUiContext) -> FoundationView {
        \\        return lowerAll(context, children)
        \\    }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/App/package.kira",
        .data =
        \\Package App {
        \\    let version = "0.1.0"
        \\    let kind = PackageKind.App
        \\    let defaults = Defaults { executionMode: Backend.Vm, buildTarget: BuildTarget.Host }
        \\    let dependencies = [
        \\        Dependency { name: "UI", path: "../UI" }
        \\    ]
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/App/app/main.kira",
        .data =
        \\import UI
        \\
        \\Widget AccentCard(title: String, accent: Color) {
        \\    body {
        \\        Text(text: title)
        \\    }
        \\}
        \\
        \\Widget Palette() {
        \\    body {
        \\        VStack() {
        \\            AccentCard(title: "purple", accent: Color.Purple)
        \\            AccentCard(title: "cyan", accent: Color.Cyan)
        \\        }
        \\    }
        \\}
        \\
        \\@Main
        \\function main() {
        \\    let root = Palette()
        \\    let context = FoundationUiContext {}
        \\    let view = root.lower(context)
        \\    let ignored = view.id
        \\    return
        \\}
        ,
    });

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/App", arena.allocator());
    var package_diags = std.array_list.Managed(diagnostics.Diagnostic).init(arena.allocator());
    _ = try package_manager.syncProject(arena.allocator(), app_root, "0.1.0", .{}, &package_diags);

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/App/app/main.kira", arena.allocator());
    const result = try pipeline.compileFileToBytecode(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.ir_program != null);
    try std.testing.expect(result.bytecode_module != null);

    const hybrid = try pipeline.compileFileForBackend(arena.allocator(), source_path, .hybrid, &.{});
    try std.testing.expectEqual(@as(usize, 0), hybrid.diagnostics.len);
    try std.testing.expect(hybrid.ir_program != null);
    try std.testing.expect(hybrid.bytecode_module != null);
}
