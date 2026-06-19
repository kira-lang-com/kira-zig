pub const KiraStatus = enum(c_int) {
    ok = 0,
    fail = 1,
};

pub const KiraDeveloperBackend = enum(c_int) {
    default = 0,
    vm = 1,
    llvm = 2,
    hybrid = 3,
    wasm32_emscripten = 4,
};
