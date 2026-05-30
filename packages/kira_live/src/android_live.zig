const std = @import("std");
const diag_messages = @import("kira_diagnostic_messages");
const live = @import("root.zig");
const shared = @import("supervisor_shared.zig");
const apple_runner = @import("apple_runner.zig");

const emitEvent = shared.emitEvent;
const renderStandaloneDiagnostic = shared.renderStandaloneDiagnostic;
const runTool = shared.runTool;
const runToolInCwd = shared.runToolInCwd;
const runToolCapture = shared.runToolCapture;
const findToolPath = shared.findToolPath;
const bundleIdForName = apple_runner.bundleIdForName;

pub const AndroidDeviceState = struct {
    physical_detected: bool = false,
    emulator_detected: bool = false,
    unauthorized_detected: bool = false,
};

pub fn auditAndroidDeviceState(allocator: std.mem.Allocator, stdout: anytype) !AndroidDeviceState {
    const adb_path_owned = try findToolPath(allocator, "adb");
    defer if (adb_path_owned) |path| allocator.free(path);
    const adb_path = adb_path_owned orelse "adb";
    const devices = try runToolCapture(allocator, &.{ adb_path, "devices" });
    defer allocator.free(devices);
    try emitEvent(stdout, "live.android.adb.devices.checked", "bytes={d}", .{devices.len});

    const state = parseAndroidDeviceState(devices);
    if (state.physical_detected) {
        try emitEvent(stdout, "live.android.physical.detected", "source=adb", .{});
    } else {
        try emitEvent(stdout, "live.android.physical.blocked", "reason=no-physical-device", .{});
    }
    if (state.emulator_detected) {
        try emitEvent(stdout, "live.android.emulator.detected", "source=adb", .{});
    } else {
        try emitEvent(stdout, "live.android.emulator.blocked", "reason=no-running-emulator", .{});
    }
    if (state.unauthorized_detected) {
        try emitEvent(stdout, "live.android.device.blocked", "reason=unauthorized", .{});
    }
    return state;
}

fn parseAndroidDeviceState(devices: []const u8) AndroidDeviceState {
    var state = AndroidDeviceState{};
    var lines = std.mem.splitScalar(u8, devices, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "List of devices")) continue;
        if (std.mem.indexOf(u8, line, "unauthorized") != null) {
            state.unauthorized_detected = true;
            continue;
        }
        if (std.mem.indexOf(u8, line, "\tdevice") == null and std.mem.indexOf(u8, line, " device") == null) continue;
        if (std.mem.startsWith(u8, line, "emulator-")) {
            state.emulator_detected = true;
        } else {
            state.physical_detected = true;
        }
    }
    return state;
}

pub fn runAndroidLiveAttempt(
    allocator: std.mem.Allocator,
    target: live.ResolvedLiveTarget,
    stdout: anytype,
    stderr: anytype,
) !void {
    try emitEvent(stdout, "live.runner.modeled", "runner=android target={s}", .{target.target_root});
    const android_state = auditAndroidDeviceState(allocator, stdout) catch {
        try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "`adb devices` failed. Install Android SDK platform-tools."));
        return error.CommandFailed;
    };
    if (!android_state.emulator_detected) {
        try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "No running Android emulator was visible for install, launch, and log validation."));
        return error.CommandFailed;
    }
    const gradle_path = (try findToolPath(allocator, "gradle")) orelse {
        try emitEvent(stdout, "live.android.build.blocked", "reason=missing-gradle", .{});
        try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "Gradle was not found."));
        return error.CommandFailed;
    };
    const adb_path = (try findToolPath(allocator, "adb")) orelse "adb";
    try emitEvent(stdout, "live.android.tools.detected", "runner=android", .{});

    const cli_path = try std.process.executablePathAlloc(std.Options.debug_io, allocator);
    try runTool(allocator, &.{ cli_path, "export", "android", target.validation_app_root });
    const android_root = try std.fs.path.join(allocator, &.{ target.validation_app_root, "exports", "android" });
    try runToolInCwd(allocator, android_root, &.{ gradle_path, "--no-daemon", "assembleDebug" });
    try emitEvent(stdout, "live.android.build.succeeded", "runner=gradle", .{});

    const apk_path = try std.fs.path.join(allocator, &.{ android_root, "app", "build", "outputs", "apk", "debug", "app-debug.apk" });
    try runTool(allocator, &.{ adb_path, "install", "-r", apk_path });
    try emitEvent(stdout, "live.android.install.succeeded", "apk={s}", .{apk_path});

    const application_id = try bundleIdForName(allocator, target.target_package_name);
    _ = runToolCapture(allocator, &.{ adb_path, "logcat", "-c" }) catch null;
    _ = runToolCapture(allocator, &.{ adb_path, "shell", "am", "force-stop", application_id }) catch null;
    try runTool(allocator, &.{ adb_path, "shell", "am", "start", "-n", try std.fmt.allocPrint(allocator, "{s}/com.kira.app.MainActivity", .{application_id}) });
    try emitEvent(stdout, "live.android.launch.succeeded", "package={s}", .{application_id});
    try std.Options.debug_io.sleep(.fromNanoseconds(1 * std.time.ns_per_s), .awake);
    if (runToolCapture(allocator, &.{ adb_path, "logcat", "-d", "-s", "KiraRunner:I", "*:S" })) |logs| {
        defer allocator.free(logs);
        if (logs.len != 0) try stdout.print("{s}", .{logs});
    } else |_| {}
    try emitEvent(stdout, "live.android.logs.captured", "source=logcat", .{});
}

test "Android device parser separates emulator and physical states" {
    const state = parseAndroidDeviceState(
        "List of devices attached\n" ++
            "emulator-5554\tdevice\n" ++
            "R58M1234567\tdevice\n" ++
            "unauthorized-id\tunauthorized\n",
    );
    try std.testing.expect(state.emulator_detected);
    try std.testing.expect(state.physical_detected);
    try std.testing.expect(state.unauthorized_detected);
}
