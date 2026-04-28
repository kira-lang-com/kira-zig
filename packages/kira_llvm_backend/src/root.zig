const build_options = @import("kira_llvm_build_options");
const impl = if (build_options.llvm_available) @import("real_root.zig") else @import("stub_root.zig");

pub const compile = impl.compile;
pub const validate = impl.validate;
pub const LlvmToolchain = impl.LlvmToolchain;
pub const clangDriver = impl.clangDriver;
pub const LlvmType = @import("types.zig").LlvmType;
pub const LlvmTarget = @import("target.zig").LlvmTarget;
pub const toolchainLayout = @import("toolchain_layout.zig");
pub const unimplemented = @import("stubs.zig").unimplemented;
