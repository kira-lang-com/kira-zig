const std = @import("std");
const manifest = @import("kira_manifest");
const RunnerKind = @import("runner_kind.zig").RunnerKind;

pub const RunnerId = manifest.RunnerId;

pub const LivePlatform = RunnerId;

pub fn parseRunnerId(text: []const u8) ?RunnerId {
    return RunnerId.parse(text);
}

pub fn runnerKind(id: RunnerId) ?RunnerKind {
    return switch (id) {
        .desktop => .desktop_dynamic_host,
        .macos => .xcode_macos,
        .ios => .xcode_ios,
        .tvos => .xcode_tvos,
        .visionos => .xcode_visionos,
        .windows => .windows_visual_studio,
        .android => .android_gradle,
        .web => .web_kira_wasm,
        .linux => .linux_cmake,
    };
}

test "LivePlatform parses user-facing aliases" {
    try std.testing.expectEqual(RunnerId.desktop, parseRunnerId("desktop").?);
    try std.testing.expectEqual(RunnerId.ios, parseRunnerId("ios").?);
    try std.testing.expectEqual(RunnerId.ios, parseRunnerId("ios-simulator").?);
    try std.testing.expectEqual(RunnerId.web, parseRunnerId("web").?);
    try std.testing.expectEqual(RunnerId.linux, parseRunnerId("linux").?);
}
