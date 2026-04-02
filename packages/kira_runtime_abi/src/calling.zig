pub const CallingConvention = enum {
    c,
    kira_vm,
    kira_hybrid,
};

pub const FunctionExecution = enum {
    inherited,
    runtime,
    native,
};

pub const ExecutionMode = enum {
    vm,
    llvm_native,
    hybrid,
};
