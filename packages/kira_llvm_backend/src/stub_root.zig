const std = @import("std");
const backend_api = @import("kira_backend_api");

pub fn compile(_: std.mem.Allocator, _: backend_api.CompileRequest) !backend_api.CompileResult {
    return error.LlvmBackendUnavailable;
}

pub fn validate(_: std.mem.Allocator, _: backend_api.CompileRequest) !void {
    return error.LlvmBackendUnavailable;
}
