const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const DiagnosticDomain = @import("DiagnosticDomain.zig").DiagnosticDomain;
const CompilerPhase = @import("CompilerPhase.zig").CompilerPhase;
const message = @import("DiagnosticMessage.zig");

pub fn missingLlvmToolchain() diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC001_MissingLlvmToolchain,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "LLVM backend is unavailable",
        .message = "Kira could not start the native toolchain because LLVM is not available in this build.",
        .help = "Set KIRA_LLVM_HOME or run `kira fetch-llvm` to install the pinned LLVM toolchain.",
    });
}

pub fn unsupportedHostTarget(allocator: std.mem.Allocator, triple: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC003_UnsupportedTargetTriple,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "unsupported host target",
        .message = try std.fmt.allocPrint(
            allocator,
            "The current host target `{s}` is not supported by this project or one of its native libraries.",
            .{triple},
        ),
        .help = "Add a matching target section to the relevant NativeLibs manifest, or build on a supported host.",
    });
}

pub fn unsupportedNativeLibraryTarget(allocator: std.mem.Allocator, target: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC003_UnsupportedTargetTriple,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "unsupported native library target",
        .message = try std.fmt.allocPrint(
            allocator,
            "A native library used by this package does not provide an artifact for target `{s}`.",
            .{target},
        ),
        .help = "Add a matching NativeLibs target section for this backend, or remove the native library from the browser-targeted package.",
    });
}

pub fn invalidToolchainActivation(allocator: std.mem.Allocator, err_name: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC007_InvalidToolchainActivation,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "toolchain build failed",
        .message = try std.fmt.allocPrint(
            allocator,
            "Kira hit a toolchain failure while preparing this program ({s}).",
            .{err_name},
        ),
        .help = "Check the managed toolchain setup and try the command again.",
    });
}

pub fn missingEmscripten(allocator: std.mem.Allocator, detail: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC030_MissingEmscripten,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "Emscripten toolchain is unavailable",
        .message = try std.fmt.allocPrint(allocator, "Kira could not activate Emscripten for the web runner. {s}", .{detail}),
        .help = "Install or activate emsdk so `emcc --version` works, then rerun the web command.",
    });
}

pub fn missingVisualStudioTools(allocator: std.mem.Allocator, detail: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC040_MissingVisualStudioTools,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "Visual Studio command-line tools are unavailable",
        .message = try std.fmt.allocPrint(allocator, "Kira generated a Windows export scaffold, but could not find Visual Studio build tools. {s}", .{detail}),
        .help = "Install Visual Studio Build Tools or open the generated CMake preset on Windows.",
    });
}

pub fn missingAndroidSdk(allocator: std.mem.Allocator, detail: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC050_MissingAndroidSdk,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "Android command-line SDK is unavailable",
        .message = try std.fmt.allocPrint(allocator, "Kira generated an Android export scaffold, but could not find command-line Android SDK tools. {s}", .{detail}),
        .help = "Install Android command-line SDK tools or open the scaffold in Android Studio. Kira will not install Android Studio automatically.",
    });
}

pub fn missingLinuxBuildTools(allocator: std.mem.Allocator, detail: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC060_MissingLinuxBuildTools,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "Linux build tools are unavailable",
        .message = try std.fmt.allocPrint(allocator, "Kira generated a Linux export scaffold, but could not find the expected command-line tools. {s}", .{detail}),
        .help = "Install CMake and Ninja, then rerun `kira export linux`.",
    });
}

pub fn missingAppleTools(allocator: std.mem.Allocator, detail: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC070_MissingXcodeTools,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "Xcode command-line tools are unavailable",
        .message = try std.fmt.allocPrint(allocator, "Kira needs Xcode command-line tools for Apple runners and exports. {s}", .{detail}),
        .help = "Install Xcode, run `xcode-select` if needed, then rerun the Apple command.",
    });
}

pub fn missingSigningIdentity(allocator: std.mem.Allocator, detail: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC074_MissingSigningIdentity,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "iOS signing identity is unavailable",
        .message = try std.fmt.allocPrint(allocator, "Kira needs an Apple Development signing identity for physical iPhone runners. {s}", .{detail}),
        .help = "Install an Apple Development certificate through Xcode Settings > Accounts, then rerun the iOS command.",
    });
}

pub fn missingProvisioningProfile(allocator: std.mem.Allocator, detail: []const u8) !diagnostics.Diagnostic {
    return message.build(.{
        .code = .KTC075_MissingProvisioningProfile,
        .domain = .toolchain,
        .phase = .toolchain_activation,
        .title = "iOS provisioning profile is unavailable",
        .message = try std.fmt.allocPrint(allocator, "Kira found a physical iPhone and an Apple Development signing identity, but Xcode could not provision the generated iOS runner. {s}", .{detail}),
        .help = "Open Xcode Settings > Accounts, add the Apple ID/team for the connected iPhone, then rerun `kira live ios --host 0.0.0.0`.",
    });
}
