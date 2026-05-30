const native = @import("kira_native_lib_definition");

pub const ExecutionTarget = enum {
    vm,
    llvm_native,
    wasm32_emscripten,
    hybrid,

    pub fn environment(self: ExecutionTarget) TargetEnvironment {
        return switch (self) {
            .vm, .llvm_native, .hybrid => .host_native,
            .wasm32_emscripten => .browser,
        };
    }

    pub fn capabilities(self: ExecutionTarget) TargetCapabilities {
        return switch (self) {
            .vm => .{ .host_native_libraries = false, .browser_host_bindings = false, .executes_in_browser_sandbox = false },
            .llvm_native, .hybrid => .{ .host_native_libraries = true, .browser_host_bindings = false, .executes_in_browser_sandbox = false },
            .wasm32_emscripten => .{ .host_native_libraries = false, .browser_host_bindings = true, .executes_in_browser_sandbox = true },
        };
    }
};

pub const BuildTarget = struct {
    execution: ExecutionTarget = .vm,
    selector: ?native.TargetSelector = null,
};

pub const TargetEnvironment = enum {
    host_native,
    browser,
};

pub const TargetCapabilities = struct {
    host_native_libraries: bool,
    browser_host_bindings: bool,
    executes_in_browser_sandbox: bool,
};
