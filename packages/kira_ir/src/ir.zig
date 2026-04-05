const runtime_abi = @import("kira_runtime_abi");

pub const ValueType = struct {
    kind: Kind,
    name: ?[]const u8 = null,

    pub const Kind = enum {
        void,
        integer,
        float,
        string,
        boolean,
        raw_ptr,
        ffi_struct,
    };
};

pub const Program = struct {
    types: []TypeDecl = &.{},
    functions: []Function,
    entry_index: usize,
};

pub const TypeDecl = struct {
    name: []const u8,
    fields: []Field,
    ffi: ?FfiTypeInfo = null,
};

pub const Field = struct {
    name: []const u8,
    ty: ValueType,
};

pub const FfiTypeInfo = union(enum) {
    ffi_struct,
    pointer: PointerInfo,
    alias: AliasInfo,
    array: ArrayInfo,
    callback: CallbackInfo,
};

pub const PointerInfo = struct {
    target_name: []const u8,
};

pub const AliasInfo = struct {
    target: ValueType,
};

pub const ArrayInfo = struct {
    element: ValueType,
    count: usize,
};

pub const CallbackInfo = struct {
    params: []const ValueType,
    result: ValueType,
};

pub const ForeignFunction = struct {
    library_name: []const u8,
    symbol_name: []const u8,
    calling_convention: runtime_abi.CallingConvention = .c,
};

pub const Function = struct {
    id: u32,
    name: []const u8,
    execution: runtime_abi.FunctionExecution,
    is_extern: bool = false,
    foreign: ?ForeignFunction = null,
    param_types: []const ValueType = &.{},
    return_type: ValueType = .{ .kind = .void },
    register_count: u32,
    local_count: u32,
    local_types: []const ValueType,
    instructions: []Instruction,
};

pub const Instruction = union(enum) {
    const_int: ConstInt,
    const_string: ConstString,
    const_bool: ConstBool,
    const_null_ptr: ConstNullPtr,
    const_function: ConstFunction,
    add: Binary,
    store_local: StoreLocal,
    load_local: LoadLocal,
    field_ptr: FieldPtr,
    load_indirect: LoadIndirect,
    store_indirect: StoreIndirect,
    copy_indirect: CopyIndirect,
    print: Print,
    call: Call,
    ret: Return,
};

pub const ConstInt = struct {
    dst: u32,
    value: i64,
};

pub const ConstString = struct {
    dst: u32,
    value: []const u8,
};

pub const ConstBool = struct {
    dst: u32,
    value: bool,
};

pub const ConstNullPtr = struct {
    dst: u32,
};

pub const ConstFunction = struct {
    dst: u32,
    function_id: u32,
};

pub const Binary = struct {
    dst: u32,
    lhs: u32,
    rhs: u32,
};

pub const StoreLocal = struct {
    local: u32,
    src: u32,
};

pub const LoadLocal = struct {
    dst: u32,
    local: u32,
};

pub const FieldPtr = struct {
    dst: u32,
    base: u32,
    owner_type_name: []const u8,
    field_name: []const u8,
};

pub const LoadIndirect = struct {
    dst: u32,
    ptr: u32,
    ty: ValueType,
};

pub const StoreIndirect = struct {
    ptr: u32,
    src: u32,
    ty: ValueType,
};

pub const CopyIndirect = struct {
    dst_ptr: u32,
    src_ptr: u32,
    type_name: []const u8,
};

pub const Print = struct {
    src: u32,
};

pub const Call = struct {
    callee: u32,
    args: []const u32,
    dst: ?u32 = null,
};

pub const Return = struct {
    src: ?u32 = null,
};
