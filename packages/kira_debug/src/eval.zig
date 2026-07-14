//! A small, self-contained expression evaluator for the debugger's `print EXPR`
//! command and for conditional-breakpoint predicates like `i == 3` or `n > 10`.
//!
//! This module is the public facade and the tree-walking interpreter. Tokenizing and
//! parsing live in `eval_parse.zig`; the shared `Value`/`EvalError`/`LookupFn` types
//! live in `eval_types.zig` (split out per Core Law #5 to keep each file focused and
//! the parser free of an import cycle). Expressions are evaluated in a stopped frame's
//! context: identifiers resolve to locals via an injected `LookupFn`, so the same
//! evaluator serves VM, native, and hybrid frames — whoever stopped the target supplies
//! the name→local mapping.
//!
//! Scope is deliberately narrow: integer and boolean literals, identifiers, unary
//! `-`/`!`, `+ - * /` on integers, the six comparisons, and `&& || !`. That is exactly
//! enough for conditional breakpoints and simple `print` queries; it is not a general
//! Kira interpreter, and it never mutates, moves, or frees the runtime storage a local
//! refers to (it reads the read-only display string the variables view produced).
const std = @import("std");
const debug_info = @import("debug_info.zig");
const eval_types = @import("eval_types.zig");
const eval_parse = @import("eval_parse.zig");

const LocalView = debug_info.LocalView;
const Node = eval_parse.Node;
const Op = eval_parse.Op;

/// A tagged evaluation result: `int` / `bool` / `str` / `unknown`.
pub const Value = eval_types.Value;
/// The evaluator's error set.
pub const EvalError = eval_types.EvalError;
/// Injected identifier resolver: name → local in the stopped frame, or null.
pub const LookupFn = eval_types.LookupFn;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Stateless facade grouping the two entry points. It carries no fields; both
/// methods are pure functions of `(expr, lookup)` plus a scratch allocator. Kept as
/// a struct (rather than bare functions) so the integration stage has one stable
/// handle to wire into the REPL and the breakpoint engine.
pub const Evaluator = struct {
    /// Evaluate `expr` to a `Value`. On success, a `.str` result is duplicated into
    /// `allocator` and owned by the caller (free it with the same allocator); `.int`,
    /// `.bool`, and `.unknown` own nothing. All scratch (tokens, parse nodes, and any
    /// intermediate strings) is released before returning.
    pub fn eval(allocator: std.mem.Allocator, expr: []const u8, lookup: LookupFn) EvalError!Value {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try eval_parse.parse(a, expr);
        const result = try evalNode(root, lookup);

        // Copy any string out of the arena so it survives `arena.deinit()`.
        if (result == .str) {
            return Value{ .str = try allocator.dupe(u8, result.str) };
        }
        return result;
    }

    /// Evaluate `expr` and reduce it to a single boolean via truthiness, for use as a
    /// conditional-breakpoint predicate. Truthiness: `bool` is itself, a nonzero `int`
    /// / nonempty `str` is true, and `unknown` is a `TypeError` (a breakpoint must not
    /// silently fire or skip on a value we could not evaluate). Allocation-free result;
    /// all scratch is released before returning.
    pub fn evalCondition(allocator: std.mem.Allocator, expr: []const u8, lookup: LookupFn) EvalError!bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try eval_parse.parse(a, expr);
        const result = try evalNode(root, lookup);
        return truthiness(result);
    }
};

fn truthiness(v: Value) EvalError!bool {
    return switch (v) {
        .bool => |b| b,
        .int => |n| n != 0,
        .str => |s| s.len != 0,
        .unknown => EvalError.TypeError,
    };
}

// ---------------------------------------------------------------------------
// Interpreter
// ---------------------------------------------------------------------------

/// Convert a `LocalView` (whose `value` is a display string produced read-only by the
/// variables view) back into a scalar `Value` for arithmetic/comparison. Only the
/// forms the renderer emits for scalars are recognized: a base-10 integer, `true`/
/// `false`, or a double-quoted string. Anything else (a struct, closure, or raw
/// pointer like `0x...`) is `unknown` — honest, and any op on it becomes a `TypeError`
/// rather than a fabricated number.
fn valueFromLocal(local: LocalView) Value {
    const s = local.value;
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        return Value{ .int = n };
    } else |_| {}
    if (std.mem.eql(u8, s, "true")) return Value{ .bool = true };
    if (std.mem.eql(u8, s, "false")) return Value{ .bool = false };
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return Value{ .str = s[1 .. s.len - 1] };
    }
    return Value.unknown;
}

fn evalNode(n: *Node, lookup: LookupFn) EvalError!Value {
    switch (n.kind) {
        .int_lit => return Value{ .int = n.int_val },
        .bool_lit => return Value{ .bool = n.bool_val },
        .str_lit => return Value{ .str = n.text },
        .ident => {
            const local = lookup(n.text) orelse return EvalError.UnknownIdentifier;
            return valueFromLocal(local);
        },
        .neg => {
            const v = try evalNode(n.lhs.?, lookup);
            if (v != .int) return EvalError.TypeError;
            return Value{ .int = -v.int };
        },
        .not => {
            const v = try evalNode(n.lhs.?, lookup);
            if (v != .bool) return EvalError.TypeError;
            return Value{ .bool = !v.bool };
        },
        .binary => return evalBinary(n, lookup),
    }
}

fn evalBinary(n: *Node, lookup: LookupFn) EvalError!Value {
    // Short-circuit boolean operators: evaluate the right operand only when needed,
    // and only ever accept boolean operands (no truthiness coercion here — a
    // conditional like `flag && n > 0` should be a type error if `flag` is an int).
    switch (n.op) {
        .logic_and => {
            const l = try evalNode(n.lhs.?, lookup);
            if (l != .bool) return EvalError.TypeError;
            if (!l.bool) return Value{ .bool = false };
            const r = try evalNode(n.rhs.?, lookup);
            if (r != .bool) return EvalError.TypeError;
            return Value{ .bool = r.bool };
        },
        .logic_or => {
            const l = try evalNode(n.lhs.?, lookup);
            if (l != .bool) return EvalError.TypeError;
            if (l.bool) return Value{ .bool = true };
            const r = try evalNode(n.rhs.?, lookup);
            if (r != .bool) return EvalError.TypeError;
            return Value{ .bool = r.bool };
        },
        else => {},
    }

    const l = try evalNode(n.lhs.?, lookup);
    const r = try evalNode(n.rhs.?, lookup);

    switch (n.op) {
        .add, .sub, .mul, .div => {
            if (l != .int or r != .int) return EvalError.TypeError;
            return arithmetic(n.op, l.int, r.int);
        },
        .eq, .ne => return equality(n.op, l, r),
        .lt, .le, .gt, .ge => return ordering(n.op, l, r),
        .logic_and, .logic_or => unreachable, // handled above
    }
}

fn arithmetic(op: Op, l: i64, r: i64) EvalError!Value {
    return switch (op) {
        .add => Value{ .int = l +% r },
        .sub => Value{ .int = l -% r },
        .mul => Value{ .int = l *% r },
        .div => blk: {
            if (r == 0) return EvalError.DivisionByZero;
            // Guard the one overflowing case (minInt / -1) to avoid a trap.
            if (l == std.math.minInt(i64) and r == -1) break :blk Value{ .int = std.math.minInt(i64) };
            break :blk Value{ .int = @divTrunc(l, r) };
        },
        else => unreachable,
    };
}

fn equality(op: Op, l: Value, r: Value) EvalError!Value {
    const equal: bool = switch (l) {
        .int => if (r == .int) l.int == r.int else return EvalError.TypeError,
        .bool => if (r == .bool) l.bool == r.bool else return EvalError.TypeError,
        .str => if (r == .str) std.mem.eql(u8, l.str, r.str) else return EvalError.TypeError,
        .unknown => return EvalError.TypeError,
    };
    return Value{ .bool = if (op == .eq) equal else !equal };
}

fn ordering(op: Op, l: Value, r: Value) EvalError!Value {
    // Ordering is defined for two ints or two strings (lexicographic); anything else
    // is a type error rather than a silently coerced comparison.
    if (l == .int and r == .int) {
        return Value{ .bool = compareInts(op, l.int, r.int) };
    }
    if (l == .str and r == .str) {
        const c = std.mem.order(u8, l.str, r.str);
        return Value{ .bool = switch (op) {
            .lt => c == .lt,
            .le => c != .gt,
            .gt => c == .gt,
            .ge => c != .lt,
            else => unreachable,
        } };
    }
    return EvalError.TypeError;
}

fn compareInts(op: Op, l: i64, r: i64) bool {
    return switch (op) {
        .lt => l < r,
        .le => l <= r,
        .gt => l > r,
        .ge => l >= r,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A fixed, tiny frame used across tests: `i = 3`, `n = 20`, `neg = -5`,
/// `flag = true`, `off = false`, `name = "kai"`, and `obj` an un-parseable display
/// value (a struct render).
fn testLookup(name: []const u8) ?LocalView {
    if (std.mem.eql(u8, name, "i")) return LocalView{ .name = "i", .value = "3", .slot = 0 };
    if (std.mem.eql(u8, name, "n")) return LocalView{ .name = "n", .value = "20", .slot = 1 };
    if (std.mem.eql(u8, name, "neg")) return LocalView{ .name = "neg", .value = "-5", .slot = 2 };
    if (std.mem.eql(u8, name, "flag")) return LocalView{ .name = "flag", .value = "true", .slot = 3 };
    if (std.mem.eql(u8, name, "off")) return LocalView{ .name = "off", .value = "false", .slot = 4 };
    if (std.mem.eql(u8, name, "name")) return LocalView{ .name = "name", .value = "\"kai\"", .slot = 5 };
    if (std.mem.eql(u8, name, "obj")) return LocalView{ .name = "obj", .value = "<struct Point@0x1>", .slot = 6 };
    return null;
}

fn emptyLookup(name: []const u8) ?LocalView {
    _ = name;
    return null;
}

test "integer literal" {
    const v = try Evaluator.eval(std.testing.allocator, "42", emptyLookup);
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "boolean literals" {
    try std.testing.expect((try Evaluator.eval(std.testing.allocator, "true", emptyLookup)).bool);
    try std.testing.expect(!(try Evaluator.eval(std.testing.allocator, "false", emptyLookup)).bool);
}

test "string literal is copied out and caller-owned" {
    const a = std.testing.allocator;
    const v = try Evaluator.eval(a, "\"hello\"", emptyLookup);
    defer a.free(v.str);
    try std.testing.expectEqualStrings("hello", v.str);
}

test "identifier lookup resolves int, bool, and string locals" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 3), (try Evaluator.eval(a, "i", testLookup)).int);
    try std.testing.expect((try Evaluator.eval(a, "flag", testLookup)).bool);
    const s = try Evaluator.eval(a, "name", testLookup);
    defer a.free(s.str);
    try std.testing.expectEqualStrings("kai", s.str);
}

test "unknown identifier errors" {
    try std.testing.expectError(EvalError.UnknownIdentifier, Evaluator.eval(std.testing.allocator, "missing", testLookup));
}

test "arithmetic with precedence and parentheses" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 14), (try Evaluator.eval(a, "2 + 3 * 4", emptyLookup)).int);
    try std.testing.expectEqual(@as(i64, 20), (try Evaluator.eval(a, "(2 + 3) * 4", emptyLookup)).int);
    try std.testing.expectEqual(@as(i64, 5), (try Evaluator.eval(a, "n - i * 5", testLookup)).int);
}

test "unary minus" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, -7), (try Evaluator.eval(a, "-7", emptyLookup)).int);
    try std.testing.expectEqual(@as(i64, 8), (try Evaluator.eval(a, "3 - -5", emptyLookup)).int);
    try std.testing.expectEqual(@as(i64, 5), (try Evaluator.eval(a, "-neg", testLookup)).int);
}

test "integer division and division by zero" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 3), (try Evaluator.eval(a, "20 / 6", emptyLookup)).int);
    try std.testing.expectError(EvalError.DivisionByZero, Evaluator.eval(a, "1 / 0", emptyLookup));
}

test "comparisons on integers" {
    const a = std.testing.allocator;
    try std.testing.expect((try Evaluator.eval(a, "i == 3", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "n > 10", testLookup)).bool);
    try std.testing.expect(!(try Evaluator.eval(a, "n < 10", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "i != n", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "i <= 3", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "n >= 20", testLookup)).bool);
}

test "equality on bools and strings" {
    const a = std.testing.allocator;
    try std.testing.expect((try Evaluator.eval(a, "flag == true", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "name == \"kai\"", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "name != \"other\"", testLookup)).bool);
}

test "string ordering is lexicographic" {
    const a = std.testing.allocator;
    try std.testing.expect((try Evaluator.eval(a, "\"abc\" < \"abd\"", emptyLookup)).bool);
}

test "boolean logic with short-circuit" {
    const a = std.testing.allocator;
    try std.testing.expect((try Evaluator.eval(a, "i == 3 && n > 10", testLookup)).bool);
    try std.testing.expect(!(try Evaluator.eval(a, "i == 3 && n < 10", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "off || flag", testLookup)).bool);
    try std.testing.expect((try Evaluator.eval(a, "!off", testLookup)).bool);
    // Short-circuit: RHS would be a type error but is never evaluated.
    try std.testing.expect((try Evaluator.eval(a, "true || i", testLookup)).bool);
    try std.testing.expect(!(try Evaluator.eval(a, "false && i", testLookup)).bool);
}

test "evalCondition truthiness" {
    const a = std.testing.allocator;
    try std.testing.expect(try Evaluator.evalCondition(a, "i == 3", testLookup));
    try std.testing.expect(!try Evaluator.evalCondition(a, "n > 100", testLookup));
    // Nonzero int and nonempty string are truthy; zero is falsy.
    try std.testing.expect(try Evaluator.evalCondition(a, "n", testLookup));
    try std.testing.expect(!try Evaluator.evalCondition(a, "0", emptyLookup));
    try std.testing.expect(try Evaluator.evalCondition(a, "name", testLookup));
}

test "type errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(EvalError.TypeError, Evaluator.eval(a, "1 && 2", emptyLookup));
    try std.testing.expectError(EvalError.TypeError, Evaluator.eval(a, "true + 1", emptyLookup));
    try std.testing.expectError(EvalError.TypeError, Evaluator.eval(a, "!5", emptyLookup));
    try std.testing.expectError(EvalError.TypeError, Evaluator.eval(a, "i == flag", testLookup));
    try std.testing.expectError(EvalError.TypeError, Evaluator.eval(a, "\"a\" * \"b\"", emptyLookup));
    // A non-scalar local is `unknown`; any operation on it is a type error.
    try std.testing.expectError(EvalError.TypeError, Evaluator.eval(a, "obj + 1", testLookup));
    try std.testing.expectError(EvalError.TypeError, Evaluator.evalCondition(a, "obj", testLookup));
}

test "malformed expressions error as syntax errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "", emptyLookup));
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "1 +", emptyLookup));
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "(1 + 2", emptyLookup));
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "1 2", emptyLookup));
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "* 3", emptyLookup));
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "1 @ 2", emptyLookup));
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "\"unterminated", emptyLookup));
    // Non-associative comparison chaining is rejected.
    try std.testing.expectError(EvalError.SyntaxError, Evaluator.eval(a, "1 < 2 < 3", emptyLookup));
}
