const std = @import("std");
const manifest_config = @import("kira_manifest");
const live = @import("root.zig");

pub const Mode = enum {
    run,
    runners_list,
    runners_build,
    runners_clean,
};

pub const ParsedArgs = struct {
    mode: Mode = .run,
    platform: live.RunnerId = .desktop,
    input_path: []const u8,
    run_for_ns: ?u64 = null,
    profile: manifest_config.BuildProfile = .debug,
    surface: manifest_config.WebSurface = .dom,
    requested_runner: []const u8 = "",
    host: ?[]const u8 = null,
    port: ?u16 = null,
    server_url: ?[]const u8 = null,
    kill_after: bool = false,
    headless: bool = false,
    device: []const u8 = "auto",
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return .{ .input_path = "." };
    if (std.mem.eql(u8, args[0], "runners")) {
        if (args.len < 3) return error.InvalidArguments;
        if (std.mem.eql(u8, args[1], "list")) return .{ .mode = .runners_list, .input_path = args[2] };
        if (std.mem.eql(u8, args[1], "build")) return .{ .mode = .runners_build, .input_path = args[2], .platform = .desktop };
        if (std.mem.eql(u8, args[1], "clean")) return .{ .mode = .runners_clean, .input_path = args[2] };
        return error.InvalidArguments;
    }

    var parsed = ParsedArgs{
        .mode = .run,
        .platform = .desktop,
        .input_path = "",
    };
    var index: usize = 0;
    if (!isPathLike(args[0])) {
        if (live.parseRunnerId(args[0])) |platform| {
            parsed.platform = platform;
            parsed.requested_runner = args[0];
            index = 1;
        } else if (args.len >= 2 and !std.mem.startsWith(u8, args[1], "-")) {
            return error.InvalidLivePlatform;
        }
    }
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--quit-after")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.run_for_ns = parseDurationNs(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--run-for")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.run_for_ns = parseDurationNs(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--kill-after")) {
            parsed.kill_after = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--headless")) {
            parsed.headless = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.profile = manifest_config.BuildProfile.parse(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--surface")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.surface = manifest_config.WebSurface.parse(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.host = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.port = std.fmt.parseInt(u16, args[index], 10) catch return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--server-url")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.server_url = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--device")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.device = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (parsed.input_path.len != 0) return error.InvalidArguments;
        parsed.input_path = arg;
    }
    if (parsed.input_path.len == 0) parsed.input_path = ".";
    return parsed;
}

fn isPathLike(value: []const u8) bool {
    return std.mem.startsWith(u8, value, ".") or
        std.mem.startsWith(u8, value, "/") or
        std.mem.indexOfScalar(u8, value, '/') != null or
        std.mem.indexOfScalar(u8, value, std.fs.path.sep) != null;
}

pub fn isIosSimulatorRequest(parsed: ParsedArgs) bool {
    return std.mem.eql(u8, parsed.requested_runner, "ios-simulator") or std.mem.eql(u8, parsed.device, "simulator");
}

fn parseDurationNs(value: []const u8) ?u64 {
    if (std.mem.endsWith(u8, value, "ms")) {
        const number = value[0 .. value.len - 2];
        const parsed = std.fmt.parseInt(u64, number, 10) catch return null;
        return parsed * std.time.ns_per_ms;
    }
    if (std.mem.endsWith(u8, value, "s")) {
        const number = value[0 .. value.len - 1];
        const parsed = std.fmt.parseInt(u64, number, 10) catch return null;
        return parsed * std.time.ns_per_s;
    }
    const parsed = std.fmt.parseInt(u64, value, 10) catch return null;
    if (parsed == 0) return null;
    return parsed * std.time.ns_per_s;
}
