const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source = @import("kira_source");
const syntax = @import("kira_ksl_syntax_model");
const ksl_parser = @import("kira_ksl_parser");
const shader_model = @import("kira_shader_model");
const shader_ir = @import("kira_shader_ir");
const FunctionScope = @import("function_scope.zig").FunctionScope;
const utils = @import("analyzer_utils.zig");

const qualifiedKey = utils.qualifiedKey;
const qualifiedNameText = utils.qualifiedNameText;
const builtinType = utils.builtinType;
const builtinFromName = utils.builtinFromName;
const annotationNameText = utils.annotationNameText;
const stageKindToModel = utils.stageKindToModel;
const StageBindingsResult = utils.StageBindingsResult;
const groupClassRank = utils.groupClassRank;
const findField = utils.findField;
const typeEql = utils.typeEql;
const typeName = utils.typeName;
const constValueText = utils.constValueText;
const reflectedLayout = utils.reflectedLayout;
const resourceDeclVisibility = utils.resourceDeclVisibility;
const isIntegerLike = utils.isIntegerLike;
const alignForward = utils.alignForward;

pub const ImportedModule = struct {
    alias: []const u8,
    module_name: []const u8,
    module: syntax.ast.Module,
};

pub fn analyze(
    allocator: std.mem.Allocator,
    root_module: syntax.ast.Module,
    imports: []const ImportedModule,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !shader_ir.Program {
    var analyzer = Analyzer{
        .allocator = allocator,
        .root_module = root_module,
        .imports = imports,
        .diagnostics = out_diagnostics,
    };
    return analyzer.analyzeProgram();
}

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    root_module: syntax.ast.Module,
    imports: []const ImportedModule,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),

    type_sources: std.StringHashMap(TypeSource) = undefined,
    function_sources: std.StringHashMap(FunctionSource) = undefined,
    resolved_types: std.StringHashMap(shader_ir.TypeDecl) = undefined,
    resolved_functions: std.StringHashMap(shader_ir.FunctionDecl) = undefined,

    fn analyzeProgram(self: *Analyzer) !shader_ir.Program {
        self.type_sources = std.StringHashMap(TypeSource).init(self.allocator);
        self.function_sources = std.StringHashMap(FunctionSource).init(self.allocator);
        self.resolved_types = std.StringHashMap(shader_ir.TypeDecl).init(self.allocator);
        self.resolved_functions = std.StringHashMap(shader_ir.FunctionDecl).init(self.allocator);

        try self.collectTopLevelSources();
        const imported_modules = try self.lowerImportedModules();
        const types = try self.lowerAllTypes();
        const functions = try self.lowerAllRootFunctions();
        const shaders = try self.lowerShaders();

        return .{
            .imported_modules = imported_modules,
            .types = types,
            .functions = functions,
            .shaders = shaders,
        };
    }

    fn collectTopLevelSources(self: *Analyzer) !void {
        try self.collectModuleSources(null, self.root_module);
        for (self.imports) |imported| {
            try self.collectModuleSources(imported.alias, imported.module);
        }
    }

    fn collectModuleSources(self: *Analyzer, module_alias: ?[]const u8, module_ast: syntax.ast.Module) !void {
        for (module_ast.types) |*type_decl| {
            const key = try qualifiedKey(self.allocator, module_alias, type_decl.name);
            if (self.type_sources.contains(key)) {
                try self.emitDiagnostic("KSL031", "duplicate type declaration", source.Span.init(type_decl.span.start, type_decl.span.end), "Rename the type or remove the duplicate declaration.");
                return error.DiagnosticsEmitted;
            }
            try self.type_sources.put(key, .{ .module_alias = module_alias, .decl = type_decl });
        }
        for (module_ast.functions) |*function_decl| {
            const key = try qualifiedKey(self.allocator, module_alias, function_decl.name);
            if (self.function_sources.contains(key)) {
                try self.emitDiagnostic("KSL032", "duplicate function declaration", source.Span.init(function_decl.span.start, function_decl.span.end), "Rename the function or remove the duplicate declaration.");
                return error.DiagnosticsEmitted;
            }
            try self.function_sources.put(key, .{ .module_alias = module_alias, .decl = function_decl });
        }
    }

    fn lowerImportedModules(self: *Analyzer) ![]const shader_ir.ImportedModule {
        var items = std.array_list.Managed(shader_ir.ImportedModule).init(self.allocator);
        for (self.imports) |imported| {
            try items.append(.{
                .alias = imported.alias,
                .module_name = imported.module_name,
            });
        }
        return items.toOwnedSlice();
    }

    fn lowerAllTypes(self: *Analyzer) ![]const shader_ir.TypeDecl {
        var items = std.array_list.Managed(shader_ir.TypeDecl).init(self.allocator);
        var iterator = self.type_sources.iterator();
        while (iterator.next()) |entry| {
            const lowered = try self.lowerTypeDecl(entry.key_ptr.*, entry.value_ptr.*);
            try items.append(lowered);
        }
        return items.toOwnedSlice();
    }

    fn lowerAllRootFunctions(self: *Analyzer) ![]const shader_ir.FunctionDecl {
        var items = std.array_list.Managed(shader_ir.FunctionDecl).init(self.allocator);
        for (self.root_module.functions) |*function_decl| {
            const key = try qualifiedKey(self.allocator, null, function_decl.name);
            try items.append(try self.lowerFunctionDecl(.{
                .module_alias = null,
                .decl = function_decl,
            }, key, null));
        }
        for (self.imports) |imported| {
            for (imported.module.functions) |*function_decl| {
                try items.append(try self.lowerFunctionDecl(.{
                    .module_alias = imported.alias,
                    .decl = function_decl,
                }, try qualifiedKey(self.allocator, imported.alias, function_decl.name), null));
            }
        }
        return items.toOwnedSlice();
    }

    fn lowerShaders(self: *Analyzer) ![]const shader_ir.ShaderDecl {
        var items = std.array_list.Managed(shader_ir.ShaderDecl).init(self.allocator);
        for (self.root_module.shaders) |shader_decl| {
            try items.append(try self.lowerShaderDecl(shader_decl));
        }
        return items.toOwnedSlice();
    }

    fn lowerTypeDecl(self: *Analyzer, key: []const u8, source_info: TypeSource) anyerror!shader_ir.TypeDecl {
        if (self.resolved_types.get(key)) |cached| return cached;

        var fields = std.array_list.Managed(shader_ir.FieldDecl).init(self.allocator);
        for (source_info.decl.fields) |field_decl| {
            const field_ty = try self.resolveTypeRef(source_info.module_alias, field_decl.ty.*);
            const builtin = try self.resolveBuiltin(field_decl.annotations);
            const interpolation = try self.resolveInterpolation(field_decl.annotations);
            try fields.append(.{
                .name = field_decl.name,
                .ty = field_ty,
                .builtin = builtin,
                .interpolation = interpolation,
                .span = field_decl.span,
            });
        }

        const uniform_layout = try self.computeStructLayout(fields.items, .uniform);
        const storage_layout = try self.computeStructLayout(fields.items, .storage);
        const owned_fields = try fields.toOwnedSlice();
        const type_decl: shader_ir.TypeDecl = .{
            .name = key,
            .fields = owned_fields,
            .uniform_layout = uniform_layout,
            .storage_layout = storage_layout,
            .span = source_info.decl.span,
        };
        try self.resolved_types.put(try self.allocator.dupe(u8, key), type_decl);
        return type_decl;
    }

    pub fn lowerFunctionDecl(
        self: *Analyzer,
        source_info: FunctionSource,
        key: []const u8,
        shader_scope: ?*const ShaderScope,
    ) !shader_ir.FunctionDecl {
        if (self.resolved_functions.get(key)) |cached| return cached;

        var params = std.array_list.Managed(shader_ir.ParamDecl).init(self.allocator);
        for (source_info.decl.params) |param_decl| {
            const param_ty = try self.resolveTypeRef(source_info.module_alias, param_decl.ty.*);
            try params.append(.{
                .name = param_decl.name,
                .ty = param_ty,
                .span = param_decl.span,
            });
        }
        const return_type = if (source_info.decl.return_type) |return_type|
            try self.resolveTypeRef(source_info.module_alias, return_type.*)
        else
            shader_model.Type{ .void = {} };

        var scope = try FunctionScope.init(self, source_info.module_alias, shader_scope, params.items, return_type);
        const body = try scope.lowerBlock(source_info.decl.body);

        const lowered: shader_ir.FunctionDecl = .{
            .name = key,
            .params = try params.toOwnedSlice(),
            .return_type = return_type,
            .body = body,
            .module_alias = source_info.module_alias,
            .span = source_info.decl.span,
        };
        try self.resolved_functions.put(try self.allocator.dupe(u8, key), lowered);
        return lowered;
    }

    fn lowerShaderDecl(self: *Analyzer, shader_decl: syntax.ast.ShaderDecl) !shader_ir.ShaderDecl {
        const kind = try determineShaderKind(self, shader_decl);
        const options = try self.lowerOptions(shader_decl.options);
        const lowered_groups = try self.lowerGroups(shader_decl.groups);
        const stage_order = try self.stageBindings(lowered_groups);

        var stages = std.array_list.Managed(shader_ir.StageDecl).init(self.allocator);
        for (shader_decl.stages) |stage_decl| {
            var stage_scope = ShaderScope{
                .shader_name = shader_decl.name,
                .shader_kind = kind,
                .stage = stageKindToModel(stage_decl.kind),
                .options = options,
                .resources = stage_order.resources,
            };
            const entry_key = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{s}", .{
                shader_decl.name,
                @tagName(stage_decl.kind),
                stage_decl.entry.name,
            });
            const lowered_entry = try self.lowerFunctionDecl(.{
                .module_alias = null,
                .decl = &stage_decl.entry,
            }, entry_key, &stage_scope);
            try stages.append(.{
                .kind = stage_scope.stage,
                .input_type = if (stage_decl.input_type) |input_type| try qualifiedNameText(self.allocator, input_type) else null,
                .output_type = if (stage_decl.output_type) |output_type| try qualifiedNameText(self.allocator, output_type) else null,
                .threads = if (stage_decl.threads) |threads_decl| try self.resolveThreads(threads_decl, options) else null,
                .entry = lowered_entry,
                .span = stage_decl.span,
            });
        }

        const stages_slice = try stages.toOwnedSlice();
        try self.validateStageRules(shader_decl, kind, stage_order.groups, stages_slice);
        const reflection = try self.buildReflection(shader_decl.name, kind, options, stage_order.groups, stages_slice);

        return .{
            .name = shader_decl.name,
            .kind = kind,
            .options = options,
            .groups = stage_order.groups,
            .stages = stages_slice,
            .reflection = reflection,
            .span = shader_decl.span,
        };
    }

    pub fn resolveTypeRef(self: *Analyzer, current_module_alias: ?[]const u8, ty: syntax.ast.TypeRef) !shader_model.Type {
        return switch (ty) {
            .named => |named| try self.resolveNamedType(current_module_alias, named),
            .runtime_array => |array_ty| blk: {
                const element = try self.allocator.create(shader_model.Type);
                element.* = try self.resolveTypeRef(current_module_alias, array_ty.element.*);
                break :blk .{ .runtime_array = element };
            },
        };
    }

    fn resolveNamedType(self: *Analyzer, current_module_alias: ?[]const u8, name: syntax.ast.QualifiedName) !shader_model.Type {
        const display_name = try qualifiedNameText(self.allocator, name);
        if (builtinType(display_name)) |builtin_ty| return builtin_ty;

        if (name.segments.len == 1) {
            if (current_module_alias) |module_alias| {
                const local_key = try qualifiedKey(self.allocator, module_alias, name.segments[0].text);
                if (self.type_sources.contains(local_key)) return .{ .struct_ref = local_key };
            }
            if (self.type_sources.contains(name.segments[0].text)) return .{ .struct_ref = try self.allocator.dupe(u8, name.segments[0].text) };
        } else if (name.segments.len == 2) {
            const key = try qualifiedKey(self.allocator, name.segments[0].text, name.segments[1].text);
            if (self.type_sources.contains(key)) return .{ .struct_ref = key };
        }

        try self.emitDiagnostic("KSL011", "unknown type", name.span, "Declare the type before it is used or import the module that defines it.");
        return error.DiagnosticsEmitted;
    }

    fn resolveBuiltin(self: *Analyzer, annotations: []const syntax.ast.Annotation) !?shader_model.Builtin {
        for (annotations) |annotation| {
            const name = try qualifiedNameText(self.allocator, annotation.name);
            if (!std.mem.eql(u8, name, "builtin")) continue;
            if (annotation.args.len != 1) {
                try self.emitDiagnostic("KSL036", "invalid builtin annotation", annotation.span, "Write `@builtin(name)` with exactly one builtin name.");
                return error.DiagnosticsEmitted;
            }
            const builtin_name = try annotationNameText(self.allocator, annotation.args[0]);
            return builtinFromName(builtin_name) orelse {
                try self.emitDiagnostic("KSL036", "invalid builtin annotation", annotation.span, "Use one of KSL's supported built-in names such as `position` or `vertex_index`.");
                return error.DiagnosticsEmitted;
            };
        }
        return null;
    }

    fn resolveInterpolation(self: *Analyzer, annotations: []const syntax.ast.Annotation) !?shader_model.Interpolation {
        for (annotations) |annotation| {
            const name = try qualifiedNameText(self.allocator, annotation.name);
            if (!std.mem.eql(u8, name, "interpolate")) continue;
            if (annotation.args.len != 1) {
                try self.emitDiagnostic("KSL037", "invalid interpolation annotation", annotation.span, "Write `@interpolate(linear)` or `@interpolate(flat)`.");
                return error.DiagnosticsEmitted;
            }
            const interp_name = try annotationNameText(self.allocator, annotation.args[0]);
            if (std.mem.eql(u8, interp_name, "perspective")) return .perspective;
            if (std.mem.eql(u8, interp_name, "linear")) return .linear;
            if (std.mem.eql(u8, interp_name, "flat")) return .flat;
            try self.emitDiagnostic("KSL037", "invalid interpolation annotation", annotation.span, "Use `perspective`, `linear`, or `flat`.");
            return error.DiagnosticsEmitted;
        }
        return null;
    }

    pub fn emitDiagnostic(self: *Analyzer, code: []const u8, title: []const u8, span: source.Span, help: []const u8) !void {
        try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
            .severity = .@"error",
            .code = code,
            .title = title,
            .message = title,
            .labels = &.{diagnostics.primaryLabel(span, title)},
            .help = help,
        });
    }

    fn computeStructLayout(self: *Analyzer, fields: []const shader_ir.FieldDecl, class: LayoutClass) anyerror!shader_ir.StructLayout {
        var layouts = std.array_list.Managed(shader_ir.FieldLayout).init(self.allocator);
        var offset: u32 = 0;
        var max_alignment: u32 = if (class == .uniform) 16 else 1;
        for (fields) |field_decl| {
            const info = try self.typeLayout(field_decl.ty, class);
            offset = alignForward(offset, info.alignment);
            try layouts.append(.{
                .name = field_decl.name,
                .offset = offset,
                .alignment = info.alignment,
                .size = info.size,
                .stride = info.stride,
            });
            offset += info.size;
            if (info.alignment > max_alignment) max_alignment = info.alignment;
        }
        const struct_alignment = if (class == .uniform) alignForward(max_alignment, 16) else max_alignment;
        return .{
            .alignment = struct_alignment,
            .size = alignForward(offset, struct_alignment),
            .fields = try layouts.toOwnedSlice(),
        };
    }

    fn typeLayout(self: *Analyzer, ty: shader_model.Type, class: LayoutClass) anyerror!TypeLayout {
        return switch (ty) {
            .scalar => .{ .alignment = 4, .size = 4 },
            .vector => |vector| blk: {
                const alignment: u32 = switch (vector.width) {
                    2 => 8,
                    3, 4 => 16,
                    else => 4,
                };
                break :blk .{ .alignment = alignment, .size = alignment };
            },
            .matrix => |matrix| blk: {
                const column_alignment: u32 = switch (matrix.rows) {
                    2 => 8,
                    3, 4 => 16,
                    else => 4,
                };
                const stride = if (class == .uniform) alignForward(column_alignment, 16) else column_alignment;
                break :blk .{
                    .alignment = if (class == .uniform) 16 else column_alignment,
                    .size = stride * matrix.columns,
                    .stride = stride,
                };
            },
            .struct_ref => |name| blk: {
                const type_decl = self.resolved_types.get(name) orelse if (self.type_sources.get(name)) |source_info|
                    try self.lowerTypeDecl(name, source_info)
                else
                    return error.DiagnosticsEmitted;
                break :blk switch (class) {
                    .uniform => .{ .alignment = type_decl.uniform_layout.?.alignment, .size = type_decl.uniform_layout.?.size },
                    .storage => .{ .alignment = type_decl.storage_layout.?.alignment, .size = type_decl.storage_layout.?.size },
                };
            },
            else => .{ .alignment = 4, .size = 4 },
        };
    }

    fn lowerOptions(self: *Analyzer, option_decls: []const syntax.ast.OptionDecl) ![]const shader_ir.OptionDecl {
        var options = std.array_list.Managed(shader_ir.OptionDecl).init(self.allocator);
        var names = std.StringHashMap(void).init(self.allocator);
        for (option_decls) |option_decl| {
            if (names.contains(option_decl.name)) {
                try self.emitDiagnostic("KSL033", "duplicate option declaration", option_decl.span, "Rename the option or remove the duplicate declaration.");
                return error.DiagnosticsEmitted;
            }
            try names.put(option_decl.name, {});
            const option_ty = try self.resolveTypeRef(null, option_decl.ty.*);
            const default_value = try self.evaluateConstExpr(option_decl.default_value, option_ty, &.{});
            try options.append(.{
                .name = option_decl.name,
                .ty = option_ty,
                .default_value = default_value,
                .span = option_decl.span,
            });
        }
        return options.toOwnedSlice();
    }

    fn lowerGroups(self: *Analyzer, group_decls: []const syntax.ast.GroupDecl) ![]const shader_ir.GroupDecl {
        var groups = std.array_list.Managed(shader_ir.GroupDecl).init(self.allocator);
        var group_names = std.StringHashMap(void).init(self.allocator);
        var resource_names = std.StringHashMap(void).init(self.allocator);

        for (group_decls) |group_decl| {
            if (group_names.contains(group_decl.name)) {
                try self.emitDiagnostic("KSL034", "duplicate resource group", group_decl.span, "Rename the group or remove the duplicate declaration.");
                return error.DiagnosticsEmitted;
            }
            try group_names.put(group_decl.name, {});

            var resources = std.array_list.Managed(shader_ir.ResourceDecl).init(self.allocator);
            for (group_decl.resources) |resource_decl| {
                if (resource_names.contains(resource_decl.name)) {
                    try self.emitDiagnostic("KSL035", "duplicate shader resource", resource_decl.span, "Resource names must be unique within a shader.");
                    return error.DiagnosticsEmitted;
                }
                try resource_names.put(resource_decl.name, {});

                const resource_ty = try self.resolveTypeRef(null, resource_decl.ty.*);
                try self.validateResourceType(resource_decl, resource_ty);
                try resources.append(.{
                    .name = resource_decl.name,
                    .kind = switch (resource_decl.kind) {
                        .uniform => .uniform,
                        .storage => .storage,
                        .texture => .texture,
                        .sampler => .sampler,
                    },
                    .access = if (resource_decl.access) |access| switch (access) {
                        .read => .read,
                        .read_write => .read_write,
                    } else null,
                    .ty = resource_ty,
                    .visibility = &.{},
                    .logical_group_index = 0,
                    .logical_binding_index = 0,
                    .span = resource_decl.span,
                });
            }

            try groups.append(.{
                .name = group_decl.name,
                .class = shader_model.classifyGroupName(group_decl.name),
                .resources = try resources.toOwnedSlice(),
                .span = group_decl.span,
            });
        }

        return groups.toOwnedSlice();
    }

    fn stageBindings(self: *Analyzer, groups: []const shader_ir.GroupDecl) !StageBindingsResult {
        const groups_copy = try self.allocator.alloc(shader_ir.GroupDecl, groups.len);
        @memcpy(groups_copy, groups);

        var index: usize = 1;
        while (index < groups_copy.len) : (index += 1) {
            var cursor = index;
            while (cursor > 0 and groupClassRank(groups_copy[cursor - 1].class) > groupClassRank(groups_copy[cursor].class)) : (cursor -= 1) {
                const temp = groups_copy[cursor - 1];
                groups_copy[cursor - 1] = groups_copy[cursor];
                groups_copy[cursor] = temp;
            }
        }

        var resources = std.array_list.Managed(shader_ir.ResourceDecl).init(self.allocator);
        for (groups_copy, 0..) |*group_decl, group_index| {
            const group_resources = try self.allocator.alloc(shader_ir.ResourceDecl, group_decl.resources.len);
            @memcpy(group_resources, group_decl.resources);
            for (group_resources, 0..) |*resource_decl, binding_index| {
                resource_decl.logical_group_index = @intCast(group_index);
                resource_decl.logical_binding_index = @intCast(binding_index);
                try resources.append(resource_decl.*);
            }
            group_decl.resources = group_resources;
        }

        return .{
            .groups = groups_copy,
            .resources = try resources.toOwnedSlice(),
        };
    }

    fn resolveThreads(self: *Analyzer, threads_decl: syntax.ast.ThreadsDecl, options: []const shader_ir.OptionDecl) !shader_ir.Threads {
        const x = try self.evaluateConstExpr(threads_decl.x, .{ .scalar = .uint }, options);
        const y = try self.evaluateConstExpr(threads_decl.y, .{ .scalar = .uint }, options);
        const z = try self.evaluateConstExpr(threads_decl.z, .{ .scalar = .uint }, options);
        const threads = shader_ir.Threads{
            .x = x.uint,
            .y = y.uint,
            .z = z.uint,
        };
        if (threads.x * threads.y * threads.z > 256) {
            try self.emitDiagnostic("KSL101", "workgroup size exceeds the portable limit", threads_decl.span, "Reduce the workgroup size or split the work across more groups.");
            return error.DiagnosticsEmitted;
        }
        return threads;
    }

    fn validateResourceType(self: *Analyzer, resource_decl: syntax.ast.ResourceDecl, resource_ty: shader_model.Type) !void {
        switch (resource_decl.kind) {
            .uniform => if (resource_ty == .texture or resource_ty == .sampler or resource_ty == .runtime_array) {
                try self.emitDiagnostic("KSL052", "invalid uniform resource declaration", resource_decl.span, "Uniform resources must use a struct or value type.");
                return error.DiagnosticsEmitted;
            },
            .storage => {
                if (resource_ty != .runtime_array) {
                    try self.emitDiagnostic("KSL053", "invalid storage resource declaration", resource_decl.span, "Storage resources must declare a runtime-sized array such as `[Particle]`.");
                    return error.DiagnosticsEmitted;
                }
                if (resource_ty.runtime_array.* == .scalar and resource_ty.runtime_array.*.scalar == .bool) {
                    try self.emitDiagnostic("KSL054", "invalid storage element type", resource_decl.span, "Bool storage buffer elements are not supported in KSL v1.");
                    return error.DiagnosticsEmitted;
                }
            },
            .texture => if (resource_ty != .texture) {
                try self.emitDiagnostic("KSL055", "invalid texture declaration", resource_decl.span, "Texture resources must use a texture type such as `Texture2d`.");
                return error.DiagnosticsEmitted;
            },
            .sampler => if (resource_ty != .sampler) {
                try self.emitDiagnostic("KSL056", "invalid sampler declaration", resource_decl.span, "Sampler resources must use `Sampler` or `ComparisonSampler`.");
                return error.DiagnosticsEmitted;
            },
        }
    }

    fn evaluateConstExpr(
        self: *Analyzer,
        expr: *const syntax.ast.Expr,
        expected_ty: shader_model.Type,
        options: []const shader_ir.OptionDecl,
    ) !shader_ir.ConstValue {
        return switch (expr.*) {
            .bool => |value| .{ .bool = value.value },
            .float => |value| .{ .float = try std.fmt.parseFloat(f32, value.text) },
            .integer => |value| switch (expected_ty) {
                .scalar => |scalar| switch (scalar) {
                    .int => .{ .int = try std.fmt.parseInt(i32, value.text, 10) },
                    .uint => .{ .uint = try std.fmt.parseInt(u32, value.text, 10) },
                    else => {
                        try self.emitDiagnostic("KSL021", "ambiguous integer literal", value.span, "Write an explicit `Int` or `UInt` context for this literal.");
                        return error.DiagnosticsEmitted;
                    },
                },
                else => {
                    try self.emitDiagnostic("KSL021", "ambiguous integer literal", value.span, "Write an explicit `Int` or `UInt` context for this literal.");
                    return error.DiagnosticsEmitted;
                },
            },
            .identifier => |value| blk: {
                const name = try qualifiedNameText(self.allocator, value.name);
                for (options) |option_decl| {
                    if (std.mem.eql(u8, option_decl.name, name)) break :blk option_decl.default_value;
                }
                try self.emitDiagnostic("KSL044", "expected a compile-time constant", value.span, "Only literals and shader options are allowed here.");
                return error.DiagnosticsEmitted;
            },
            else => {
                try self.emitDiagnostic("KSL044", "expected a compile-time constant", syntax.ast.exprSpan(expr.*), "Only literals and shader options are allowed here.");
                return error.DiagnosticsEmitted;
            },
        };
    }

    fn validateStageRules(
        self: *Analyzer,
        shader_decl: syntax.ast.ShaderDecl,
        kind: shader_model.module.ShaderKind,
        groups: []const shader_ir.GroupDecl,
        stages: []const shader_ir.StageDecl,
    ) !void {
        var vertex: ?shader_ir.StageDecl = null;
        var fragment: ?shader_ir.StageDecl = null;
        var compute: ?shader_ir.StageDecl = null;

        for (stages) |stage_decl| switch (stage_decl.kind) {
            .vertex => vertex = stage_decl,
            .fragment => fragment = stage_decl,
            .compute => compute = stage_decl,
        };

        switch (kind) {
            .graphics => {
                if (vertex == null) {
                    try self.emitDiagnostic("KSL081", "missing vertex entry", shader_decl.span, "Add a `vertex { ... function entry(...) ... }` block.");
                    return error.DiagnosticsEmitted;
                }
                try self.validateStageInterface(vertex.?);
                if (fragment) |fragment_stage| try self.validateGraphicsInterfaces(vertex.?, fragment_stage);
                if (fragment) |fragment_stage| try self.validateStageInterface(fragment_stage);
            },
            .compute => {
                if (compute == null) {
                    try self.emitDiagnostic("KSL082", "missing compute entry", shader_decl.span, "Add a `compute { ... function entry(...) ... }` block.");
                    return error.DiagnosticsEmitted;
                }
                try self.validateStageInterface(compute.?);
            },
        }

        for (groups) |group_decl| {
            for (group_decl.resources) |resource_decl| {
                if (resource_decl.kind == .storage and resource_decl.access == .read_write and kind != .compute) {
                    try self.emitDiagnostic("KSL071", "resource is not writable", resource_decl.span, "Writable storage resources are compute-only in KSL v1.");
                    return error.DiagnosticsEmitted;
                }
            }
        }
    }

    fn validateStageInterface(self: *Analyzer, stage: shader_ir.StageDecl) !void {
        if (stage.input_type) |input_name| {
            const input_type = self.resolved_types.get(input_name) orelse return;
            try self.validateInterfaceFields(input_type, stage.kind, .input);
        }
        if (stage.output_type) |output_name| {
            const output_type = self.resolved_types.get(output_name) orelse return;
            try self.validateInterfaceFields(output_type, stage.kind, .output);
        }
    }

    fn validateInterfaceFields(
        self: *Analyzer,
        type_decl: shader_ir.TypeDecl,
        stage: shader_model.Stage,
        direction: shader_model.InterfaceDirection,
    ) !void {
        var seen_builtins = std.AutoHashMap(shader_model.Builtin, void).init(self.allocator);
        for (type_decl.fields) |field_decl| {
            if (field_decl.builtin) |builtin| {
                if (!shader_model.builtinAllowed(builtin, stage, direction)) {
                    try self.emitDiagnostic("KSL051", "illegal use of stage-specific built-in", field_decl.span, "Use this built-in only in the stage and direction where KSL allows it.");
                    return error.DiagnosticsEmitted;
                }
                if (seen_builtins.contains(builtin)) {
                    try self.emitDiagnostic("KSL052", "duplicate built-in semantic", field_decl.span, "Declare each built-in at most once per interface type.");
                    return error.DiagnosticsEmitted;
                }
                try seen_builtins.put(builtin, {});
            } else if (direction == .output and stage == .vertex and isIntegerLike(field_decl.ty) and field_decl.interpolation != .flat) {
                try self.emitDiagnostic("KSL053", "integer varyings require flat interpolation", field_decl.span, "Add `@interpolate(flat)` to integer varyings shared between vertex and fragment stages.");
                return error.DiagnosticsEmitted;
            }
        }
    }

    fn validateGraphicsInterfaces(self: *Analyzer, vertex_stage: shader_ir.StageDecl, fragment_stage: shader_ir.StageDecl) !void {
        const vertex_output_name = vertex_stage.output_type orelse return;
        const fragment_input_name = fragment_stage.input_type orelse return;
        const vertex_type = self.resolved_types.get(vertex_output_name) orelse return;
        const fragment_type = self.resolved_types.get(fragment_input_name) orelse return;

        var has_position = false;
        for (vertex_type.fields) |vertex_field| {
            if (vertex_field.builtin == .position) has_position = true;
        }
        if (!has_position) {
            try self.emitDiagnostic("KSL042", "missing vertex position output", vertex_type.span, "Vertex output types must declare `@builtin(position)`.");
            return error.DiagnosticsEmitted;
        }

        for (fragment_type.fields) |fragment_field| {
            if (fragment_field.builtin != null) continue;
            const matching_vertex = findField(vertex_type.fields, fragment_field.name) orelse {
                try self.emitDiagnostic("KSL041", "fragment input does not match vertex output", fragment_field.span, "Make the fragment input field match the vertex output exactly.");
                return error.DiagnosticsEmitted;
            };
            if (!typeEql(matching_vertex.ty, fragment_field.ty) or matching_vertex.interpolation != fragment_field.interpolation) {
                try self.emitDiagnostic("KSL041", "fragment input does not match vertex output", fragment_field.span, "Make the fragment input field match the vertex output exactly.");
                return error.DiagnosticsEmitted;
            }
        }
    }

    fn buildReflection(
        self: *Analyzer,
        shader_name: []const u8,
        kind: shader_model.module.ShaderKind,
        options: []const shader_ir.OptionDecl,
        groups: []const shader_ir.GroupDecl,
        stages: []const shader_ir.StageDecl,
    ) !shader_model.Reflection {
        var reflected_options = std.array_list.Managed(shader_model.ReflectedOption).init(self.allocator);
        for (options) |option_decl| {
            try reflected_options.append(.{
                .name = option_decl.name,
                .type_name = try typeName(self.allocator, option_decl.ty),
                .default_value = try constValueText(self.allocator, option_decl.default_value),
            });
        }

        var reflected_stages = std.array_list.Managed(shader_model.ReflectedStage).init(self.allocator);
        for (stages) |stage_decl| {
            const input_fields = if (stage_decl.input_type) |input_name|
                try self.reflectInterfaceFields(input_name)
            else
                &.{};
            const output_fields = if (stage_decl.output_type) |output_name|
                try self.reflectInterfaceFields(output_name)
            else
                &.{};
            try reflected_stages.append(.{
                .stage = stage_decl.kind,
                .entry_name = stage_decl.entry.name,
                .input_type = stage_decl.input_type,
                .output_type = stage_decl.output_type,
                .threads = if (stage_decl.threads) |threads| .{ threads.x, threads.y, threads.z } else null,
                .inputs = input_fields,
                .outputs = output_fields,
            });
        }

        var reflected_types = std.array_list.Managed(shader_model.ReflectedType).init(self.allocator);
        var type_iter = self.resolved_types.iterator();
        while (type_iter.next()) |entry| {
            var fields = std.array_list.Managed(shader_model.ReflectedField).init(self.allocator);
            for (entry.value_ptr.fields) |field_decl| {
                try fields.append(.{
                    .name = field_decl.name,
                    .type_name = try typeName(self.allocator, field_decl.ty),
                    .builtin = field_decl.builtin,
                    .interpolation = field_decl.interpolation,
                });
            }
            try reflected_types.append(.{
                .name = entry.key_ptr.*,
                .fields = try fields.toOwnedSlice(),
                .uniform_layout = if (entry.value_ptr.uniform_layout) |layout| try reflectedLayout(self.allocator, "uniform", layout) else null,
                .storage_layout = if (entry.value_ptr.storage_layout) |layout| try reflectedLayout(self.allocator, "storage", layout) else null,
            });
        }

        var reflected_resources = std.array_list.Managed(shader_model.ReflectedResource).init(self.allocator);
        for (groups) |group_decl| {
            for (group_decl.resources) |resource_decl| {
                const visibility = try resourceDeclVisibility(self.allocator, stages, resource_decl.name);
                const bindings = try self.allocator.dupe(shader_model.BackendBinding, &.{.{
                    .target = .glsl_330,
                    .group_index = resource_decl.logical_group_index,
                    .binding_index = resource_decl.logical_binding_index,
                    .glsl_name = resource_decl.name,
                }});
                try reflected_resources.append(.{
                    .group_name = group_decl.name,
                    .group_class = group_decl.class,
                    .group_index = resource_decl.logical_group_index,
                    .resource_name = resource_decl.name,
                    .resource_kind = resource_decl.kind,
                    .type_name = try typeName(self.allocator, resource_decl.ty),
                    .visibility = visibility,
                    .access = resource_decl.access,
                    .backend_bindings = bindings,
                });
            }
        }

        return .{
            .shader_name = shader_name,
            .shader_kind = kind,
            .backend = .glsl_330,
            .options = try reflected_options.toOwnedSlice(),
            .stages = try reflected_stages.toOwnedSlice(),
            .types = try reflected_types.toOwnedSlice(),
            .resources = try reflected_resources.toOwnedSlice(),
        };
    }

    fn reflectInterfaceFields(self: *Analyzer, type_name: []const u8) ![]const shader_model.ReflectedField {
        const type_decl = self.resolved_types.get(type_name) orelse return &.{};
        var fields = std.array_list.Managed(shader_model.ReflectedField).init(self.allocator);
        var location: u32 = 0;
        for (type_decl.fields) |field_decl| {
            try fields.append(.{
                .name = field_decl.name,
                .type_name = try typeName(self.allocator, field_decl.ty),
                .builtin = field_decl.builtin,
                .interpolation = field_decl.interpolation,
                .location = if (field_decl.builtin == null) blk: {
                    const value = location;
                    location += 1;
                    break :blk value;
                } else null,
            });
        }
        return fields.toOwnedSlice();
    }
};

const TypeSource = struct {
    module_alias: ?[]const u8,
    decl: *const syntax.ast.TypeDecl,
};

const FunctionSource = struct {
    module_alias: ?[]const u8,
    decl: *const syntax.ast.FunctionDecl,
};

pub const ShaderScope = struct {
    shader_name: []const u8,
    shader_kind: shader_model.module.ShaderKind,
    stage: shader_model.Stage,
    options: []const shader_ir.OptionDecl,
    resources: []const shader_ir.ResourceDecl,
};

const LayoutClass = enum {
    uniform,
    storage,
};

const TypeLayout = struct {
    alignment: u32,
    size: u32,
    stride: u32 = 0,
};

fn determineShaderKind(analyzer: *Analyzer, shader_decl: syntax.ast.ShaderDecl) !shader_model.module.ShaderKind {
    var saw_graphics = false;
    var saw_compute = false;
    for (shader_decl.stages) |stage_decl| {
        switch (stage_decl.kind) {
            .vertex, .fragment => saw_graphics = true,
            .compute => saw_compute = true,
        }
    }
    if (saw_graphics and saw_compute) {
        try analyzer.emitDiagnostic("KSL083", "graphics and compute stages cannot share one shader", shader_decl.span, "Split the graphics and compute work into separate shader declarations.");
        return error.DiagnosticsEmitted;
    }
    if (saw_compute) return .compute;
    return .graphics;
}

test "analyze basic textured shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const file = try source.SourceFile.initOwned(allocator, "test.ksl",
        \\type CameraUniform { let view_projection: Float4x4 }
        \\type SurfaceUniform { let tint: Float4 }
        \\type VertexIn { let position: Float3 let uv: Float2 }
        \\type VertexToFragment { @builtin(position) let clip_position: Float4 let uv: Float2 }
        \\type FragmentOut { let color: Float4 }
        \\shader TexturedQuad {
        \\    option use_tint: Bool = true
        \\    group Frame { uniform camera: CameraUniform }
        \\    group Material { uniform surface: SurfaceUniform texture albedo: Texture2d sampler linear: Sampler }
        \\    vertex {
        \\        input VertexIn
        \\        output VertexToFragment
        \\        function entry(input: VertexIn) -> VertexToFragment {
        \\            let out: VertexToFragment
        \\            out.clip_position = mul(camera.view_projection, Float4(input.position, 1.0))
        \\            out.uv = input.uv
        \\            return out
        \\        }
        \\    }
        \\    fragment {
        \\        input VertexToFragment
        \\        output FragmentOut
        \\        function entry(input: VertexToFragment) -> FragmentOut {
        \\            let out: FragmentOut
        \\            let sampled = sample(albedo, linear, input.uv)
        \\            if use_tint { out.color = sampled * surface.tint } else { out.color = sampled }
        \\            return out
        \\        }
        \\    }
        \\}
    );
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try ksl_parser.tokenize(allocator, &file, &diags);
    const module = try ksl_parser.parse(allocator, tokens, &diags);
    const program = try analyze(allocator, module, &.{}, &diags);
    try std.testing.expectEqual(@as(usize, 1), program.shaders.len);
}
