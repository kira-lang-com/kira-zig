const std = @import("std");
const backend_api = @import("kira_backend_api");

pub fn compile(_: std.mem.Allocator, _: backend_api.CompileRequest) !backend_api.CompileResult {
    return error.LlvmBackendUnavailable;
}

pub fn validate(_: std.mem.Allocator, _: backend_api.CompileRequest) !void {
    return error.LlvmBackendUnavailable;
}

pub const LlvmToolchain = struct {
    pub fn discover(_: std.mem.Allocator) !LlvmToolchain {
        return error.LlvmBackendUnavailable;
    }

    pub fn clangPath(_: LlvmToolchain, _: std.mem.Allocator) ![]const u8 {
        return error.LlvmBackendUnavailable;
    }

    pub fn llvmArPath(_: LlvmToolchain, _: std.mem.Allocator) ![]const u8 {
        return error.LlvmBackendUnavailable;
    }

    pub fn compilerDriverPath(_: LlvmToolchain, _: std.mem.Allocator) ![]const u8 {
        return error.LlvmBackendUnavailable;
    }
};
pub const clangDriver = @import("clang_driver.zig");
