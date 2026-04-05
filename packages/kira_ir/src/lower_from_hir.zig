const std = @import("std");
const ir = @import("ir.zig");
const model = @import("kira_semantics_model");

pub fn lowerProgram(allocator: std.mem.Allocator, program: model.Program) !ir.Program {
    var reachable = std.AutoHashMapUnmanaged(u32, void){};
    defer reachable.deinit(allocator);
    try markReachableFunction(allocator, program, &reachable, program.functions[program.entry_index].id);

    const types = try lowerTypeDecls(allocator, program, reachable);
    var functions = std.array_list.Managed(ir.Function).init(allocator);
    var entry_index: ?usize = null;
    for (program.functions) |function_decl| {
        if (!reachable.contains(function_decl.id)) continue;
        if (function_decl.id == program.functions[program.entry_index].id) entry_index = functions.items.len;
        try functions.append(try lowerFunction(allocator, program, function_decl));
    }
    return .{
        .types = types,
        .functions = try functions.toOwnedSlice(),
        .entry_index = entry_index orelse return error.UnsupportedExecutableFeature,
    };
}

fn lowerFunction(allocator: std.mem.Allocator, program: model.Program, function_decl: model.Function) !ir.Function {
    if (function_decl.is_extern) {
        return .{
            .id = function_decl.id,
            .name = function_decl.name,
            .execution = function_decl.execution,
            .is_extern = true,
            .foreign = if (function_decl.foreign) |foreign| .{
                .library_name = foreign.library_name,
                .symbol_name = foreign.symbol_name,
                .calling_convention = foreign.calling_convention,
            } else null,
            .param_types = try lowerParamTypes(allocator, program, function_decl.params),
            .return_type = try lowerResolvedType(program, function_decl.return_type),
            .register_count = 0,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{},
        };
    }

    var lowerer = Lowerer{
        .allocator = allocator,
        .program = program,
        .next_register = 0,
    };
    var instructions = std.array_list.Managed(ir.Instruction).init(allocator);

    for (function_decl.body) |statement| {
        switch (statement) {
            .let_stmt => |node| {
                if (node.value) |value| {
                    const reg = try lowerer.lowerExpr(&instructions, value);
                    if ((try lowerResolvedType(program, node.ty)).kind == .ffi_struct) {
                        const dst_ptr = lowerer.freshRegister();
                        try instructions.append(.{ .load_local = .{ .dst = dst_ptr, .local = node.local_id } });
                        try instructions.append(.{ .copy_indirect = .{
                            .dst_ptr = dst_ptr,
                            .src_ptr = reg,
                            .type_name = node.ty.name orelse return error.UnsupportedExecutableFeature,
                        } });
                    } else {
                        try instructions.append(.{ .store_local = .{ .local = node.local_id, .src = reg } });
                    }
                }
            },
            .assign_stmt => |node| try lowerAssignmentStatement(&lowerer, &instructions, program, node),
            .expr_stmt => |node| try lowerExprStatement(&lowerer, &instructions, node.expr),
            .if_stmt, .for_stmt, .switch_stmt => return error.UnsupportedExecutableFeature,
            .return_stmt => |node| {
                const src = if (node.value) |value| try lowerer.lowerExpr(&instructions, value) else null;
                try instructions.append(.{ .ret = .{ .src = src } });
            },
        }
    }

    if (instructions.items.len == 0 or instructions.items[instructions.items.len - 1] != .ret) {
        try instructions.append(.{ .ret = .{ .src = null } });
    }

    return .{
        .id = function_decl.id,
        .name = function_decl.name,
        .execution = function_decl.execution,
        .is_extern = false,
        .foreign = null,
        .param_types = try lowerParamTypes(allocator, program, function_decl.params),
        .return_type = try lowerResolvedType(program, function_decl.return_type),
        .register_count = lowerer.next_register,
        .local_count = @as(u32, @intCast(function_decl.locals.len)),
        .local_types = try lowerLocalTypes(allocator, program, function_decl.locals),
        .instructions = try instructions.toOwnedSlice(),
    };
}

fn lowerLocalTypes(allocator: std.mem.Allocator, program: model.Program, locals: []const model.LocalSymbol) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, locals.len);
    for (locals, 0..) |local, index| {
        lowered[index] = try lowerResolvedType(program, local.ty);
    }
    return lowered;
}

fn lowerParamTypes(allocator: std.mem.Allocator, program: model.Program, params: []const model.Parameter) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, params.len);
    for (params, 0..) |param, index| {
        lowered[index] = try lowerResolvedType(program, param.ty);
    }
    return lowered;
}

fn lowerResolvedType(program: model.Program, ty: model.ResolvedType) !ir.ValueType {
    return switch (ty.kind) {
        .void => .{ .kind = .void },
        .integer => .{ .kind = .integer, .name = ty.name },
        .float => .{ .kind = .float, .name = ty.name },
        .string => .{ .kind = .string },
        .boolean => .{ .kind = .boolean, .name = ty.name },
        .raw_ptr, .c_string, .callback => .{ .kind = .raw_ptr, .name = ty.name },
        .named => if (ty.name) |name| lowerNamedType(program, name) else return error.UnsupportedType,
        .ffi_struct, .array, .unknown => return error.UnsupportedType,
    };
}

fn lowerNamedType(program: model.Program, name: []const u8) anyerror!ir.ValueType {
    for (program.types) |type_decl| {
        if (!std.mem.eql(u8, type_decl.name, name)) continue;
        if (type_decl.ffi) |ffi_info| {
            return switch (ffi_info) {
                .pointer, .callback => .{ .kind = .raw_ptr, .name = name },
                .alias => |value| lowerResolvedType(program, value.target),
                .ffi_struct => .{ .kind = .ffi_struct, .name = name },
                .array => .{ .kind = .raw_ptr, .name = name },
            };
        }
    }
    if (std.mem.endsWith(u8, name, "_ptr")) return .{ .kind = .raw_ptr, .name = name };
    return error.UnsupportedType;
}

fn lowerExprStatement(lowerer: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), expr: *model.Expr) !void {
    switch (expr.*) {
        .call => |call| {
            if (std.mem.eql(u8, call.callee_name, "print")) {
                if (call.args.len != 1) return error.UnsupportedExecutableFeature;
                const reg = try lowerer.lowerExpr(instructions, call.args[0]);
                try instructions.append(.{ .print = .{ .src = reg } });
                return;
            }
            if (call.function_id == null) return error.UnsupportedExecutableFeature;
            var args = std.array_list.Managed(u32).init(lowerer.allocator);
            defer args.deinit();
            for (call.args) |arg| try args.append(try lowerer.lowerExpr(instructions, arg));
            try instructions.append(.{ .call = .{
                .callee = call.function_id.?,
                .args = try args.toOwnedSlice(),
                .dst = null,
            } });
        },
        else => return error.UnsupportedExecutableFeature,
    }
}

const Lowerer = struct {
    allocator: std.mem.Allocator,
    program: model.Program,
    next_register: u32,

    fn freshRegister(self: *Lowerer) u32 {
        const reg = self.next_register;
        self.next_register += 1;
        return reg;
    }

    fn lowerExpr(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), expr: *model.Expr) !u32 {
        return switch (expr.*) {
            .integer => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_int = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .boolean => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_bool = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .null_ptr => |node| blk: {
                _ = node;
                const dst = self.freshRegister();
                try instructions.append(.{ .const_null_ptr = .{ .dst = dst } });
                break :blk dst;
            },
            .function_ref => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_function = .{ .dst = dst, .function_id = node.function_id } });
                break :blk dst;
            },
            .float, .namespace_ref, .array, .unary => error.UnsupportedExecutableFeature,
            .string => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_string = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .call => |node| blk: {
                if (node.function_id == null) return error.UnsupportedExecutableFeature;
                if (node.ty.kind == .void) return error.UnsupportedExecutableFeature;
                var args = std.array_list.Managed(u32).init(self.allocator);
                defer args.deinit();
                for (node.args) |arg| try args.append(try self.lowerExpr(instructions, arg));
                const dst = self.freshRegister();
                try instructions.append(.{ .call = .{
                    .callee = node.function_id.?,
                    .args = try args.toOwnedSlice(),
                    .dst = dst,
                } });
                break :blk dst;
            },
            .local => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .load_local = .{ .dst = dst, .local = node.local_id } });
                break :blk dst;
            },
            .field => |node| blk: {
                const object_reg = try self.lowerExpr(instructions, node.object);
                const owner_name = node.owner_type.name orelse return error.UnsupportedExecutableFeature;
                const field_ptr = self.freshRegister();
                try instructions.append(.{ .field_ptr = .{
                    .dst = field_ptr,
                    .base = object_reg,
                    .owner_type_name = owner_name,
                    .field_name = node.field_name,
                } });
                const field_ty = try lowerResolvedType(self.program, node.ty);
                if (field_ty.kind == .ffi_struct) break :blk field_ptr;
                const dst = self.freshRegister();
                try instructions.append(.{ .load_indirect = .{
                    .dst = dst,
                    .ptr = field_ptr,
                    .ty = field_ty,
                } });
                break :blk dst;
            },
            .binary => |node| blk: {
                if (node.op != .add) return error.UnsupportedExecutableFeature;
                const lhs = try self.lowerExpr(instructions, node.lhs);
                const rhs = try self.lowerExpr(instructions, node.rhs);
                const dst = self.freshRegister();
                try instructions.append(.{ .add = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                break :blk dst;
            },
        };
    }
};

fn lowerTypeDecls(
    allocator: std.mem.Allocator,
    program: model.Program,
    reachable_functions: std.AutoHashMapUnmanaged(u32, void),
) ![]ir.TypeDecl {
    var referenced = std.StringHashMapUnmanaged(void){};
    defer referenced.deinit(allocator);

    for (program.functions) |function_decl| {
        if (!reachable_functions.contains(function_decl.id)) continue;
        for (function_decl.params) |param| try markReferencedType(allocator, program, &referenced, param.ty);
        try markReferencedType(allocator, program, &referenced, function_decl.return_type);
        for (function_decl.locals) |local| try markReferencedType(allocator, program, &referenced, local.ty);
    }

    var types = std.array_list.Managed(ir.TypeDecl).init(allocator);
    for (program.types) |type_decl| {
        if (!referenced.contains(type_decl.name)) continue;
        try types.append(.{
            .name = try allocator.dupe(u8, type_decl.name),
            .fields = try lowerFieldTypes(allocator, program, type_decl.fields),
            .ffi = if (type_decl.ffi) |ffi_info| try lowerFfiTypeInfo(allocator, program, ffi_info) else null,
        });
    }
    return types.toOwnedSlice();
}

fn markReachableFunction(
    allocator: std.mem.Allocator,
    program: model.Program,
    reachable: *std.AutoHashMapUnmanaged(u32, void),
    function_id: u32,
) anyerror!void {
    if (reachable.contains(function_id)) return;
    try reachable.put(allocator, function_id, {});

    for (program.functions) |function_decl| {
        if (function_decl.id != function_id) continue;
        if (function_decl.is_extern) return;
        for (function_decl.body) |statement| try markReachableStatement(allocator, program, reachable, statement);
        return;
    }
}

fn markReachableStatement(
    allocator: std.mem.Allocator,
    program: model.Program,
    reachable: *std.AutoHashMapUnmanaged(u32, void),
    statement: model.Statement,
) anyerror!void {
    switch (statement) {
        .let_stmt => |node| if (node.value) |value| try markReachableExpr(allocator, program, reachable, value),
        .assign_stmt => |node| {
            try markReachableExpr(allocator, program, reachable, node.target);
            try markReachableExpr(allocator, program, reachable, node.value);
        },
        .expr_stmt => |node| try markReachableExpr(allocator, program, reachable, node.expr),
        .if_stmt => |node| {
            try markReachableExpr(allocator, program, reachable, node.condition);
            for (node.then_body) |inner| try markReachableStatement(allocator, program, reachable, inner);
            if (node.else_body) |else_body| for (else_body) |inner| try markReachableStatement(allocator, program, reachable, inner);
        },
        .for_stmt => |node| {
            try markReachableExpr(allocator, program, reachable, node.iterator);
            for (node.body) |inner| try markReachableStatement(allocator, program, reachable, inner);
        },
        .switch_stmt => |node| {
            try markReachableExpr(allocator, program, reachable, node.subject);
            for (node.cases) |case_node| {
                try markReachableExpr(allocator, program, reachable, case_node.pattern);
                for (case_node.body) |inner| try markReachableStatement(allocator, program, reachable, inner);
            }
            if (node.default_body) |default_body| for (default_body) |inner| try markReachableStatement(allocator, program, reachable, inner);
        },
        .return_stmt => |node| if (node.value) |value| try markReachableExpr(allocator, program, reachable, value),
    }
}

fn markReachableExpr(
    allocator: std.mem.Allocator,
    program: model.Program,
    reachable: *std.AutoHashMapUnmanaged(u32, void),
    expr: *model.Expr,
) anyerror!void {
    switch (expr.*) {
        .call => |node| {
            if (node.function_id) |function_id| try markReachableFunction(allocator, program, reachable, function_id);
            for (node.args) |arg| try markReachableExpr(allocator, program, reachable, arg);
        },
        .function_ref => |node| try markReachableFunction(allocator, program, reachable, node.function_id),
        .field => |node| try markReachableExpr(allocator, program, reachable, node.object),
        .binary => |node| {
            try markReachableExpr(allocator, program, reachable, node.lhs);
            try markReachableExpr(allocator, program, reachable, node.rhs);
        },
        .unary => |node| try markReachableExpr(allocator, program, reachable, node.operand),
        .array => |node| for (node.elements) |element| try markReachableExpr(allocator, program, reachable, element),
        else => {},
    }
}

fn markReferencedType(
    allocator: std.mem.Allocator,
    program: model.Program,
    referenced: *std.StringHashMapUnmanaged(void),
    ty: model.ResolvedType,
) !void {
    if (ty.kind != .named or ty.name == null) return;
    const name = ty.name.?;
    if (referenced.contains(name)) return;
    try referenced.put(allocator, name, {});

    for (program.types) |type_decl| {
        if (!std.mem.eql(u8, type_decl.name, name)) continue;
        for (type_decl.fields) |field_decl| try markReferencedType(allocator, program, referenced, field_decl.ty);
        if (type_decl.ffi) |ffi_info| {
            switch (ffi_info) {
                .pointer => |value| try markReferencedType(allocator, program, referenced, .{ .kind = .named, .name = value.target_name }),
                .alias => |value| try markReferencedType(allocator, program, referenced, value.target),
                .array => |value| try markReferencedType(allocator, program, referenced, value.element),
                .callback => |value| {
                    for (value.params) |param| try markReferencedType(allocator, program, referenced, param);
                    try markReferencedType(allocator, program, referenced, value.result);
                },
                .ffi_struct => {},
            }
        }
        break;
    }
}

fn lowerFieldTypes(allocator: std.mem.Allocator, program: model.Program, fields: []const model.Field) ![]ir.Field {
    const lowered = try allocator.alloc(ir.Field, fields.len);
    for (fields, 0..) |field_decl, index| {
        lowered[index] = .{
            .name = try allocator.dupe(u8, field_decl.name),
            .ty = try lowerResolvedType(program, field_decl.ty),
        };
    }
    return lowered;
}

fn lowerFfiTypeInfo(allocator: std.mem.Allocator, program: model.Program, ffi_info: model.NamedTypeInfo) !ir.FfiTypeInfo {
    return switch (ffi_info) {
        .ffi_struct => .ffi_struct,
        .pointer => |value| .{ .pointer = .{ .target_name = try allocator.dupe(u8, value.target_name) } },
        .alias => |value| .{ .alias = .{ .target = try lowerResolvedType(program, value.target) } },
        .array => |value| .{ .array = .{
            .element = try lowerResolvedType(program, value.element),
            .count = value.count,
        } },
        .callback => |value| blk: {
            var params = std.array_list.Managed(ir.ValueType).init(allocator);
            for (value.params) |param| try params.append(try lowerResolvedType(program, param));
            break :blk .{ .callback = .{
                .params = try params.toOwnedSlice(),
                .result = try lowerResolvedType(program, value.result),
            } };
        },
    };
}

fn lowerAssignmentStatement(
    lowerer: *Lowerer,
    instructions: *std.array_list.Managed(ir.Instruction),
    program: model.Program,
    node: model.AssignStatement,
) !void {
    const value_reg = try lowerer.lowerExpr(instructions, node.value);
    switch (node.target.*) {
        .local => |target| {
            const local_ty = try lowerResolvedType(program, target.ty);
            if (local_ty.kind == .ffi_struct) {
                const dst_ptr = lowerer.freshRegister();
                try instructions.append(.{ .load_local = .{ .dst = dst_ptr, .local = target.local_id } });
                try instructions.append(.{ .copy_indirect = .{
                    .dst_ptr = dst_ptr,
                    .src_ptr = value_reg,
                    .type_name = local_ty.name orelse return error.UnsupportedExecutableFeature,
                } });
            } else {
                try instructions.append(.{ .store_local = .{ .local = target.local_id, .src = value_reg } });
            }
        },
        .field => |target| {
            const base_reg = try lowerer.lowerExpr(instructions, target.object);
            const owner_name = target.owner_type.name orelse return error.UnsupportedExecutableFeature;
            const ptr_reg = lowerer.freshRegister();
            try instructions.append(.{ .field_ptr = .{
                .dst = ptr_reg,
                .base = base_reg,
                .owner_type_name = owner_name,
                .field_name = target.field_name,
            } });
            const target_ty = try lowerResolvedType(program, target.ty);
            if (target_ty.kind == .ffi_struct) {
                try instructions.append(.{ .copy_indirect = .{
                    .dst_ptr = ptr_reg,
                    .src_ptr = value_reg,
                    .type_name = target_ty.name orelse return error.UnsupportedExecutableFeature,
                } });
            } else {
                try instructions.append(.{ .store_indirect = .{
                    .ptr = ptr_reg,
                    .src = value_reg,
                    .ty = target_ty,
                } });
            }
        },
        else => return error.UnsupportedExecutableFeature,
    }
}

test "lowers zero-argument expression-statement calls even when return type is not resolved to void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const callee_expr = try allocator.create(model.Expr);
    callee_expr.* = .{ .call = .{
        .callee_name = "helper",
        .function_id = 1,
        .args = &.{},
        .ty = .{ .kind = .unknown },
        .span = .{ .start = 0, .end = 0 },
    } };

    const program = model.Program{
        .imports = &.{},
        .constructs = &.{},
        .types = &.{},
        .forms = &.{},
        .functions = &.{
            .{
                .id = 0,
                .name = "entry",
                .is_main = true,
                .execution = .native,
                .is_extern = false,
                .foreign = null,
                .annotations = &.{},
                .params = &.{},
                .locals = &.{},
                .return_type = .{ .kind = .void },
                .body = &.{
                    .{ .expr_stmt = .{ .expr = callee_expr, .span = .{ .start = 0, .end = 0 } } },
                    .{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } },
                },
                .span = .{ .start = 0, .end = 0 },
            },
            .{
                .id = 1,
                .name = "helper",
                .is_main = false,
                .execution = .runtime,
                .is_extern = false,
                .foreign = null,
                .annotations = &.{},
                .params = &.{},
                .locals = &.{},
                .return_type = .{ .kind = .void },
                .body = &.{.{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } }},
                .span = .{ .start = 0, .end = 0 },
            },
        },
        .entry_index = 0,
    };

    const lowered = try lowerProgram(allocator, program);
    try std.testing.expectEqual(@as(usize, 2), lowered.functions.len);
    try std.testing.expect(lowered.functions[0].instructions[0] == .call);
}
