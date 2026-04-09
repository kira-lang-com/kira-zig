const std = @import("std");
const app_generation = @import("kira_app_generation");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    const parsed = try parseArgs(args);

    const resource_root = try support.resolveResourceRoot(allocator);
    defer allocator.free(resource_root);

    const templates_root = try std.fs.path.join(allocator, &.{ resource_root, "templates" });
    defer allocator.free(templates_root);
    try app_generation.generate(allocator, templates_root, parsed.kind, parsed.name, parsed.destination);
    try stdout.print("created {s} {s} at {s}\n", .{
        switch (parsed.kind) {
            .app => "app",
            .library => "library",
        },
        parsed.name,
        parsed.destination,
    });
}

const ParsedArgs = struct {
    kind: app_generation.TemplateKind = .app,
    name: []const u8,
    destination: []const u8,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var kind: app_generation.TemplateKind = .app;
    var name: ?[]const u8 = null;
    var destination: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--lib")) {
            kind = .library;
            continue;
        }
        if (name == null) {
            name = arg;
            continue;
        }
        if (destination == null) {
            destination = arg;
            continue;
        }
        return error.InvalidArguments;
    }

    if (name == null or destination == null) return error.InvalidArguments;
    return .{
        .kind = kind,
        .name = name.?,
        .destination = destination.?,
    };
}
