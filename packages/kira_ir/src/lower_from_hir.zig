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
                const reg = try lowerer.lowerExpr(&instructions, node.value);
                try instructions.append(.{ .store_local = .{ .local = node.local_id, .src = reg } });
            },
            .print_stmt => |node| {
                const reg = try lowerer.lowerExpr(&instructions, node.value);
                try instructions.append(.{ .print = .{ .src = reg } });
            },
            .call_stmt => |node| try instructions.append(.{ .call = .{ .callee = node.function_id } }),
            .return_stmt => try instructions.append(.{ .ret_void = {} }),
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
            .void => return error.UnsupportedType,
        };
    }
    return lowered;
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
                const lhs = try self.lowerExpr(instructions, node.lhs);
                const rhs = try self.lowerExpr(instructions, node.rhs);
                const dst = self.freshRegister();
                try instructions.append(.{ .add = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                break :blk dst;
            },
        };
    }
};
