const runtime_abi = @import("kira_runtime_abi");

pub fn printValue(writer: anytype, value: runtime_abi.Value) !void {
    try value.format(writer);
    try writer.writeByte('\n');
}
