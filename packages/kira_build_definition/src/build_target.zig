const native = @import("kira_native_lib_definition");

pub const ExecutionTarget = enum {
    vm,
    llvm_native,
    hybrid,
};

pub const BuildTarget = struct {
    execution: ExecutionTarget = .vm,
    selector: ?native.TargetSelector = null,
};
