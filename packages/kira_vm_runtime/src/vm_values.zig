const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");

pub fn compareValues(vm: anytype, lhs: runtime_abi.Value, rhs: runtime_abi.Value, op: bytecode.CompareOp) !bool {
    switch (lhs) {
        .integer => |lhs_value| {
            if (rhs != .integer) {
                vm.rememberFmt("vm compare expects matching operand types (lhs={s}, rhs={s})", .{ @tagName(lhs), @tagName(rhs) });
                return error.RuntimeFailure;
            }
            return switch (op) {
                .equal => lhs_value == rhs.integer,
                .not_equal => lhs_value != rhs.integer,
                .less => lhs_value < rhs.integer,
                .less_equal => lhs_value <= rhs.integer,
                .greater => lhs_value > rhs.integer,
                .greater_equal => lhs_value >= rhs.integer,
            };
        },
        .float => |lhs_value| {
            if (rhs != .float) {
                vm.rememberFmt("vm compare expects matching operand types (lhs={s}, rhs={s})", .{ @tagName(lhs), @tagName(rhs) });
                return error.RuntimeFailure;
            }
            return switch (op) {
                .equal => lhs_value == rhs.float,
                .not_equal => lhs_value != rhs.float,
                .less => lhs_value < rhs.float,
                .less_equal => lhs_value <= rhs.float,
                .greater => lhs_value > rhs.float,
                .greater_equal => lhs_value >= rhs.float,
            };
        },
        .boolean => |lhs_value| {
            if (rhs != .boolean) {
                vm.rememberFmt("vm compare expects matching operand types (lhs={s}, rhs={s})", .{ @tagName(lhs), @tagName(rhs) });
                return error.RuntimeFailure;
            }
            return switch (op) {
                .equal => lhs_value == rhs.boolean,
                .not_equal => lhs_value != rhs.boolean,
                else => {
                    vm.rememberError("vm compare does not support ordered boolean comparisons");
                    return error.RuntimeFailure;
                },
            };
        },
        .raw_ptr => |lhs_value| {
            if (rhs != .raw_ptr) {
                vm.rememberFmt("vm compare expects matching operand types (lhs={s}, rhs={s})", .{ @tagName(lhs), @tagName(rhs) });
                return error.RuntimeFailure;
            }
            return switch (op) {
                .equal => lhs_value == rhs.raw_ptr,
                .not_equal => lhs_value != rhs.raw_ptr,
                else => {
                    vm.rememberError("vm compare does not support ordered pointer comparisons");
                    return error.RuntimeFailure;
                },
            };
        },
        .string => |lhs_value| {
            if (rhs != .string) {
                vm.rememberFmt("vm compare expects matching operand types (lhs={s}, rhs={s})", .{ @tagName(lhs), @tagName(rhs) });
                return error.RuntimeFailure;
            }
            return switch (op) {
                .equal => std.mem.eql(u8, lhs_value, rhs.string),
                .not_equal => !std.mem.eql(u8, lhs_value, rhs.string),
                else => {
                    vm.rememberError("vm compare does not support ordered string comparisons");
                    return error.RuntimeFailure;
                },
            };
        },
        else => {
            vm.rememberError("vm compare does not support this value type");
            return error.RuntimeFailure;
        },
    }
}

pub fn unaryValue(vm: anytype, value: runtime_abi.Value, op: bytecode.UnaryOp) !runtime_abi.Value {
    return switch (op) {
        .negate => switch (value) {
            .integer => |inner| .{ .integer = -inner },
            .float => |inner| .{ .float = -inner },
            else => {
                vm.rememberError("vm negate expects a numeric operand");
                return error.RuntimeFailure;
            },
        },
        .not => switch (value) {
            .boolean => |inner| .{ .boolean = !inner },
            else => {
                vm.rememberError("vm logical not expects a boolean operand");
                return error.RuntimeFailure;
            },
        },
        .bit_not => switch (value) {
            // Ones' complement on the raw bit pattern; sign-agnostic.
            .integer => |inner| .{ .integer = ~inner },
            else => {
                vm.rememberError("vm bitwise not expects an integer operand");
                return error.RuntimeFailure;
            },
        },
    };
}

// Bitwise AND/OR/XOR and shifts on the raw 64-bit pattern. `unsigned` only
// affects shift_right (logical vs arithmetic). Shift amount is taken mod 64.
pub fn bitwiseValue(vm: anytype, lhs: runtime_abi.Value, rhs: runtime_abi.Value, op: bytecode.BitOp, unsigned: bool) !runtime_abi.Value {
    if (lhs != .integer or rhs != .integer) {
        vm.rememberError("vm bitwise op expects integer operands");
        return error.RuntimeFailure;
    }
    const a: u64 = @bitCast(lhs.integer);
    const b: u64 = @bitCast(rhs.integer);
    const shift_amt: u6 = @intCast(b & 63);
    const result: u64 = switch (op) {
        .bit_and => a & b,
        .bit_or => a | b,
        .bit_xor => a ^ b,
        .shift_left => a << shift_amt,
        .shift_right => if (unsigned)
            a >> shift_amt
        else
            @bitCast(lhs.integer >> shift_amt),
    };
    return .{ .integer = @bitCast(result) };
}

pub fn addValues(vm: anytype, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
    return switch (lhs) {
        .integer => |lhs_value| blk: {
            if (rhs != .integer) {
                vm.rememberError("vm add expects matching numeric operands");
                return error.RuntimeFailure;
            }
            break :blk .{ .integer = lhs_value + rhs.integer };
        },
        .float => |lhs_value| blk: {
            if (rhs != .float) {
                vm.rememberError("vm add expects matching numeric operands");
                return error.RuntimeFailure;
            }
            break :blk .{ .float = lhs_value + rhs.float };
        },
        // String concatenation: `+` on two strings allocates a heap-managed result
        // (registered so slot-ownership tracking frees it like any managed string).
        .string => |lhs_value| blk: {
            if (rhs != .string) {
                vm.rememberError("vm add expects matching string operands");
                return error.RuntimeFailure;
            }
            const out = try vm.heap.allocator.alloc(u8, lhs_value.len + rhs.string.len);
            @memcpy(out[0..lhs_value.len], lhs_value);
            @memcpy(out[lhs_value.len..], rhs.string);
            try vm.heap.registerString(out);
            break :blk .{ .string = out };
        },
        else => {
            vm.rememberError("vm add expects numeric operands");
            return error.RuntimeFailure;
        },
    };
}

pub fn subtractValues(vm: anytype, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
    return switch (lhs) {
        .integer => |lhs_value| blk: {
            if (rhs != .integer) {
                vm.rememberError("vm subtract expects matching numeric operands");
                return error.RuntimeFailure;
            }
            break :blk .{ .integer = lhs_value - rhs.integer };
        },
        .float => |lhs_value| blk: {
            if (rhs != .float) {
                vm.rememberError("vm subtract expects matching numeric operands");
                return error.RuntimeFailure;
            }
            break :blk .{ .float = lhs_value - rhs.float };
        },
        else => {
            vm.rememberError("vm subtract expects numeric operands");
            return error.RuntimeFailure;
        },
    };
}

pub fn multiplyValues(vm: anytype, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
    return switch (lhs) {
        .integer => |lhs_value| blk: {
            if (rhs != .integer) {
                vm.rememberError("vm multiply expects matching numeric operands");
                return error.RuntimeFailure;
            }
            break :blk .{ .integer = lhs_value * rhs.integer };
        },
        .float => |lhs_value| blk: {
            if (rhs != .float) {
                vm.rememberError("vm multiply expects matching numeric operands");
                return error.RuntimeFailure;
            }
            break :blk .{ .float = lhs_value * rhs.float };
        },
        else => {
            vm.rememberError("vm multiply expects numeric operands");
            return error.RuntimeFailure;
        },
    };
}

pub fn divideValues(vm: anytype, lhs: runtime_abi.Value, rhs: runtime_abi.Value, unsigned: bool) !runtime_abi.Value {
    return switch (lhs) {
        .integer => |lhs_value| blk: {
            if (rhs != .integer) {
                vm.rememberError("vm divide expects matching numeric operands");
                return error.RuntimeFailure;
            }
            if (rhs.integer == 0) {
                vm.rememberError("vm divide does not allow division by zero");
                return error.RuntimeFailure;
            }
            if (unsigned) {
                // Reinterpret the raw 64-bit pattern as u64 so high-bit-set values
                // (> i64 max) divide by magnitude, not sign. Matches LLVM `udiv`.
                const lu: u64 = @bitCast(lhs_value);
                const ru: u64 = @bitCast(rhs.integer);
                break :blk .{ .integer = @bitCast(lu / ru) };
            }
            break :blk .{ .integer = @divTrunc(lhs_value, rhs.integer) };
        },
        .float => |lhs_value| blk: {
            if (rhs != .float) {
                vm.rememberError("vm divide expects matching numeric operands");
                return error.RuntimeFailure;
            }
            if (rhs.float == 0.0) {
                vm.rememberError("vm divide does not allow division by zero");
                return error.RuntimeFailure;
            }
            break :blk .{ .float = lhs_value / rhs.float };
        },
        else => {
            vm.rememberError("vm divide expects numeric operands");
            return error.RuntimeFailure;
        },
    };
}

// Truncate a float toward zero into an i64, saturating out-of-range and NaN
// inputs so the VM never hits Zig's `@intFromFloat` UB. In-range values match
// the LLVM backend's `fptosi`.
fn floatToIntTruncate(f: f64) i64 {
    if (std.math.isNan(f)) return 0;
    const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (f >= max_f) return std.math.maxInt(i64);
    if (f <= min_f) return std.math.minInt(i64);
    return @intFromFloat(@trunc(f));
}

// `Int(x)` / `Float(x)` numeric cast. `to_float` selects the target. A cast to
// a value's existing kind is an identity copy; Float->Int truncates toward zero.
pub fn convertValue(vm: anytype, src: runtime_abi.Value, to_float: bool) !runtime_abi.Value {
    if (to_float) {
        return switch (src) {
            .float => src,
            .integer => |value| .{ .float = @floatFromInt(value) },
            else => {
                vm.rememberError("vm Float() expects a numeric operand");
                return error.RuntimeFailure;
            },
        };
    }
    return switch (src) {
        .integer => src,
        .float => |value| .{ .integer = floatToIntTruncate(value) },
        else => {
            vm.rememberError("vm Int() expects a numeric operand");
            return error.RuntimeFailure;
        },
    };
}

pub fn moduloValues(vm: anytype, lhs: runtime_abi.Value, rhs: runtime_abi.Value, unsigned: bool) !runtime_abi.Value {
    return switch (lhs) {
        .integer => |lhs_value| blk: {
            if (rhs != .integer) {
                vm.rememberError("vm modulo expects matching numeric operands");
                return error.RuntimeFailure;
            }
            if (rhs.integer == 0) {
                vm.rememberError("vm modulo does not allow division by zero");
                return error.RuntimeFailure;
            }
            if (unsigned) {
                // Unsigned remainder on the raw 64-bit pattern. Matches LLVM `urem`.
                const lu: u64 = @bitCast(lhs_value);
                const ru: u64 = @bitCast(rhs.integer);
                break :blk .{ .integer = @bitCast(lu % ru) };
            }
            // Truncated remainder (toward zero) to match `@divTrunc` above, the
            // LLVM backend's `srem`, and Rust's `%`, so `(a/b)*b + a%b == a`
            // holds for negative operands and vm/llvm/hybrid agree (S8).
            break :blk .{ .integer = @rem(lhs_value, rhs.integer) };
        },
        .float => |lhs_value| blk: {
            if (rhs != .float) {
                vm.rememberError("vm modulo expects matching numeric operands");
                return error.RuntimeFailure;
            }
            if (rhs.float == 0.0) {
                vm.rememberError("vm modulo does not allow division by zero");
                return error.RuntimeFailure;
            }
            // Truncated remainder (toward zero) to match integer `%`, the LLVM
            // backend's `frem`, and Rust's `%` (S8).
            break :blk .{ .float = @rem(lhs_value, rhs.float) };
        },
        else => {
            vm.rememberError("vm modulo expects numeric operands");
            return error.RuntimeFailure;
        },
    };
}
