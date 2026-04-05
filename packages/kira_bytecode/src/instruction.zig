pub const OpCode = enum(u8) {
    const_int,
    const_string,
    const_bool,
    const_null_ptr,
    add,
    store_local,
    load_local,
    print,
    call_runtime,
    call_native,
    ret,
};

pub const Instruction = union(OpCode) {
    const_int: struct { dst: u32, value: i64 },
    const_string: struct { dst: u32, value: []const u8 },
    const_bool: struct { dst: u32, value: bool },
    const_null_ptr: struct { dst: u32 },
    add: struct { dst: u32, lhs: u32, rhs: u32 },
    store_local: struct { local: u32, src: u32 },
    load_local: struct { dst: u32, local: u32 },
    print: struct { src: u32 },
    call_runtime: struct { function_id: u32, args: []const u32, dst: ?u32 = null },
    call_native: struct { function_id: u32, args: []const u32, dst: ?u32 = null },
    ret: struct { src: ?u32 = null },
};
