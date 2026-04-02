pub const ir = @import("ir.zig");
pub const Program = ir.Program;
pub const Function = ir.Function;
pub const ValueType = ir.ValueType;
pub const Instruction = ir.Instruction;
pub const Call = ir.Call;
pub const lowerProgram = @import("lower_from_hir.zig").lowerProgram;
