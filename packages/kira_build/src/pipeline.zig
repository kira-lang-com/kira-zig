const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostics = @import("kira_diagnostics");
const lexer = @import("kira_lexer");
const parser = @import("kira_parser");
const semantics = @import("kira_semantics");
const syntax = @import("kira_syntax_model");
const ir = @import("kira_ir");
const bytecode = @import("kira_bytecode");

pub const FrontendStage = enum {
    lexer,
    parser,
    semantics,
    ir,
};

pub const LexPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    tokens: ?[]const syntax.Token,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: LexPipelineResult) bool {
        return self.tokens == null;
    }
};

pub const ParsePipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    program: ?syntax.ast.Program,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: ParsePipelineResult) bool {
        return self.program == null;
    }
};

pub const CheckPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: CheckPipelineResult) bool {
        return diagnostics.hasErrors(self.diagnostics);
    }
};

pub const FrontendPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    ir_program: ?ir.Program,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: FrontendPipelineResult) bool {
        return self.ir_program == null;
    }
};

pub const VmPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    ir_program: ?ir.Program,
    bytecode_module: ?bytecode.Module,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: VmPipelineResult) bool {
        return self.bytecode_module == null;
    }
};

pub fn compileFileToIr(allocator: std.mem.Allocator, path: []const u8) !FrontendPipelineResult {
    const parsed = try parseFile(allocator, path);
    if (parsed.program == null) {
        return .{
            .source = parsed.source,
            .diagnostics = parsed.diagnostics,
            .ir_program = null,
            .failure_stage = parsed.failure_stage,
        };
    }

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (parsed.diagnostics) |diag| try diags.append(diag);

    validateImports(allocator, &parsed.source, parsed.program.?, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = null,
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    const imported_globals = try collectImportedGlobals(allocator, &parsed.source, parsed.program.?);
    const hir = semantics.analyzeWithImports(allocator, parsed.program.?, imported_globals, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = null,
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    const ir_program = ir.lowerProgram(allocator, hir) catch |err| switch (err) {
        error.UnsupportedExecutableFeature, error.UnsupportedType => {
            try diags.append(.{
                .severity = .@"error",
                .code = "KIR001",
                .title = "feature is not executable in the current backend pipeline",
                .message = "This program uses language constructs that are not yet lowered into the shared executable IR.",
                .help = "Use `kirac check` to validate the frontend shape, or stay within the currently executable subset for `run` and `build`.",
            });
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = null,
                .failure_stage = .ir,
            };
        },
        else => return err,
    };
    return .{
        .source = parsed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .ir_program = ir_program,
    };
}

pub fn compileFileToBytecode(allocator: std.mem.Allocator, path: []const u8) !VmPipelineResult {
    const frontend = try compileFileToIr(allocator, path);
    if (frontend.ir_program == null) {
        return .{
            .source = frontend.source,
            .diagnostics = frontend.diagnostics,
            .ir_program = null,
            .bytecode_module = null,
            .failure_stage = frontend.failure_stage,
        };
    }

    const module = bytecode.compileProgram(allocator, frontend.ir_program.?, .vm) catch |err| switch (err) {
        error.NativeFunctionInVmBuild => {
            var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
            for (frontend.diagnostics) |diag| try diags.append(diag);
            try diags.append(.{
                .severity = .@"error",
                .code = "KBUILD001",
                .title = "native code requires a native-capable backend",
                .message = "This program contains @Native functions, but the VM backend only supports runtime execution.",
                .help = try std.fmt.allocPrint(
                    allocator,
                    "Use `kira run --backend hybrid {s}` for mixed @Runtime/@Native programs, or `kira run --backend llvm {s}` for fully native execution.",
                    .{ path, path },
                ),
            });
            return .{
                .source = frontend.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = frontend.ir_program,
                .bytecode_module = null,
                .failure_stage = .ir,
            };
        },
        else => return err,
    };
    return .{
        .source = frontend.source,
        .diagnostics = frontend.diagnostics,
        .ir_program = frontend.ir_program,
        .bytecode_module = module,
        .failure_stage = frontend.failure_stage,
    };
}

pub fn lexFile(allocator: std.mem.Allocator, path: []const u8) !LexPipelineResult {
    const source = try source_pkg.SourceFile.fromPath(allocator, path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = lexer.tokenize(allocator, &source, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = source,
                .diagnostics = try diags.toOwnedSlice(),
                .tokens = null,
                .failure_stage = .lexer,
            };
        },
        else => return err,
    };

    return .{
        .source = source,
        .diagnostics = try diags.toOwnedSlice(),
        .tokens = tokens,
    };
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !ParsePipelineResult {
    const lexed = try lexFile(allocator, path);
    if (lexed.tokens == null) {
        return .{
            .source = lexed.source,
            .diagnostics = lexed.diagnostics,
            .program = null,
            .failure_stage = lexed.failure_stage,
        };
    }

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (lexed.diagnostics) |diag| try diags.append(diag);

    const program = parser.parse(allocator, lexed.tokens.?, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = lexed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .program = null,
                .failure_stage = .parser,
            };
        },
        else => return err,
    };

    return .{
        .source = lexed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .program = program,
    };
}

pub fn checkFile(allocator: std.mem.Allocator, path: []const u8) !CheckPipelineResult {
    const parsed = try parseFile(allocator, path);
    if (parsed.program == null) {
        return .{
            .source = parsed.source,
            .diagnostics = parsed.diagnostics,
            .failure_stage = parsed.failure_stage,
        };
    }

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (parsed.diagnostics) |diag| try diags.append(diag);

    validateImports(allocator, &parsed.source, parsed.program.?, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    const imported_globals = try collectImportedGlobals(allocator, &parsed.source, parsed.program.?);
    _ = semantics.analyzeWithImports(allocator, parsed.program.?, imported_globals, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    return .{
        .source = parsed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .failure_stage = null,
    };
}

fn validateImports(
    allocator: std.mem.Allocator,
    source: *const source_pkg.SourceFile,
    program: syntax.ast.Program,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !void {
    for (program.imports) |import_decl| {
        const resolved = try resolveImportPath(allocator, source.path, import_decl.module_name);
        defer allocator.free(resolved.display_name);
        defer {
            for (resolved.candidates) |candidate| allocator.free(candidate);
            allocator.free(resolved.candidates);
        }

        if (resolved.exists) continue;

        try diagnostics.appendOwned(allocator, diags, .{
            .severity = .@"error",
            .code = "KSEM032",
            .title = "unresolved import",
            .message = try std.fmt.allocPrint(
                allocator,
                "Kira could not find a module for import '{s}'.",
                .{resolved.display_name},
            ),
            .labels = &.{
                diagnostics.primaryLabel(import_decl.span, "import does not resolve to a module file"),
            },
            .notes = try resolvedCandidateNotes(allocator, resolved.candidates),
            .help = "Create the imported module file or remove the import.",
        });
        return error.DiagnosticsEmitted;
    }
}

fn collectImportedGlobals(
    allocator: std.mem.Allocator,
    source: *const source_pkg.SourceFile,
    program: syntax.ast.Program,
) !semantics.ImportedGlobals {
    var constructs = std.array_list.Managed([]const u8).init(allocator);
    var callables = std.array_list.Managed([]const u8).init(allocator);

    for (program.imports) |import_decl| {
        const resolved = try resolveImportPath(allocator, source.path, import_decl.module_name);
        defer allocator.free(resolved.display_name);
        defer {
            for (resolved.candidates) |candidate| allocator.free(candidate);
            allocator.free(resolved.candidates);
        }

        const module_path = firstExistingCandidate(resolved.candidates) orelse continue;
        const harvested = try collectModuleGlobals(allocator, module_path);
        for (harvested.constructs) |name| try constructs.append(name);
        for (harvested.callables) |name| try callables.append(name);
    }

    return .{
        .constructs = try constructs.toOwnedSlice(),
        .callables = try callables.toOwnedSlice(),
    };
}

fn collectModuleGlobals(allocator: std.mem.Allocator, module_path: []const u8) !semantics.ImportedGlobals {
    const source = try source_pkg.SourceFile.fromPath(allocator, module_path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);

    const tokens = lexer.tokenize(allocator, &source, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => return .{},
        else => return err,
    };
    const program = parser.parse(allocator, tokens, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => return .{},
        else => return err,
    };

    return harvestProgramGlobals(allocator, program);
}

fn harvestProgramGlobals(allocator: std.mem.Allocator, program: syntax.ast.Program) !semantics.ImportedGlobals {
    var constructs = std.array_list.Managed([]const u8).init(allocator);
    var callables = std.array_list.Managed([]const u8).init(allocator);

    for (program.decls) |decl| {
        switch (decl) {
            .construct_decl => |construct_decl| try constructs.append(try allocator.dupe(u8, construct_decl.name)),
            .construct_form_decl => |form_decl| try callables.append(try allocator.dupe(u8, form_decl.name)),
            .function_decl => |function_decl| try callables.append(try allocator.dupe(u8, function_decl.name)),
            else => {},
        }
    }

    return .{
        .constructs = try constructs.toOwnedSlice(),
        .callables = try callables.toOwnedSlice(),
    };
}

const ImportResolution = struct {
    display_name: []u8,
    candidates: [][]u8,
    exists: bool,
};

fn resolveImportPath(allocator: std.mem.Allocator, source_path: []const u8, module_name: syntax.ast.QualifiedName) !ImportResolution {
    const base_dir = std.fs.path.dirname(source_path) orelse ".";
    const display_name = try qualifiedNameDisplay(allocator, module_name);
    const relative_slash = try qualifiedNameRelativePath(allocator, module_name, '/');
    defer allocator.free(relative_slash);
    const relative_backslash = try qualifiedNameRelativePath(allocator, module_name, '\\');
    defer allocator.free(relative_backslash);

    const candidates = try allocator.alloc([]u8, 4);
    candidates[0] = try std.fmt.allocPrint(allocator, "{s}/{s}.kira", .{ base_dir, relative_slash });
    candidates[1] = try std.fmt.allocPrint(allocator, "{s}/{s}/main.kira", .{ base_dir, relative_slash });
    candidates[2] = try std.fmt.allocPrint(allocator, "{s}\\{s}.kira", .{ base_dir, relative_backslash });
    candidates[3] = try std.fmt.allocPrint(allocator, "{s}\\{s}\\main.kira", .{ base_dir, relative_backslash });

    var exists = false;
    for (candidates) |candidate| {
        if (fileExists(candidate)) {
            exists = true;
            break;
        }
    }

    return .{
        .display_name = display_name,
        .candidates = candidates,
        .exists = exists,
    };
}

fn resolvedCandidateNotes(allocator: std.mem.Allocator, candidates: [][]u8) ![]const []const u8 {
    const notes = try allocator.alloc([]const u8, candidates.len);
    for (candidates, 0..) |candidate, index| {
        notes[index] = try std.fmt.allocPrint(allocator, "looked for {s}", .{candidate});
    }
    return notes;
}

fn qualifiedNameDisplay(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName) ![]u8 {
    return joinQualifiedName(allocator, name, ".");
}

fn qualifiedNameRelativePath(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName, comptime separator: u8) ![]u8 {
    const sep = [_]u8{separator};
    return joinQualifiedName(allocator, name, &sep);
}

fn joinQualifiedName(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName, separator: []const u8) ![]u8 {
    var builder = std.array_list.Managed(u8).init(allocator);
    for (name.segments, 0..) |segment, index| {
        if (index != 0) try builder.appendSlice(separator);
        try builder.appendSlice(segment.text);
    }
    return builder.toOwnedSlice();
}

fn firstExistingCandidate(candidates: [][]u8) ?[]const u8 {
    for (candidates) |candidate| {
        if (fileExists(candidate)) return candidate;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
