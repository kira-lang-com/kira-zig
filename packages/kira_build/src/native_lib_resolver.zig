const std = @import("std");
const manifest = @import("kira_manifest");
const native = @import("kira_native_lib_definition");

pub fn resolveNativeManifestFile(allocator: std.mem.Allocator, path: []const u8, target: native.TargetSelector) !native.ResolvedNativeLibrary {
    const text = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    const parsed = try manifest.parseNativeLibManifest(allocator, text);
    return native.resolveLibrary(allocator, parsed.library, target);
}
