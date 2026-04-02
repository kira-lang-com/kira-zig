const std = @import("std");

pub fn copyTemplateTree(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, app_name: []const u8) !void {
    _ = allocator;
    try std.fs.cwd().makePath(dst_path);
    try copyDirRecursive(src_path, dst_path, app_name);
}

fn copyDirRecursive(src_path: []const u8, dst_path: []const u8, app_name: []const u8) !void {
    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    var iterator = src_dir.iterate();
    while (try iterator.next()) |entry| {
        const child_src = try std.fs.path.join(std.heap.page_allocator, &.{ src_path, entry.name });
        const child_dst = try std.fs.path.join(std.heap.page_allocator, &.{ dst_path, entry.name });
        defer std.heap.page_allocator.free(child_src);
        defer std.heap.page_allocator.free(child_dst);

        switch (entry.kind) {
            .directory => {
                try std.fs.cwd().makePath(child_dst);
                try copyDirRecursive(child_src, child_dst, app_name);
            },
            .file => {
                const contents = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, child_src, 1024 * 1024);
                defer std.heap.page_allocator.free(contents);
                const rendered = try std.mem.replaceOwned(u8, std.heap.page_allocator, contents, "DemoApp", app_name);
                defer std.heap.page_allocator.free(rendered);
                try std.fs.cwd().writeFile(.{ .sub_path = child_dst, .data = rendered });
            },
            else => {},
        }
    }
}
