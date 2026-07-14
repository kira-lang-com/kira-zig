//! Unit tests for the VM debug seam (vm_debug.zig) and the prepare-time
//! source-location remap (vm_prepare.zig):
//!   1. an armed INT3 breakpoint invokes the debug callback exactly once and the
//!      program continues to a correct result, with the frame stack unwound;
//!   2. `PreparedFunction.sourceLocAt(pc)` maps a fused superinstruction back to
//!      the source span of the FIRST original op it covers.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const Vm = @import("vm.zig").Vm;
const vm_debug = @import("vm_debug.zig");
const vm_prepare = @import("vm_prepare.zig");

const StopRecorder = struct {
    count: usize = 0,
    last_pc: usize = 0,
    last_kind: vm_debug.StopKind = .step,
    last_function_id: u32 = 0,
};

fn recordAndResume(ctx: ?*anyopaque, event: vm_debug.StopEvent) vm_debug.ResumeAction {
    const recorder: *StopRecorder = @ptrCast(@alignCast(ctx.?));
    recorder.count += 1;
    recorder.last_pc = event.pc;
    recorder.last_kind = event.kind;
    recorder.last_function_id = event.function_id;
    return .resume_run;
}

test "breakpoint fires once and execution continues correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 7,
                .name = "main",
                .register_count = 1,
                .local_count = 0,
                .return_type = .{ .kind = .integer, .name = "I64" },
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_int = .{ .dst = 0, .value = 42 } },
                    .{ .ret = .{ .src = 0 } },
                }),
            },
        }),
        .entry_function_id = 7,
    };

    // Arm a breakpoint on the SAME prepared instance the run will use
    // (preparedFor caches by module pointer, so runFunctionById reuses it).
    const prepared = try vm.preparedFor(&module);
    const function = &prepared.functions[0];

    var recorder = StopRecorder{};
    var controller = vm_debug.DebugController.init(recordAndResume, &recorder);
    defer controller.deinit(arena.allocator());
    _ = try controller.arm(arena.allocator(), function, 0);
    vm.debug = &controller;

    var buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    const result = try vm.runFunctionById(&module, 7, &.{}, &stream, .{});

    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(vm_debug.StopKind.breakpoint, recorder.last_kind);
    try std.testing.expectEqual(@as(usize, 0), recorder.last_pc);
    try std.testing.expectEqual(@as(u32, 7), recorder.last_function_id);
    try std.testing.expect(result == .integer);
    try std.testing.expectEqual(@as(i64, 42), result.integer);
    // The frame pushed for the call unwinds on return.
    try std.testing.expectEqual(@as(usize, 0), vm.debugFrames().len);
}

test "breakpoint disarm restores the original instruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .register_count = 1,
                .local_count = 0,
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_int = .{ .dst = 0, .value = 1 } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };
    const prepared = try vm.preparedFor(&module);
    const function = &prepared.functions[0];
    const original = function.code[0];

    var recorder = StopRecorder{};
    var controller = vm_debug.DebugController.init(recordAndResume, &recorder);
    defer controller.deinit(arena.allocator());
    const id = try controller.arm(arena.allocator(), function, 0);
    // Armed: the site now holds the sentinel, not the original const_int.
    try std.testing.expect(function.code[0] == .call_runtime);
    try std.testing.expectEqual(vm_debug.breakpoint_sentinel, function.code[0].call_runtime.function_id);
    controller.clear(id);
    // Disarmed: the original instruction is back in place byte-for-byte.
    try std.testing.expect(function.code[0] == .const_int);
    try std.testing.expectEqual(original.const_int.value, function.code[0].const_int.value);
}

test "sourceLocAt maps a fused region to its first covered op" {
    const allocator = std.testing.allocator;

    // The filler const between the second const and the compare stops the 3-op
    // const+compare+branch fusion, leaving the 2-op compare+branch fusion whose
    // first covered op is the compare — the location sourceLocAt must report.
    var insts = [_]bytecode.Instruction{
        .{ .const_int = .{ .dst = 0, .value = 1 } }, // 0
        .{ .const_int = .{ .dst = 1, .value = 2 } }, // 1
        .{ .const_int = .{ .dst = 3, .value = 5 } }, // 2 (filler)
        .{ .compare = .{ .dst = 2, .lhs = 0, .rhs = 1, .op = .less } }, // 3
        .{ .branch = .{ .condition = 2, .true_label = 0, .false_label = 0 } }, // 4
        .{ .label = .{ .id = 0 } }, // 5
        .{ .ret = .{ .src = null } }, // 6
    };
    const locs = [_]bytecode.SourceLoc{
        .{ .file_id = 0, .start = 10, .end = 20 }, // const r0
        .{ .file_id = 0, .start = 21, .end = 30 }, // const r1
        .{ .file_id = 0, .start = 40, .end = 50 }, // const r3 (filler)
        .{ .file_id = 0, .start = 100, .end = 110 }, // compare (first covered)
        .{ .file_id = 0, .start = 200, .end = 210 }, // branch
        .{ .file_id = 0, .start = 0, .end = 0 }, // label (no location)
        .{ .file_id = 0, .start = 300, .end = 310 }, // ret
    };
    var funcs = [_]bytecode.Function{
        .{
            .id = 0,
            .name = "main",
            .register_count = 4,
            .local_count = 0,
            .instructions = &insts,
            .debug_locations = &locs,
        },
    };
    const module = bytecode.Module{ .functions = &funcs, .entry_function_id = 0 };

    const prepared = try vm_prepare.prepare(allocator, &module);
    defer {
        prepared.deinit(allocator);
        allocator.destroy(prepared);
    }
    const function = &prepared.functions[0];

    var fused_pc: ?usize = null;
    for (function.code, 0..) |inst, pc| {
        if (inst == .fused_compare_branch) fused_pc = pc;
    }
    try std.testing.expect(fused_pc != null);

    const fused_loc = function.sourceLocAt(fused_pc.?) orelse return error.MissingLocation;
    try std.testing.expectEqual(@as(u32, 100), fused_loc.start);
    try std.testing.expectEqual(@as(u32, 110), fused_loc.end);

    // A non-fused instruction keeps its own location.
    const first_loc = function.sourceLocAt(0) orelse return error.MissingLocation;
    try std.testing.expectEqual(@as(u32, 10), first_loc.start);

    // The synthesized trailing ret (code_len-2) inherits the previous
    // instruction's location; the label trap (code_len-1) has none.
    const trailing_ret = function.sourceLocAt(function.code.len - 2) orelse return error.MissingLocation;
    try std.testing.expectEqual(@as(u32, 300), trailing_ret.start);
    try std.testing.expect(function.sourceLocAt(function.code.len - 1) == null);
}

test "sourceLocAt returns null without debug info" {
    const allocator = std.testing.allocator;
    var insts = [_]bytecode.Instruction{
        .{ .const_int = .{ .dst = 0, .value = 1 } },
        .{ .ret = .{ .src = null } },
    };
    var funcs = [_]bytecode.Function{
        .{ .id = 0, .name = "main", .register_count = 1, .local_count = 0, .instructions = &insts },
    };
    const module = bytecode.Module{ .functions = &funcs, .entry_function_id = 0 };
    const prepared = try vm_prepare.prepare(allocator, &module);
    defer {
        prepared.deinit(allocator);
        allocator.destroy(prepared);
    }
    // No debug_locations => empty prepared_locations => every pc is unknown.
    try std.testing.expectEqual(@as(usize, 0), prepared.functions[0].prepared_locations.len);
    try std.testing.expect(prepared.functions[0].sourceLocAt(0) == null);
    try std.testing.expectEqualStrings("main", prepared.functions[0].decl.name);
}
