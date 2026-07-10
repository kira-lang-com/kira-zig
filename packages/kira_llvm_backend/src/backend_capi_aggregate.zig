// Aggregate stores, array operations, and enum construction for the LLVM
// C-API backend. Split out of backend_capi_codegen.zig (Core Law #5); the
// native-state boxing/field-set paths moved on to
// backend_capi_native_state.zig. Free functions over *FunctionCodegen.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const drop = @import("backend_capi_drop.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

pub fn lowerStoreIndirect(fc: *FunctionCodegen, v: ir.StoreIndirect) !void {
    const api = fc.api;
    const b = fc.builder;
    const ptr = api.LLVMBuildIntToPtr(b, fc.registers[v.ptr], fc.types.ptr_ty, "store.ptr");
    const src = fc.registers[v.src];
    sw: switch (v.ty.kind) {
        .integer => {
            const storage = try fc.storageType(v.ty);
            const value = if (storage == fc.types.i64) src else api.LLVMBuildTrunc(b, src, storage, "store.trunc");
            _ = api.LLVMBuildStore(b, value, ptr);
        },
        .float => _ = api.LLVMBuildStore(b, src, ptr),
        .string => {
            if (!fc.drop_enabled) {
                _ = api.LLVMBuildStore(b, src, ptr);
                break :sw;
            }
            // A string field owns a deep clone of every stored value (strings are
            // deep values; release_contents/kira_array_release free field buffers).
            // Drop the field's prior buffer first — only when the target is known
            // OWNED field storage (a field_ptr/subobject_ptr result): a borrow-mut
            // pointer to a caller's string local must not free the prior buffer the
            // caller's per-local slot still owns (double free). Pure-native only:
            // in hybrid the old buffer may be VM-owned (written through the
            // borrow-mut bridge) and must not be freed with libc. The clone itself
            // runs in both modes and is always a fresh native buffer, so no
            // self-store aliasing is possible.
            if (fc.request.mode == .llvm_native and v.ptr < fc.reg_field_ptr.len and fc.reg_field_ptr[v.ptr]) {
                const old = api.LLVMBuildLoad2(b, fc.types.string_ty, ptr, "store.str.old");
                const old_buf = api.LLVMBuildExtractValue(b, old, 0, "store.str.oldbuf");
                var fargs = [_]llvm.c.LLVMValueRef{old_buf};
                _ = api.LLVMBuildCall2(b, fc.runtime_decls.free.ty, fc.runtime_decls.free.fn_value, &fargs, fargs.len, "");
            }
            const cloned = drop.cloneStringValue(fc, src);
            _ = api.LLVMBuildStore(b, cloned, ptr);
        },
        .boolean => {
            const value = api.LLVMBuildZExt(b, src, fc.types.i8, "store.bool");
            _ = api.LLVMBuildStore(b, value, ptr);
        },
        .array => {
            if (!fc.drop_enabled) {
                const value = api.LLVMBuildIntToPtr(b, src, fc.types.ptr_ty, "store.rawptr");
                _ = api.LLVMBuildStore(b, value, ptr);
                break :sw;
            }
            // Self-store is a no-op. The `var x = obj.arr; x[i] = ...; obj.arr = x` idiom
            // aliases the field into `x`, mutates in place, then writes the SAME array back.
            // Cloning here (x reads as borrowed) would store a fresh copy and orphan the
            // original the field still pointed at — a per-call leak that is quadratic in a
            // loop. When the source already is the field's current array, leave it untouched.
            const old = api.LLVMBuildLoad2(b, fc.types.ptr_ty, ptr, "store.arr.prev");
            const newp = api.LLVMBuildIntToPtr(b, src, fc.types.ptr_ty, "store.arr.newp");
            const same = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, old, newp, "store.arr.same");
            const work_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "store.arr.work");
            const done_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "store.arr.done");
            _ = api.LLVMBuildCondBr(b, same, done_block, work_block);
            api.LLVMPositionBuilderAtEnd(b, work_block);
            // Drop-before-overwrite: free the field's (different) prior array. Borrow-checking
            // keeps any borrowed read of the old value from being live across this store.
            const reldtor = fc.dtors.elementDestroy(fc.request.program.programPtr(), v.ty);
            var rargs = [_]llvm.c.LLVMValueRef{ old, reldtor orelse api.LLVMConstNull(fc.types.ptr_ty) };
            _ = api.LLVMBuildCall2(b, fc.runtime_decls.array_release.ty, fc.runtime_decls.array_release.fn_value, &rargs, rargs.len, "");
            if (!drop.isOwned(fc, v.src)) {
                // Borrowed array into an owned field: deep clone so the struct owns
                // independent storage (its destructor frees the clone; the original is untouched).
                const sptr = api.LLVMBuildIntToPtr(b, src, fc.types.ptr_ty, "store.arr.src");
                const elem = fc.dtors.elementClone(fc.request.program.programPtr(), v.ty);
                var cargs = [_]llvm.c.LLVMValueRef{ sptr, elem orelse api.LLVMConstNull(fc.types.ptr_ty) };
                const clone = api.LLVMBuildCall2(b, fc.runtime_decls.array_clone.ty, fc.runtime_decls.array_clone.fn_value, &cargs, cargs.len, "store.arr.clone");
                _ = api.LLVMBuildStore(b, clone, ptr);
            } else {
                // Fresh/owned array moves into the field; the struct destructor frees it.
                const value = api.LLVMBuildIntToPtr(b, src, fc.types.ptr_ty, "store.arr.move");
                _ = api.LLVMBuildStore(b, value, ptr);
                drop.onEscape(fc, v.src);
            }
            _ = api.LLVMBuildBr(b, done_block);
            api.LLVMPositionBuilderAtEnd(b, done_block);
        },
        .enum_instance => {
            // An enum struct field is owned by the struct (its destructor frees it, and
            // copies clone it — see backend_capi_destructors). Match the array-field rule:
            //   owned source  -> MOVE the heap enum pointer in and escape the source slot.
            //   borrowed src   -> CLONE the enum block so the struct owns independent
            //                     storage and the borrowed original is untouched. Storing a
            //                     borrowed field (`Other { mode: src.mode }`) without cloning
            //                     would alias one enum into two owners -> double free.
            // The clone must also run in HYBRID: this is native-compiled code (an @Native
            // function in a hybrid build) building a native struct with native enum blocks —
            // the VM is not party to this store, so without the clone the borrowed enum aliases
            // into two owners and is freed twice (the `Frame { backend: self.backend }` double
            // free that crashed the Metal backend's first hybrid run).
            // Drop-before-overwrite (self-store guarded): a reassigned enum field
            // (`holder.status = ...` after literal init) discards the block the
            // field already owns — destroy it first or every overwrite leaks the
            // replaced block plus its payload chain. The typed destroy null-checks,
            // so the first store into a zeroed field no-ops. Guard on old == src:
            // a self-store (`x.status = x.status`) must neither destroy nor clone
            // the block it is about to keep.
            if (fc.drop_enabled and (fc.request.mode == .llvm_native or fc.request.mode == .hybrid)) {
                const sptr = api.LLVMBuildIntToPtr(b, src, fc.types.ptr_ty, "store.enum.srcptr");
                const old = api.LLVMBuildLoad2(b, fc.types.ptr_ty, ptr, "store.enum.old");
                const same = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, old, sptr, "store.enum.same");
                const work_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "store.enum.work");
                const done_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "store.enum.done");
                _ = api.LLVMBuildCondBr(b, same, done_block, work_block);
                api.LLVMPositionBuilderAtEnd(b, work_block);
                const destroy_fn = fc.dtors.enumDestroyFn(v.ty);
                var dargs = [_]llvm.c.LLVMValueRef{old};
                _ = api.LLVMBuildCall2(b, destroy_fn.ty, destroy_fn.fn_value, &dargs, dargs.len, "");
                if (!drop.isOwned(fc, v.src)) {
                    const clone_fn = fc.dtors.enumCloneFn(v.ty);
                    var cargs = [_]llvm.c.LLVMValueRef{sptr};
                    const clone = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &cargs, cargs.len, "store.enum.clone");
                    _ = api.LLVMBuildStore(b, clone, ptr);
                } else {
                    _ = api.LLVMBuildStore(b, sptr, ptr);
                    drop.onEscape(fc, v.src);
                }
                _ = api.LLVMBuildBr(b, done_block);
                api.LLVMPositionBuilderAtEnd(b, done_block);
            } else {
                const value = api.LLVMBuildIntToPtr(b, src, fc.types.ptr_ty, "store.enum.move");
                _ = api.LLVMBuildStore(b, value, ptr);
                drop.onEscape(fc, v.src);
            }
        },
        .construct_any, .raw_ptr => {
            // Storing a Kira String into a CString field passes the string's data pointer
            // (the {ptr,len} pair degrades to a char*), matching the text backend. String
            // literals are NUL-terminated globals, so the pointer is a valid C string.
            const src_kind = if (v.src < fc.register_types.len) fc.register_types[v.src].kind else ir.ValueType.Kind.raw_ptr;
            if (v.ty.name != null and std.mem.eql(u8, v.ty.name.?, "CString") and src_kind == .string) {
                const literal_src = v.src < fc.reg_string_literal.len and fc.reg_string_literal[v.src];
                if (fc.drop_enabled and !literal_src) {
                    // Any non-literal string is a view of a buffer some slot frees at
                    // scope exit (a producer slot, a string local's clone, or a caller
                    // frame's clone); aliasing it into a CString field would dangle.
                    // Copy into a fresh NUL-terminated buffer the field keeps (owned
                    // buffers are exact-length, no NUL — literals are the
                    // NUL-terminated ones). The copy is deliberately unmanaged:
                    // C-side lifetime is unknowable here (conservative leak, mirrors
                    // kira_dynamic_cstring_dup).
                    const sptr = api.LLVMBuildExtractValue(b, src, 0, "store.cstr.src");
                    const slen = api.LLVMBuildExtractValue(b, src, 1, "store.cstr.len");
                    const total = api.LLVMBuildAdd(b, slen, api.LLVMConstInt(fc.types.i64, 1, 0), "store.cstr.total");
                    var margs = [_]llvm.c.LLVMValueRef{fc.types.sizeArg(b, total)};
                    const buf = api.LLVMBuildCall2(b, fc.runtime_decls.malloc.ty, fc.runtime_decls.malloc.fn_value, &margs, margs.len, "store.cstr.buf");
                    var cargs = [_]llvm.c.LLVMValueRef{ buf, sptr, fc.types.sizeArg(b, slen) };
                    _ = api.LLVMBuildCall2(b, fc.runtime_decls.memcpy.ty, fc.runtime_decls.memcpy.fn_value, &cargs, cargs.len, "");
                    var nul_idx = [_]llvm.c.LLVMValueRef{slen};
                    const nul_ptr = api.LLVMBuildInBoundsGEP2(b, fc.types.i8, buf, &nul_idx, nul_idx.len, "store.cstr.nul");
                    _ = api.LLVMBuildStore(b, api.LLVMConstInt(fc.types.i8, 0, 0), nul_ptr);
                    _ = api.LLVMBuildStore(b, buf, ptr);
                } else {
                    // Literal source (or drop disabled): the pointer is a
                    // NUL-terminated global that nothing frees; alias it.
                    const data_ptr = api.LLVMBuildExtractValue(b, src, 0, "store.cstr");
                    _ = api.LLVMBuildStore(b, data_ptr, ptr);
                }
            } else if (fc.drop_enabled and fc.request.mode == .llvm_native and v.ty.kind == .raw_ptr and src_kind == .raw_ptr) {
                // Closure field store (deep-value model, mirrors strings): the field
                // owns an independent DEEP CLONE and the replaced closure is destroyed
                // first; the source register keeps its own block (its slot frees it at
                // scope exit). Both primitives are tag-safe, so a plain FFI pointer
                // stored through this path passes through unchanged and the old value
                // is only freed when it is a real closure. Self-store guard: storing
                // the value the field already holds must neither destroy nor clone.
                // A closure-typed field is a full i64 slot (fieldStorageType): load and
                // store the whole word so the bit-63 closure tag survives on wasm32.
                // Other raw_ptr fields stay at pointer storage width — a raw i64 load
                // of those would over-read the adjacent field on wasm32 (4-byte ptr)
                // and set garbage tag bits, misfiring the tag-safe destroy.
                const closure_field = utils.isClosureValueType(v.ty);
                const old = if (closure_field)
                    api.LLVMBuildLoad2(b, fc.types.i64, ptr, "store.clos.old")
                else blk: {
                    const old_ptr = api.LLVMBuildLoad2(b, fc.types.ptr_ty, ptr, "store.clos.oldptr");
                    break :blk api.LLVMBuildPtrToInt(b, old_ptr, fc.types.i64, "store.clos.old");
                };
                const same = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, old, src, "store.clos.same");
                const work_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "store.clos.work");
                const done_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "store.clos.done");
                _ = api.LLVMBuildCondBr(b, same, done_block, work_block);
                api.LLVMPositionBuilderAtEnd(b, work_block);
                var dargs = [_]llvm.c.LLVMValueRef{old};
                _ = api.LLVMBuildCall2(b, fc.dtors.destroy_closure.ty, fc.dtors.destroy_closure.fn_value, &dargs, dargs.len, "");
                var cargs = [_]llvm.c.LLVMValueRef{src};
                const clone = api.LLVMBuildCall2(b, fc.dtors.closure_clone.ty, fc.dtors.closure_clone.fn_value, &cargs, cargs.len, "store.clos.clone");
                if (closure_field) {
                    _ = api.LLVMBuildStore(b, clone, ptr);
                } else {
                    const clone_ptr = api.LLVMBuildIntToPtr(b, clone, fc.types.ptr_ty, "store.clos.cloneptr");
                    _ = api.LLVMBuildStore(b, clone_ptr, ptr);
                }
                _ = api.LLVMBuildBr(b, done_block);
                api.LLVMPositionBuilderAtEnd(b, done_block);
            } else {
                // Closure-typed fields are i64 slots (tag-preserving, see
                // fieldStorageType); everything else stores at pointer width.
                if (utils.isClosureValueType(v.ty)) {
                    _ = api.LLVMBuildStore(b, src, ptr);
                } else {
                    const value = api.LLVMBuildIntToPtr(b, src, fc.types.ptr_ty, "store.rawptr");
                    _ = api.LLVMBuildStore(b, value, ptr);
                }
                // A closure/enum moved into a struct field on the non-deep paths is no
                // longer ours to free (no destructor for it there, so it leaks rather
                // than double-frees).
                drop.onEscape(fc, v.src);
            }
        },
        else => return error.UnsupportedExecutableFeature,
    }
}

pub fn lowerAllocArray(fc: *FunctionCodegen, v: ir.AllocArray) !void {
    const api = fc.api;
    const b = fc.builder;
    var args = [_]llvm.c.LLVMValueRef{fc.registers[v.len]};
    const ptr = api.LLVMBuildCall2(b, fc.runtime_decls.array_alloc.ty, fc.runtime_decls.array_alloc.fn_value, &args, args.len, "array.alloc");
    fc.registers[v.dst] = api.LLVMBuildPtrToInt(b, ptr, fc.types.i64, "array.ptr");
    drop.onAlloc(fc, v.dst);
}

pub fn lowerArrayLen(fc: *FunctionCodegen, v: ir.ArrayLen) void {
    const api = fc.api;
    const b = fc.builder;
    const arr = api.LLVMBuildIntToPtr(b, fc.registers[v.array], fc.types.ptr_ty, "array.lenptr");
    var args = [_]llvm.c.LLVMValueRef{arr};
    fc.registers[v.dst] = api.LLVMBuildCall2(b, fc.runtime_decls.array_len.ty, fc.runtime_decls.array_len.fn_value, &args, args.len, "array.len");
}

// `arr[i]` where `arr` is an @FFI.Array place (register = ADDRESS of the inline
// storage; see lowerFfiFixedArraySet). A struct element reads as its in-place
// pointer (a borrow — same repr the arr[i].field peepholes rely on); scalars
// load and widen to the register representation. Returns false when the source
// is not an FFI fixed array.
fn lowerFfiFixedArrayGet(fc: *FunctionCodegen, v: ir.ArrayGet) !bool {
    const api = fc.api;
    const b = fc.builder;
    if (v.array >= fc.register_types.len) return false;
    const arr_ty = fc.register_types[v.array];
    if (arr_ty.kind != .raw_ptr) return false;
    const name = arr_ty.name orelse return false;
    const type_decl = utils.findTypeDecl(fc.request.program.programPtr(), name) orelse return false;
    const ffi_info = type_decl.ffi orelse return false;
    const info = switch (ffi_info) {
        .array => |value| value,
        else => return false,
    };
    const elem_storage = try fc.storageType(info.element);
    const base = api.LLVMBuildIntToPtr(b, fc.registers[v.array], fc.types.ptr_ty, "ffiarr.getbase");
    var idx = [_]llvm.c.LLVMValueRef{fc.registers[v.index]};
    const elem_ptr = api.LLVMBuildInBoundsGEP2(b, elem_storage, base, &idx, idx.len, "ffiarr.getelem");
    switch (info.element.kind) {
        .ffi_struct => fc.registers[v.dst] = api.LLVMBuildPtrToInt(b, elem_ptr, fc.types.i64, "ffiarr.getptr"),
        .integer => {
            const raw = api.LLVMBuildLoad2(b, elem_storage, elem_ptr, "ffiarr.getint");
            const unsigned = info.element.name != null and info.element.name.?.len > 0 and info.element.name.?[0] == 'U';
            fc.registers[v.dst] = if (elem_storage == fc.types.i64)
                raw
            else if (unsigned)
                api.LLVMBuildZExt(b, raw, fc.types.i64, "ffiarr.getzext")
            else
                api.LLVMBuildSExt(b, raw, fc.types.i64, "ffiarr.getsext");
        },
        .float => fc.registers[v.dst] = api.LLVMBuildLoad2(b, elem_storage, elem_ptr, "ffiarr.getfloat"),
        .boolean => {
            const raw = api.LLVMBuildLoad2(b, fc.types.i8, elem_ptr, "ffiarr.getbool8");
            fc.registers[v.dst] = api.LLVMBuildTrunc(b, raw, fc.types.bool_ty, "ffiarr.getbool");
        },
        .raw_ptr => {
            const raw = api.LLVMBuildLoad2(b, fc.types.ptr_ty, elem_ptr, "ffiarr.getraw");
            fc.registers[v.dst] = api.LLVMBuildPtrToInt(b, raw, fc.types.i64, "ffiarr.getrawint");
        },
        else => return false,
    }
    return true;
}

pub fn lowerArrayGet(fc: *FunctionCodegen, v: ir.ArrayGet) !void {
    const api = fc.api;
    const b = fc.builder;
    if (try lowerFfiFixedArrayGet(fc, v)) return;
    const arr = api.LLVMBuildIntToPtr(b, fc.registers[v.array], fc.types.ptr_ty, "array.getptr");
    const slot = fc.entryAlloca(fc.types.bridge_ty, "array.get.slot");
    var args = [_]llvm.c.LLVMValueRef{ arr, fc.registers[v.index], slot };
    // A checker-verified element DRAIN takes the element's value (dst owns it —
    // tracked via the .array_get pre-scan slot) and VOID-tombstones the array
    // slot, so kira_array_release skips it and a later read of the drained
    // slot yields a zero value (deterministic dispatch failure, no double
    // free). Plain reads keep the borrow/copy semantics of kira_array_load.
    const load = if (v.moved) fc.runtime_decls.array_take else fc.runtime_decls.array_load;
    _ = api.LLVMBuildCall2(b, load.ty, load.fn_value, &args, args.len, "");
    const bv = api.LLVMBuildLoad2(b, fc.types.bridge_ty, slot, "array.get.bv");
    fc.registers[v.dst] = try fc.unpackBridge(v.ty, bv);
    if (v.moved) drop.onAlloc(fc, v.dst);
}

// Build the bridge value to store into an array element, applying Rust-style ownership
// for ffi_struct elements (native drop only):
//   owned source  -> MOVE: store its heap pointer directly (no boxed copy, no orphaned
//                    shell); the caller escapes the source slot so the function won't
//                    also free it. The element now owns the struct; array release frees it.
//   borrowed src  -> CLONE: deep-clone (kira_clone_<T>) so the element owns independent
//                    storage and the borrowed original is untouched.
// All other cases (non-struct elements, or the VM-owned hybrid path) keep the existing
// boxed copy. Both move and clone use the box_struct=false packing (tag RAW_PTR + pointer),
// matching the boxed element layout the per-element destructor expects.
fn buildElementBridge(fc: *FunctionCodegen, src_reg: u32) !llvm.c.LLVMValueRef {
    const vt = fc.register_types[src_reg];
    if (fc.drop_enabled and fc.request.mode == .llvm_native and vt.kind == .ffi_struct) {
        if (vt.name) |name| {
            if (fc.dtors.map.get(name) != null) {
                // Move the owned source (or clone a borrow) into a fresh caller-stable
                // heap struct, then store that pointer directly as the element — no boxed
                // shallow copy, no orphaned shell. moveOrCloneToHeap consumes the source.
                const heap = drop.moveOrCloneToHeap(fc, src_reg, name);
                return fc.packBridgeBoxed(vt, heap, false);
            }
        }
    }
    // A string element owns a deep clone of its buffer (strings are deep values):
    // kira_array_release / kira_array_store_release free STRING-tag element
    // buffers, and kira_array_clone deep-copies them, so the element must never
    // alias a register's buffer. The source register stays tracked by its own
    // producer slot (no escape).
    if (fc.drop_enabled and vt.kind == .string) {
        const cloned = drop.cloneStringValue(fc, fc.registers[src_reg]);
        return fc.packBridge(vt, cloned);
    }
    // A BORROWED closure element deep-clones in (tag-safe, blocks are small):
    // the element destructor fallback frees closure elements, so an aliased
    // borrow would be freed under its real owner. An owned source moves in
    // as-is (lowerArraySet/Append escape it afterwards). Type-erased (Any)
    // elements are NOT cloned — construct values move (deep-cloning widget
    // trees per store is a per-frame memory explosion).
    if (fc.drop_enabled and fc.request.mode == .llvm_native and
        vt.kind == .raw_ptr and !drop.isOwned(fc, src_reg))
    {
        var cargs = [_]llvm.c.LLVMValueRef{fc.registers[src_reg]};
        const cloned = fc.api.LLVMBuildCall2(fc.builder, fc.dtors.closure_clone.ty, fc.dtors.closure_clone.fn_value, &cargs, cargs.len, "element.heap.clone");
        return fc.packBridge(vt, cloned);
    }
    return fc.packBridge(vt, fc.registers[src_reg]);
}

// `arr[i] = v` where `arr` is an @FFI.Array place. The array register holds the
// ADDRESS of the inline `[count x element]` storage (a field_ptr — see
// lowerMutableObject in lower_from_hir_places.zig), not a heap kira-array
// handle, so the kira_array_store_* runtime helpers must not run: they would
// read the inline bytes as a (null/garbage) KiraArray pointer, silently drop
// the store, and orphan the element copy — the ffi_nested_fixed_array_assignment
// leak. Lower a direct element store instead: GEP into the inline storage and
// copy the element by value (C layout). A struct element releases the replaced
// slot's owned contents first and deep-clones the stored copy's contents after,
// mirroring copy_indirect's value semantics; the source register is NOT escaped
// (it keeps ownership of its own storage and drops at scope exit). No bounds
// check: the index range is FFI-boundary C semantics, same as native code
// writing the array. Returns false when the destination is not an FFI fixed
// array (callers fall through to the kira-array path).
fn lowerFfiFixedArraySet(fc: *FunctionCodegen, v: ir.ArraySet) !bool {
    const api = fc.api;
    const b = fc.builder;
    if (v.array >= fc.register_types.len) return false;
    const arr_ty = fc.register_types[v.array];
    if (arr_ty.kind != .raw_ptr) return false;
    const name = arr_ty.name orelse return false;
    const type_decl = utils.findTypeDecl(fc.request.program.programPtr(), name) orelse return false;
    const ffi_info = type_decl.ffi orelse return false;
    const info = switch (ffi_info) {
        .array => |value| value,
        else => return false,
    };
    const elem_storage = try fc.storageType(info.element);
    const base = api.LLVMBuildIntToPtr(b, fc.registers[v.array], fc.types.ptr_ty, "ffiarr.base");
    var idx = [_]llvm.c.LLVMValueRef{fc.registers[v.index]};
    const elem_ptr = api.LLVMBuildInBoundsGEP2(b, elem_storage, base, &idx, idx.len, "ffiarr.elem");
    switch (info.element.kind) {
        .ffi_struct => {
            const elem_name = info.element.name orelse return false;
            const helpers = if (fc.drop_enabled) fc.dtors.map.get(elem_name) else null;
            // Drop-before-overwrite: the inline slot's owned contents (arrays,
            // strings, nested structs) are discarded by the shallow store below.
            if (helpers) |h| {
                var rargs = [_]llvm.c.LLVMValueRef{elem_ptr};
                _ = api.LLVMBuildCall2(b, h.release_contents.ty, h.release_contents.fn_value, &rargs, rargs.len, "");
            }
            const src_ptr = api.LLVMBuildIntToPtr(b, fc.registers[v.src], fc.types.ptr_ty, "ffiarr.src");
            const value = api.LLVMBuildLoad2(b, elem_storage, src_ptr, "ffiarr.val");
            _ = api.LLVMBuildStore(b, value, elem_ptr);
            // Deep-clone the stored copy's contents so the slot owns storage
            // independent of the source (which keeps its own drop obligation).
            if (helpers) |h| {
                var cargs = [_]llvm.c.LLVMValueRef{elem_ptr};
                _ = api.LLVMBuildCall2(b, h.clone_contents.ty, h.clone_contents.fn_value, &cargs, cargs.len, "");
            }
        },
        .integer => {
            const value = if (elem_storage == fc.types.i64)
                fc.registers[v.src]
            else
                api.LLVMBuildTrunc(b, fc.registers[v.src], elem_storage, "ffiarr.trunc");
            _ = api.LLVMBuildStore(b, value, elem_ptr);
        },
        .float => _ = api.LLVMBuildStore(b, fc.registers[v.src], elem_ptr),
        .boolean => {
            const value = api.LLVMBuildZExt(b, fc.registers[v.src], fc.types.i8, "ffiarr.bool");
            _ = api.LLVMBuildStore(b, value, elem_ptr);
        },
        .raw_ptr => {
            const value = api.LLVMBuildIntToPtr(b, fc.registers[v.src], fc.types.ptr_ty, "ffiarr.ptr");
            _ = api.LLVMBuildStore(b, value, elem_ptr);
        },
        // String/enum/array/Any elements inside an @FFI.Array have no defined
        // C-layout store here; fall through to the kira-array path (which
        // no-ops on the non-array pointer) rather than corrupt inline memory.
        else => return false,
    }
    return true;
}

pub fn lowerArraySet(fc: *FunctionCodegen, v: ir.ArraySet) !void {
    const api = fc.api;
    const b = fc.builder;
    if (try lowerFfiFixedArraySet(fc, v)) return;
    const arr = api.LLVMBuildIntToPtr(b, fc.registers[v.array], fc.types.ptr_ty, "array.setptr");
    const bv = try buildElementBridge(fc, v.src);
    const slot = fc.entryAlloca(fc.types.bridge_ty, "array.set.slot");
    _ = api.LLVMBuildStore(b, bv, slot);
    // Drop the element being overwritten when it owns heap contents (a struct element
    // with its own arrays/sub-structs, or a boxed inner array), or each overwrite
    // orphans the prior occupant. The destructor is the ARRAY's element destructor
    // (elementDestroy of the container type register_types[v.array]) — NOT the source
    // element's own type. For struct/enum/string elements the two resolve identically
    // (elementDestroy is name-keyed for those), but for a nested array `[[T]]` the
    // container gives the inner-array wrapper (kira_destroy_arr_<[T]>) while the source
    // `[T]` type would return the destructor for `[T]`'s OWN elements — the tag-safe
    // closure no-op — leaking the replaced inner array (box + storage + contents).
    // kira_array_store_release guards old==new so storing a borrowed element back to its
    // own slot is a no-op, not a use-after-free. Primitive elements (no destructor) keep
    // the plain store.
    const elem_destroy = if (fc.drop_enabled and v.array < fc.register_types.len)
        fc.dtors.elementDestroy(fc.request.program.programPtr(), fc.register_types[v.array])
    else
        null;
    // String elements own a cloned buffer that kira_array_store_release frees by
    // STRING tag (no RAW_PTR destructor needed). elementDestroy returns null for
    // them, so without forcing the release path a plain kira_array_store would
    // orphan the old buffer — one leaked string per overwrite (Codex review).
    const is_string_elem = fc.drop_enabled and v.src < fc.register_types.len and fc.register_types[v.src].kind == .string;
    if (elem_destroy != null or is_string_elem) {
        const destroy_fn = elem_destroy orelse api.LLVMConstNull(fc.types.ptr_ty);
        var args = [_]llvm.c.LLVMValueRef{ arr, fc.registers[v.index], slot, destroy_fn };
        _ = api.LLVMBuildCall2(b, fc.runtime_decls.array_store_release.ty, fc.runtime_decls.array_store_release.fn_value, &args, args.len, "");
    } else {
        var args = [_]llvm.c.LLVMValueRef{ arr, fc.registers[v.index], slot };
        _ = api.LLVMBuildCall2(b, fc.runtime_decls.array_store.ty, fc.runtime_decls.array_store.fn_value, &args, args.len, "");
    }
    // The element copy now owns (shares) the value's nested storage; stop tracking the
    // source so its slot can't free storage the array still references (conservative:
    // leaks the source shell, never double-frees). A string source is exempt: the
    // element received a CLONE (buildElementBridge), so the source register keeps
    // ownership of its own buffer and its slot frees it at exit.
    if (v.src >= fc.register_types.len or fc.register_types[v.src].kind != .string) drop.onEscape(fc, v.src);
}

pub fn lowerArrayAppend(fc: *FunctionCodegen, v: ir.ArrayAppend) !void {
    const api = fc.api;
    const b = fc.builder;
    const arr = api.LLVMBuildIntToPtr(b, fc.registers[v.array], fc.types.ptr_ty, "array.appendptr");
    const bv = try buildElementBridge(fc, v.src);
    const slot = fc.entryAlloca(fc.types.bridge_ty, "array.append.slot");
    _ = api.LLVMBuildStore(b, bv, slot);
    var args = [_]llvm.c.LLVMValueRef{ arr, slot };
    _ = api.LLVMBuildCall2(b, fc.runtime_decls.array_append.ty, fc.runtime_decls.array_append.fn_value, &args, args.len, "");
    // See lowerArraySet: the appended element copy shares the value's nested storage,
    // so the source must stop being tracked for drop — except strings, whose element
    // received a clone and whose source keeps its own buffer.
    if (v.src >= fc.register_types.len or fc.register_types[v.src].kind != .string) drop.onEscape(fc, v.src);
}

// An enum value is a heap 16-byte block: { i64 tag, i64 payload }. The payload
// is the value widened to i64 (strings are heap-boxed). Mirrors
// backend_text_ir_enum_ops.
pub fn lowerAllocEnum(fc: *FunctionCodegen, v: ir.AllocEnum) !void {
    const api = fc.api;
    const b = fc.builder;
    var margs = [_]llvm.c.LLVMValueRef{fc.types.sizeArg(b, api.LLVMConstInt(fc.types.i64, 16, 0))};
    const ptr = api.LLVMBuildCall2(b, fc.runtime_decls.malloc.ty, fc.runtime_decls.malloc.fn_value, &margs, margs.len, "enum.alloc");
    var tag_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, 0, 0)};
    const tag_slot = api.LLVMBuildInBoundsGEP2(b, fc.types.i64, ptr, &tag_idx, tag_idx.len, "enum.tag.slot");
    _ = api.LLVMBuildStore(b, api.LLVMConstInt(fc.types.i64, v.discriminant, 0), tag_slot);
    var payload_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, 1, 0)};
    const payload_slot = api.LLVMBuildInBoundsGEP2(b, fc.types.i64, ptr, &payload_idx, payload_idx.len, "enum.payload.slot");
    const payload: llvm.c.LLVMValueRef = if (v.payload_src) |src| blk: {
        const src_ty = fc.register_types[src];
        // A payload that is itself an owned heap value (an enum/array/struct/closure)
        // moves into this enum block: escape the source so scope-exit teardown does
        // not free it a second time once the enum escapes (return/store). Without
        // this transfer the payload is freed at the constructing frame's exit and a
        // returned enum dangles (use-after-free on re-match). A *borrowed* enum
        // payload is deep-cloned instead, so the new enum owns independent storage
        // and the borrowed original is left intact — mirrors the struct-field store
        // rule in lowerStoreAggregate.
        if (src_ty.kind == .enum_instance and fc.drop_enabled and (fc.request.mode == .llvm_native or fc.request.mode == .hybrid) and !drop.isOwned(fc, src)) {
            const sptr = api.LLVMBuildIntToPtr(b, fc.registers[src], fc.types.ptr_ty, "enum.payload.clonesrc");
            const clone_fn = fc.dtors.enumCloneFn(src_ty);
            var cargs = [_]llvm.c.LLVMValueRef{sptr};
            const clone = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &cargs, cargs.len, "enum.payload.clone");
            break :blk api.LLVMBuildPtrToInt(b, clone, fc.types.i64, "enum.payload.cloneint");
        }
        const widened = try enumPayloadAsI64(fc, src_ty, fc.registers[src]);
        switch (src_ty.kind) {
            // Owned heap payloads transfer ownership into the enum (escape nulls the
            // source's cleanup slot); a borrowed source has no slot, so this is a no-op.
            .enum_instance, .array, .ffi_struct, .raw_ptr, .construct_any => drop.onEscape(fc, src),
            else => {},
        }
        break :blk widened;
    } else api.LLVMConstInt(fc.types.i64, 0, 0);
    _ = api.LLVMBuildStore(b, payload, payload_slot);
    fc.registers[v.dst] = api.LLVMBuildPtrToInt(b, ptr, fc.types.i64, "enum.ptr");
}

pub fn enumPayloadAsI64(fc: *FunctionCodegen, value_type: ir.ValueType, value: llvm.c.LLVMValueRef) !llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    return switch (value_type.kind) {
        .integer, .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => value,
        .boolean => api.LLVMBuildZExt(b, value, fc.types.i64, "enum.bool"),
        .float => blk: {
            const as_double = if (value_type.name != null and std.mem.eql(u8, value_type.name.?, "F32"))
                api.LLVMBuildFPExt(b, value, fc.types.double_ty, "enum.fpext")
            else
                value;
            break :blk api.LLVMBuildBitCast(b, as_double, fc.types.i64, "enum.fbits");
        },
        .string => blk: {
            // Box the %kira.string on the heap and store its address. The box owns
            // a deep CLONE of the buffer (strings are deep values; the source's
            // producer/local slot frees the original at scope exit, and a payload
            // read clones back out). The box and its clone are reclaimed with the
            // enum's known leak class (kira_destroy_raw_ptr frees only the 16-byte
            // block — phase-2 per-enum destructors will free string payloads).
            const boxed_value = if (fc.drop_enabled) drop.cloneStringValue(fc, value) else value;
            var margs = [_]llvm.c.LLVMValueRef{fc.types.sizeArg(b, api.LLVMConstInt(fc.types.i64, 16, 0))};
            const box = api.LLVMBuildCall2(b, fc.runtime_decls.malloc.ty, fc.runtime_decls.malloc.fn_value, &margs, margs.len, "enum.str.box");
            _ = api.LLVMBuildStore(b, boxed_value, box);
            break :blk api.LLVMBuildPtrToInt(b, box, fc.types.i64, "enum.str.int");
        },
        .void => api.LLVMConstInt(fc.types.i64, 0, 0),
    };
}

pub fn lowerEnumPayload(fc: *FunctionCodegen, v: ir.EnumPayload) !llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    const base = api.LLVMBuildIntToPtr(b, fc.registers[v.src], fc.types.ptr_ty, "enum.payload.base");
    var idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, 1, 0)};
    const slot = api.LLVMBuildInBoundsGEP2(b, fc.types.i64, base, &idx, idx.len, "enum.payload.slot");
    const raw = api.LLVMBuildLoad2(b, fc.types.i64, slot, "enum.payload.raw");
    return switch (v.payload_ty.kind) {
        .integer, .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => raw,
        .boolean => api.LLVMBuildTrunc(b, raw, fc.types.bool_ty, "enum.payload.bool"),
        .float => blk: {
            const d = api.LLVMBuildBitCast(b, raw, fc.types.double_ty, "enum.payload.double");
            break :blk if (v.payload_ty.name != null and std.mem.eql(u8, v.payload_ty.name.?, "F32"))
                api.LLVMBuildFPTrunc(b, d, fc.types.float_ty, "enum.payload.f32")
            else
                d;
        },
        .string => blk: {
            const sp = api.LLVMBuildIntToPtr(b, raw, fc.types.ptr_ty, "enum.payload.strptr");
            break :blk api.LLVMBuildLoad2(b, fc.types.string_ty, sp, "enum.payload.str");
        },
        .void => error.UnsupportedExecutableFeature,
    };
}

// Pack a register value into a %kira.bridge.value (tagged union) for the array
// runtime. Field 0 = type tag, field 2 = i64 payload, field 3 = extra (string
// length). Mirrors backend_text_ir_core array_set/append packing.
// A closure is a heap block: { i64 function_id, i64 capture_count, [N x bridge] }.
// The register value is the pointer with the high bit set, so call_value can tell
// a closure from a plain function id.
