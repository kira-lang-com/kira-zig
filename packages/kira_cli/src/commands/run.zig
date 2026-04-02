const std = @import("std");
const build = @import("kira_build");
const vm_runtime = @import("kira_vm_runtime");
const diagnostics = @import("kira_diagnostics");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len < 1) return error.InvalidArguments;

    var system = build.BuildSystem.init(allocator);
    const result = system.compileVm(args[0]) catch |err| {
        try stderr.print("run failed: {s}\n", .{@errorName(err)});
        return err;
    };
    if (result.diagnostics.len > 0) {
        try diagnostics.renderer.renderAll(stderr, &result.source, result.diagnostics);
    }
    var vm = vm_runtime.Vm.init(allocator);
    try vm.runMain(&result.bytecode_module, stdout);
}
