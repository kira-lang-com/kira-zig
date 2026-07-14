//! Async-task lowering satellite for HIR -> IR (Core Law #5 split from
//! lower_from_hir.zig): deferred spawn, ready spawn, join, and the cooperative
//! handle operations. Semantics live with the IR instruction definitions in
//! ir.zig; execution lives in the VM interpreter and the LLVM task lowering.
const std = @import("std");
const ir = @import("ir.zig");
const InstructionBuf = @import("instruction_buf.zig").InstructionBuf;
const model = @import("kira_semantics_model");
const parent = @import("lower_from_hir.zig");
const type_impl = @import("lower_from_hir_types.zig");

const Lowerer = parent.Lowerer;
const lowerResolvedType = type_impl.lowerResolvedType;

/// Deferred spawn: args evaluate here, the call does not — it runs when the
/// task is first driven (await/detach).
pub fn lowerTaskSpawn(lowerer: *Lowerer, instructions: *InstructionBuf, node: model.hir.TaskSpawnExpr) !u32 {
    var arg_regs = std.array_list.Managed(u32).init(lowerer.allocator);
    defer arg_regs.deinit();
    for (node.args) |arg| try arg_regs.append(try lowerer.lowerExpr(instructions, arg));
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .task_spawn = .{
        .dst = dst,
        .callee = node.function_id,
        .args = try lowerer.allocator.dupe(u32, arg_regs.items),
        .result_ty = try lowerResolvedType(lowerer.program, node.ty),
    } });
    return dst;
}

pub fn lowerTaskSpawnReady(lowerer: *Lowerer, instructions: *InstructionBuf, node: model.hir.TaskSpawnReadyExpr) !u32 {
    const value_reg = try lowerer.lowerExpr(instructions, node.value);
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .task_spawn_ready = .{
        .dst = dst,
        .value = value_reg,
        .ty = try lowerResolvedType(lowerer.program, node.ty),
    } });
    return dst;
}

pub fn lowerTaskAwait(lowerer: *Lowerer, instructions: *InstructionBuf, node: model.hir.TaskAwaitExpr) !u32 {
    const task_reg = try lowerer.lowerExpr(instructions, node.task);
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .task_await = .{
        .dst = dst,
        .task = task_reg,
        .ty = try lowerResolvedType(lowerer.program, node.ty),
    } });
    return dst;
}

/// Cancel/detach are void-producing; a fresh zero register stands in for the
/// unused result slot.
pub fn lowerTaskCancel(lowerer: *Lowerer, instructions: *InstructionBuf, node: model.hir.TaskCancelExpr) !u32 {
    const task_reg = try lowerer.lowerExpr(instructions, node.task);
    try instructions.append(.{ .task_cancel = .{ .task = task_reg } });
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .const_int = .{ .dst = dst, .value = 0 } });
    return dst;
}

pub fn lowerTaskDetach(lowerer: *Lowerer, instructions: *InstructionBuf, node: model.hir.TaskDetachExpr) !u32 {
    const task_reg = try lowerer.lowerExpr(instructions, node.task);
    try instructions.append(.{ .task_detach = .{ .task = task_reg } });
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .const_int = .{ .dst = dst, .value = 0 } });
    return dst;
}
