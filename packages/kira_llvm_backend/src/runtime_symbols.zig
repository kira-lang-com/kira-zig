pub const print_i64 = "kira_native_print_i64";
pub const print_string = "kira_native_print_string";
pub const call_runtime = "kira_hybrid_call_runtime";

pub fn nativeExportName(buffer: []u8, function_id: u32) ![:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "kira_native_fn_{d}", .{function_id});
}

const std = @import("std");
