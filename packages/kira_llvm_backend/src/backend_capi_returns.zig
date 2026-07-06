// `ret` lowering for the LLVM C-API backend: the returned-value ownership
// promotions that make every call result a caller-owned fresh value (the
// call-result invariants the drop driver relies on), plus frame exit cleanup.
// Split out of backend_capi_codegen.zig (Core Law #5).
//
// Invariants established here, one per return kind:
//   struct  — the caller receives an owned heap shell (move or deep clone).
//   array   — a borrowed source deep-clones; the caller always owns.
//   enum    — a borrowed source deep-clones (typed clone); every enum a call
//             yields is a fresh owned block ("returned-enum invariant").
//   string  — an untracked source clones its buffer; returned strings are
//             always fresh owned buffers.
//   closure — an untracked raw_ptr source deep-clones (tag-safe).
//   everything else — returned as-is; a tracked owned source escapes through
//             the emitExitCleanup slot-skip.
const llvm = @import("llvm_c.zig");
const drop = @import("backend_capi_drop.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

pub fn lowerReturn(self: *FunctionCodegen, src_opt: ?u32) void {
    const api = self.api;
    const b = self.builder;
    if (src_opt) |src| {
        if (self.drop_enabled and self.function_decl.return_type.kind == .ffi_struct) {
            // Lower the struct result into caller-stable heap storage and
            // escape its source slot BEFORE exit cleanup, so the returned
            // struct outlives the callee frame and the callee can release all
            // of its own remaining temporaries. The caller receives an owned
            // heap struct, tracked as struct_heap at the call site (lowerCall
            // / setup) and freed there.
            const ret_val = drop.prepareStructReturn(self, src);
            drop.emitExitCleanup(self, null);
            _ = api.LLVMBuildRet(b, ret_val);
        } else if (self.drop_enabled and self.function_decl.return_type.kind == .array and !drop.isOwned(self, src)) {
            // A BORROWED array returned as owned (`return session.contentPath`,
            // `return view.children`): the caller tracks every array-returning
            // call as owned and frees it, so handing back the alias lets the
            // caller free storage the real owner (a native-state box, a borrowed
            // param) still holds — the editorContentPathSegments use-after-free.
            // Deep-clone so the caller owns independent storage. In hybrid mode
            // kira_array_clone returns the array unchanged (the VM owns it).
            const src_ptr = api.LLVMBuildIntToPtr(b, self.registers[src], self.types.ptr_ty, "ret.arr.src");
            const elem = self.dtors.elementClone(self.request.program.programPtr(), self.function_decl.return_type);
            var cargs = [_]llvm.c.LLVMValueRef{ src_ptr, elem orelse api.LLVMConstNull(self.types.ptr_ty) };
            const clone = api.LLVMBuildCall2(b, self.runtime_decls.array_clone.ty, self.runtime_decls.array_clone.fn_value, &cargs, cargs.len, "ret.arr.clone");
            const ret_val = api.LLVMBuildPtrToInt(b, clone, self.types.i64, "ret.arr.cloneint");
            drop.emitExitCleanup(self, null);
            _ = api.LLVMBuildRet(b, ret_val);
        } else if (self.drop_enabled and self.function_decl.return_type.kind == .enum_instance and !drop.isOwned(self, src)) {
            // Same borrowed->owned promotion for a returned enum block.
            const src_ptr = api.LLVMBuildIntToPtr(b, self.registers[src], self.types.ptr_ty, "ret.enum.src");
            const clone_fn = self.dtors.enumCloneFn(self.function_decl.return_type);
            var cargs = [_]llvm.c.LLVMValueRef{src_ptr};
            const clone = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &cargs, cargs.len, "ret.enum.clone");
            const ret_val = api.LLVMBuildPtrToInt(b, clone, self.types.i64, "ret.enum.cloneint");
            drop.emitExitCleanup(self, null);
            _ = api.LLVMBuildRet(b, ret_val);
        } else if (self.drop_enabled and self.function_decl.return_type.kind == .string and !drop.isOwned(self, src)) {
            // Returned-string invariant: every string a call yields is a
            // fresh owned buffer the caller frees. An UNTRACKED source (a
            // literal, a parameter, or a string local — string locals are
            // deliberately outside the register<->local map) is cloned
            // BEFORE exit cleanup so the returned buffer survives the
            // frame's per-local/producer slot frees. A tracked source
            // (a direct concat/coercion/read result) moves out through the
            // emitExitCleanup(src) slot-skip in the branch below.
            const ret_val = drop.cloneStringValue(self, self.registers[src]);
            drop.emitExitCleanup(self, null);
            _ = api.LLVMBuildRet(b, ret_val);
        } else if (self.drop_enabled and self.request.mode == .llvm_native and self.function_decl.return_type.kind == .raw_ptr and !drop.isOwned(self, src)) {
            // Returned-closure invariant (native): every raw_ptr a call
            // yields is a fresh owned value the caller tracks as .closure
            // and frees (tag-safe). An UNTRACKED source (a borrow param, an
            // array element, a field read) is deep-cloned before exit
            // cleanup; kira_capi_closure_clone passes callable values and
            // plain FFI pointers through unchanged. A tracked source moves
            // out via the emitExitCleanup(src) slot-skip below.
            var cargs = [_]llvm.c.LLVMValueRef{self.registers[src]};
            const ret_val = api.LLVMBuildCall2(b, self.dtors.closure_clone.ty, self.dtors.closure_clone.fn_value, &cargs, cargs.len, "ret.clos.clone");
            drop.emitExitCleanup(self, null);
            _ = api.LLVMBuildRet(b, ret_val);
        } else {
            drop.emitExitCleanup(self, src);
            _ = api.LLVMBuildRet(b, self.registers[src]);
        }
    } else {
        drop.emitExitCleanup(self, null);
        _ = api.LLVMBuildRetVoid(b);
    }
    self.terminated = true;
}
