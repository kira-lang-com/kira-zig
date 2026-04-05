const std = @import("std");
const ir = @import("ir.zig");
const model = @import("kira_semantics_model");

pub fn lowerProgram(allocator: std.mem.Allocator, program: model.Program) !ir.Program {
    var functions = std.array_list.Managed(ir.Function).init(allocator);
    for (program.functions) |function_decl| {
        try functions.append(try lowerFunction(allocator, function_decl));
    }
    return .{
        .functions = try functions.toOwnedSlice(),
        .entry_index = program.entry_index,
    };
}

fn lowerFunction(allocator: std.mem.Allocator, function_decl: model.Function) !ir.Function {
    var lowerer = Lowerer{
        .next_register = 0,
    };
    var instructions = std.array_list.Managed(ir.Instruction).init(allocator);

    for (function_decl.body) |statement| {
        switch (statement) {
            .let_stmt => |node| {
                if (node.value) |value| {
                    const reg = try lowerer.lowerExpr(&instructions, value);
                    try instructions.append(.{ .store_local = .{ .local = node.local_id, .src = reg } });
                }
            },
            .expr_stmt => |node| try lowerExprStatement(&lowerer, &instructions, node.expr),
            .if_stmt, .for_stmt, .switch_stmt => return error.UnsupportedExecutableFeature,
            .return_stmt => |node| {
                if (node.value != null) return error.UnsupportedExecutableFeature;
                try instructions.append(.{ .ret_void = {} });
            },
        }
    }

    if (instructions.items.len == 0 or instructions.items[instructions.items.len - 1] != .ret_void) {
        try instructions.append(.{ .ret_void = {} });
    }

    return .{
        .id = function_decl.id,
        .name = function_decl.name,
        .execution = function_decl.execution,
        .register_count = lowerer.next_register,
        .local_count = @as(u32, @intCast(function_decl.locals.len)),
        .local_types = try lowerLocalTypes(allocator, function_decl.locals),
        .instructions = try instructions.toOwnedSlice(),
    };
}

fn lowerLocalTypes(allocator: std.mem.Allocator, locals: []const model.LocalSymbol) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, locals.len);
    for (locals, 0..) |local, index| {
        lowered[index] = switch (local.ty) {
            .integer => .integer,
            .string => .string,
            .void, .float, .boolean, .named, .array, .unknown => return error.UnsupportedType,
        };
    }
    return lowered;
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
            if (call.function_id == null or call.args.len != 0) return error.UnsupportedExecutableFeature;
            try instructions.append(.{ .call = .{ .callee = call.function_id.? } });
        },
        else => return error.UnsupportedExecutableFeature,
    }
}

const Lowerer = struct {
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
            .float, .boolean, .namespace_ref, .call, .array, .unary => error.UnsupportedExecutableFeature,
            .string => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_string = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .local => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .load_local = .{ .dst = dst, .local = node.local_id } });
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

test "lowers zero-argument expression-statement calls even when return type is not resolved to void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const callee_expr = try allocator.create(model.Expr);
    callee_expr.* = .{ .call = .{
        .callee_name = "helper",
        .function_id = 1,
        .args = &.{},
        .ty = .unknown,
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
                .annotations = &.{},
                .params = &.{},
                .locals = &.{},
                .return_type = .void,
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
                .annotations = &.{},
                .params = &.{},
                .locals = &.{},
                .return_type = .void,
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
