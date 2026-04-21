pub const print_i64 = "kira_native_print_i64";
pub const print_f64 = "kira_native_print_f64";
pub const print_string = "kira_native_print_string";
pub const array_alloc = "kira_array_alloc";
pub const array_len = "kira_array_len";
pub const array_store = "kira_array_store";
pub const array_load = "kira_array_load";
pub const native_state_alloc = "kira_native_state_alloc";
pub const native_state_payload = "kira_native_state_payload";
pub const native_state_recover = "kira_native_state_recover";
pub const call_runtime = "kira_hybrid_call_runtime";

pub fn nativeExportName(buffer: []u8, function_id: u32) ![:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "kira_native_fn_{d}", .{function_id});
}

const std = @import("std");
