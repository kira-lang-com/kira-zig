pub const OpCode = enum(u8) {
    const_int,
    const_string,
    const_bool,
    const_null_ptr,
    alloc_struct,
    add,
    store_local,
    load_local,
    field_ptr,
    load_indirect,
    store_indirect,
    copy_indirect,
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
    alloc_struct: struct { dst: u32, type_name: []const u8 },
    add: struct { dst: u32, lhs: u32, rhs: u32 },
    store_local: struct { local: u32, src: u32 },
    load_local: struct { dst: u32, local: u32 },
    field_ptr: struct { dst: u32, base: u32, owner_type_name: []const u8, field_name: []const u8 },
    load_indirect: struct { dst: u32, ptr: u32, ty: TypeRef },
    store_indirect: struct { ptr: u32, src: u32, ty: TypeRef },
    copy_indirect: struct { dst_ptr: u32, src_ptr: u32, type_name: []const u8 },
    print: struct { src: u32, ty: TypeRef },
    call_runtime: struct { function_id: u32, args: []const u32, dst: ?u32 = null },
    call_native: struct { function_id: u32, args: []const u32, dst: ?u32 = null },
    ret: struct { src: ?u32 = null },
};

pub const TypeRef = struct {
    kind: Kind,
    name: ?[]const u8 = null,

    pub const Kind = enum(u8) {
        void,
        integer,
        float,
        string,
        boolean,
        raw_ptr,
        ffi_struct,
    };
};
