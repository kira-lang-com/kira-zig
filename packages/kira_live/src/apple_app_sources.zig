const std = @import("std");

const Platform = @import("apple_workspace.zig").Platform;

pub fn unifiedMainSource() []const u8 {
    return
    \\#import <Foundation/Foundation.h>
    \\
    \\// Unified Kira Runner Entry: identical for macOS, iOS, iPadOS, tvOS and visionOS.
    \\// The KiraRunner.toml `mode` field selects standalone playback vs. live reload.
    \\extern int kira_live_runner_entry(const char *manifest_path);
    \\
    \\int main(int argc, char **argv) {
    \\    (void)argc;
    \\    (void)argv;
    \\#if defined(KIRA_TARGET_UNAVAILABLE)
    \\    @autoreleasepool {
    \\        NSLog(@"Kira: this platform target has no native backend build yet.");
    \\    }
    \\    return 0;
    \\#else
    \\    @autoreleasepool {
    \\        NSString *path = [[NSBundle mainBundle] pathForResource:@"KiraRunner" ofType:@"toml"];
    \\        return kira_live_runner_entry([path UTF8String]);
    \\    }
    \\#endif
    \\}
    \\
    ;
}

pub fn infoPlist(allocator: std.mem.Allocator, platform: Platform, name: []const u8, bundle_id: []const u8) ![]const u8 {
    _ = bundle_id;
    const requires_ios = switch (platform) {
        .macos => "",
        else => "<key>LSRequiresIPhoneOS</key><true/>",
    };
    const launch = switch (platform) {
        .macos => "<key>NSHighResolutionCapable</key><true/>",
        else => "<key>UILaunchScreen</key><dict/><key>UIApplicationSupportsMultipleScenes</key><false/>",
    };
    const orientations = switch (platform) {
        .ios => "<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>",
        else => "",
    };
    // ProMotion: iPhone caps CADisplayLink at 60 Hz unless this key opts in.
    const promotion = switch (platform) {
        .ios => "<key>CADisableMinimumFrameDurationOnPhone</key><true/>",
        else => "",
    };
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict><key>CFBundleName</key><string>{s}</string><key>CFBundleDisplayName</key><string>{s}</string><key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string><key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>LSSupportsGameMode</key><false/>{s}{s}{s}{s}</dict></plist>
        \\
    , .{ name, name, requires_ios, launch, orientations, promotion });
}

test "iOS Info.plist opts into ProMotion (>60 Hz) and macOS does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = "CADisableMinimumFrameDurationOnPhone";
    const ios = try infoPlist(arena.allocator(), .ios, "Demo", "com.kira.demo");
    try std.testing.expect(std.mem.indexOf(u8, ios, key) != null);
    const mac = try infoPlist(arena.allocator(), .macos, "Demo", "com.kira.demo");
    try std.testing.expect(std.mem.indexOf(u8, mac, key) == null);
}
