pub const Vm = @import("vm.zig").Vm;
pub const Hooks = @import("vm.zig").Hooks;
pub const OpCode = @import("opcodes.zig").OpCode;
pub const printValue = @import("builtins.zig").printValue;
pub const loadModuleFromFile = @import("module_loader.zig").loadModuleFromFile;
pub const FfiDispatcher = @import("vm_ffi.zig").Dispatcher;
/// End-of-run task-executor drain (detached tasks outliving their handles);
/// used by the hybrid runtime after its entrypoint returns.
pub const drainTasks = @import("vm_interpreter_tasks.zig").drainAll;
/// Live hot-reload support: remap live closures / native-state boxes when the
/// executing module is swapped in place (see kira_hybrid_runtime hot swap).
pub const reload = @import("vm_reload.zig");

test {
    _ = @import("vm_ffi.zig");
    _ = @import("vm.zig");
    _ = @import("vm_tasks.zig");
    _ = @import("vm_reload.zig");
    _ = @import("vm_native_bridge_hybrid_regression_tests.zig");
    // Keep vm.zig imported so the interpreter/execution/native-bridge suites
    // run under the normal package test entrypoint. These tests previously
    // existed but were dormant because root.zig only imported vm_ffi.zig.
}
