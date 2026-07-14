//! DWARF debug-info glue between the per-function `FunctionCodegen` state machine
//! (backend_capi_codegen.zig) and the DIBuilder driver (debug_dwarf.zig). Split
//! out under Core Law #5 so the instruction-lowering file stays focused: this
//! module owns subprogram attachment, per-instruction `!dbg` locations, and
//! `dbg.declare` emission for locals. Every entry point no-ops when debug info is
//! disabled or the toolchain can't emit it (`FunctionCodegen.dwarf == null`).

const llvm = @import("llvm_c.zig");
const codegen = @import("backend_capi_codegen.zig");
const FunctionCodegen = codegen.FunctionCodegen;

/// Create + attach this function's DISubprogram and seed the builder's initial
/// debug location to the function's declaration line. Runs before any IR is
/// built so the shared builder always carries a location (LLVM's verifier
/// rejects an inlinable call with debug info but no `!dbg`).
pub fn attach(self: *FunctionCodegen) void {
    const dw = self.dwarf orelse return;
    const attached = dw.attachFunction(self.function_decl, self.function_value);
    self.di_scope = attached.scope;
    self.di_file = attached.file;
    self.di_source_path = attached.source_path;
    self.di_current_line = attached.line;
    dw.setLocation(self.builder, attached.scope, attached.line, 0);
}

/// Set the builder's `!dbg` location from the instruction at `index`. When the
/// instruction has no usable location, the last real line (kept in
/// `di_current_line`) is reused so the location stays valid and in-scope.
pub fn applyLocation(self: *FunctionCodegen, index: usize) void {
    const dw = self.dwarf orelse return;
    const scope = self.di_scope orelse return;
    var line = self.di_current_line;
    var column: c_uint = 0;
    if (index < self.function_decl.locations.len) {
        const lc = dw.lineColumnFor(self.di_source_path, self.function_decl.locations[index]);
        if (lc.line != 0) {
            line = @intCast(lc.line);
            column = @intCast(lc.column);
            self.di_current_line = line;
        }
    }
    dw.setLocation(self.builder, scope, line, column);
}

/// Emit a `dbg.declare` for every entry-block local alloca, naming each by its
/// frame slot index. No-op when DWARF (or the records API) is off.
pub fn declareLocals(self: *FunctionCodegen, entry_block: llvm.c.LLVMBasicBlockRef) void {
    const dw = self.dwarf orelse return;
    const scope = self.di_scope orelse return;
    const file = self.di_file orelse return;
    for (self.locals, 0..) |storage, index| {
        if (storage == null) continue;
        dw.declareLocal(scope, file, storage, entry_block, index, self.di_current_line);
    }
}
