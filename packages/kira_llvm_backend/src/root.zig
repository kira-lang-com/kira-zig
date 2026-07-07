pub const compile = @import("backend.zig").compile;
pub const validate = @import("backend.zig").validate;
pub const cgu_hash = @import("cgu_hash.zig");
pub const LlvmToolchain = @import("toolchain.zig").Toolchain;
pub const clangDriver = @import("clang_driver.zig");
pub const link = @import("link.zig");
pub const emscripten = @import("emscripten.zig");
pub const LlvmType = @import("types.zig").LlvmType;
pub const LlvmTarget = @import("target.zig").LlvmTarget;
pub const toolchainLayout = @import("kira_llvm_toolchain_layout");
pub const unimplemented = @import("stubs.zig").unimplemented;

pub const cgu_cache = @import("cgu_cache.zig");
pub const cgu_build = @import("cgu_build.zig");

test {
    // Pull the CGU unit tests into this package's test binary. Zig only runs tests
    // from files the root references through a `test`/`comptime` block, not from
    // bare `pub const _ = @import(...)` re-exports.
    _ = @import("cgu_hash.zig");
    _ = @import("cgu_cache.zig");
}
