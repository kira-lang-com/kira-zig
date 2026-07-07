//! Function-level HIR -> IR lowering machinery: per-function lowering plans
//! (with deterministic generated-callback id ranges), serial and parallel plan
//! execution, lowering of a single function declaration into an IR function,
//! and the deep-clone helpers that move arena-allocated parallel results onto
//! the caller's allocator.
const builtin = @import("builtin");
const std = @import("std");
const ir = @import("ir.zig");
const model = @import("kira_semantics_model");
const parent = @import("lower_from_hir.zig");
const type_impl = @import("lower_from_hir_types.zig");
const boxed_impl = @import("lower_from_hir_boxed.zig");
const callback_impl = @import("lower_from_hir_callbacks.zig");

const Lowerer = parent.Lowerer;
const UnsupportedFeature = parent.UnsupportedFeature;
const LowerProgramOptions = parent.LowerProgramOptions;
const lowerResolvedType = type_impl.lowerResolvedType;
const lowerOwnershipMode = parent.lowerOwnershipMode;
const collectBoxedLocals = boxed_impl.collectBoxedLocals;

pub const FunctionPlan = struct {
    function_decl: model.Function,
    first_generated_id: u32,
    generated_count: u32,
};

pub fn buildFunctionPlans(
    allocator: std.mem.Allocator,
    program: model.Program,
    reachable: std.AutoHashMapUnmanaged(u32, void),
) ![]FunctionPlan {
    var plans = std.array_list.Managed(FunctionPlan).init(allocator);
    var next_generated_id = nextGeneratedFunctionId(program);
    for (program.functions) |function_decl| {
        if (!reachable.contains(function_decl.id)) continue;
        const generated_count = callback_impl.countCallbacksInStatements(function_decl.body);
        try plans.append(.{
            .function_decl = function_decl,
            .first_generated_id = next_generated_id,
            .generated_count = generated_count,
        });
        next_generated_id += generated_count;
    }
    return plans.toOwnedSlice();
}

pub const FunctionLoweringState = struct {
    next_generated_function_id: u32,
    generated_functions: std.array_list.Managed(ir.Function),
    /// Threaded from `LowerProgramOptions.unsupported_out`; the Lowerer records
    /// the failing construct here via `recordUnsupported`. Null when the caller
    /// is not collecting diagnostics.
    unsupported: ?*UnsupportedFeature = null,
};

pub const LoweredFunctionBatch = struct {
    primary: ir.Function,
    generated_functions: []ir.Function,
};

fn nextGeneratedFunctionId(program: model.Program) u32 {
    var next_id: u32 = 0;
    for (program.functions) |function_decl| {
        if (function_decl.id >= next_id) next_id = function_decl.id + 1;
    }
    return next_id;
}

pub fn lowerFunctionPlansSerial(
    allocator: std.mem.Allocator,
    program: model.Program,
    plans: []const FunctionPlan,
    unsupported: ?*UnsupportedFeature,
) ![]LoweredFunctionBatch {
    const batches = try allocator.alloc(LoweredFunctionBatch, plans.len);
    for (plans, 0..) |plan, index| {
        batches[index] = try lowerFunctionBatch(allocator, program, plan, unsupported);
    }
    return batches;
}

fn lowerFunctionBatch(
    allocator: std.mem.Allocator,
    program: model.Program,
    plan: FunctionPlan,
    unsupported: ?*UnsupportedFeature,
) !LoweredFunctionBatch {
    var state = FunctionLoweringState{
        .next_generated_function_id = plan.first_generated_id,
        .generated_functions = std.array_list.Managed(ir.Function).init(allocator),
        .unsupported = unsupported,
    };
    errdefer state.generated_functions.deinit();

    const primary = try lowerFunction(allocator, program, plan.function_decl, &state);
    const generated_functions = try state.generated_functions.toOwnedSlice();
    if (state.next_generated_function_id != plan.first_generated_id + plan.generated_count) {
        return error.GeneratedCallbackPlanMismatch;
    }
    return .{
        .primary = primary,
        .generated_functions = generated_functions,
    };
}

pub fn shouldParallelLower(options: LowerProgramOptions, plan_count: usize) bool {
    _ = options;
    _ = plan_count;
    return false;
}

fn resolveLowerWorkerCount(options: LowerProgramOptions, plan_count: usize) usize {
    if (plan_count < 4) return 1;
    if (options.worker_count_override) |override| {
        if (override == 0) return 1;
        return @min(override, plan_count);
    }

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const cap = switch (builtin.os.tag) {
        .windows => @min(cpu_count, 4),
        else => @min(cpu_count, 8),
    };
    return @max(@min(cap, plan_count), 1);
}

const ParallelLowerResult = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    batch: ?LoweredFunctionBatch = null,
    err: ?anyerror = null,

    fn deinit(self: *ParallelLowerResult) void {
        if (self.arena) |arena_ptr| {
            arena_ptr.deinit();
            std.heap.smp_allocator.destroy(arena_ptr);
        }
        self.* = .{};
    }
};

const ParallelLowerShared = struct {
    program: model.Program,
    plans: []const FunctionPlan,
    results: []ParallelLowerResult,
    unsupported: ?*UnsupportedFeature = null,
    next_index: std.atomic.Value(usize) = .init(0),

    fn runUntilDone(self: *ParallelLowerShared) void {
        while (true) {
            const index = self.next_index.fetchAdd(1, .monotonic);
            if (index >= self.plans.len) break;
            self.runJob(index);
        }
    }

    fn runJob(self: *ParallelLowerShared, index: usize) void {
        const result = &self.results[index];
        const arena_ptr = std.heap.smp_allocator.create(std.heap.ArenaAllocator) catch {
            result.err = error.OutOfMemory;
            return;
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        const allocator = arena_ptr.allocator();

        const batch = lowerFunctionBatch(allocator, self.program, self.plans[index], self.unsupported) catch |err| {
            result.arena = arena_ptr;
            result.err = err;
            return;
        };

        result.arena = arena_ptr;
        result.batch = batch;
    }
};

fn parallelLowerWorkerMain(shared: *ParallelLowerShared) void {
    shared.runUntilDone();
}

pub fn lowerFunctionPlansParallel(
    allocator: std.mem.Allocator,
    program: model.Program,
    plans: []const FunctionPlan,
    options: LowerProgramOptions,
) ![]LoweredFunctionBatch {
    const worker_count = resolveLowerWorkerCount(options, plans.len);
    if (worker_count <= 1) return lowerFunctionPlansSerial(allocator, program, plans, options.unsupported_out);

    const results = try allocator.alloc(ParallelLowerResult, plans.len);
    for (results) |*result| result.* = .{};
    defer {
        for (results) |*result| result.deinit();
        allocator.free(results);
    }

    var shared = ParallelLowerShared{
        .program = program,
        .plans = plans,
        .results = results,
        .unsupported = options.unsupported_out,
    };

    const extra_workers = worker_count - 1;
    const threads = try allocator.alloc(std.Thread, extra_workers);
    defer allocator.free(threads);
    var spawned: usize = 0;
    errdefer {
        shared.runUntilDone();
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, parallelLowerWorkerMain, .{&shared});
        spawned += 1;
    }
    shared.runUntilDone();
    for (threads) |thread| thread.join();

    const batches = try allocator.alloc(LoweredFunctionBatch, plans.len);
    errdefer allocator.free(batches);
    for (results, 0..) |*result, index| {
        if (result.err) |err| return err;
        batches[index] = try cloneLoweredFunctionBatch(allocator, result.batch.?);
    }
    return batches;
}

fn lowerFunction(
    allocator: std.mem.Allocator,
    program: model.Program,
    function_decl: model.Function,
    state: *FunctionLoweringState,
) !ir.Function {
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
            .param_ownership = try lowerParamOwnership(allocator, function_decl.params),
            .return_type = try lowerResolvedType(program, function_decl.return_type),
            .return_ownership = lowerOwnershipMode(function_decl.return_ownership),
            .register_count = 0,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{},
        };
    }

    const boxed_locals = try collectBoxedLocals(allocator, function_decl.locals.len, function_decl.body);
    var lowerer = Lowerer{
        .allocator = allocator,
        .program = program,
        .state = state,
        .execution = function_decl.execution,
        .function_name = function_decl.name,
        .next_register = 0,
        .next_label = 0,
        .next_local = @as(u32, @intCast(function_decl.locals.len)),
        .hidden_local_types = std.array_list.Managed(ir.ValueType).init(allocator),
        .loop_stack = std.array_list.Managed(Lowerer.LoopLabels).init(allocator),
        .boxed_locals = boxed_locals,
    };
    defer allocator.free(boxed_locals);
    defer lowerer.hidden_local_types.deinit();
    defer lowerer.loop_stack.deinit();
    // On an unsupported-feature failure anywhere below, record the construct the
    // lowerer was on so KIR001 can point at it. Innermost frame wins.
    errdefer |err| parent.recordUnsupported(state.unsupported, lowerer.current_span, lowerer.current_construct, err);
    var instructions = std.array_list.Managed(ir.Instruction).init(allocator);
    for (function_decl.locals) |local| {
        if (!local.is_param or !lowerer.isBoxedLocal(local.id)) continue;
        const value_reg = lowerer.freshRegister();
        try instructions.append(.{ .load_local = .{ .dst = value_reg, .local = local.id } });
        try lowerer.initializeBoxedLocal(&instructions, local.id, try lowerResolvedType(program, local.ty), value_reg);
    }
    const terminated = try lowerer.lowerStatements(&instructions, function_decl.body);

    if (!terminated and (instructions.items.len == 0 or instructions.items[instructions.items.len - 1] != .ret)) {
        try instructions.append(.{ .ret = .{ .src = null } });
    }

    return .{
        .id = function_decl.id,
        .name = function_decl.name,
        .execution = function_decl.execution,
        .is_extern = false,
        .foreign = null,
        .param_types = try lowerParamTypes(allocator, program, function_decl.params),
        .param_ownership = try lowerParamOwnership(allocator, function_decl.params),
        .return_type = try lowerResolvedType(program, function_decl.return_type),
        .return_ownership = lowerOwnershipMode(function_decl.return_ownership),
        .register_count = lowerer.next_register,
        .local_count = lowerer.next_local,
        .local_types = try lowerAllLocalTypesBoxed(allocator, program, function_decl.locals, lowerer.hidden_local_types.items, boxed_locals),
        .instructions = try instructions.toOwnedSlice(),
    };
}

fn lowerAllLocalTypes(
    allocator: std.mem.Allocator,
    program: model.Program,
    locals: []const model.LocalSymbol,
    hidden_locals: []const ir.ValueType,
) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, locals.len + hidden_locals.len);
    for (locals, 0..) |local, index| {
        lowered[index] = try lowerResolvedType(program, local.ty);
    }
    for (hidden_locals, 0..) |local, index| {
        lowered[locals.len + index] = local;
    }
    return lowered;
}

fn lowerAllLocalTypesBoxed(
    allocator: std.mem.Allocator,
    program: model.Program,
    locals: []const model.LocalSymbol,
    hidden_locals: []const ir.ValueType,
    boxed_locals: []const bool,
) ![]ir.ValueType {
    const lowered = try lowerAllLocalTypes(allocator, program, locals, hidden_locals);
    for (boxed_locals, 0..) |boxed, index| {
        if (boxed and index < lowered.len) lowered[index] = .{ .kind = .raw_ptr, .name = "CaptureCell" };
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

fn lowerParamOwnership(allocator: std.mem.Allocator, params: []const model.Parameter) ![]const ir.OwnershipMode {
    const lowered = try allocator.alloc(ir.OwnershipMode, params.len);
    for (params, 0..) |param, index| lowered[index] = lowerOwnershipMode(param.ownership);
    return lowered;
}

fn cloneLoweredFunctionBatch(allocator: std.mem.Allocator, batch: LoweredFunctionBatch) !LoweredFunctionBatch {
    const generated_functions = try allocator.alloc(ir.Function, batch.generated_functions.len);
    for (batch.generated_functions, 0..) |function_decl, index| {
        generated_functions[index] = try cloneFunction(allocator, function_decl);
    }
    return .{
        .primary = try cloneFunction(allocator, batch.primary),
        .generated_functions = generated_functions,
    };
}

fn cloneFunction(allocator: std.mem.Allocator, function_decl: ir.Function) !ir.Function {
    return .{
        .id = function_decl.id,
        .name = try allocator.dupe(u8, function_decl.name),
        .execution = function_decl.execution,
        .is_extern = function_decl.is_extern,
        .foreign = if (function_decl.foreign) |foreign| .{
            .library_name = try allocator.dupe(u8, foreign.library_name),
            .symbol_name = try allocator.dupe(u8, foreign.symbol_name),
            .calling_convention = foreign.calling_convention,
        } else null,
        .param_types = try cloneValueTypeSlice(allocator, function_decl.param_types),
        .param_ownership = try cloneOwnershipModeSlice(allocator, function_decl.param_ownership),
        .return_type = function_decl.return_type,
        .return_ownership = function_decl.return_ownership,
        .register_count = function_decl.register_count,
        .local_count = function_decl.local_count,
        .local_types = try cloneValueTypeSlice(allocator, function_decl.local_types),
        .instructions = try cloneInstructionSlice(allocator, function_decl.instructions),
    };
}

fn cloneValueTypeSlice(allocator: std.mem.Allocator, items: []const ir.ValueType) ![]const ir.ValueType {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(ir.ValueType, items.len);
    @memcpy(cloned, items);
    return cloned;
}

fn cloneOwnershipModeSlice(allocator: std.mem.Allocator, items: []const ir.OwnershipMode) ![]const ir.OwnershipMode {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(ir.OwnershipMode, items.len);
    @memcpy(cloned, items);
    return cloned;
}

fn cloneInstructionSlice(allocator: std.mem.Allocator, items: []const ir.Instruction) ![]ir.Instruction {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(ir.Instruction, items.len);
    for (items, 0..) |instruction, index| {
        cloned[index] = try cloneInstruction(allocator, instruction);
    }
    return cloned;
}

fn cloneInstruction(allocator: std.mem.Allocator, instruction: ir.Instruction) !ir.Instruction {
    return switch (instruction) {
        .const_closure => |value| .{ .const_closure = .{
            .dst = value.dst,
            .function_id = value.function_id,
            .captures = try cloneU32Slice(allocator, value.captures),
            .capture_ownership = try cloneOwnershipModeSlice(allocator, value.capture_ownership),
        } },
        .call => |value| .{ .call = .{
            .callee = value.callee,
            .args = try cloneU32Slice(allocator, value.args),
            .dst = value.dst,
        } },
        .call_virtual => |value| .{ .call_virtual = .{
            .receiver = value.receiver,
            .static_type_name = try allocator.dupe(u8, value.static_type_name),
            .method_name = try allocator.dupe(u8, value.method_name),
            .args = try cloneU32Slice(allocator, value.args),
            .return_ty = value.return_ty,
            .dst = value.dst,
        } },
        .call_value => |value| .{ .call_value = .{
            .callee = value.callee,
            .args = try cloneU32Slice(allocator, value.args),
            .param_types = try cloneValueTypeSlice(allocator, value.param_types),
            .param_ownership = try cloneOwnershipModeSlice(allocator, value.param_ownership),
            .return_type = value.return_type,
            .dst = value.dst,
        } },
        .scope_exit => |value| .{ .scope_exit = .{
            .locals = try cloneU32Slice(allocator, value.locals),
        } },
        else => instruction,
    };
}

fn cloneU32Slice(allocator: std.mem.Allocator, items: []const u32) ![]const u32 {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(u32, items.len);
    @memcpy(cloned, items);
    return cloned;
}
