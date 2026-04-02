const build_target = @import("build_target.zig");
const native = @import("kira_native_lib_definition");

pub const BuildRequest = struct {
    source_path: []const u8,
    output_path: []const u8,
    target: build_target.BuildTarget = .{},
    native_libraries: []const native.ResolvedNativeLibrary = &.{},
};
