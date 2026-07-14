// Enum construction and payload projection for the LLVM C-API backend.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const drop = @import("backend_capi_drop.zig");
const value_repr = @import("backend_capi_value_repr.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

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
            // Payload words are f64 bit patterns; the register may carry either
            // float width regardless of the payload's declared name, so coerce
            // by the VALUE's actual type (identity when already f64).
            const as_double = value_repr.coerceFloatWidth(fc, value, fc.types.double_ty);
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
