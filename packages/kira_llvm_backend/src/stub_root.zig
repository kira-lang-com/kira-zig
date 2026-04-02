const std = @import("std");
const backend_api = @import("kira_backend_api");
const build_options = @import("kira_llvm_build_options");

pub fn compile(_: std.mem.Allocator, _: backend_api.CompileRequest) !backend_api.CompileResult {
    std.debug.print(
        "LLVM backend is unavailable in this build. Rebuild with KIRA_LLVM_HOME set or install a toolchain under {s}\\.kira\\llvm\\current.\n",
        .{build_options.repo_root},
    );
    return error.LlvmBackendUnavailable;
}
