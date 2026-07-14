const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostics = @import("kira_diagnostics");
const syntax = @import("kira_syntax_model");
const lexer = @import("kira_lexer");
const parser = @import("kira_parser");
const native = @import("kira_native_lib_definition");

const dependency = @import("dependency.zig");
const platform_config = @import("platform_config.zig");
const tests_config = @import("tests_config.zig");
const ProjectManifest = @import("project_manifest.zig").ProjectManifest;
const PackageKind = @import("project_manifest.zig").PackageKind;
const Loader = @import("declaration_loader_state.zig").Loader;

const Diagnostic = diagnostics.Diagnostic;
const Span = source_pkg.Span;
const Expr = syntax.ast.Expr;

/// The result of a declaration-manifest load. `manifest` is meaningful only when
/// `diagnostics.len == 0`; otherwise the diagnostics describe every schema
/// violation found (unknown field, wrong literal type, non-literal initializer,
/// unknown enum value, ...), each carrying a source span.
pub const LoadResult = struct {
    manifest: ProjectManifest,
    diagnostics: []const Diagnostic,

    /// True when no error-severity diagnostics were produced. Warnings (e.g. an
    /// ignored `output` field) do not make the manifest unusable.
    pub fn ok(self: LoadResult) bool {
        for (self.diagnostics) |d| {
            if (d.severity == .@"error") return false;
        }
        return true;
    }

    /// Count of error-severity diagnostics.
    pub fn errorCount(self: LoadResult) usize {
        var count: usize = 0;
        for (self.diagnostics) |d| {
            if (d.severity == .@"error") count += 1;
        }
        return count;
    }
};

/// Load a `package.kira` declaration manifest into the same `ProjectManifest`
/// model the TOML loader produces. Parses with the Kira lexer+parser only (no
/// semantic analysis) and statically walks the `Package <Name> { let ... }`
/// declaration. `source_path` is used for span attribution in diagnostics.
///
/// The returned `LoadResult` owns everything out of `allocator`; callers should
/// use an arena. A clean load has `diagnostics.len == 0`.
pub fn loadProjectManifestFromDeclaration(
    allocator: std.mem.Allocator,
    text: []const u8,
    source_path: []const u8,
) !LoadResult {
    var loader = Loader{
        .allocator = allocator,
        .diags = std.array_list.Managed(Diagnostic).init(allocator),
        .source_path = source_path,
    };

    var source = try source_pkg.SourceFile.initOwned(allocator, source_path, text);
    defer source.deinit();

    var parse_diags = std.array_list.Managed(Diagnostic).init(allocator);
    const tokens = lexer.tokenize(allocator, &source, &parse_diags) catch |e| switch (e) {
        error.DiagnosticsEmitted => return failedResult(try parse_diags.toOwnedSlice()),
        else => return e,
    };
    const program = parser.parse(allocator, tokens, &parse_diags) catch |e| switch (e) {
        error.DiagnosticsEmitted => return failedResult(try parse_diags.toOwnedSlice()),
        else => return e,
    };

    var manifest = ProjectManifest{ .name = "", .version = "0.1.0" };
    manifest.kind = .app;

    var found = false;
    for (program.decls) |decl| {
        if (decl != .construct_form_decl) continue;
        const form = decl.construct_form_decl;
        if (!isPackageForm(form)) continue;
        if (found) {
            try loader.err(form.span, "KMAN010", "duplicate Package declaration", "A package.kira manifest must declare exactly one Package.");
            continue;
        }
        found = true;
        try applyPackage(&loader, &manifest, form);
    }

    if (!found) {
        const span = if (program.decls.len > 0) declSpan(program.decls[0]) else Span.init(0, 0);
        try loader.err(span, "KMAN001", "missing Package declaration", "A package.kira manifest must contain a `Package <Name> { ... }` declaration.");
    }

    return .{ .manifest = manifest, .diagnostics = try loader.diags.toOwnedSlice() };
}

/// Load a `ProjectManifest` from an already-read manifest file's text,
/// dispatching on the file name: `package.kira` uses the declaration loader (and
/// returns `error.InvalidManifest` on any schema error), every other name uses
/// the TOML parser. This is the single entry point every manifest-discovery site
/// should call so `package.kira` precedence is honored uniformly.
pub fn loadProjectManifestFromText(
    allocator: std.mem.Allocator,
    text: []const u8,
    manifest_path: []const u8,
) !ProjectManifest {
    if (std.mem.eql(u8, std.fs.path.basename(manifest_path), "package.kira")) {
        const result = try loadProjectManifestFromDeclaration(allocator, text, manifest_path);
        if (!result.ok()) return error.InvalidManifest;
        return result.manifest;
    }
    return @import("parser.zig").parseProjectManifest(allocator, text);
}

fn failedResult(diags: []const Diagnostic) LoadResult {
    return .{ .manifest = ProjectManifest{ .name = "", .version = "0.1.0" }, .diagnostics = diags };
}

fn isPackageForm(form: syntax.ast.ConstructFormDecl) bool {
    const segments = form.construct_name.segments;
    return segments.len != 0 and std.mem.eql(u8, segments[segments.len - 1].text, "Package");
}

fn declSpan(decl: syntax.ast.Decl) Span {
    return switch (decl) {
        inline else => |d| d.span,
    };
}

fn applyPackage(loader: *Loader, manifest: *ProjectManifest, form: syntax.ast.ConstructFormDecl) !void {
    // The declaration name is the package name.
    manifest.name = try loader.allocator.dupe(u8, form.name);

    for (form.body.members) |member| {
        if (member != .field_decl) {
            try loader.err(memberSpan(member), "KMAN002", "unsupported manifest member", "Only `let <field> = <literal>` entries are allowed in a Package declaration.");
            continue;
        }
        const field = member.field_decl;
        const value = field.value orelse {
            try loader.err(field.span, "KMAN003", "missing field initializer", "Every Package field must have a literal initializer.");
            continue;
        };

        if (std.mem.eql(u8, field.name, "version")) {
            if (try stringValue(loader, value)) |v| manifest.version = v;
        } else if (std.mem.eql(u8, field.name, "kind")) {
            if (try enumValue(loader, value, "PackageKind")) |variant| {
                manifest.kind = parsePackageKind(variant) orelse {
                    try loader.err(exprSpan(value), "KMAN005", "unknown PackageKind", "Expected PackageKind.App or PackageKind.Library.");
                    continue;
                };
            }
        } else if (std.mem.eql(u8, field.name, "kira")) {
            if (try stringValue(loader, value)) |v| manifest.kira_version = v;
        } else if (std.mem.eql(u8, field.name, "moduleRoot") or std.mem.eql(u8, field.name, "module_root")) {
            if (try stringValue(loader, value)) |v| manifest.module_root = v;
        } else if (std.mem.eql(u8, field.name, "defaults")) {
            try applyDefaults(loader, manifest, value);
        } else if (std.mem.eql(u8, field.name, "tests")) {
            try applyTests(loader, manifest, value);
        } else if (std.mem.eql(u8, field.name, "dependencies")) {
            try applyDependencies(loader, manifest, value);
        } else if (std.mem.eql(u8, field.name, "nativeLibraries") or std.mem.eql(u8, field.name, "native_libraries")) {
            try applyNativeLibraries(loader, manifest, value);
        } else if (std.mem.eql(u8, field.name, "assets")) {
            manifest.assets = try stringArray(loader, value);
        } else {
            try loader.err(field.span, "KMAN004", "unknown Package field", "This field is not part of the package.kira schema.");
        }
    }
}

fn applyDefaults(loader: *Loader, manifest: *ProjectManifest, value: *Expr) !void {
    const fields = (try structValue(loader, value, "Defaults")) orelse return;
    for (fields.fields) |f| {
        if (std.mem.eql(u8, f.name, "executionMode") or std.mem.eql(u8, f.name, "execution_mode")) {
            if (try enumValue(loader, f.value, "Backend")) |variant| {
                if (backendMode(variant)) |mode| {
                    manifest.execution_mode = try loader.allocator.dupe(u8, mode);
                    if (platform_config.ExecutionBackend.parse(mode)) |eb| {
                        manifest.execution_policy.default_backend = eb;
                        manifest.execution_policy.default_source = .app_manifest;
                    }
                } else {
                    try loader.err(exprSpan(f.value), "KMAN006", "unknown Backend", "Expected Backend.Vm, Backend.Llvm, Backend.Hybrid, or Backend.Wasm.");
                }
            }
        } else if (std.mem.eql(u8, f.name, "buildTarget") or std.mem.eql(u8, f.name, "build_target")) {
            if (try enumValue(loader, f.value, "BuildTarget")) |variant| {
                manifest.build_target = try loader.allocator.dupe(u8, lowerFirst(loader.allocator, variant) catch variant);
            }
        } else {
            try loader.err(f.span, "KMAN004", "unknown Defaults field", "This field is not part of the Defaults schema.");
        }
    }
}

fn applyTests(loader: *Loader, manifest: *ProjectManifest, value: *Expr) !void {
    const fields = (try structValue(loader, value, "Tests")) orelse return;

    var backends = std.array_list.Managed(platform_config.Backend).init(loader.allocator);
    var phase: tests_config.TestPhase = .run;
    var saw_backends = false;

    for (fields.fields) |f| {
        if (std.mem.eql(u8, f.name, "backends")) {
            saw_backends = true;
            const elements = (try arrayElements(loader, f.value)) orelse continue;
            for (elements) |el| {
                if (try enumValue(loader, el, "Backend")) |variant| {
                    if (backendEnum(variant)) |b| {
                        try backends.append(b);
                    } else {
                        try loader.err(exprSpan(el), "KMAN006", "unsupported test backend", "Test backends are Backend.Vm, Backend.Llvm, or Backend.Hybrid.");
                    }
                }
            }
        } else if (std.mem.eql(u8, f.name, "phase")) {
            if (try enumValue(loader, f.value, "TestPhase")) |variant| {
                phase = tests_config.TestPhase.parse(variant) orelse {
                    try loader.err(exprSpan(f.value), "KMAN007", "unknown TestPhase", "Expected TestPhase.Check, TestPhase.Run, or TestPhase.Both.");
                    continue;
                };
            }
        } else {
            try loader.err(f.span, "KMAN004", "unknown Tests field", "This field is not part of the Tests schema.");
        }
    }

    if (!saw_backends) {
        try loader.err(exprSpan(value), "KMAN008", "Tests requires backends", "A Tests declaration must list at least one backend.");
        return;
    }
    manifest.tests = .{ .backends = try backends.toOwnedSlice(), .phase = phase };
}

fn applyDependencies(loader: *Loader, manifest: *ProjectManifest, value: *Expr) !void {
    const elements = (try arrayElements(loader, value)) orelse return;
    var deps = std.array_list.Managed(dependency.DependencySpec).init(loader.allocator);
    for (elements) |el| {
        const lit = (try structValue(loader, el, "Dependency")) orelse continue;
        var name: ?[]const u8 = null;
        var version: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var git: ?[]const u8 = null;
        var rev: ?[]const u8 = null;
        var tag: ?[]const u8 = null;
        for (lit.fields) |f| {
            if (std.mem.eql(u8, f.name, "name")) {
                name = try stringValue(loader, f.value);
            } else if (std.mem.eql(u8, f.name, "version")) {
                version = try stringValue(loader, f.value);
            } else if (std.mem.eql(u8, f.name, "path")) {
                path = try stringValue(loader, f.value);
            } else if (std.mem.eql(u8, f.name, "git")) {
                git = try stringValue(loader, f.value);
            } else if (std.mem.eql(u8, f.name, "rev")) {
                rev = try stringValue(loader, f.value);
            } else if (std.mem.eql(u8, f.name, "tag")) {
                tag = try stringValue(loader, f.value);
            } else {
                try loader.err(f.span, "KMAN004", "unknown Dependency field", "This field is not part of the Dependency schema.");
            }
        }
        if (name == null) {
            try loader.err(exprSpan(el), "KMAN009", "Dependency requires name", "Every Dependency must declare a name.");
            continue;
        }
        const source_count = @as(u8, if (path != null) 1 else 0) + @as(u8, if (version != null) 1 else 0) + @as(u8, if (git != null) 1 else 0);
        if (source_count > 1) {
            try loader.err(exprSpan(el), "KMAN009", "Dependency has multiple sources", "A Dependency must declare exactly one of version, path, or git.");
        } else if (path) |p| {
            try deps.append(.{ .name = name.?, .source = .{ .path = .{ .path = p } } });
        } else if (version) |v| {
            try deps.append(.{ .name = name.?, .source = .{ .registry = .{ .version = v } } });
        } else if (git) |url| {
            try deps.append(.{ .name = name.?, .source = .{ .git = .{ .url = url, .rev = rev, .tag = tag } } });
        } else {
            try loader.err(exprSpan(el), "KMAN009", "Dependency requires a source", "A Dependency must declare one of version, path, or git.");
        }
    }
    manifest.dependencies = try deps.toOwnedSlice();
}

fn applyNativeLibraries(loader: *Loader, manifest: *ProjectManifest, value: *Expr) !void {
    const elements = (try arrayElements(loader, value)) orelse return;
    var libs = std.array_list.Managed(native.NativeLibrarySpec).init(loader.allocator);
    for (elements) |el| {
        if (try parseNativeLibrary(loader, el)) |spec| try libs.append(spec);
    }
    manifest.inline_native_libraries = try libs.toOwnedSlice();
}

fn parseNativeLibrary(loader: *Loader, value: *Expr) !?native.NativeLibrarySpec {
    const fields = (try structValue(loader, value, "NativeLibrary")) orelse return null;

    var name: []const u8 = "";
    var link_mode: native.LinkMode = .static;
    var headers = native.HeaderSpec{};
    var sources: []const []const u8 = &.{};
    var autobinding: ?native.AutobindingSpec = null;
    var targets: []const native.TargetSpec = &.{};

    for (fields.fields) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            name = (try stringValue(loader, f.value)) orelse "";
        } else if (std.mem.eql(u8, f.name, "linkMode") or std.mem.eql(u8, f.name, "link_mode")) {
            if (try enumValue(loader, f.value, "LinkMode")) |variant| {
                link_mode = parseLinkMode(variant) orelse blk: {
                    try loader.err(exprSpan(f.value), "KMAN006", "unknown LinkMode", "Expected LinkMode.Static or LinkMode.Dynamic.");
                    break :blk .static;
                };
            }
        } else if (std.mem.eql(u8, f.name, "headers")) {
            headers = try parseHeaders(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "sources")) {
            sources = try stringArray(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "autobind") or std.mem.eql(u8, f.name, "autobinding")) {
            autobinding = try parseAutobind(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "nativeTargets") or std.mem.eql(u8, f.name, "targets")) {
            targets = try parseNativeTargets(loader, f.value);
        } else {
            try loader.err(f.span, "KMAN004", "unknown NativeLibrary field", "This field is not part of the NativeLibrary schema.");
        }
    }

    if (name.len == 0) {
        try loader.err(exprSpan(value), "KMAN009", "NativeLibrary requires name", "Every NativeLibrary must declare a name.");
        return null;
    }

    return native.NativeLibrarySpec{
        .name = name,
        .link_mode = link_mode,
        .abi = .c,
        .headers = headers,
        .autobinding = autobinding,
        .build = .{ .sources = sources, .include_dirs = headers.include_dirs, .defines = headers.defines },
        .targets = targets,
    };
}

fn parseNativeTargets(loader: *Loader, value: *Expr) ![]const native.TargetSpec {
    const elements = (try arrayElements(loader, value)) orelse return &.{};
    var targets = std.array_list.Managed(native.TargetSpec).init(loader.allocator);
    for (elements) |element| {
        const fields = (try structValue(loader, element, "NativeTarget")) orelse continue;
        var triple: ?[]const u8 = null;
        var compiler_flags: []const []const u8 = &.{};
        var link = native.LinkExtras{};
        for (fields.fields) |field| {
            if (std.mem.eql(u8, field.name, "triple")) {
                triple = try stringValue(loader, field.value);
            } else if (std.mem.eql(u8, field.name, "compilerFlags") or std.mem.eql(u8, field.name, "compiler_flags")) {
                compiler_flags = try stringArray(loader, field.value);
            } else if (std.mem.eql(u8, field.name, "includeDirs") or std.mem.eql(u8, field.name, "include_dirs")) {
                link.include_dirs = try stringArray(loader, field.value);
            } else if (std.mem.eql(u8, field.name, "defines")) {
                link.defines = try stringArray(loader, field.value);
            } else if (std.mem.eql(u8, field.name, "frameworks")) {
                link.frameworks = try stringArray(loader, field.value);
            } else if (std.mem.eql(u8, field.name, "systemLibs") or std.mem.eql(u8, field.name, "system_libs")) {
                link.system_libs = try stringArray(loader, field.value);
            } else if (std.mem.eql(u8, field.name, "linkerFlags") or std.mem.eql(u8, field.name, "linker_flags")) {
                link.linker_flags = try stringArray(loader, field.value);
            } else {
                try loader.err(field.span, "KMAN004", "unknown NativeTarget field", "This field is not part of the NativeTarget schema.");
            }
        }
        const target_triple = triple orelse {
            try loader.err(exprSpan(element), "KMAN009", "NativeTarget requires triple", "Every NativeTarget must declare a target triple.");
            continue;
        };
        const selector = native.TargetSelector.parse(loader.allocator, target_triple) catch {
            try loader.err(exprSpan(element), "KMAN009", "invalid NativeTarget triple", "Expected an architecture-operating_system-abi target triple.");
            continue;
        };
        try targets.append(.{ .selector = selector, .compiler_flags = compiler_flags, .link = link });
    }
    return targets.toOwnedSlice();
}

fn parseHeaders(loader: *Loader, value: *Expr) !native.HeaderSpec {
    const fields = (try structValue(loader, value, "Headers")) orelse return .{};
    var headers = native.HeaderSpec{};
    for (fields.fields) |f| {
        if (std.mem.eql(u8, f.name, "entrypoint")) {
            headers.entrypoint = try stringValue(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "includeDirs") or std.mem.eql(u8, f.name, "include_dirs")) {
            headers.include_dirs = try stringArray(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "defines")) {
            headers.defines = try stringArray(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "frameworks")) {
            headers.frameworks = try stringArray(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "systemLibs") or std.mem.eql(u8, f.name, "system_libs")) {
            headers.system_libs = try stringArray(loader, f.value);
        } else {
            try loader.err(f.span, "KMAN004", "unknown Headers field", "This field is not part of the Headers schema.");
        }
    }
    return headers;
}

fn parseAutobind(loader: *Loader, value: *Expr) !?native.AutobindingSpec {
    const fields = (try structValue(loader, value, "Autobind")) orelse return null;
    var module_name: []const u8 = "";
    var mode: native.AutobindingMode = .listed;
    var profile: native.AutobindingProfile = .generic;
    var functions: []const []const u8 = &.{};
    var structs: []const []const u8 = &.{};
    var callbacks: []const []const u8 = &.{};
    var headers: []const []const u8 = &.{};

    for (fields.fields) |f| {
        if (std.mem.eql(u8, f.name, "module")) {
            module_name = (try stringValue(loader, f.value)) orelse "";
        } else if (std.mem.eql(u8, f.name, "output")) {
            // The autobind output location is a compiler law: it is always
            // `app/bindings/<module>.kira`. An explicit `output` is ignored.
            try loader.warn(f.span, "KMAN011", "ignored autobind output", "`output` is ignored; bindings always write to app/bindings/<module>.kira.");
        } else if (std.mem.eql(u8, f.name, "mode")) {
            if (try enumValue(loader, f.value, "AutobindMode")) |variant| {
                if (std.mem.eql(u8, variant, "AllPublic") or std.mem.eql(u8, variant, "all_public")) {
                    mode = .all_public;
                } else if (std.mem.eql(u8, variant, "Listed") or std.mem.eql(u8, variant, "listed")) {
                    mode = .listed;
                } else {
                    try loader.err(exprSpan(f.value), "KMAN006", "unknown AutobindMode", "Expected AutobindMode.Listed or AutobindMode.AllPublic.");
                }
            }
        } else if (std.mem.eql(u8, f.name, "headers")) {
            headers = try stringArray(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "profile")) {
            if (try enumValue(loader, f.value, "AutobindProfile")) |variant| {
                if (std.mem.eql(u8, variant, "Generic") or std.mem.eql(u8, variant, "generic")) {
                    profile = .generic;
                } else if (std.mem.eql(u8, variant, "Vulkan") or std.mem.eql(u8, variant, "vulkan")) {
                    profile = .vulkan;
                } else if (std.mem.eql(u8, variant, "DirectX12") or std.mem.eql(u8, variant, "directx12")) {
                    profile = .directx12;
                } else {
                    try loader.err(exprSpan(f.value), "KMAN006", "unknown AutobindProfile", "Expected AutobindProfile.Generic, AutobindProfile.Vulkan, or AutobindProfile.DirectX12.");
                }
            }
        } else if (std.mem.eql(u8, f.name, "functions")) {
            functions = try stringArray(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "structs")) {
            structs = try stringArray(loader, f.value);
        } else if (std.mem.eql(u8, f.name, "callbacks")) {
            callbacks = try stringArray(loader, f.value);
        } else {
            try loader.err(f.span, "KMAN004", "unknown Autobind field", "This field is not part of the Autobind schema.");
        }
    }

    if (module_name.len == 0) {
        try loader.err(exprSpan(value), "KMAN009", "Autobind requires module", "Every Autobind must declare a module name.");
        return null;
    }

    return native.AutobindingSpec{
        .module_name = module_name,
        // Placeholder; kira_build derives the real path (app/bindings/<module>.kira).
        .output_path = "",
        .headers = headers,
        .bindings = .{ .mode = mode, .profile = profile, .functions = functions, .structs = structs, .callbacks = callbacks },
    };
}

// ---- literal extraction helpers -------------------------------------------

fn stringValue(loader: *Loader, value: *Expr) !?[]const u8 {
    switch (value.*) {
        .string => |s| return try loader.allocator.dupe(u8, s.value),
        else => {
            try loader.err(exprSpan(value), "KMAN012", "expected string literal", "This field requires a string literal.");
            return null;
        },
    }
}

fn stringArray(loader: *Loader, value: *Expr) ![]const []const u8 {
    const elements = (try arrayElements(loader, value)) orelse return &.{};
    var list = std.array_list.Managed([]const u8).init(loader.allocator);
    for (elements) |el| {
        if (try stringValue(loader, el)) |s| try list.append(s);
    }
    return list.toOwnedSlice();
}

fn arrayElements(loader: *Loader, value: *Expr) !?[]const *Expr {
    switch (value.*) {
        .array => |a| return a.elements,
        else => {
            try loader.err(exprSpan(value), "KMAN013", "expected array literal", "This field requires an array literal `[ ... ]`.");
            return null;
        },
    }
}

fn structValue(loader: *Loader, value: *Expr, comptime type_name: []const u8) !?syntax.ast.StructLiteralExpr {
    switch (value.*) {
        .struct_literal => |s| return s,
        else => {
            try loader.err(exprSpan(value), "KMAN014", "expected " ++ type_name ++ " literal", "This field requires a `" ++ type_name ++ " { ... }` literal.");
            return null;
        },
    }
}

/// Reads either an explicit enum access (`Enum.Variant`) or the schema-anchored
/// implicit spelling (`.Variant`). The manifest loader already knows the enum
/// type from the field it is decoding, so no general semantic pass is needed.
fn enumValue(loader: *Loader, value: *Expr, comptime expected_type: []const u8) !?[]const u8 {
    switch (value.*) {
        .implicit_member => |m| return m.name,
        .member => |m| {
            switch (m.object.*) {
                .identifier => return m.member,
                else => {},
            }
        },
        else => {},
    }
    try loader.err(exprSpan(value), "KMAN015", "expected " ++ expected_type ++ " value", "This field requires an enum value like `.Variant` (or the explicit `" ++ expected_type ++ ".Variant`).");
    return null;
}

// ---- enum mapping ----------------------------------------------------------

fn parsePackageKind(variant: []const u8) ?PackageKind {
    if (std.mem.eql(u8, variant, "App")) return .app;
    if (std.mem.eql(u8, variant, "Library")) return .library;
    return null;
}

fn parseLinkMode(variant: []const u8) ?native.LinkMode {
    if (std.mem.eql(u8, variant, "Static")) return .static;
    if (std.mem.eql(u8, variant, "Dynamic")) return .dynamic;
    return null;
}

/// Foundation `Backend` variants -> internal execution_mode string.
fn backendMode(variant: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, variant, "Vm")) return "vm";
    if (std.mem.eql(u8, variant, "Llvm")) return "llvm";
    if (std.mem.eql(u8, variant, "Hybrid")) return "hybrid";
    if (std.mem.eql(u8, variant, "Wasm")) return "wasm32-emscripten";
    return null;
}

/// Foundation `Backend` variants that are valid test backends.
fn backendEnum(variant: []const u8) ?platform_config.Backend {
    if (std.mem.eql(u8, variant, "Vm")) return .vm;
    if (std.mem.eql(u8, variant, "Llvm")) return .llvm;
    if (std.mem.eql(u8, variant, "Hybrid")) return .hybrid;
    return null;
}

fn lowerFirst(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return value;
    const out = try allocator.dupe(u8, value);
    out[0] = std.ascii.toLower(out[0]);
    return out;
}

fn memberSpan(member: syntax.ast.BodyMember) Span {
    return switch (member) {
        inline else => |m| m.span,
    };
}

fn exprSpan(expr: *Expr) Span {
    return switch (expr.*) {
        inline else => |e| e.span,
    };
}
