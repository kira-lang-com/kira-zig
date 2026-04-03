const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("kira_llvm_build_options");
const kira_toolchain = @import("kira_toolchain");
const toolchain_layout = @import("toolchain_layout.zig");

pub const InitSymbols = struct {
    target_info: [:0]const u8,
    target: [:0]const u8,
    target_mc: [:0]const u8,
    asm_printer: [:0]const u8,
    asm_parser: ?[:0]const u8,
};

pub const Toolchain = struct {
    home: []const u8,
    bin_dir: []const u8,
    lib_dir: []const u8,
    llvm_config_path: ?[]const u8,
    llvm_c_library_path: []const u8,
    init_symbols: InitSymbols,

    pub fn discover(allocator: std.mem.Allocator) !Toolchain {
        var checked = std.array_list.Managed([]const u8).init(allocator);

        if (std.process.getEnvVarOwned(allocator, "KIRA_LLVM_HOME")) |env_home| {
            try checked.append(env_home);
            if (try fromHome(allocator, env_home)) |tc| return tc;
            std.debug.print("KIRA_LLVM_HOME was set to '{s}', but no usable LLVM-C runtime was found there.\n", .{env_home});
        } else |_| {}

        if (build_options.llvm_version.len > 0 and !std.mem.eql(u8, build_options.llvm_host_key, "unsupported-host")) {
            const managed_home = try kira_toolchain.managedLlvmHome(
                allocator,
                build_options.llvm_version,
                build_options.llvm_host_key,
            );
            try checked.append(managed_home);
            if (try fromHome(allocator, managed_home)) |tc| return tc;
        }

        if (build_options.llvm_version.len > 0 and !std.mem.eql(u8, build_options.llvm_host_key, "unsupported-host")) {
            const managed_home = try toolchain_layout.managedLlvmHome(
                allocator,
                build_options.repo_root,
                build_options.llvm_version,
                build_options.llvm_host_key,
            );
            try checked.append(managed_home);
            if (try fromHome(allocator, managed_home)) |tc| return tc;
        }

        const legacy_current = try toolchain_layout.legacyLlvmCurrentHome(allocator, build_options.repo_root);
        try checked.append(legacy_current);
        if (try fromHome(allocator, legacy_current)) |tc| return tc;

        if (build_options.llvm_version.len > 0 and !std.mem.eql(u8, build_options.llvm_host_key, "unsupported-host")) {
            const legacy_versioned = try toolchain_layout.legacyLlvmVersionedHome(
                allocator,
                build_options.repo_root,
                build_options.llvm_version,
                build_options.llvm_host_key,
            );
            try checked.append(legacy_versioned);
            if (try fromHome(allocator, legacy_versioned)) |tc| return tc;
        }

        std.debug.print("LLVM toolchain unavailable. Checked:\n", .{});
        for (checked.items) |path| {
            std.debug.print("  - {s}\n", .{path});
        }
        std.debug.print(
            "Set KIRA_LLVM_HOME or run `kira-bootstrapper fetch-llvm` to install the pinned LLVM toolchain.\n",
            .{},
        );
        return error.LlvmToolchainUnavailable;
    }
};

fn fromHome(allocator: std.mem.Allocator, home: []const u8) !?Toolchain {
    const install_bin = try std.fs.path.join(allocator, &.{ home, "bin" });
    const install_lib = try std.fs.path.join(allocator, &.{ home, "lib" });
    if (libraryPath(allocator, install_bin, install_lib)) |library_path| {
        const config_path = llvmConfigPath(allocator, install_bin);
        const resolved = try resolveWithLlvmConfig(allocator, config_path, install_bin, install_lib);
        return .{
            .home = try allocator.dupe(u8, home),
            .bin_dir = resolved.bin_dir,
            .lib_dir = resolved.lib_dir,
            .llvm_config_path = if (config_path) |value| try allocator.dupe(u8, value) else null,
            .llvm_c_library_path = library_path,
            .init_symbols = initSymbols(),
        };
    }

    const build_variants = [_][]const u8{
        "build",
        "build-msvc",
        "build-release",
        "build-debug",
    };
    for (build_variants) |variant| {
        const bin_dir = try std.fs.path.join(allocator, &.{ home, variant, "bin" });
        const lib_dir = try std.fs.path.join(allocator, &.{ home, variant, "lib" });
        if (libraryPath(allocator, bin_dir, lib_dir)) |library_path| {
            return .{
                .home = try allocator.dupe(u8, home),
                .bin_dir = bin_dir,
                .lib_dir = lib_dir,
                .llvm_config_path = llvmConfigPath(allocator, bin_dir),
                .llvm_c_library_path = library_path,
                .init_symbols = initSymbols(),
            };
        }
    }
    return null;
}

fn resolveWithLlvmConfig(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    fallback_bin: []const u8,
    fallback_lib: []const u8,
) !struct { bin_dir: []const u8, lib_dir: []const u8 } {
    if (config_path) |llvm_config| {
        const bin_dir = runLlvmConfig(allocator, llvm_config, "--bindir") catch null;
        const lib_dir = runLlvmConfig(allocator, llvm_config, "--libdir") catch null;
        if (bin_dir != null and lib_dir != null) {
            return .{ .bin_dir = bin_dir.?, .lib_dir = lib_dir.? };
        }
    }
    return .{
        .bin_dir = try allocator.dupe(u8, fallback_bin),
        .lib_dir = try allocator.dupe(u8, fallback_lib),
    };
}

fn runLlvmConfig(allocator: std.mem.Allocator, llvm_config: []const u8, arg: []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ llvm_config, arg },
        .max_output_bytes = 8 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.LlvmConfigFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}

fn llvmConfigPath(allocator: std.mem.Allocator, bin_dir: []const u8) ?[]const u8 {
    const name = if (builtin.os.tag == .windows) "llvm-config.exe" else "llvm-config";
    const path = std.fs.path.join(allocator, &.{ bin_dir, name }) catch return null;
    if (!fileExists(path)) return null;
    return path;
}

fn libraryPath(allocator: std.mem.Allocator, bin_dir: []const u8, lib_dir: []const u8) ?[]const u8 {
    const candidates = switch (builtin.os.tag) {
        .windows => [_]struct { dir: []const u8, name: []const u8 }{
            .{ .dir = bin_dir, .name = "LLVM-C.dll" },
            .{ .dir = lib_dir, .name = "LLVM-C.dll" },
        },
        .linux => [_]struct { dir: []const u8, name: []const u8 }{
            .{ .dir = lib_dir, .name = "libLLVM-C.so" },
            .{ .dir = bin_dir, .name = "libLLVM-C.so" },
        },
        .macos => [_]struct { dir: []const u8, name: []const u8 }{
            .{ .dir = lib_dir, .name = "libLLVM-C.dylib" },
            .{ .dir = bin_dir, .name = "libLLVM-C.dylib" },
        },
        else => return null,
    };

    for (candidates) |candidate| {
        const path = std.fs.path.join(allocator, &.{ candidate.dir, candidate.name }) catch continue;
        if (fileExists(path)) return path;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{})
    else
        std.fs.cwd().openFile(path, .{});
    if (file) |value| {
        value.close();
        return true;
    } else |_| {
        return false;
    }
}

fn initSymbols() InitSymbols {
    return switch (builtin.cpu.arch) {
        .x86_64 => .{
            .target_info = "LLVMInitializeX86TargetInfo",
            .target = "LLVMInitializeX86Target",
            .target_mc = "LLVMInitializeX86TargetMC",
            .asm_printer = "LLVMInitializeX86AsmPrinter",
            .asm_parser = "LLVMInitializeX86AsmParser",
        },
        .aarch64 => .{
            .target_info = "LLVMInitializeAArch64TargetInfo",
            .target = "LLVMInitializeAArch64Target",
            .target_mc = "LLVMInitializeAArch64TargetMC",
            .asm_printer = "LLVMInitializeAArch64AsmPrinter",
            .asm_parser = "LLVMInitializeAArch64AsmParser",
        },
        else => .{
            .target_info = "LLVMInitializeX86TargetInfo",
            .target = "LLVMInitializeX86Target",
            .target_mc = "LLVMInitializeX86TargetMC",
            .asm_printer = "LLVMInitializeX86AsmPrinter",
            .asm_parser = "LLVMInitializeX86AsmParser",
        },
    };
}
