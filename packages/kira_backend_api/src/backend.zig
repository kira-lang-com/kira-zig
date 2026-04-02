const std = @import("std");
const CompileRequest = @import("compile_request.zig").CompileRequest;
const CompileResult = @import("compile_result.zig").CompileResult;

pub const Backend = struct {
    context: *anyopaque,
    compileFn: *const fn (*anyopaque, std.mem.Allocator, CompileRequest) anyerror!CompileResult,

    pub fn compile(self: Backend, allocator: std.mem.Allocator, request: CompileRequest) !CompileResult {
        return self.compileFn(self.context, allocator, request);
    }
};
