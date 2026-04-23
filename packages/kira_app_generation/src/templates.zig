const std = @import("std");

pub fn copyTemplateTree(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, app_name: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dst_path);
    try copyDirRecursive(allocator, src_path, dst_path, app_name);
}

fn copyDirRecursive(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, app_name: []const u8) !void {
    var src_dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, src_path, .{ .iterate = true });
    defer src_dir.close(std.Options.debug_io);

    var iterator = src_dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        const child_src = try std.fs.path.join(std.heap.page_allocator, &.{ src_path, entry.name });
        const rendered_name = try renderTemplateName(allocator, entry.name, app_name);
        defer allocator.free(rendered_name);
        const child_dst = try std.fs.path.join(std.heap.page_allocator, &.{ dst_path, rendered_name });
        defer std.heap.page_allocator.free(child_src);
        defer std.heap.page_allocator.free(child_dst);

        switch (entry.kind) {
            .directory => {
                try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, child_dst);
                try copyDirRecursive(allocator, child_src, child_dst, app_name);
            },
            .file => {
                const contents = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, child_src, std.heap.page_allocator, .limited(1024 * 1024));
                defer std.heap.page_allocator.free(contents);
                const rendered = try renderTemplateContents(allocator, contents, app_name);
                defer allocator.free(rendered);
                try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = child_dst, .data = rendered });
            },
            else => {},
        }
    }
}

fn renderTemplateContents(allocator: std.mem.Allocator, contents: []const u8, app_name: []const u8) ![]u8 {
    const lower_name = try std.ascii.allocLowerString(allocator, app_name);
    defer allocator.free(lower_name);

    const with_app = try std.mem.replaceOwned(u8, allocator, contents, "DemoApp", app_name);
    defer allocator.free(with_app);
    const with_library = try std.mem.replaceOwned(u8, allocator, with_app, "DemoLibrary", app_name);
    defer allocator.free(with_library);
    return std.mem.replaceOwned(u8, allocator, with_library, "demolibrary", lower_name);
}

fn renderTemplateName(allocator: std.mem.Allocator, name: []const u8, app_name: []const u8) ![]u8 {
    const lower_name = try std.ascii.allocLowerString(allocator, app_name);
    defer allocator.free(lower_name);

    const with_library = try std.mem.replaceOwned(u8, allocator, name, "DemoLibrary", app_name);
    defer allocator.free(with_library);
    return std.mem.replaceOwned(u8, allocator, with_library, "demolibrary", lower_name);
}
