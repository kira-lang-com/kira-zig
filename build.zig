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
    .{ .name = "kira_semantics_model", .path = "packages/kira_semantics_model/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model" } },
    .{ .name = "kira_semantics", .path = "packages/kira_semantics/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_syntax_model", "kira_diagnostics", "kira_semantics_model" } },
    .{ .name = "kira_ir", .path = "packages/kira_ir/src/root.zig", .imports = &.{ "kira_core", "kira_semantics_model" } },
    .{ .name = "kira_hybrid_definition", .path = "packages/kira_hybrid_definition/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi" } },
    .{ .name = "kira_native_lib_definition", .path = "packages/kira_native_lib_definition/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi" } },
    .{ .name = "kira_backend_api", .path = "packages/kira_backend_api/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_native_lib_definition" } },
    .{ .name = "kira_bytecode", .path = "packages/kira_bytecode/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_runtime_abi" } },
    .{ .name = "kira_vm_runtime", .path = "packages/kira_vm_runtime/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_bytecode" } },
    .{ .name = "kira_native_bridge", .path = "packages/kira_native_bridge/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_native_lib_definition" } },
    .{ .name = "kira_hybrid_runtime", .path = "packages/kira_hybrid_runtime/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_native_bridge", "kira_vm_runtime", "kira_bytecode" } },
    .{ .name = "kira_llvm_backend", .path = "packages/kira_llvm_backend/src/root.zig", .imports = &.{ "kira_core", "kira_ir", "kira_backend_api", "kira_native_lib_definition" } },
    .{ .name = "kira_manifest", .path = "packages/kira_manifest/src/root.zig", .imports = &.{ "kira_core", "kira_native_lib_definition" } },
    .{ .name = "kira_project", .path = "packages/kira_project/src/root.zig", .imports = &.{ "kira_core", "kira_manifest" } },
    .{ .name = "kira_build_definition", .path = "packages/kira_build_definition/src/root.zig", .imports = &.{ "kira_core", "kira_native_lib_definition" } },
    .{ .name = "kira_build", .path = "packages/kira_build/src/root.zig", .imports = &.{ "kira_core", "kira_source", "kira_diagnostics", "kira_syntax_model", "kira_lexer", "kira_parser", "kira_semantics", "kira_ir", "kira_bytecode", "kira_vm_runtime", "kira_manifest", "kira_project", "kira_build_definition", "kira_backend_api", "kira_native_lib_definition" } },
    .{ .name = "kira_linter", .path = "packages/kira_linter/src/root.zig", .imports = &.{ "kira_core", "kira_diagnostics", "kira_parser", "kira_semantics" } },
    .{ .name = "kira_doc", .path = "packages/kira_doc/src/root.zig", .imports = &.{ "kira_core", "kira_parser", "kira_semantics" } },
    .{ .name = "kira_app_generation", .path = "packages/kira_app_generation/src/root.zig", .imports = &.{"kira_core"} },
    .{ .name = "kira_main", .path = "packages/kira_main/src/root.zig", .imports = &.{ "kira_core", "kira_runtime_abi", "kira_hybrid_definition", "kira_bytecode", "kira_vm_runtime", "kira_native_bridge", "kira_hybrid_runtime" } },
    .{ .name = "kira_cli", .path = "packages/kira_cli/src/main.zig", .imports = &.{ "kira_core", "kira_source", "kira_diagnostics", "kira_syntax_model", "kira_lexer", "kira_parser", "kira_semantics", "kira_ir", "kira_bytecode", "kira_vm_runtime", "kira_build", "kira_app_generation" } },
};

fn applyImports(module: *std.Build.Module, modules: *std.StringArrayHashMap(*std.Build.Module), names: []const []const u8) void {
    for (names) |name| {
        module.addImport(name, modules.get(name).?);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
