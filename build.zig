const std = @import("std");

const Package = struct {
    name: []const u8,
    path: []const u8,
    imports: []const []const u8,
};

const packages = [_]Package{
    .{ .name = "kira_core", .path = "packages/kira_core/src/root.zig", .imports = &.{} },
    .{ .name = "kira_source", .path = "packages/kira_source/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_diagnostics", .path = "packages/kira_diagnostics/src/root.zig", .imports = &.{ "kira_core", "kira_source" } },
    .{ .name = "kira_log", .path = "packages/kira_log/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_runtime_abi", .path = "packages/kira_runtime_abi/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_syntax_model", .path = "packages/kira_syntax_model/src/root.zig", .imports = &.{ "kira_core", "kira_source" } },
    .{ .name = "kira_lexer", .path = "packages/kira_lexer/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_diagnostics" } },
    .{ .name = "kira_parser", .path = "packages/kira_parser/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_lexer", "kira_diagnostics" } },
    .{ .name = "kira_semantics_model", .path = "packages/kira_semantics_model/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_runtime_abi" } },
    .{ .name = "kira_semantics", .path = "packages/kira_semantics/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_diagnostics", "kira_semantics_model", "kira_runtime_abi" } },
    .{ .name = "kira_ir", .path = "packages/kira_ir/src/root.zig", .imports = &.{ "kira_core", "kira_semantics_model", "kira_runtime_abi" } },
    .{ .name = "kira_hybrid_definition", .path = "packages/kira_hybrid_definition/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi" } },
    .{ .name = "kira_native_lib_definition", .path = "packages/kira_native_lib_definition/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi" } },
    .{ .name = "kira_backend_api", .path = "packages/kira_backend_api/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_native_lib_definition" } },
    .{ .name = "kira_bytecode", .path = "packages/kira_bytecode/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_runtime_abi" } },
    .{ .name = "kira_vm_runtime", .path = "packages/kira_vm_runtime/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_bytecode" } },
    .{ .name = "kira_native_bridge", .path = "packages/kira_native_bridge/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_native_lib_definition" } },
    .{ .name = "kira_hybrid_runtime", .path = "packages/kira_hybrid_runtime/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_native_bridge", "kira_vm_runtime", "kira_bytecode" } },
    .{ .name = "kira_llvm_backend", .path = "packages/kira_llvm_backend/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_backend_api", "kira_native_lib_definition", "kira_runtime_abi" } },
    .{ .name = "kira_manifest", .path = "packages/kira_manifest/src/root.zig", .imports = &.{ "kira_core", "kira_native_lib_definition" } },
    .{ .name = "kira_project", .path = "packages/kira_project/src/root.zig", .imports = &.{ "kira_core", "kira_manifest" } },
    .{ .name = "kira_build_definition", .path = "packages/kira_build_definition/src/root.zig", .imports = &.{ "kira_core", "kira_native_lib_definition" } },
    .{ .name = "kira_build", .path = "packages/kira_build/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_diagnostics", "kira_syntax_model", "kira_lexer", "kira_parser", "kira_semantics", "kira_ir", "kira_bytecode", "kira_vm_runtime", "kira_manifest", "kira_project", "kira_build_definition", "kira_backend_api", "kira_native_lib_definition", "kira_hybrid_definition", "kira_llvm_backend" } },
    .{ .name = "kira_linter", .path = "packages/kira_linter/src/root.zig", .imports = &.{ "kira_core", "kira_diagnostics", "kira_parser", "kira_semantics" } },
    .{ .name = "kira_doc", .path = "packages/kira_doc/src/root.zig", .imports = &.{ "kira_core", "kira_parser", "kira_semantics" } },
    .{ .name = "kira_app_generation", .path = "packages/kira_app_generation/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_main", .path = "packages/kira_main/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_bytecode", "kira_vm_runtime", "kira_native_bridge", "kira_hybrid_runtime" } },
    .{ .name = "kira_cli", .path = "packages/kira_cli/src/main.zig", .imports = &.{ "kira_core", "kira_source", "kira_diagnostics", "kira_syntax_model", "kira_lexer", "kira_parser", "kira_semantics", "kira_ir", "kira_bytecode", "kira_vm_runtime", "kira_build", "kira_build_definition", "kira_hybrid_runtime", "kira_app_generation" } },
};

fn applyImports(module: *std.Build.Module, modules: *std.StringArrayHashMap(*std.Build.Module), names: []const []const u8) void {
    for (names) |name| {
        module.addImport(name, modules.get(name).?);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const repo_root = b.pathFromRoot("");
    const llvm_version = readLlvmVersion(b.allocator, repo_root) catch "";
    const llvm_host_key = hostLlvmBundleKey(b.graph.host.result);
    const llvm_probe = discoverLlvmHeaders(b.allocator, repo_root, llvm_version, llvm_host_key);

    var modules = std.StringArrayHashMap(*std.Build.Module).init(b.allocator);
    defer modules.deinit();

    for (packages) |pkg| {
        const module = b.createModule(.{
            .root_source_file = b.path(pkg.path),
            .target = target,
            .optimize = optimize,
        });
        modules.put(pkg.name, module) catch @panic("failed to register module");
    }

    for (packages) |pkg| {
        applyImports(modules.get(pkg.name).?, &modules, pkg.imports);
    }

    const llvm_options = b.addOptions();
    llvm_options.addOption(bool, "llvm_available", llvm_probe != null);
    llvm_options.addOption([]const u8, "repo_root", repo_root);
    llvm_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    llvm_options.addOption([]const u8, "llvm_version", llvm_version);
    llvm_options.addOption([]const u8, "llvm_host_key", llvm_host_key);
    modules.get("kira_llvm_backend").?.addOptions("kira_llvm_build_options", llvm_options);
    modules.get("kira_llvm_backend").?.link_libc = true;

    if (llvm_probe) |probe| {
        for (probe.include_dirs) |dir| {
            modules.get("kira_llvm_backend").?.addIncludePath(.{ .cwd_relative = dir });
        }
    }

    const cli = b.addExecutable(.{
        .name = "kira",
        .root_module = modules.get("kira_cli").?,
    });
    b.installArtifact(cli);

    const kira_main = b.addLibrary(.{
        .linkage = .static,
        .name = "kira_main",
        .root_module = modules.get("kira_main").?,
    });
    b.installArtifact(kira_main);
    kira_main.installHeadersDirectory(b.path("packages/kira_main/include"), "", .{});

    const run_cmd = b.addRunArtifact(cli);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Kira CLI");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run package tests");
    const test_roots = [_][]const u8{
        "kira_lexer",
        "kira_parser",
        "kira_semantics",
        "kira_bytecode",
        "kira_vm_runtime",
        "kira_manifest",
        "kira_native_lib_definition",
        "kira_build",
        "kira_llvm_backend",
        "kira_native_bridge",
    };
    for (test_roots) |name| {
        const unit_tests = b.addTest(.{
            .root_module = modules.get(name).?,
        });
        const run_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_tests.step);
    }

    b.default_step.dependOn(&cli.step);
    b.default_step.dependOn(&kira_main.step);
}

const LlvmHeaderProbe = struct {
    include_dirs: []const []const u8,
};

fn discoverLlvmHeaders(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    llvm_version: []const u8,
    llvm_host_key: []const u8,
) ?LlvmHeaderProbe {
    const env_home = std.process.getEnvVarOwned(allocator, "KIRA_LLVM_HOME") catch null;
    if (env_home) |path| {
        if (headerProbeForHome(allocator, path)) |probe| return probe;
    }

    const repo_current = std.fs.path.join(allocator, &.{ repo_root, ".kira", "llvm", "current" }) catch return null;
    if (headerProbeForHome(allocator, repo_current)) |probe| return probe;

    if (llvm_version.len > 0) {
        const versioned = std.fs.path.join(allocator, &.{ repo_root, ".kira", "llvm", bFmt(allocator, "llvm-{s}-{s}", .{ llvm_version, llvm_host_key }) catch return null }) catch return null;
        if (headerProbeForHome(allocator, versioned)) |probe| return probe;
    }

    return null;
}

fn headerProbeForHome(allocator: std.mem.Allocator, home: []const u8) ?LlvmHeaderProbe {
    const install_include = std.fs.path.join(allocator, &.{ home, "include" }) catch return null;
    if (isValidLlvmIncludeDir(install_include)) {
        return .{ .include_dirs = allocator.dupe([]const u8, &.{install_include}) catch return null };
    }

    const source_include = std.fs.path.join(allocator, &.{ home, "llvm-project", "llvm", "include" }) catch return null;
    if (!isDir(source_include)) return null;

    const build_variants = [_][]const u8{
        "build/include",
        "build-msvc/include",
        "build-release/include",
        "build-debug/include",
    };
    for (build_variants) |suffix| {
        const build_include = std.fs.path.join(allocator, &.{ home, suffix }) catch continue;
        if (isValidLlvmSplitIncludeDirs(source_include, build_include)) {
            return .{
                .include_dirs = allocator.dupe([]const u8, &.{ source_include, build_include }) catch return null,
            };
        }
    }
    return null;
}

fn isValidLlvmIncludeDir(include_dir: []const u8) bool {
    const core_header = std.fs.path.join(std.heap.page_allocator, &.{ include_dir, "llvm-c", "Core.h" }) catch return false;
    defer std.heap.page_allocator.free(core_header);
    const config_header = std.fs.path.join(std.heap.page_allocator, &.{ include_dir, "llvm", "Config", "llvm-config.h" }) catch return false;
    defer std.heap.page_allocator.free(config_header);
    return isFile(core_header) and isFile(config_header);
}

fn isValidLlvmSplitIncludeDirs(source_include: []const u8, build_include: []const u8) bool {
    const core_header = std.fs.path.join(std.heap.page_allocator, &.{ source_include, "llvm-c", "Core.h" }) catch return false;
    defer std.heap.page_allocator.free(core_header);
    const config_header = std.fs.path.join(std.heap.page_allocator, &.{ build_include, "llvm", "Config", "llvm-config.h" }) catch return false;
    defer std.heap.page_allocator.free(config_header);
    return isFile(core_header) and isFile(config_header);
}

fn isDir(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn isFile(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn readLlvmVersion(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    const metadata_path = try std.fs.path.join(allocator, &.{ repo_root, "llvm-metadata.toml" });
    const contents = try std.fs.cwd().readFileAlloc(allocator, metadata_path, 16 * 1024);
    const needle = "version = \"";
    const start = std.mem.indexOf(u8, contents, needle) orelse return "";
    const value_start = start + needle.len;
    const value_end = std.mem.indexOfScalarPos(u8, contents, value_start, '"') orelse return "";
    return contents[value_start..value_end];
}

fn hostLlvmBundleKey(host: std.Target) []const u8 {
    return switch (host.os.tag) {
        .windows => switch (host.cpu.arch) {
            .x86_64 => "x86_64-windows-msvc",
            else => "unsupported-host",
        },
        .linux => switch (host.cpu.arch) {
            .x86_64 => "x86_64-linux-gnu",
            else => "unsupported-host",
        },
        .macos => switch (host.cpu.arch) {
            .aarch64 => "aarch64-macos",
            else => "unsupported-host",
        },
        else => "unsupported-host",
    };
}

fn bFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}
