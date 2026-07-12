//! Shared scalar types for the debugger's expression evaluator: the result `Value`,
//! the `EvalError` set, and the `LookupFn` identifier resolver. These live in their
//! own dependency-light module so both the parser (`eval_parse.zig`) and the
//! facade/interpreter (`eval.zig`) can import them without an import cycle.
const std = @import("std");
const debug_info = @import("debug_info.zig");

const LocalView = debug_info.LocalView;

/// Resolves an identifier to a local in the current frame, or null if there is no
/// such name in scope. Pure and read-only: it must not mutate or free runtime
/// state. The returned `LocalView.value` is borrowed for the duration of the call
/// tree; the top-level `eval` copies any string it needs to hand back to the caller.
pub const LookupFn = *const fn ([]const u8) ?LocalView;

/// Everything that can go wrong evaluating an expression. Kept small and precise so
/// the REPL can print an honest diagnostic instead of a generic failure.
pub const EvalError = error{
    /// The expression did not tokenize/parse (bad token, unbalanced parens, trailing
    /// junk, empty input).
    SyntaxError,
    /// An identifier referenced a name not present in the stopped frame.
    UnknownIdentifier,
    /// An operator was applied to operand types it does not support (e.g. `1 && 2`,
    /// `"a" * "b"`), or a boolean operator saw a non-boolean operand.
    TypeError,
    /// Integer division by zero.
    DivisionByZero,
    OutOfMemory,
};

/// A tagged evaluation result. `str` is only ever produced as a fresh, caller-owned
/// copy by the top-level `Evaluator.eval`; intermediate string operands stay borrowed
/// and never escape. `unknown` is the honest result for a local the debugger could
/// render for display but cannot losslessly parse back into a scalar (e.g. a struct,
/// closure, or raw pointer) — arithmetic/logic on it is a `TypeError`, never a guess.
pub const Value = union(enum) {
    int: i64,
    bool: bool,
    str: []const u8,
    unknown,
};
