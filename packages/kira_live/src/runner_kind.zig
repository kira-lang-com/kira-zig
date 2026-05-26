const std = @import("std");

pub const RunnerKind = enum {
    desktop_dynamic_host,
    xcode_macos,
    xcode_ios,
    xcode_tvos,
    xcode_visionos,
    windows_visual_studio,
    android_gradle,
    web_kira_wasm,
    linux_cmake,

    pub fn parse(text: []const u8) ?RunnerKind {
        if (std.mem.eql(u8, text, "desktop") or std.mem.eql(u8, text, "desktop-dynamic-host")) return .desktop_dynamic_host;
        if (std.mem.eql(u8, text, "macos") or std.mem.eql(u8, text, "xcode-macos")) return .xcode_macos;
        if (std.mem.eql(u8, text, "ios") or std.mem.eql(u8, text, "xcode-ios")) return .xcode_ios;
        if (std.mem.eql(u8, text, "tvos") or std.mem.eql(u8, text, "xcode-tvos")) return .xcode_tvos;
        if (std.mem.eql(u8, text, "visionos") or std.mem.eql(u8, text, "xcode-visionos")) return .xcode_visionos;
        if (std.mem.eql(u8, text, "windows") or std.mem.eql(u8, text, "visual-studio-windows")) return .windows_visual_studio;
        if (std.mem.eql(u8, text, "android") or std.mem.eql(u8, text, "android-gradle")) return .android_gradle;
        if (std.mem.eql(u8, text, "web") or std.mem.eql(u8, text, "kira-wasm")) return .web_kira_wasm;
        if (std.mem.eql(u8, text, "linux") or std.mem.eql(u8, text, "linux-cmake")) return .linux_cmake;
        return null;
    }

    pub fn cliName(self: RunnerKind) []const u8 {
        return switch (self) {
            .desktop_dynamic_host => "desktop",
            .xcode_macos => "macos",
            .xcode_ios => "ios",
            .xcode_tvos => "tvos",
            .xcode_visionos => "visionos",
            .windows_visual_studio => "windows",
            .android_gradle => "android",
            .web_kira_wasm => "web",
            .linux_cmake => "linux",
        };
    }

    pub fn manifestName(self: RunnerKind) []const u8 {
        return switch (self) {
            .desktop_dynamic_host => "desktop-dynamic-host",
            .xcode_macos => "xcode-macos",
            .xcode_ios => "xcode-ios",
            .xcode_tvos => "xcode-tvos",
            .xcode_visionos => "xcode-visionos",
            .windows_visual_studio => "windows-visual-studio",
            .android_gradle => "android-gradle",
            .web_kira_wasm => "web-kira-wasm",
            .linux_cmake => "linux-cmake",
        };
    }

    pub fn deterministicDirectoryName(self: RunnerKind) []const u8 {
        return self.manifestName();
    }
};

test "RunnerKind parses and prints canonical names" {
    try std.testing.expectEqual(RunnerKind.desktop_dynamic_host, RunnerKind.parse("desktop").?);
    try std.testing.expectEqual(RunnerKind.xcode_macos, RunnerKind.parse("xcode-macos").?);
    try std.testing.expectEqual(RunnerKind.xcode_ios, RunnerKind.parse("ios").?);
    try std.testing.expectEqualStrings("desktop-dynamic-host", RunnerKind.desktop_dynamic_host.manifestName());
    try std.testing.expectEqualStrings("xcode-macos", RunnerKind.xcode_macos.manifestName());
    try std.testing.expectEqualStrings("xcode-ios", RunnerKind.xcode_ios.manifestName());
}
