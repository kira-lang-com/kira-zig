//! Target-aware string <-> KiraBridgeValue field packing.
//!
//! A `KiraBridgeValue`'s payload union is exactly one target pointer-pair wide.
//! On 64-bit targets a string `{ptr, len}` needs two 8-byte words, so it occupies
//! the bridge's payload field (index 2 = ptr) and the extra field (index 3 = len)
//! — total 24 bytes, matching the C struct byte-for-byte (ptr@8, len@16).
//!
//! On wasm32 a pointer and `size_t` are 32-bit, so the C `KiraBridgeValue`'s
//! payload union is only 8 bytes and the whole struct is 16 bytes: the string ptr
//! and len both live INSIDE the single payload word — ptr in the low 32 bits
//! (offset 8), len in the high 32 bits (offset 12). The runtime array helpers
//! (`kira_array_store`/`load`/`append`/`store_release`/`clone`) memcpy
//! `sizeof(KiraBridgeValue)` per element, so on wasm32 they copy 16 bytes and
//! never touch a field-3 len at offset 16. Writing the len to field 3 there
//! dropped it on every array round-trip, and the C runtime then read the string
//! length out of the pointer's (always-zero) high word — printing EMPTY strings
//! (ownership_string_deep_value_parity regression). Packing both halves into the
//! payload word keeps the emitted LLVM byte layout identical to the C struct on
//! every target, so the shared C string helpers (kira_bridge_clone_string_element,
//! the store_release/release string-buffer frees) read ptr/len from the right
//! offsets. On 64-bit the split is unchanged (usize_ty aliases i64), so native
//! codegen is byte-identical.
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");

/// True on targets whose C pointer/size_t is narrower than i64 (wasm32), where the
/// string ptr+len must share the single 8-byte payload word instead of using a
/// separate 8-byte extra field.
inline fn packed32(types: capi.Types) bool {
    return types.usize_ty != types.i64;
}

/// Insert a `%kira.string` value's ptr/len into a bridge value's payload fields,
/// choosing the split (64-bit) or packed (wasm32) layout for the target.
pub fn packInto(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    bv: llvm.c.LLVMValueRef,
    string_value: llvm.c.LLVMValueRef,
) llvm.c.LLVMValueRef {
    const sp = api.LLVMBuildExtractValue(b, string_value, 0, "bv.str.ptr");
    const spi = api.LLVMBuildPtrToInt(b, sp, types.i64, "bv.str.ptrint");
    const sl = api.LLVMBuildExtractValue(b, string_value, 1, "bv.str.len");
    if (!packed32(types)) {
        var out = api.LLVMBuildInsertValue(b, bv, spi, 2, "bv.payload");
        out = api.LLVMBuildInsertValue(b, out, sl, 3, "bv.extra");
        return out;
    }
    // wasm32: payload word = (ptr & 0xffffffff) | (len << 32). The ptr is a 32-bit
    // pointer (zero-extended by ptrtoint) and len < 4 GiB, so the OR is disjoint.
    const hi = api.LLVMBuildShl(b, sl, api.LLVMConstInt(types.i64, 32, 0), "bv.str.lenhi");
    const word = api.LLVMBuildOr(b, spi, hi, "bv.str.word");
    return api.LLVMBuildInsertValue(b, bv, word, 2, "bv.payload");
}

/// Rebuild a `%kira.string` value from a bridge value's payload fields, mirroring
/// `packInto`'s per-target layout.
pub fn unpack(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    bv: llvm.c.LLVMValueRef,
) llvm.c.LLVMValueRef {
    const payload = api.LLVMBuildExtractValue(b, bv, 2, "bv.get.payload");
    var s = api.LLVMConstNull(types.string_ty);
    // inttoptr on wasm32 truncates the i64 payload word to the 32-bit low half (ptr);
    // on 64-bit it is an exact reinterpret.
    const sp = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "bv.get.strptr");
    const len = if (!packed32(types))
        api.LLVMBuildExtractValue(b, bv, 3, "bv.get.extra")
    else
        api.LLVMBuildLShr(b, payload, api.LLVMConstInt(types.i64, 32, 0), "bv.get.strlen");
    s = api.LLVMBuildInsertValue(b, s, sp, 0, "bv.get.str0");
    s = api.LLVMBuildInsertValue(b, s, len, 1, "bv.get.str1");
    return s;
}

/// The string length carried in a capture/bridge slot whose payload word (field 2)
/// has already been loaded as an i64, for the per-target layout. Used by the closure
/// capture clone, which reads the payload/extra fields directly from heap slots
/// rather than through an aggregate bridge value.
pub fn lenFromLoadedPayload(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    payload_i64: llvm.c.LLVMValueRef,
    extra_slot_load: ?llvm.c.LLVMValueRef,
) llvm.c.LLVMValueRef {
    if (!packed32(types)) return extra_slot_load.?;
    return api.LLVMBuildLShr(b, payload_i64, api.LLVMConstInt(types.i64, 32, 0), "cc.strlen");
}

/// Re-pack a freshly cloned string pointer (i64) with its length back into a payload
/// word for storing into a capture/bridge slot's field 2. On 64-bit the pointer is
/// stored as-is (the length stays in the separate field 3); on wasm32 the length is
/// folded back into the high 32 bits so the slot keeps the packed layout.
pub fn repackClonedPtr(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    cloned_ptr_i64: llvm.c.LLVMValueRef,
    len_i64: llvm.c.LLVMValueRef,
) llvm.c.LLVMValueRef {
    if (!packed32(types)) return cloned_ptr_i64;
    const hi = api.LLVMBuildShl(b, len_i64, api.LLVMConstInt(types.i64, 32, 0), "cc.strclone.lenhi");
    return api.LLVMBuildOr(b, cloned_ptr_i64, hi, "cc.strclone.word");
}
