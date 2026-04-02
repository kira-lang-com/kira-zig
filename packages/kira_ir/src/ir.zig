pub const Program = struct {
    functions: []Function,
    entry_index: usize,
};

pub const Function = struct {
    name: []const u8,
    register_count: u32,
    local_count: u32,
    instructions: []Instruction,
};

pub const Instruction = union(enum) {
    const_int: ConstInt,
    const_string: ConstString,
    add: Binary,
    store_local: StoreLocal,
    load_local: LoadLocal,
    print: Print,
    ret_void: void,
};

pub const ConstInt = struct {
    dst: u32,
    value: i64,
};

pub const ConstString = struct {
    dst: u32,
    value: []const u8,
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

pub const Print = struct {
    src: u32,
};
