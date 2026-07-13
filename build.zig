const std = @import("std");
const kira_toolchain = @import("packages/kira_toolchain/src/root.zig");
const llvm_metadata = @import("packages/kira_build/src/llvm_metadata.zig");
const toolchain_layout = @import("packages/kira_llvm_toolchain_layout/src/root.zig");
const llvm_probe = @import("build_support/llvm_probe.zig");
const managed_install = @import("build_support/managed_install.zig");
const test_roots = @import("build_support/test_roots.zig").test_roots;
const kirac_version = "2026.07.2";
const kira_primary_executable = "kirac";
const kira_bootstrapper_name = "kira-bootstrapper";
const kira_repository = "kira-lang-com/kira";

const Package = struct {
    name: []const u8,

    path: []const u8,
    imports: []const []const u8,
};

const packages = [_]Package{
    .{ .name = "kira_core", .path = "packages/kira_core/src/root.zig", .imports = &.{} },
    .{ .name = "kira_toolchain", .path = "packages/kira_toolchain/src/root.zig", .imports = &.{} },
    .{ .name = "kira_source", .path = "packages/kira_source/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_diagnostics", .path = "packages/kira_diagnostics/src/root.zig", .imports = &.{ "kira_core", "kira_source" } },
    .{ .name = "kira_diagnostic_messages", .path = "packages/kira_diagnostic_messages/src/root.zig", .imports = &.{ "kira_diagnostics", "kira_source" } },
    .{ .name = "kira_log", .path = "packages/kira_log/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_runtime_abi", .path = "packages/kira_runtime_abi/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_syntax_model", .path = "packages/kira_syntax_model/src/root.zig", .imports = &.{ "kira_core", "kira_source" } },
    .{ .name = "kira_lexer", .path = "packages/kira_lexer/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_diagnostics" } },
    .{ .name = "kira_parser", .path = "packages/kira_parser/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_lexer", "kira_diagnostics" } },
    .{ .name = "kira_semantics_model", .path = "packages/kira_semantics_model/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_runtime_abi" } },
    .{ .name = "kira_shader_model", .path = "packages/kira_shader_model/src/root.zig", .imports = &.{} },
    .{ .name = "kira_ksl_syntax_model", .path = "packages/kira_ksl_syntax_model/src/root.zig", .imports = &.{"kira_source"} },
    .{ .name = "kira_ksl_parser", .path = "packages/kira_ksl_parser/src/root.zig", .imports = &.{ "kira_source", "kira_diagnostics", "kira_ksl_syntax_model" } },
    .{ .name = "kira_shader_ir", .path = "packages/kira_shader_ir/src/root.zig", .imports = &.{ "kira_source", "kira_shader_model" } },
    .{ .name = "kira_ksl_semantics", .path = "packages/kira_ksl_semantics/src/root.zig", .imports = &.{ "kira_source", "kira_diagnostics", "kira_ksl_syntax_model", "kira_ksl_parser", "kira_shader_model", "kira_shader_ir" } },
    .{ .name = "kira_glsl_backend", .path = "packages/kira_glsl_backend/src/root.zig", .imports = &.{ "kira_diagnostics", "kira_shader_model", "kira_shader_ir" } },
    .{ .name = "kira_wgsl_backend", .path = "packages/kira_wgsl_backend/src/root.zig", .imports = &.{ "kira_diagnostics", "kira_shader_model", "kira_shader_ir" } },
    .{ .name = "kira_hlsl_backend", .path = "packages/kira_hlsl_backend/src/root.zig", .imports = &.{ "kira_diagnostics", "kira_shader_model", "kira_shader_ir" } },
    .{ .name = "kira_msl_backend", .path = "packages/kira_msl_backend/src/root.zig", .imports = &.{ "kira_diagnostics", "kira_shader_model", "kira_shader_ir" } },
    .{ .name = "kira_spirv_backend", .path = "packages/kira_spirv_backend/src/root.zig", .imports = &.{ "kira_diagnostics", "kira_shader_model", "kira_shader_ir" } },
    .{ .name = "kira_semantics", .path = "packages/kira_semantics/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_diagnostics", "kira_semantics_model", "kira_runtime_abi", "kira_lexer", "kira_parser" } },
    .{ .name = "kira_ir", .path = "packages/kira_ir/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_diagnostics", "kira_semantics_model", "kira_runtime_abi" } },
    .{ .name = "kira_hybrid_definition", .path = "packages/kira_hybrid_definition/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi" } },
    .{ .name = "kira_native_lib_definition", .path = "packages/kira_native_lib_definition/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi" } },
    .{ .name = "kira_dynamic_ffi", .path = "packages/kira_dynamic_ffi/src/root.zig", .imports = &.{} },
    .{ .name = "kira_backend_api", .path = "packages/kira_backend_api/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_native_lib_definition" } },
    .{ .name = "kira_bytecode", .path = "packages/kira_bytecode/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_runtime_abi", "kira_source" } },
    .{ .name = "kira_vm_runtime", .path = "packages/kira_vm_runtime/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_bytecode", "kira_dynamic_ffi" } },
    .{ .name = "kira_native_bridge", .path = "packages/kira_native_bridge/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_native_lib_definition", "kira_dynamic_ffi" } },
    .{ .name = "kira_hybrid_runtime", .path = "packages/kira_hybrid_runtime/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_native_bridge", "kira_vm_runtime", "kira_bytecode" } },
    .{ .name = "kira_debug", .path = "packages/kira_debug/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_ir", "kira_bytecode", "kira_runtime_abi", "kira_vm_runtime", "kira_hybrid_definition", "kira_hybrid_runtime", "kira_diagnostics" } },
    .{ .name = "kira_llvm_toolchain_layout", .path = "packages/kira_llvm_toolchain_layout/src/root.zig", .imports = &.{} },
    .{ .name = "kira_llvm_backend", .path = "packages/kira_llvm_backend/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_backend_api", "kira_native_lib_definition", "kira_runtime_abi", "kira_toolchain", "kira_llvm_toolchain_layout", "kira_dynamic_ffi", "kira_source" } },
    .{ .name = "kira_manifest", .path = "packages/kira_manifest/src/root.zig", .imports = &.{ "kira_core", "kira_native_lib_definition", "kira_source", "kira_diagnostics", "kira_syntax_model", "kira_lexer", "kira_parser" } },
    .{ .name = "kira_wasm_runtime", .path = "packages/kira_wasm_runtime/src/root.zig", .imports = &.{} },
    .{ .name = "kira_project", .path = "packages/kira_project/src/root.zig", .imports = &.{ "kira_core", "kira_diagnostics", "kira_manifest" } },
    .{ .name = "kira_package_manager", .path = "packages/kira_package_manager/src/root.zig", .imports = &.{ "kira_manifest", "kira_diagnostics", "kira_toolchain" } },
    .{ .name = "kira_program_graph", .path = "packages/kira_program_graph/src/root.zig", .imports = &.{ "kira_source", "kira_diagnostics", "kira_syntax_model", "kira_lexer", "kira_parser", "kira_package_manager" } },
    .{ .name = "kira_build_definition", .path = "packages/kira_build_definition/src/root.zig", .imports = &.{ "kira_core", "kira_native_lib_definition" } },
    .{ .name = "kira_build", .path = "packages/kira_build/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_diagnostics", "kira_diagnostic_messages", "kira_syntax_model", "kira_lexer", "kira_parser", "kira_semantics", "kira_ir", "kira_bytecode", "kira_vm_runtime", "kira_manifest", "kira_project", "kira_package_manager", "kira_program_graph", "kira_build_definition", "kira_backend_api", "kira_native_lib_definition", "kira_hybrid_definition", "kira_runtime_abi", "kira_llvm_backend", "kira_llvm_toolchain_layout", "kira_toolchain", "kira_dynamic_ffi", "kira_ksl_syntax_model", "kira_ksl_parser", "kira_ksl_semantics", "kira_shader_ir", "kira_shader_model", "kira_glsl_backend", "kira_wgsl_backend", "kira_hlsl_backend", "kira_msl_backend", "kira_spirv_backend" } },
    .{ .name = "kira_instruments", .path = "packages/kira_instruments/src/root.zig", .imports = &.{} },
    .{ .name = "kira_linter", .path = "packages/kira_linter/src/root.zig", .imports = &.{ "kira_core", "kira_diagnostics", "kira_parser", "kira_semantics" } },
    .{ .name = "kira_doc", .path = "packages/kira_doc/src/root.zig", .imports = &.{ "kira_core", "kira_parser", "kira_semantics" } },
    .{ .name = "kira_app_generation", .path = "packages/kira_app_generation/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_main", .path = "packages/kira_main/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_runtime_abi", "kira_hybrid_definition", "kira_bytecode", "kira_vm_runtime", "kira_native_bridge", "kira_hybrid_runtime", "kira_build", "kira_build_definition", "kira_diagnostics", "kira_project", "kira_manifest", "kira_syntax_model", "kira_parser" } },
    .{ .name = "kira_live", .path = "packages/kira_live/src/root.zig", .imports = &.{ "kira_build", "kira_build_definition", "kira_bytecode", "kira_diagnostics", "kira_diagnostic_messages", "kira_hybrid_definition", "kira_hybrid_runtime", "kira_ir", "kira_llvm_backend", "kira_manifest", "kira_native_lib_definition", "kira_package_manager", "kira_project", "kira_wasm_runtime" } },
    .{ .name = "kira_cli", .path = "packages/kira_cli/src/main.zig", .imports = &.{ "kira_core", "kira_source", "kira_diagnostics", "kira_diagnostic_messages", "kira_syntax_model", "kira_lexer", "kira_parser", "kira_semantics", "kira_ir", "kira_bytecode", "kira_vm_runtime", "kira_build", "kira_build_definition", "kira_hybrid_runtime", "kira_runtime_abi", "kira_app_generation", "kira_live", "kira_log", "kira_toolchain", "kira_project", "kira_package_manager", "kira_manifest", "kira_native_lib_definition", "kira_ksl_syntax_model", "kira_shader_model", "kira_instruments", "kira_wasm_runtime", "kira_main", "kira_debug" } },
};

fn applyImports(module: *std.Build.Module, modules: *std.StringArrayHashMapUnmanaged(*std.Build.Module), names: []const []const u8) void {
    for (names) |name| {
        module.addImport(name, modules.get(name).?);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = preferredDefaultTarget(b.graph.host.result),
    });
    const optimize = b.standardOptimizeOption(.{});
    const apple_sdk = b.option([]const u8, "apple-sdk", "Apple SDK sysroot path used when cross-compiling generated runner support") orelse "";
    const channel = channelForOptimize(optimize);
    const repo_root = b.pathFromRoot("");
    const metadata = llvm_metadata.parseFile(b.allocator, b.pathFromRoot("llvm-metadata.toml")) catch
        @panic("failed to parse llvm-metadata.toml");
    const llvm_version = metadata.llvm_version;
    const llvm_host_key = toolchain_layout.hostLlvmBundleKey(b.graph.host.result) orelse "unsupported-host";
    const llvm_headers = llvm_probe.discoverLlvmHeaders(b.allocator, repo_root, llvm_version, llvm_host_key, b.graph.environ_map.get("KIRA_LLVM_HOME"));
    var modules: std.StringArrayHashMapUnmanaged(*std.Build.Module) = .empty;
    defer modules.deinit(b.allocator);
    // Interpreter-hot packages are compiled ReleaseFast even in Debug builds:
    // the Debug dev snapshot is what `kira run` uses for interactive UI work
    // (live apps, resize/layout frames), and a Debug interpreter is 4-11x
    // slower than an optimized one (tag/bounds checks alone cost ~7x in the
    // dispatch loop, so ReleaseSafe is not enough). Unit tests still exercise
    // these packages with full safety: the test step builds its own
    // safety-mode variants below. Pass -Dvm-debug to debug the VM runtime
    // itself with full Debug codegen.
    const vm_debug = b.option(bool, "vm-debug", "Compile the VM runtime packages with Debug codegen (default: ReleaseFast inside Debug builds for usable `kira run` performance)") orelse false;
    const runtime_hot_optimize: std.builtin.OptimizeMode = if (optimize == .Debug and !vm_debug) .ReleaseFast else optimize;

    for (packages) |pkg| {
        const pkg_optimize = if (isRuntimeHotPackage(pkg.name)) runtime_hot_optimize else optimize;
        const module = b.createModule(.{
            .root_source_file = b.path(pkg.path),
            .target = target,
            .optimize = pkg_optimize,
        });
        modules.put(b.allocator, pkg.name, module) catch @panic("failed to register module");
    }

    for (packages) |pkg| {
        applyImports(modules.get(pkg.name).?, &modules, pkg.imports);
    }

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "repo_root", repo_root);
    modules.get("kira_build").?.addOptions("kira_build_build_options", build_options);

    const llvm_options = b.addOptions();
    llvm_options.addOption([]const u8, "repo_root", repo_root);
    llvm_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    llvm_options.addOption([]const u8, "llvm_version", llvm_version);
    llvm_options.addOption([]const u8, "llvm_host_key", llvm_host_key);
    llvm_options.addOption([]const u8, "kira_channel", channel.dirName());
    llvm_options.addOption([]const u8, "kira_version", kirac_version);
    modules.get("kira_llvm_backend").?.addOptions("kira_llvm_build_options", llvm_options);
    modules.get("kira_llvm_backend").?.link_libc = true;

    // kira_dynamic_ffi resolves process symbols via dlfcn/dlsym (@cImport of
    // <dlfcn.h>) and drives libffi, so it needs libc headers + linkage. The
    // main `kira` snapshot links libc transitively through other modules, but
    // the isolated unit-test compiles for this package and kira_native_bridge
    // do not, which fails on hosts without an implicitly-linked libc (Linux).
    modules.get("kira_dynamic_ffi").?.link_libc = true;
    // The native hardware-debug controllers call into libc/Mach/ptrace/Win32.
    modules.get("kira_debug").?.link_libc = true;

    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "binary_name", kira_bootstrapper_name);
    cli_options.addOption([]const u8, "version", kirac_version);
    cli_options.addOption([]const u8, "channel", channel.dirName());
    cli_options.addOption([]const u8, "primary_executable", kira_primary_executable);
    modules.get("kira_cli").?.addOptions("kira_cli_build_options", cli_options);

    const live_options = b.addOptions();
    live_options.addOption([]const u8, "repo_root", repo_root);
    live_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    live_options.addOption([]const u8, "static_file_server_path", b.getInstallPath(.bin, "kira-static-file-server"));
    modules.get("kira_live").?.addOptions("kira_live_build_options", live_options);

    if (llvm_headers) |probe| {
        for (probe.include_dirs) |dir| {
            modules.get("kira_llvm_backend").?.addIncludePath(.{ .cwd_relative = dir });
        }
        if (probe.library_dir) |dir| {
            if (probe.link_name) |name| {
                const llvm_backend = modules.get("kira_llvm_backend").?;
                llvm_backend.addLibraryPath(.{ .cwd_relative = dir });
                llvm_backend.linkSystemLibrary(name, .{
                    .use_pkg_config = .no,
                    .preferred_link_mode = .dynamic,
                    .search_strategy = .paths_first,
                });
                if (target.result.os.tag != .windows) {
                    llvm_backend.addRPath(.{ .cwd_relative = dir });
                }
            }
        }
    }
    if (apple_sdk.len > 0) {
        const apple_include = std.fs.path.join(b.allocator, &.{ apple_sdk, "usr", "include" }) catch @panic("failed to build Apple SDK include path");
        modules.get("kira_native_bridge").?.addSystemIncludePath(.{ .cwd_relative = apple_include });
    }

    const cli = b.addExecutable(.{
        .name = kira_primary_executable,
        .root_module = modules.get("kira_cli").?,
    });
    // Export the executable's dynamic symbol table. `kira test` resolves the
    // in-process developer/native API (e.g. `kira_developer_*`, statically
    // linked from kira_main) through `dlsym(RTLD_DEFAULT, ...)`. On ELF hosts
    // those symbols are invisible to `dlsym` unless the main executable is
    // linked with `-rdynamic`/`-Wl,-export-dynamic`, so without this the
    // in-process FFI path fails with `MissingNativeSymbol` on Linux (macOS
    // resolves process-image symbols regardless). Additive only: it exports
    // more symbols, never removes any.
    cli.rdynamic = true;
    // The VM interpreter recurses on the native stack once per Kira call frame
    // with a large dispatch frame (~72 KiB — thousands of uncoalesced slots
    // across the threaded switch). The S6 recursion guard allows 256 nested
    // calls, which needs ~18 MiB of headroom plus margin; the platform default
    // main-thread stack sits below that and segfaults before the guard can
    // raise its clean RuntimeFailure. 64 MiB keeps the overflow cliff far
    // above the guard even if the dispatch frame grows further.
    cli.stack_size = 64 * 1024 * 1024;

    const bootstrapper_options = b.addOptions();
    bootstrapper_options.addOption([]const u8, "version", kirac_version);
    bootstrapper_options.addOption([]const u8, "channel", channel.dirName());
    bootstrapper_options.addOption([]const u8, "llvm_version", llvm_version);
    bootstrapper_options.addOption([]const u8, "llvm_host_key", llvm_host_key);
    bootstrapper_options.addOption([]const u8, "release_repository", kira_repository);
    const bootstrapper_module = b.createModule(.{
        .root_source_file = b.path("packages/kira_bootstrapper/src/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    bootstrapper_module.addImport("kira_toolchain", modules.get("kira_toolchain").?);
    bootstrapper_module.addOptions("kira_bootstrapper_build_options", bootstrapper_options);
    bootstrapper_module.link_libc = true;
    const bootstrapper = b.addExecutable(.{
        .name = kira_bootstrapper_name,
        .root_module = bootstrapper_module,
    });
    const install_bootstrapper = b.addInstallArtifact(bootstrapper, .{});

    const bootstrapper_install_path = b.getInstallPath(.bin, hostExecutableName(b.graph.host.result, kira_bootstrapper_name));
    const bootstrapper_install_dir = std.fs.path.dirname(bootstrapper_install_path) orelse ".";
    const install_toolchain_step = managed_install.addManagedToolchainInstallStep(
        b,
        b.graph.host.result,
        cli,
        bootstrapper,
        kirac_version,
        channel.dirName(),
        b.path("llvm-metadata.toml"),
        b.path("templates"),
        b.path("foundation"),
        b.path("packages/kira_main/include"),
        bootstrapper_install_dir,
    );

    b.getInstallStep().dependOn(&install_bootstrapper.step);
    b.getInstallStep().dependOn(&install_toolchain_step.step);

    const kirac_step = b.step("kirac", "Build the standalone kirac executable");
    kirac_step.dependOn(&cli.step);

    const bootstrapper_step = b.step("kira-bootstrapper", "Build the kira-bootstrapper launcher");
    bootstrapper_step.dependOn(&bootstrapper.step);

    const install_kirac_step = b.step("install-kirac", "Install the active Kira toolchain and kira-bootstrapper");
    install_kirac_step.dependOn(&install_toolchain_step.step);

    const kira_main = b.addLibrary(.{
        .linkage = .static,
        .name = "kira_main",
        .root_module = modules.get("kira_main").?,
    });
    b.installArtifact(kira_main);
    kira_main.installHeadersDirectory(b.path("packages/kira_main/include"), "", .{});

    const live_support_module = b.createModule(.{
        .root_source_file = b.path("packages/kira_live/src/runner_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_support_module.addImport("kira_hybrid_definition", modules.get("kira_hybrid_definition").?);
    live_support_module.addImport("kira_hybrid_runtime", modules.get("kira_hybrid_runtime").?);
    live_support_module.addImport("kira_bytecode", modules.get("kira_bytecode").?);
    live_support_module.link_libc = true;
    const live_support_c_flags: []const []const u8 = if (apple_sdk.len > 0) &.{ "-isysroot", apple_sdk } else &.{};
    if (apple_sdk.len > 0) live_support_module.addSystemIncludePath(.{ .cwd_relative = std.fs.path.join(b.allocator, &.{ apple_sdk, "usr", "include" }) catch @panic("failed to build Apple SDK include path") });

    const live_support = b.addLibrary(.{
        .linkage = .static,
        .name = "kira_live_runner_support",
        .root_module = live_support_module,
    });
    live_support.root_module.addCSourceFile(.{
        .file = b.path("packages/kira_native_bridge/src/runtime_helpers.c"),
        .flags = live_support_c_flags,
    });
    const install_live_support = b.addInstallArtifact(live_support, .{});

    const live_desktop_module = b.createModule(.{
        .root_source_file = b.path("packages/kira_live/src/desktop_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_desktop_module.addImport("kira_hybrid_definition", modules.get("kira_hybrid_definition").?);
    live_desktop_module.addImport("kira_hybrid_runtime", modules.get("kira_hybrid_runtime").?);
    live_desktop_module.link_libc = true;
    const live_desktop_runner = b.addExecutable(.{
        .name = "kira-live-desktop-runner",
        .root_module = live_desktop_module,
    });
    const install_live_desktop_runner = b.addInstallArtifact(live_desktop_runner, .{});
    const static_file_server_module = b.createModule(.{ .root_source_file = b.path("packages/kira_live/src/static_file_server.zig"), .target = target, .optimize = optimize });
    const static_file_server = b.addExecutable(.{ .name = "kira-static-file-server", .root_module = static_file_server_module });
    _ = b.addInstallArtifact(static_file_server, .{});

    const run_cmd = b.addRunArtifact(cli);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the kirac CLI");
    run_step.dependOn(&run_cmd.step);

    const fetch_llvm_options = b.addOptions();
    fetch_llvm_options.addOption([]const u8, "repo_root", repo_root);
    const fetch_llvm_module = b.createModule(.{
        .root_source_file = b.path("packages/kira_build/src/fetch_llvm_main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    fetch_llvm_module.addImport("kira_llvm_toolchain_layout", modules.get("kira_llvm_toolchain_layout").?);
    fetch_llvm_module.addImport("kira_toolchain", modules.get("kira_toolchain").?);
    fetch_llvm_module.link_libc = true;
    const fetch_llvm_tool = b.addExecutable(.{
        .name = "fetch-llvm",
        .root_module = fetch_llvm_module,
    });
    fetch_llvm_tool.root_module.addOptions("fetch_llvm_build_options", fetch_llvm_options);
    const fetch_llvm_run = b.addRunArtifact(fetch_llvm_tool);
    if (b.args) |args| fetch_llvm_run.addArgs(args);
    const fetch_llvm_step = b.step("fetch-llvm", "Download and install the pinned LLVM toolchain");
    fetch_llvm_step.dependOn(&fetch_llvm_run.step);

    const fetch_libffi_options = b.addOptions();
    fetch_libffi_options.addOption([]const u8, "repo_root", repo_root);
    const fetch_libffi_module = b.createModule(.{
        .root_source_file = b.path("packages/kira_build/src/fetch_libffi_main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    fetch_libffi_module.addImport("kira_llvm_toolchain_layout", modules.get("kira_llvm_toolchain_layout").?);
    fetch_libffi_module.addImport("kira_toolchain", modules.get("kira_toolchain").?);
    fetch_libffi_module.link_libc = true;
    const fetch_libffi_tool = b.addExecutable(.{
        .name = "fetch-libffi",
        .root_module = fetch_libffi_module,
    });
    fetch_libffi_tool.root_module.addOptions("fetch_libffi_build_options", fetch_libffi_options);
    const fetch_libffi_run = b.addRunArtifact(fetch_libffi_tool);
    if (b.args) |args| fetch_libffi_run.addArgs(args);
    const fetch_libffi_step = b.step("fetch-libffi", "Download and install the pinned LibFFI toolchain");
    fetch_libffi_step.dependOn(&fetch_libffi_run.step);

    const devflow_module = b.createModule(.{
        .root_source_file = b.path("packages/kira_devflow/src/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    devflow_module.link_libc = true;
    const devflow_tool = b.addExecutable(.{ .name = "devflow", .root_module = devflow_module });
    const devflow_run = b.addRunArtifact(devflow_tool);
    if (b.args) |args| devflow_run.addArgs(args);
    const devflow_step = b.step("devflow", "Run the fork/upstream PR flow automation");
    devflow_step.dependOn(&devflow_run.step);

    const devflow_test_module = b.createModule(.{
        .root_source_file = b.path("packages/kira_devflow/src/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    devflow_test_module.link_libc = true;
    const devflow_test = b.addTest(.{ .root_module = devflow_test_module });
    const devflow_test_run = b.addRunArtifact(devflow_test);
    const devflow_test_step = b.step("devflow-test", "Run devflow unit tests");
    devflow_test_step.dependOn(&devflow_test_run.step);

    const live_support_step = b.step("live-runner-support", "Build the generic live runner support static library");
    live_support_step.dependOn(&install_live_support.step);
    const live_desktop_step = b.step("live-desktop-runner", "Build the generic desktop live runner executable");
    live_desktop_step.dependOn(&install_live_desktop_runner.step);

    // Repository-purity policy gate. Relocated out of the deleted legacy tests/
    // tree into build_support/; a self-contained repo-wide scan that rejects
    // Python, root Zig clutter, and fake-success markers, kept wired into
    // `zig build test` as a repository policy check.
    //
    // The former platform-validation-matrix and memory-validation harnesses were
    // deleted with tests/: their evidence tables asserted tokens *inside* tests/
    // internals (tests/discovery.zig, tests/execute.zig, corpus expect.toml), so
    // they could not survive the tree's removal without a rewrite. The VM
    // heap-cleanup guarantee memory-validation cross-checked still runs directly
    // in the kira_vm_runtime unit tests (`expectEqual(0, heap.count())`), and the
    // runtime leak dimension is now gated by `kira test`'s KIRA_TEST_CHECK_LEAKS
    // mode over the tests-kik suites.
    const repository_truth_module = b.createModule(.{ .root_source_file = b.path("build_support/repository_truth.zig"), .target = target, .optimize = optimize });
    const repository_truth = b.addExecutable(.{ .name = "kira-repository-truth", .root_module = repository_truth_module });
    const repo_truth_cmd = b.addRunArtifact(repository_truth);
    const repo_truth_step = b.step("repo-truth", "Reject Python, root Zig clutter, and fake validation markers");
    repo_truth_step.dependOn(&repo_truth_cmd.step);

    const test_step = b.step("test", "Run package unit tests and repository policy checks");
    // `zig build` is the documented workflow for refreshing the development
    // snapshot that the `kira` bootstrapper launches from ~/.kira/toolchains.
    // Keep the managed kirac install in lock-step with source changes before
    // running the default validation step.
    test_step.dependOn(&install_toolchain_step.step);
    test_step.dependOn(&repo_truth_cmd.step);
    // Unit tests for the interpreter-hot packages run against safety-mode
    // variants (full optimize-mode checks), independent of the ReleaseFast
    // modules the `kira` snapshot ships with.
    var safety_test_modules: std.StringArrayHashMapUnmanaged(*std.Build.Module) = .empty;
    defer safety_test_modules.deinit(b.allocator);
    for (test_roots) |name| {
        const root_module = if (isRuntimeHotPackage(name))
            safetyTestModule(b, name, &modules, &safety_test_modules, target, optimize)
        else
            modules.get(name).?;
        const unit_tests = b.addTest(.{
            .root_module = root_module,
        });
        const run_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_tests.step);
    }

    const main_test_step = b.step("test-main", "Run only the kira_main unit tests");
    const main_test_module = modules.get("kira_main").?;
    const main_unit_tests = b.addTest(.{ .root_module = main_test_module });
    const run_main_tests = b.addRunArtifact(main_unit_tests);
    main_test_step.dependOn(&run_main_tests.step);

    const vm_runtime_test_step = b.step("test-vm-runtime", "Run only the kira_vm_runtime unit tests");
    const vm_runtime_test_module = safetyTestModule(b, "kira_vm_runtime", &modules, &safety_test_modules, target, optimize);
    const vm_runtime_unit_tests = b.addTest(.{
        .root_module = vm_runtime_test_module,
    });
    const run_vm_runtime_tests = b.addRunArtifact(vm_runtime_unit_tests);
    vm_runtime_test_step.dependOn(&run_vm_runtime_tests.step);

    const bootstrapper_tests = b.addTest(.{
        .root_module = bootstrapper_module,
    });
    const run_bootstrapper_tests = b.addRunArtifact(bootstrapper_tests);
    // The legacy tests/ corpus (corpus_main.zig, hybrid_runner.zig) and the
    // test-backends / test-full steps that drove it were deleted. User-visible
    // behavior — stdout parity, the fail/diagnostic corpus, check-surface, the
    // backend matrix, and the leak gate — is now covered by the Kira-native
    // tests-kik suites run through `kira test` (parity mode, FailTests incl.
    // fixtures, KIRA_TEST_CHECK_LEAKS). `zig build test` is package unit tests
    // plus the repo-purity gate; the bootstrapper unit tests are folded in here
    // so their coverage is preserved.
    test_step.dependOn(&run_bootstrapper_tests.step);

    b.default_step = b.getInstallStep(); // Default to build + install, not tests
}

fn preferredDefaultTarget(host: std.Target) std.Target.Query {
    return switch (host.os.tag) {
        .windows => .{
            .cpu_arch = host.cpu.arch,
            .os_tag = .windows,
            .abi = .msvc,
        },
        else => .{},
    };
}

fn hostExecutableName(host: std.Target, base_name: []const u8) []const u8 {
    return if (host.os.tag == .windows)
        std.fmt.allocPrint(std.heap.page_allocator, "{s}.exe", .{base_name}) catch @panic("out of memory")
    else
        base_name;
}

/// Builds (and memoizes) a module for `name` compiled with the requested
/// optimize mode for unit testing, recursively giving the runtime-hot
/// dependencies safety-mode variants too; everything else reuses the main
/// module map.
fn safetyTestModule(
    b: *std.Build,
    name: []const u8,
    main_modules: *std.StringArrayHashMapUnmanaged(*std.Build.Module),
    safety_modules: *std.StringArrayHashMapUnmanaged(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    if (safety_modules.get(name)) |existing| return existing;
    const pkg = for (packages) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) break candidate;
    } else @panic("unknown runtime-hot package");
    if (!isRuntimeHotPackage(name) and !dependsOnRuntimeHotPackage(pkg)) return main_modules.get(name).?;
    const module = b.createModule(.{
        .root_source_file = b.path(pkg.path),
        .target = target,
        .optimize = optimize,
    });
    if (std.mem.eql(u8, name, "kira_vm_runtime")) module.link_libc = true;
    safety_modules.put(b.allocator, name, module) catch @panic("failed to register safety test module");
    for (pkg.imports) |import_name| {
        module.addImport(import_name, safetyTestModule(b, import_name, main_modules, safety_modules, target, optimize));
    }
    return module;
}

/// Packages on the per-frame interpreter/bridge hot path of `kira run`.
fn isRuntimeHotPackage(name: []const u8) bool {
    const hot = [_][]const u8{
        "kira_vm_runtime",
        "kira_runtime_abi",
        "kira_bytecode",
        "kira_hybrid_runtime",
    };
    for (hot) |hot_name| {
        if (std.mem.eql(u8, name, hot_name)) return true;
    }
    return false;
}

fn dependsOnRuntimeHotPackage(pkg: Package) bool {
    for (pkg.imports) |import_name| {
        if (isRuntimeHotPackage(import_name)) return true;
    }
    return false;
}

fn channelForOptimize(optimize: std.builtin.OptimizeMode) kira_toolchain.Channel {
    return switch (optimize) {
        .Debug => .dev,
        .ReleaseSmall, .ReleaseFast, .ReleaseSafe => .release,
    };
}
