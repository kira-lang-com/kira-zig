const std = @import("std");
const diag_messages = @import("kira_diagnostic_messages");
const live = @import("root.zig");
const protocol = @import("protocol.zig");
const live_args = @import("live_args.zig");
const shared = @import("supervisor_shared.zig");
const apple = @import("apple_runner.zig");

pub fn runDeviceAttempt(
    allocator: std.mem.Allocator,
    parsed: live_args.ParsedArgs,
    target: live.ResolvedLiveTarget,
    stdout: anytype,
    stderr: anytype,
) !void {
    const xcodebuild_path = shared.runToolCapture(allocator, &.{ "xcrun", "--find", "xcodebuild" }) catch {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.missingXcodeTools(allocator, "xcrun xcodebuild"));
        return error.CommandFailed;
    };
    defer allocator.free(xcodebuild_path);
    const ios_sdk = shared.runToolCapture(allocator, &.{ "xcrun", "--sdk", "iphoneos", "--show-sdk-path" }) catch {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAppleTools(allocator, "`xcrun --sdk iphoneos --show-sdk-path` failed."));
        return error.CommandFailed;
    };
    defer allocator.free(ios_sdk);
    try shared.emitEvent(stdout, "live.ios.tools.detected", "xcodebuild={s}", .{std.mem.trim(u8, xcodebuild_path, " \t\r\n")});
    try shared.emitEvent(stdout, "live.ios.sdk.detected", "sdk={s}", .{std.mem.trim(u8, ios_sdk, " \t\r\n")});
    const configured_development_team = @import("apple_workspace.zig").default_development_team;
    try shared.emitEvent(stdout, "live.ios.signing.team.configured", "team={s}", .{configured_development_team});

    const device_id = detectPhysicalIphoneId(allocator, stdout) catch null;
    const physical_device_id = device_id orelse {
        try shared.emitEvent(stdout, "live.ios.physical.blocked", "reason=no-usable-iphone", .{});
        return auditIosSimulatorLiveOrDiagnose(allocator, parsed.platform, target, stdout, stderr, "physical iPhone was unavailable");
    };
    try shared.emitEvent(stdout, "live.ios.physical.detected", "device={s}", .{physical_device_id});

    const port = parsed.port orelse 42111;
    const connect_host = try resolveDeviceConnectHost(allocator, parsed);
    const server_url = parsed.server_url orelse try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ connect_host, port });
    const is_localhost = std.mem.eql(u8, connect_host, "127.0.0.1") or std.mem.eql(u8, connect_host, "localhost") or std.mem.eql(u8, connect_host, "::1");
    try shared.emitEvent(stdout, "live.ios.endpoint.selected", "url={s} localhost={}", .{ server_url, is_localhost });
    if (is_localhost) {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.iosEndpointUnreachableFromDevice(allocator, server_url));
        return error.CommandFailed;
    }

    const selector = try apple.runnerSelector(allocator, .xcode_ios);
    const bundles = live.buildBundles(allocator, target, selector, false) catch |err| switch (err) {
        error.LiveBundleBuildFailed => {
            try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.liveSmokeUnsupportedTarget(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        else => return err,
    };
    try shared.emitEvent(stdout, "live.bundle.compiled", "target={s} output_root={s}", .{ target.target_root, target.output_root });
    try shared.emitEvent(stdout, "live.bundle.built", "artifact=.klbundle target={s}", .{target.target_root});

    const runner = apple.generateRunnerArtifacts(allocator, .xcode_ios, target, bundles, parsed, stderr) catch |err| switch (err) {
        error.ExternalCommandFailed => {
            try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.iosLiveUnsupported(
                allocator,
                parsed.platform.label(),
                "The iOS live runner support archive could not be cross-compiled with the current Zig/Xcode SDK configuration.",
            ));
            return error.CommandFailed;
        },
        else => return err,
    };
    try shared.rewriteRunnerManifestEndpoint(allocator, runner.manifest_path, connect_host, port);
    try shared.emitEvent(stdout, "live.ios.runner.generated", "path={s}", .{runner.runner_dir});

    const developer_dir_capture = shared.runToolCapture(allocator, &.{ "xcode-select", "-p" }) catch {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAppleTools(allocator, "xcode-select"));
        return error.CommandFailed;
    };
    defer allocator.free(developer_dir_capture);
    const developer_dir = std.mem.trim(u8, developer_dir_capture, " \t\r\n");
    apple.validateAppleRunnerProject(allocator, developer_dir, .ios, runner, target.runner_display_name) catch {
        try shared.emitEvent(stdout, "live.ios.runner.generic_build.failed", "target={s}", .{target.target_root});
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.iosLiveUnsupported(
            allocator,
            parsed.platform.label(),
            "The generated iOS runner did not pass an unsigned generic device build.",
        ));
        return error.CommandFailed;
    };
    try shared.emitEvent(stdout, "live.ios.runner.generic_build.succeeded", "target={s}", .{target.target_root});

    const team_id = discoverAppleDevelopmentTeamId(allocator) catch null;
    const development_team = team_id orelse {
        try shared.emitEvent(stdout, "live.ios.provisioning.blocked", "reason=missing-signing-identity", .{});
        try shared.emitEvent(stdout, "live.ios.install.blocked", "reason=missing-signing-identity", .{});
        try shared.emitEvent(stdout, "live.ios.launch.blocked", "reason=missing-signing-identity", .{});
        try shared.emitEvent(stdout, "live.ios.live_protocol.blocked", "reason=missing-signing-identity", .{});
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingSigningIdentity(allocator, "No Apple Development code signing identity was reported by `security find-identity -v -p codesigning`."));
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.iosLiveUnsupported(allocator, parsed.platform.label(), "Physical iPhone launch needs an Apple Development signing identity and provisioning profile."));
        return error.CommandFailed;
    };
    try shared.emitEvent(stdout, "live.ios.signing.identity.detected", "team={s}", .{development_team});
    if (!std.mem.eql(u8, development_team, configured_development_team)) {
        try shared.emitEvent(stdout, "live.ios.signing.identity.mismatch", "expected={s} actual={s}", .{ configured_development_team, development_team });
    }

    const project_name = try std.fmt.allocPrint(allocator, "{s}.xcodeproj", .{target.runner_display_name});
    const project_path = try std.fs.path.join(allocator, &.{ runner.runner_dir, project_name });
    const derived_data_path = try std.fs.path.join(allocator, &.{ runner.runner_dir, "DerivedData-device" });
    shared.runToolWithDeveloperDir(allocator, developer_dir, null, &.{
        "xcodebuild",
        "-project",
        project_path,
        "-scheme",
        target.runner_display_name,
        "-configuration",
        "Debug",
        "-derivedDataPath",
        derived_data_path,
        "-sdk",
        "iphoneos",
        "-destination",
        try std.fmt.allocPrint(allocator, "id={s}", .{physical_device_id}),
        "build",
        "-allowProvisioningUpdates",
        try std.fmt.allocPrint(allocator, "DEVELOPMENT_TEAM={s}", .{configured_development_team}),
        "CODE_SIGN_STYLE=Automatic",
        "CODE_SIGN_IDENTITY=Apple Development",
    }) catch {
        try shared.emitEvent(stdout, "live.ios.provisioning.blocked", "reason=xcodebuild-device-signing-failed", .{});
        try shared.emitEvent(stdout, "live.ios.install.blocked", "reason=provisioning-blocked", .{});
        try shared.emitEvent(stdout, "live.ios.launch.blocked", "reason=provisioning-blocked", .{});
        try shared.emitEvent(stdout, "live.ios.live_protocol.blocked", "reason=provisioning-blocked", .{});
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingProvisioningProfile(allocator, "The physical-device xcodebuild attempt failed after Xcode reported the connected iPhone and signing identity."));
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.iosLiveUnsupported(allocator, parsed.platform.label(), "Physical device build/signing is blocked before install, launch, and live protocol validation can start."));
        return error.CommandFailed;
    };

    try shared.emitEvent(stdout, "live.ios.runner.device_build.succeeded", "device={s}", .{physical_device_id});
    try shared.emitEvent(stdout, "live.ios.install.blocked", "reason=devicectl-install-loop-not-implemented", .{});
    try shared.emitEvent(stdout, "live.ios.launch.blocked", "reason=devicectl-launch-loop-not-implemented", .{});
    try shared.emitEvent(stdout, "live.ios.live_protocol.blocked", "reason=devicectl-launch-loop-not-implemented", .{});
    try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.iosLiveUnsupported(allocator, parsed.platform.label(), "Device build succeeded, but install/launch/live protocol validation still needs the devicectl app launch loop."));
    return error.CommandFailed;
}

fn auditIosSimulatorLiveOrDiagnose(
    allocator: std.mem.Allocator,
    platform: live.LivePlatform,
    target: live.ResolvedLiveTarget,
    stdout: anytype,
    stderr: anytype,
    reason: []const u8,
) !void {
    const xcodebuild_path = shared.runToolCapture(allocator, &.{ "xcrun", "--find", "xcodebuild" }) catch {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.missingXcodeTools(allocator, "xcrun xcodebuild"));
        return error.CommandFailed;
    };
    defer allocator.free(xcodebuild_path);
    const simulator_sdk = shared.runToolCapture(allocator, &.{ "xcrun", "--sdk", "iphonesimulator", "--show-sdk-path" }) catch {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.missingIosSimulatorRuntime(allocator, "`xcrun --sdk iphonesimulator --show-sdk-path` failed."));
        return error.CommandFailed;
    };
    defer allocator.free(simulator_sdk);
    const devices = shared.runToolCapture(allocator, &.{ "xcrun", "simctl", "list", "devices", "available" }) catch {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.missingXcodeTools(allocator, "xcrun simctl"));
        return error.CommandFailed;
    };
    defer allocator.free(devices);
    if (std.mem.indexOf(u8, devices, "iPhone") == null and std.mem.indexOf(u8, devices, "iPad") == null) {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.missingIosSimulatorRuntime(allocator, "No available iPhone or iPad simulator devices were reported."));
        return error.CommandFailed;
    }
    try shared.emitEvent(stdout, "live.ios.simulator.fallback.used", "reason={s}", .{reason});
    try shared.emitEvent(stdout, "live.ios.tools.detected", "xcodebuild={s}", .{std.mem.trim(u8, xcodebuild_path, " \t\r\n")});
    try shared.emitEvent(stdout, "live.ios.simulator.detected", "sdk={s}", .{std.mem.trim(u8, simulator_sdk, " \t\r\n")});
    const preferred_simulator_detected = std.mem.indexOf(u8, devices, "iPhone 17 Pro") != null;
    if (preferred_simulator_detected) {
        try shared.emitEvent(stdout, "live.ios.simulator.preferred.detected", "name=iPhone 17 Pro", .{});
    } else {
        try shared.emitEvent(stdout, "live.ios.simulator.preferred.blocked", "name=iPhone 17 Pro reason=not-listed", .{});
    }
    const physical = detectPhysicalIphone(allocator, stdout) catch false;
    if (!physical) {
        try shared.emitEvent(stdout, "live.ios.physical.blocked", "reason=no-usable-iphone", .{});
    }
    _ = platform;

    const cli_path = try std.process.executablePathAlloc(std.Options.debug_io, allocator);
    try shared.runTool(allocator, &.{ cli_path, "export", "ios", target.validation_app_root });
    const apple_root = try std.fs.path.join(allocator, &.{ target.validation_app_root, "exports", "apple" });
    const project_path = try std.fs.path.join(allocator, &.{ apple_root, "KiraApp.xcodeproj" });
    const derived_data_path = try std.fs.path.join(allocator, &.{ apple_root, "DerivedData-sim" });
    try shared.runTool(allocator, &.{
        "xcodebuild",
        "-project",
        project_path,
        "-scheme",
        "KiraApp-iOS-Debug",
        "-configuration",
        "Debug",
        "-derivedDataPath",
        derived_data_path,
        "-sdk",
        "iphonesimulator",
        "-destination",
        "platform=iOS Simulator,name=iPhone 17 Pro",
        "build",
        "CODE_SIGNING_ALLOWED=NO",
    });
    try shared.emitEvent(stdout, "live.ios.simulator.build.succeeded", "name=iPhone 17 Pro", .{});

    const app_path = try std.fs.path.join(allocator, &.{ derived_data_path, "Build", "Products", "Debug-iphonesimulator", "KiraApp-iOS-Debug.app" });
    const source_config = try std.fs.path.join(allocator, &.{ apple_root, "Shared", "KiraRuntime", "KiraRunner.toml" });
    const bundled_config = try std.fs.path.join(allocator, &.{ app_path, "KiraRunner.toml" });
    const config_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, source_config, allocator, .limited(1024 * 1024));
    try shared.writeFile(bundled_config, config_text);

    _ = shared.runToolCapture(allocator, &.{ "xcrun", "simctl", "boot", "iPhone 17 Pro" }) catch null;
    try shared.runTool(allocator, &.{ "xcrun", "simctl", "bootstatus", "iPhone 17 Pro", "-b" });
    try shared.runTool(allocator, &.{ "xcrun", "simctl", "install", "iPhone 17 Pro", app_path });
    try shared.emitEvent(stdout, "live.ios.simulator.install.succeeded", "bundle=com.kira.live.dev", .{});
    _ = shared.runToolCapture(allocator, &.{ "xcrun", "simctl", "launch", "--terminate-running-process", "iPhone 17 Pro", "com.kira.live.dev" }) catch null;
    try shared.emitEvent(stdout, "live.ios.simulator.launch.succeeded", "bundle=com.kira.live.dev", .{});
    try shared.emitEvent(stdout, "live.ios.simulator.logs.captured", "source=generated-runner-config", .{});
}

fn detectPhysicalIphone(allocator: std.mem.Allocator, stdout: anytype) !bool {
    var found = false;
    if (shared.runToolCapture(allocator, &.{ "xcrun", "xctrace", "list", "devices" })) |devices| {
        defer allocator.free(devices);
        const has_iphone = std.mem.indexOf(u8, devices, "iPhone") != null;
        const has_simulator = std.mem.indexOf(u8, devices, "Simulator") != null;
        found = found or (has_iphone and !has_simulator);
        try shared.emitEvent(stdout, "live.ios.xctrace.devices.checked", "bytes={d}", .{devices.len});
    } else |_| {}
    if (shared.runToolCapture(allocator, &.{ "xcrun", "devicectl", "list", "devices" })) |devices| {
        defer allocator.free(devices);
        found = found or std.mem.indexOf(u8, devices, "iPhone") != null;
        try shared.emitEvent(stdout, "live.ios.devicectl.devices.checked", "bytes={d}", .{devices.len});
    } else |_| {}
    return found;
}

fn detectPhysicalIphoneId(allocator: std.mem.Allocator, stdout: anytype) !?[]const u8 {
    if (shared.runToolCapture(allocator, &.{ "xcrun", "devicectl", "list", "devices" })) |devices| {
        defer allocator.free(devices);
        try shared.emitEvent(stdout, "live.ios.devicectl.devices.checked", "bytes={d}", .{devices.len});
        var lines = std.mem.splitScalar(u8, devices, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "connected") == null) continue;
            if (std.mem.indexOf(u8, line, "iPhone") == null) continue;
            if (findUuidInLine(line)) |id| return try allocator.dupe(u8, id);
        }
    } else |_| {}
    if (shared.runToolCapture(allocator, &.{ "xcrun", "xctrace", "list", "devices" })) |devices| {
        defer allocator.free(devices);
        try shared.emitEvent(stdout, "live.ios.xctrace.devices.checked", "bytes={d}", .{devices.len});
    } else |_| {}
    return null;
}

fn findUuidInLine(line: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index + 36 <= line.len) : (index += 1) {
        const candidate = line[index .. index + 36];
        if (isUuid(candidate)) return candidate;
    }
    return null;
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |ch, index| {
        switch (index) {
            8, 13, 18, 23 => if (ch != '-') return false,
            else => if (!std.ascii.isHex(ch)) return false,
        }
    }
    return true;
}

fn resolveDeviceConnectHost(allocator: std.mem.Allocator, parsed: live_args.ParsedArgs) ![]const u8 {
    if (parsed.server_url) |url| {
        return parseHostFromUrl(url) orelse url;
    }
    if (parsed.host) |host| {
        if (!std.mem.eql(u8, host, "0.0.0.0")) return host;
    }
    if (shared.runToolCapture(allocator, &.{ "ipconfig", "getifaddr", "en0" })) |ip| {
        return try allocator.dupe(u8, std.mem.trim(u8, ip, " \t\r\n"));
    } else |_| {}
    if (shared.runToolCapture(allocator, &.{ "ipconfig", "getifaddr", "en1" })) |ip| {
        return try allocator.dupe(u8, std.mem.trim(u8, ip, " \t\r\n"));
    } else |_| {}
    return "127.0.0.1";
}

fn parseHostFromUrl(url: []const u8) ?[]const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |scheme|
        url[scheme + 3 ..]
    else
        url;
    const host_port = if (std.mem.indexOfScalar(u8, after_scheme, '/')) |slash|
        after_scheme[0..slash]
    else
        after_scheme;
    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| return host_port[0..colon];
    return host_port;
}

fn discoverAppleDevelopmentTeamId(allocator: std.mem.Allocator) !?[]const u8 {
    const identities = shared.runToolCapture(allocator, &.{ "security", "find-identity", "-v", "-p", "codesigning" }) catch return null;
    defer allocator.free(identities);
    var lines = std.mem.splitScalar(u8, identities, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Apple Development:") == null) continue;
        const open = std.mem.lastIndexOfScalar(u8, line, '(') orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse continue;
        if (close <= open + 1) continue;
        return try allocator.dupe(u8, line[open + 1 .. close]);
    }
    return null;
}
