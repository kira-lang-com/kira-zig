//! Tests for cgu_hash.zig: the invalidation properties the incremental codegen
//! cache depends on. Split out of cgu_hash.zig (Core Law #5); they exercise only
//! the public CguHasher surface (init / hashFunction / hashSupport), so no
//! private access is required.

const std = @import("std");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const cgu_hash = @import("cgu_hash.zig");

const CguConfig = cgu_hash.CguConfig;
const CguHasher = cgu_hash.CguHasher;
const Digest = cgu_hash.Digest;

const testing = std.testing;

const test_config = CguConfig{
    .triple = "arm64-apple-macosx",
    .opt_flag = "-O2",
    .mode = .llvm_native,
    .drop_enabled = false,
};

fn testFunction(id: u32, name: []const u8, instructions: []ir.Instruction) ir.Function {
    return .{
        .id = id,
        .name = name,
        .execution = .native,
        .return_type = .{ .kind = .integer, .name = "I64" },
        .register_count = 2,
        .local_count = 0,
        .local_types = &.{},
        .instructions = instructions,
    };
}

fn hashOne(program: *const ir.Program, id: u32) !Digest {
    var hasher = try CguHasher.init(testing.allocator, program, test_config);
    defer hasher.deinit();
    for (program.functions) |function| {
        if (function.id == id) return hasher.hashFunction(function);
    }
    return error.NotFound;
}

test "editing one function body invalidates exactly that CGU" {
    var f0_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 1 } }, .{ .ret = .{ .src = 0 } } };
    var f1_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 2 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{ testFunction(0, "f0", &f0_body), testFunction(1, "f1", &f1_body) };
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };

    const f0_before = try hashOne(&program, 0);
    const f1_before = try hashOne(&program, 1);

    // Change only f0's body (the constant it returns).
    f0_body[0] = .{ .const_int = .{ .dst = 0, .value = 999 } };
    const f0_after = try hashOne(&program, 0);
    const f1_after = try hashOne(&program, 1);

    try testing.expect(!std.mem.eql(u8, &f0_before, &f0_after)); // edited CGU changed
    try testing.expectEqualSlices(u8, &f1_before, &f1_after); // untouched CGU stable
}

test "changing a struct layout invalidates functions that use the program's types" {
    var body = [_]ir.Instruction{.{ .ret = .{ .src = 0 } }};
    var functions = [_]ir.Function{testFunction(0, "f0", &body)};
    var fields = [_]ir.Field{.{ .name = "x", .ty = .{ .kind = .integer, .name = "I64" } }};
    var types = [_]ir.TypeDecl{.{ .name = "Point", .fields = &fields }};
    const program = ir.Program{ .functions = &functions, .types = &types, .entry_index = 0 };

    const before = try hashOne(&program, 0);

    // Change Point's field type (a layout change).
    fields[0] = .{ .name = "x", .ty = .{ .kind = .integer, .name = "I8" } };
    const after = try hashOne(&program, 0);

    try testing.expect(!std.mem.eql(u8, &before, &after));
}

test "callee signature change invalidates caller; body change does not" {
    // f0 references f1 via const_function (a direct callee).
    var caller_body = [_]ir.Instruction{
        .{ .const_function = .{ .dst = 0, .function_id = 1 } },
        .{ .ret = .{ .src = 0 } },
    };
    var callee_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 1 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{ testFunction(0, "f0", &caller_body), testFunction(1, "f1", &callee_body) };
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };

    const caller_before = try hashOne(&program, 0);

    // (a) Change f1's BODY only — caller must NOT be invalidated.
    functions[1].instructions[0] = .{ .const_int = .{ .dst = 0, .value = 42 } };
    const caller_after_body = try hashOne(&program, 0);
    try testing.expectEqualSlices(u8, &caller_before, &caller_after_body);

    // (b) Change f1's SIGNATURE (return type) — caller MUST be invalidated.
    functions[1].return_type = .{ .kind = .integer, .name = "I8" };
    const caller_after_sig = try hashOne(&program, 0);
    try testing.expect(!std.mem.eql(u8, &caller_before, &caller_after_sig));
}

test "hashing is deterministic across independent hasher instances" {
    var body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 7 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{testFunction(0, "f0", &body)};
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };
    try testing.expectEqualSlices(u8, &(try hashOne(&program, 0)), &(try hashOne(&program, 0)));
}

fn hashSupportOf(program: *const ir.Program) !Digest {
    var hasher = try CguHasher.init(testing.allocator, program, test_config);
    defer hasher.deinit();
    return hasher.hashSupport();
}

test "support CGU stays cached across a pure body edit, rebuilds on signature change" {
    var f0_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 1 } }, .{ .ret = .{ .src = 0 } } };
    var f1_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 2 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{ testFunction(0, "f0", &f0_body), testFunction(1, "f1", &f1_body) };
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };

    const support_before = try hashSupportOf(&program);

    // (a) Pure body edit (constant f1 returns) — support has no user bodies, and
    // this changes no signature/dispatcher/closure shape, so it MUST stay cached.
    f1_body[0] = .{ .const_int = .{ .dst = 0, .value = 999 } };
    const support_after_body = try hashSupportOf(&program);
    try testing.expectEqualSlices(u8, &support_before, &support_after_body);

    // (b) Signature change (f1's return type) — the support object holds f1's
    // extern declaration, so it MUST rebuild.
    functions[1].return_type = .{ .kind = .integer, .name = "I8" };
    const support_after_sig = try hashSupportOf(&program);
    try testing.expect(!std.mem.eql(u8, &support_before, &support_after_sig));
}

comptime {
    _ = runtime_abi;
}
