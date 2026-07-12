//! Async state-machine transform (saved-frame suspension).
//!
//! Rewrites eligible async function bodies that contain `task_yield` into
//! resumable state machines, running on the SHARED IR so every backend
//! compiles identical semantics:
//!
//!   * The body's params/locals are externalized into a heap task frame
//!     (slot 0 = resume state, slot 1 = result, slots 2.. = params/locals);
//!     the function's signature becomes `(frame: RawPtr) -> Int` where the
//!     return value is a drive status (0 complete / 1 suspended).
//!   * Each `task_yield` becomes: store resume state, return SUSPENDED. The
//!     executor re-enqueues a suspended task at the back of the FIFO — true
//!     round-robin interleaving — and the next drive re-enters through a
//!     prologue dispatch that jumps to the matching resume label.
//!   * `ret x` becomes: store x into the result slot, return COMPLETE.
//!
//! Eligibility (graceful: ineligible bodies keep the nested-drive yield
//! semantics — the decision happens here, pre-backend, so all backends agree):
//!   * every param/local is a scalar (Int/Float/Bool) — the frame holds plain
//!     slots, no ownership;
//!   * no `local_ptr` (borrow writeback machinery) and no `const_closure`
//!     (captures address locals);
//!   * no register's linear live range spans a yield: a resume jump must not
//!     skip a register definition (LLVM registers are SSA values). Prologue
//!     registers are exempt — their defs sit in the entry block, which
//!     dominates every resume label.
//!   * the function is only ever referenced by `task_spawn` (never called
//!     directly, never taken as a value).
const std = @import("std");
const ir = @import("ir.zig");
const InstructionBuf = @import("instruction_buf.zig").InstructionBuf;

/// Rewrite every eligible yielding async body in `program` and flag its
/// spawn sites (`suspendable` + `frame_slots`).
pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !void {
    for (program.functions, 0..) |function_decl, index| {
        if (!isEligible(program.*, function_decl)) continue;
        var await_count: u32 = 0;
        for (function_decl.instructions) |inst| {
            if (inst == .task_await) await_count += 1;
        }
        // Frame layout: state, result, params/locals, then one parked-handle
        // slot per await suspend point.
        const frame_slots = ir.frame_first_data_slot + function_decl.local_count + await_count;
        program.functions[index] = try transformFunction(allocator, function_decl);
        markSpawnSites(program.*, function_decl.id, frame_slots);
    }
}

fn isScalar(kind: ir.ValueType.Kind) bool {
    return kind == .integer or kind == .float or kind == .boolean;
}

fn isEligible(program: ir.Program, function_decl: ir.Function) bool {
    if (!function_decl.is_async or function_decl.is_extern) return false;

    var has_suspend_point = false;
    for (function_decl.instructions) |inst| {
        switch (inst) {
            // Yields and joins both suspend a state-machine body.
            .task_yield, .task_await, .task_sleep => has_suspend_point = true,
            // Locals must be plain frame slots.
            .local_ptr, .const_closure => return false,
            else => {},
        }
    }
    if (!has_suspend_point) return false;

    for (function_decl.local_types) |local_ty| {
        if (!isScalar(local_ty.kind)) return false;
    }
    if (!isScalar(function_decl.return_type.kind) and function_decl.return_type.kind != .void) return false;

    // No register live range may span a yield (a resume jump would skip the
    // definition). Linear ranges are conservative and sound: any def-before /
    // read-after pair around a yield rejects.
    if (registerRangeSpansYield(function_decl)) return false;

    // Only task_spawn may reference the function; a direct call re-enters a
    // body that no longer has its own locals.
    for (program.functions) |other| {
        for (other.instructions) |inst| {
            switch (inst) {
                .call => |v| if (v.callee == function_decl.id) return false,
                .const_function => |v| if (v.function_id == function_decl.id) return false,
                else => {},
            }
        }
    }
    return true;
}

fn registerRangeSpansYield(function_decl: ir.Function) bool {
    var min_def = std.AutoHashMapUnmanaged(u32, usize){};
    var max_read = std.AutoHashMapUnmanaged(u32, usize){};
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    defer min_def.deinit(fba.allocator());
    defer max_read.deinit(fba.allocator());

    for (function_decl.instructions, 0..) |inst, index| {
        if (registerWrite(inst)) |dst| {
            const entry = min_def.getOrPut(fba.allocator(), dst) catch return true;
            if (!entry.found_existing) entry.value_ptr.* = index;
        }
        forEachRead(inst, struct {
            reads: *std.AutoHashMapUnmanaged(u32, usize),
            alloc: std.mem.Allocator,
            index: usize,
            fn on(self: @This(), register: u32) void {
                const entry = self.reads.getOrPut(self.alloc, register) catch return;
                entry.value_ptr.* = self.index;
            }
        }{ .reads = &max_read, .alloc = fba.allocator(), .index = index });
    }

    for (function_decl.instructions, 0..) |inst, suspend_index| {
        if (inst != .task_yield and inst != .task_await and inst != .task_sleep) continue;
        var it = min_def.iterator();
        while (it.next()) |entry| {
            const read_index = max_read.get(entry.key_ptr.*) orelse continue;
            if (entry.value_ptr.* < suspend_index and read_index > suspend_index) return true;
        }
    }
    return false;
}

fn registerWrite(inst: ir.Instruction) ?u32 {
    return switch (inst) {
        .const_int => |v| v.dst,
        .const_float => |v| v.dst,
        .const_string => |v| v.dst,
        .const_bool => |v| v.dst,
        .const_null_ptr => |v| v.dst,
        .const_function => |v| v.dst,
        .const_closure => |v| v.dst,
        .alloc_struct => |v| v.dst,
        .alloc_enum => |v| v.dst,
        .alloc_native_state => |v| v.dst,
        .alloc_array => |v| v.dst,
        .add => |v| v.dst,
        .subtract => |v| v.dst,
        .multiply => |v| v.dst,
        .divide => |v| v.dst,
        .modulo => |v| v.dst,
        .bitwise => |v| v.dst,
        .convert => |v| v.dst,
        .compare => |v| v.dst,
        .unary => |v| v.dst,
        .load_local => |v| v.dst,
        .local_ptr => |v| v.dst,
        .subobject_ptr => |v| v.dst,
        .field_ptr => |v| v.dst,
        .recover_native_state => |v| v.dst,
        .native_state_field_get => |v| v.dst,
        .c_string_to_string => |v| v.dst,
        .array_len => |v| v.dst,
        .string_len => |v| v.dst,
        .array_get => |v| v.dst,
        .enum_tag => |v| v.dst,
        .enum_payload => |v| v.dst,
        .load_indirect => |v| v.dst,
        .call => |v| v.dst,
        .call_virtual => |v| v.dst,
        .call_value => |v| v.dst,
        .task_spawn => |v| v.dst,
        .task_spawn_ready => |v| v.dst,
        .task_await => |v| v.dst,
        .task_is_complete => |v| v.dst,
        .frame_get => |v| v.dst,
        else => null,
    };
}

fn forEachRead(inst: ir.Instruction, ctx: anytype) void {
    switch (inst) {
        .const_closure => |v| for (v.captures) |r| ctx.on(r),
        .alloc_enum => |v| if (v.payload_src) |r| ctx.on(r),
        .alloc_native_state => |v| ctx.on(v.src),
        .alloc_array => |v| ctx.on(v.len),
        .add, .subtract, .multiply, .divide, .modulo => |v| {
            ctx.on(v.lhs);
            ctx.on(v.rhs);
        },
        .bitwise => |v| {
            ctx.on(v.lhs);
            ctx.on(v.rhs);
        },
        .convert => |v| ctx.on(v.src),
        .compare => |v| {
            ctx.on(v.lhs);
            ctx.on(v.rhs);
        },
        .unary => |v| ctx.on(v.src),
        .store_local => |v| ctx.on(v.src),
        .subobject_ptr => |v| ctx.on(v.base),
        .field_ptr => |v| ctx.on(v.base),
        .recover_native_state => |v| ctx.on(v.state),
        .free_native_state => |v| ctx.on(v.state),
        .native_state_field_get => |v| ctx.on(v.state),
        .native_state_field_set => |v| {
            ctx.on(v.state);
            ctx.on(v.src);
        },
        .c_string_to_string => |v| ctx.on(v.src),
        .array_len => |v| ctx.on(v.array),
        .string_len => |v| ctx.on(v.string),
        .array_get => |v| {
            ctx.on(v.array);
            ctx.on(v.index);
        },
        .array_set => |v| {
            ctx.on(v.array);
            ctx.on(v.index);
            ctx.on(v.src);
        },
        .array_append => |v| {
            ctx.on(v.array);
            ctx.on(v.src);
        },
        .enum_tag => |v| ctx.on(v.src),
        .enum_payload => |v| ctx.on(v.src),
        .load_indirect => |v| ctx.on(v.ptr),
        .store_indirect => |v| {
            ctx.on(v.ptr);
            ctx.on(v.src);
        },
        .copy_indirect => |v| {
            ctx.on(v.dst_ptr);
            ctx.on(v.src_ptr);
        },
        .branch => |v| ctx.on(v.condition),
        .print => |v| ctx.on(v.src),
        .call => |v| for (v.args) |r| ctx.on(r),
        .call_virtual => |v| {
            ctx.on(v.receiver);
            for (v.args) |r| ctx.on(r);
        },
        .call_value => |v| {
            ctx.on(v.callee);
            for (v.args) |r| ctx.on(r);
        },
        .ret => |v| if (v.src) |r| ctx.on(r),
        .task_spawn => |v| for (v.args) |r| ctx.on(r),
        .task_spawn_ready => |v| ctx.on(v.value),
        .task_await => |v| ctx.on(v.task),
        .task_cancel => |v| ctx.on(v.task),
        .task_detach => |v| ctx.on(v.task),
        .task_sleep => |v| ctx.on(v.milliseconds),
        .task_is_complete => |v| ctx.on(v.task),
        .frame_get => |v| ctx.on(v.frame),
        .frame_set => |v| {
            ctx.on(v.frame);
            ctx.on(v.src);
        },
        else => {},
    }
}

fn transformFunction(allocator: std.mem.Allocator, function_decl: ir.Function) !ir.Function {
    var suspend_count: u32 = 0;
    var max_label: u32 = 0;
    for (function_decl.instructions) |inst| {
        switch (inst) {
            .task_yield, .task_await, .task_sleep => suspend_count += 1,
            .label => |v| max_label = @max(max_label, v.id),
            else => {},
        }
    }

    var next_register = function_decl.register_count;
    var next_label = max_label + 1;
    const int_ty: ir.ValueType = .{ .kind = .integer, .name = "I64" };
    const result_ty: ir.ValueType = if (function_decl.return_type.kind == .void) int_ty else function_decl.return_type;

    var out = InstructionBuf.init(allocator, &InstructionBuf.null_span);
    // Async lowering drops per-instruction spans for now; free the unused
    // locations buffer (toOwnedInstructions consumes only the instruction list).
    defer out.deinit();

    // Prologue: load the frame pointer (the only real local) and dispatch on
    // the resume state. Entry-block defs dominate every resume label.
    const r_frame = next_register;
    next_register += 1;
    try out.append(.{ .load_local = .{ .dst = r_frame, .local = 0, .ownership = .borrow_read } });
    const r_state = next_register;
    next_register += 1;
    try out.append(.{ .frame_get = .{ .dst = r_state, .frame = r_frame, .slot = ir.frame_state_slot, .ty = int_ty } });
    const resume_labels = try allocator.alloc(u32, suspend_count);
    for (resume_labels) |*label| {
        label.* = next_label;
        next_label += 1;
    }
    var check: u32 = 0;
    while (check < suspend_count) : (check += 1) {
        const r_expected = next_register;
        next_register += 1;
        try out.append(.{ .const_int = .{ .dst = r_expected, .value = @as(i64, check) + 1 } });
        const r_is = next_register;
        next_register += 1;
        try out.append(.{ .compare = .{ .dst = r_is, .lhs = r_state, .rhs = r_expected, .op = .equal } });
        const fallthrough = next_label;
        next_label += 1;
        try out.append(.{ .branch = .{ .condition = r_is, .true_label = resume_labels[check], .false_label = fallthrough } });
        try out.append(.{ .label = .{ .id = fallthrough } });
    }

    // Body: locals -> frame slots; yields/joins -> suspend/resume; returns ->
    // result slot + COMPLETE status.
    const raw_ptr_ty: ir.ValueType = .{ .kind = .raw_ptr, .name = "Task" };
    const await_slot_base = ir.frame_first_data_slot + function_decl.local_count;
    var suspend_index: u32 = 0;
    var await_index: u32 = 0;
    for (function_decl.instructions) |inst| {
        switch (inst) {
            .load_local => |v| try out.append(.{ .frame_get = .{
                .dst = v.dst,
                .frame = r_frame,
                .slot = ir.frame_first_data_slot + v.local,
                .ty = function_decl.local_types[v.local],
            } }),
            .store_local => |v| try out.append(.{ .frame_set = .{
                .frame = r_frame,
                .slot = ir.frame_first_data_slot + v.local,
                .src = v.src,
                .ty = function_decl.local_types[v.local],
            } }),
            .task_yield => {
                const r_next_state = next_register;
                next_register += 1;
                try out.append(.{ .const_int = .{ .dst = r_next_state, .value = @as(i64, suspend_index) + 1 } });
                try out.append(.{ .frame_set = .{ .frame = r_frame, .slot = ir.frame_state_slot, .src = r_next_state, .ty = int_ty } });
                const r_suspended = next_register;
                next_register += 1;
                try out.append(.{ .const_int = .{ .dst = r_suspended, .value = ir.task_status_suspended } });
                try out.append(.{ .ret = .{ .src = r_suspended } });
                try out.append(.{ .label = .{ .id = resume_labels[suspend_index] } });
                suspend_index += 1;
            },
            .task_sleep => |v| {
                // Park-with-deadline: the runtime records the wake time on the
                // current task, then the body suspends; the executor skips it
                // until the deadline passes.
                try out.append(.{ .task_sleep = .{ .milliseconds = v.milliseconds } });
                const r_next_state = next_register;
                next_register += 1;
                try out.append(.{ .const_int = .{ .dst = r_next_state, .value = @as(i64, suspend_index) + 1 } });
                try out.append(.{ .frame_set = .{ .frame = r_frame, .slot = ir.frame_state_slot, .src = r_next_state, .ty = int_ty } });
                const r_suspended = next_register;
                next_register += 1;
                try out.append(.{ .const_int = .{ .dst = r_suspended, .value = ir.task_status_suspended } });
                try out.append(.{ .ret = .{ .src = r_suspended } });
                try out.append(.{ .label = .{ .id = resume_labels[suspend_index] } });
                suspend_index += 1;
            },
            .task_await => |v| {
                // Join = park-until-complete: save the handle to its frame
                // slot, then loop { complete? join : suspend }. The resume
                // label sits at the recheck so a resumed body re-tests the
                // parked handle rather than recomputing the receiver.
                const park_slot = await_slot_base + await_index;
                await_index += 1;
                try out.append(.{ .frame_set = .{ .frame = r_frame, .slot = park_slot, .src = v.task, .ty = raw_ptr_ty } });
                try out.append(.{ .label = .{ .id = resume_labels[suspend_index] } });
                const r_saved = next_register;
                next_register += 1;
                try out.append(.{ .frame_get = .{ .dst = r_saved, .frame = r_frame, .slot = park_slot, .ty = raw_ptr_ty } });
                const r_done = next_register;
                next_register += 1;
                try out.append(.{ .task_is_complete = .{ .dst = r_done, .task = r_saved } });
                const proceed_label = next_label;
                next_label += 1;
                const suspend_label = next_label;
                next_label += 1;
                try out.append(.{ .branch = .{ .condition = r_done, .true_label = proceed_label, .false_label = suspend_label } });
                try out.append(.{ .label = .{ .id = suspend_label } });
                const r_next_state = next_register;
                next_register += 1;
                try out.append(.{ .const_int = .{ .dst = r_next_state, .value = @as(i64, suspend_index) + 1 } });
                try out.append(.{ .frame_set = .{ .frame = r_frame, .slot = ir.frame_state_slot, .src = r_next_state, .ty = int_ty } });
                const r_suspended = next_register;
                next_register += 1;
                try out.append(.{ .const_int = .{ .dst = r_suspended, .value = ir.task_status_suspended } });
                try out.append(.{ .ret = .{ .src = r_suspended } });
                try out.append(.{ .label = .{ .id = proceed_label } });
                // The target is complete (or a trapping join): the await
                // yields without driving.
                try out.append(.{ .task_await = .{ .dst = v.dst, .task = r_saved, .ty = v.ty } });
                suspend_index += 1;
            },
            .ret => |v| {
                if (v.src) |src| {
                    try out.append(.{ .frame_set = .{ .frame = r_frame, .slot = ir.frame_result_slot, .src = src, .ty = result_ty } });
                } else {
                    const r_zero = next_register;
                    next_register += 1;
                    try out.append(.{ .const_int = .{ .dst = r_zero, .value = 0 } });
                    try out.append(.{ .frame_set = .{ .frame = r_frame, .slot = ir.frame_result_slot, .src = r_zero, .ty = int_ty } });
                }
                const r_complete = next_register;
                next_register += 1;
                try out.append(.{ .const_int = .{ .dst = r_complete, .value = ir.task_status_complete } });
                try out.append(.{ .ret = .{ .src = r_complete } });
            },
            else => try out.append(inst),
        }
    }

    var transformed = function_decl;
    transformed.instructions = try out.toOwnedInstructions();
    transformed.register_count = next_register;
    transformed.param_ownership = &.{.owned};
    transformed.param_types = try allocator.dupe(ir.ValueType, &.{.{ .kind = .raw_ptr, .name = "TaskFrame" }});
    transformed.local_count = 1;
    transformed.local_types = try allocator.dupe(ir.ValueType, &.{.{ .kind = .raw_ptr, .name = "TaskFrame" }});
    transformed.return_type = int_ty;
    transformed.return_ownership = .owned;
    return transformed;
}

fn markSpawnSites(program: ir.Program, callee_id: u32, frame_slots: u32) void {
    for (program.functions) |function_decl| {
        for (function_decl.instructions) |*inst| {
            switch (inst.*) {
                .task_spawn => |*v| if (v.callee == callee_id) {
                    v.suspendable = true;
                    v.frame_slots = frame_slots;
                },
                else => {},
            }
        }
    }
}
