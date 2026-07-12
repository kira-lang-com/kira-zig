//! Resolve the LLVM tool directory for the current build so out-of-band tooling
//! (the source-level debugger's `llvm-dwarfdump`/`llvm-nm` shell-outs) can find
//! the same toolchain that produced a native artifact. The managed toolchain
//! lives under `~/.kira/toolchains/llvm/<version>/<host>/bin` and is *not* on
//! `PATH`, so a bare tool name never resolves; the debugger needs this directory.
const std = @import("std");
const llvm_backend = @import("kira_llvm_backend");

/// The `bin` directory of the LLVM toolchain `LlvmToolchain.discover` selects
/// (env `KIRA_LLVM_HOME`, then the managed install). Returns null when no
/// toolchain is available — the caller degrades to env + `PATH` discovery rather
/// than failing, since VM debugging needs no LLVM tools at all. Caller owns the
/// returned slice.
pub fn llvmToolDir(allocator: std.mem.Allocator) ?[]const u8 {
    const toolchain = llvm_backend.LlvmToolchain.discover(allocator) catch return null;
    return allocator.dupe(u8, toolchain.bin_dir) catch null;
}
