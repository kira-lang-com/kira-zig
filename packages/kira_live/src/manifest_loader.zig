const std = @import("std");
const manifest = @import("kira_manifest");

/// Load either the declaration-first `package.kira` format or a legacy TOML
/// project manifest. Live targets use the path selected by kira_project, so they
/// must honor the same precedence and format dispatch.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !manifest.ProjectManifest {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(2 * 1024 * 1024));
    return manifest.loadProjectManifestFromText(allocator, text, path);
}

test "loads package.kira declarations for live targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "package.kira",
        .data =
        \\Package LiveDemo {
        \\    let defaults = Defaults { executionMode: .Llvm, buildTarget: .Host }
        \\}
        ,
    });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "package.kira", arena.allocator());
    const project = try load(arena.allocator(), path);
    try std.testing.expectEqualStrings("LiveDemo", project.name);
    try std.testing.expectEqualStrings("llvm", project.execution_mode);
}
