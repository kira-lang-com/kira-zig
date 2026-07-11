// Value-representation lowering for the LLVM C-API backend: register<->storage
// conversion, bridge-value packing, string constants/concatenation, scalar
// compare/convert semantics. Split out of backend_capi_codegen.zig (Core Law #5).
// Free functions over *FunctionCodegen, matching backend_capi_aggregate.zig /
// backend_capi_calls.zig; FunctionCodegen keeps thin delegating methods so call
// sites across the backend keep the `fc.packBridge(...)` shape.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const capi = @import("backend_capi.zig");
const bridge_string = @import("backend_capi_bridge_string.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

const allocPrintZ = utils.allocPrintZ;

pub fn zeroValue(fc: *FunctionCodegen, value_type: ir.ValueType) llvm.c.LLVMValueRef {
    const api = fc.api;
    return switch (value_type.kind) {
        .float => api.LLVMConstReal(fc.types.llvmType(value_type), 0.0),
        .string => api.LLVMGetUndef(fc.types.string_ty),
        .boolean => api.LLVMConstInt(fc.types.bool_ty, 0, 0),
        else => api.LLVMConstInt(fc.types.i64, 0, 0),
    };
}

// Kira Float is f64 everywhere in the VM, but a named F32 value is a 32-bit
// LLVM float in native registers, locals, fields, and function signatures.
// Wherever an f32-typed value meets an f64 context (or vice versa) the width
// must be converted explicitly — LLVM verifies operand types, so an implicit
// mix (`fcmp float, double`, `ret float` from a double function) is an invalid
// module, the sokolDpiScale editor/host build failure. Identity when the value
// already has the wanted width or is not a float at all, so this is safe to
// call unconditionally at boundaries.
pub fn coerceFloatWidth(fc: *FunctionCodegen, value: llvm.c.LLVMValueRef, want: llvm.c.LLVMTypeRef) llvm.c.LLVMValueRef {
    return coerceFloatWidthRaw(fc.api, fc.builder, fc.types, value, want);
}

// As coerceFloatWidth, for lowering contexts without a FunctionCodegen (the
// shared bridge pack/unpack helpers in backend_capi_dispatch.zig).
pub fn coerceFloatWidthRaw(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    value: llvm.c.LLVMValueRef,
    want: llvm.c.LLVMTypeRef,
) llvm.c.LLVMValueRef {
    const have = api.LLVMTypeOf(value);
    if (have == want) return value;
    if (have == types.float_ty and want == types.double_ty) {
        return api.LLVMBuildFPExt(b, value, want, "f32.widen");
    }
    if (have == types.double_ty and want == types.float_ty) {
        return api.LLVMBuildFPTrunc(b, value, want, "f64.narrow");
    }
    return value;
}

// Float ARITHMETIC and COMPARISON always run at f64, matching the VM (which
// stores and computes every float as f64) — an f32-width operand is widened
// before the operation. Narrowing back to F32 happens only at explicit storage
// boundaries (locals, fields, returns, call arguments) via coerceFloatWidth.
pub fn floatOperand(fc: *FunctionCodegen, value: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    return coerceFloatWidth(fc, value, fc.types.double_ty);
}

// String concatenation: malloc(len_l + len_r), memcpy both halves, and package
// the buffer as a {ptr, len} string value. Matches the VM's `+` on strings.
// The buffer is a fresh owned heap allocation tracked by the dst register's
// string_buf cleanup slot (strings are deep values — see backend_capi_drop.zig).
pub fn lowerStringConcat(fc: *FunctionCodegen, lhs: llvm.c.LLVMValueRef, rhs: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    const lhs_ptr = api.LLVMBuildExtractValue(b, lhs, 0, "scat.lp");
    const lhs_len = api.LLVMBuildExtractValue(b, lhs, 1, "scat.ll");
    const rhs_ptr = api.LLVMBuildExtractValue(b, rhs, 0, "scat.rp");
    const rhs_len = api.LLVMBuildExtractValue(b, rhs, 1, "scat.rl");
    const total = api.LLVMBuildAdd(b, lhs_len, rhs_len, "scat.total");
    var malloc_args = [_]llvm.c.LLVMValueRef{fc.types.sizeArg(b, total)};
    const buf = api.LLVMBuildCall2(b, fc.runtime_decls.malloc.ty, fc.runtime_decls.malloc.fn_value, &malloc_args, malloc_args.len, "scat.buf");
    var copy_l = [_]llvm.c.LLVMValueRef{ buf, lhs_ptr, fc.types.sizeArg(b, lhs_len) };
    _ = api.LLVMBuildCall2(b, fc.runtime_decls.memcpy.ty, fc.runtime_decls.memcpy.fn_value, &copy_l, copy_l.len, "scat.cpyl");
    var tail_index = [_]llvm.c.LLVMValueRef{lhs_len};
    const tail = api.LLVMBuildInBoundsGEP2(b, fc.types.i8, buf, &tail_index, tail_index.len, "scat.tail");
    var copy_r = [_]llvm.c.LLVMValueRef{ tail, rhs_ptr, fc.types.sizeArg(b, rhs_len) };
    _ = api.LLVMBuildCall2(b, fc.runtime_decls.memcpy.ty, fc.runtime_decls.memcpy.fn_value, &copy_r, copy_r.len, "scat.cpyr");
    var out = api.LLVMGetUndef(fc.types.string_ty);
    out = api.LLVMBuildInsertValue(b, out, buf, 0, "scat.sp");
    out = api.LLVMBuildInsertValue(b, out, total, 1, "scat.sl");
    return out;
}

/// Float -> Int conversion matching the VM's `convertValue`: truncate toward
/// zero, but saturate out-of-range magnitudes to i64 min/max and map NaN to
/// 0. A bare `fptosi` is poison for those inputs, so VM and LLVM would
/// otherwise diverge (Core Law #1). `raw` is only selected when the source
/// is in range and non-NaN, so its poison value never reaches the result.
pub fn lowerFloatToIntSaturating(fc: *FunctionCodegen, src: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    const i64_ty = fc.types.i64;
    const f64_ty = fc.types.double_ty;
    const raw = api.LLVMBuildFPToSI(b, src, i64_ty, "fptosi");
    // i64 bounds as doubles (these round to +/-2^63, matching the VM's
    // `@floatFromInt(maxInt/minInt)` comparison thresholds).
    const max_f = api.LLVMConstReal(f64_ty, @as(f64, @floatFromInt(std.math.maxInt(i64))));
    const min_f = api.LLVMConstReal(f64_ty, @as(f64, @floatFromInt(std.math.minInt(i64))));
    const max_i = api.LLVMConstInt(i64_ty, @bitCast(@as(i64, std.math.maxInt(i64))), 1);
    const min_i = api.LLVMConstInt(i64_ty, @bitCast(@as(i64, std.math.minInt(i64))), 1);
    const zero_i = api.LLVMConstInt(i64_ty, 0, 1);
    const ge_max = api.LLVMBuildFCmp(b, llvm.c.LLVMRealOGE, src, max_f, "sat.ge");
    const le_min = api.LLVMBuildFCmp(b, llvm.c.LLVMRealOLE, src, min_f, "sat.le");
    const is_nan = api.LLVMBuildFCmp(b, llvm.c.LLVMRealUNO, src, src, "sat.nan");
    var result = api.LLVMBuildSelect(b, ge_max, max_i, raw, "sat.hi");
    result = api.LLVMBuildSelect(b, le_min, min_i, result, "sat.lo");
    result = api.LLVMBuildSelect(b, is_nan, zero_i, result, "sat.nan.sel");
    return result;
}

pub fn lowerCompare(fc: *FunctionCodegen, v: ir.Compare) !llvm.c.LLVMValueRef {
    const api = fc.api;
    const operand_kind = if (v.lhs < fc.register_types.len) fc.register_types[v.lhs].kind else ir.ValueType.Kind.integer;
    if (operand_kind == .string) {
        // String content equality: a `{ptr,len}` value equals another iff the
        // lengths match and the first `min(len)` bytes compare equal. memcmp
        // over min(len) is always in-bounds for both buffers; the length check
        // distinguishes a string from its own prefix.
        const b = fc.builder;
        const lhs = fc.registers[v.lhs];
        const rhs = fc.registers[v.rhs];
        const len_a = api.LLVMBuildExtractValue(b, lhs, 1, "streq.alen");
        const len_b = api.LLVMBuildExtractValue(b, rhs, 1, "streq.blen");
        const ptr_a = api.LLVMBuildExtractValue(b, lhs, 0, "streq.aptr");
        const ptr_b = api.LLVMBuildExtractValue(b, rhs, 0, "streq.bptr");
        const len_eq = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, len_a, len_b, "streq.leneq");
        const a_shorter = api.LLVMBuildICmp(b, llvm.c.LLVMIntULT, len_a, len_b, "streq.ashorter");
        const min_len = api.LLVMBuildSelect(b, a_shorter, len_a, len_b, "streq.min");
        var args = [_]llvm.c.LLVMValueRef{ ptr_a, ptr_b, fc.types.sizeArg(b, min_len) };
        const cmp = api.LLVMBuildCall2(b, fc.runtime_decls.memcmp.ty, fc.runtime_decls.memcmp.fn_value, &args, args.len, "streq.memcmp");
        const zero = api.LLVMConstInt(fc.types.i32, 0, 0);
        const bytes_eq = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, cmp, zero, "streq.byteseq");
        const equal = api.LLVMBuildAnd(b, len_eq, bytes_eq, "streq.eq");
        return switch (v.op) {
            .equal => equal,
            .not_equal => api.LLVMBuildNot(b, equal, "streq.ne"),
            // The compare-operand gate rejects ordered string comparisons.
            else => equal,
        };
    }
    if (operand_kind == .float) {
        // Compare at f64: an F32-width operand is widened first (VM parity —
        // the VM compares every float as f64; mixed widths are invalid IR).
        return api.LLVMBuildFCmp(
            fc.builder,
            switch (v.op) {
                .equal => llvm.c.LLVMRealOEQ,
                .not_equal => llvm.c.LLVMRealONE,
                .less => llvm.c.LLVMRealOLT,
                .less_equal => llvm.c.LLVMRealOLE,
                .greater => llvm.c.LLVMRealOGT,
                .greater_equal => llvm.c.LLVMRealOGE,
            },
            floatOperand(fc, fc.registers[v.lhs]),
            floatOperand(fc, fc.registers[v.rhs]),
            "fcmp",
        );
    }
    // Integer / boolean / pointer comparison. Equality is valid for all;
    // ordering uses signed predicates (Kira Int is signed).
    return api.LLVMBuildICmp(
        fc.builder,
        switch (v.op) {
            .equal => llvm.c.LLVMIntEQ,
            .not_equal => llvm.c.LLVMIntNE,
            .less => if (v.unsigned) llvm.c.LLVMIntULT else llvm.c.LLVMIntSLT,
            .less_equal => if (v.unsigned) llvm.c.LLVMIntULE else llvm.c.LLVMIntSLE,
            .greater => if (v.unsigned) llvm.c.LLVMIntUGT else llvm.c.LLVMIntSGT,
            .greater_equal => if (v.unsigned) llvm.c.LLVMIntUGE else llvm.c.LLVMIntSGE,
        },
        fc.registers[v.lhs],
        fc.registers[v.rhs],
        "icmp",
    );
}

pub fn storageType(fc: *FunctionCodegen, value_type: ir.ValueType) !llvm.c.LLVMTypeRef {
    return capi.fieldStorageType(fc.types, fc.struct_types.*, fc.request.program.programPtr(), value_type);
}

// Load a value from an LLVM pointer and convert storage→register representation
// (does not handle ffi_struct, whose "value" is the pointer itself).
pub fn loadConverted(fc: *FunctionCodegen, ptr: llvm.c.LLVMValueRef, value_type: ir.ValueType) !llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    // Pointer-like values live in registers as an i64 pointer. Load a pointer-sized
    // word regardless of the field's storage type: an inline fixed FFI array field is
    // laid out as `[N x elem]` in the struct, but reading it as a value yields the
    // pointer in its first word (matching the text backend's degenerate array-field
    // load), so do not load the whole aggregate (ptrtoint of an aggregate is invalid).
    switch (value_type.kind) {
        .array, .construct_any, .raw_ptr, .enum_instance => {
            // A closure-typed field is stored at full i64 width (fieldStorageType):
            // the value is a tagged closure i64 whose bit 63 a ptr-width load would
            // drop on wasm32 (see utils.isClosureValueType). Load the whole word.
            if (utils.isClosureValueType(value_type)) {
                return api.LLVMBuildLoad2(b, fc.types.i64, ptr, "load.clos");
            }
            const raw = api.LLVMBuildLoad2(b, fc.types.ptr_ty, ptr, "load");
            return api.LLVMBuildPtrToInt(b, raw, fc.types.i64, "load.ptrint");
        },
        else => {},
    }
    const storage = try storageType(fc, value_type);
    const raw = api.LLVMBuildLoad2(b, storage, ptr, "load");
    return switch (value_type.kind) {
        .integer => if (storage == fc.types.i64) raw else api.LLVMBuildSExt(b, raw, fc.types.i64, "load.sext"),
        .float, .string => raw,
        // Boolean fields are stored as i8 but live in registers as i1.
        .boolean => api.LLVMBuildTrunc(b, raw, fc.types.bool_ty, "load.bool"),
        else => error.UnsupportedExecutableFeature,
    };
}

// box_struct: array elements own an independent heap copy of an ffi_struct;
// closure captures store the struct pointer directly (matching the text backend).
pub fn packBridgeBoxed(fc: *FunctionCodegen, value_type: ir.ValueType, value: llvm.c.LLVMValueRef, box_struct: bool) !llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    var bv = api.LLVMConstNull(fc.types.bridge_ty);
    bv = api.LLVMBuildInsertValue(b, bv, api.LLVMConstInt(fc.types.i8, utils.bridgeTagValue(value_type), 0), 0, "bv.tag");
    switch (value_type.kind) {
        .integer, .construct_any, .raw_ptr, .array, .enum_instance => {
            bv = api.LLVMBuildInsertValue(b, bv, value, 2, "bv.payload");
        },
        .ffi_struct => {
            if (!box_struct) {
                bv = api.LLVMBuildInsertValue(b, bv, value, 2, "bv.payload");
            } else {
                // Box the inline struct on the heap so the array element owns a copy.
                const struct_ty = fc.struct_types.get(value_type.name orelse return error.UnsupportedExecutableFeature) orelse return error.UnsupportedExecutableFeature;
                const src = api.LLVMBuildIntToPtr(b, value, fc.types.ptr_ty, "bv.struct.src");
                const loaded = api.LLVMBuildLoad2(b, struct_ty, src, "bv.struct.val");
                const type_name = value_type.name orelse return error.UnsupportedExecutableFeature;
                var margs = [_]llvm.c.LLVMValueRef{
                    api.LLVMConstInt(fc.types.i64, ir.nativeStateTypeId(type_name), 0),
                    fc.types.sizeArg(b, api.LLVMSizeOf(struct_ty)),
                };
                const copy = api.LLVMBuildCall2(b, fc.runtime_decls.struct_alloc.ty, fc.runtime_decls.struct_alloc.fn_value, &margs, margs.len, "bv.struct.copy");
                _ = api.LLVMBuildStore(b, loaded, copy);
                bv = api.LLVMBuildInsertValue(b, bv, api.LLVMBuildPtrToInt(b, copy, fc.types.i64, "bv.struct.int"), 2, "bv.payload");
            }
        },
        .float => {
            // Bridge payloads are f64 bit patterns; coerce by the value's ACTUAL
            // width (an F32-typed register may already hold f64 after arithmetic).
            const as_double = coerceFloatWidth(fc, value, fc.types.double_ty);
            const bits = api.LLVMBuildBitCast(b, as_double, fc.types.i64, "bv.fbits");
            bv = api.LLVMBuildInsertValue(b, bv, bits, 2, "bv.payload");
        },
        .boolean => {
            const word = api.LLVMBuildZExt(b, value, fc.types.i64, "bv.bool");
            bv = api.LLVMBuildInsertValue(b, bv, word, 2, "bv.payload");
        },
        .string => bv = bridge_string.packInto(api, b, fc.types, bv, value),
        .void => return error.UnsupportedExecutableFeature,
    }
    return bv;
}

// A private constant global per string literal, packaged as a {ptr, len}
// %kira.string. NUL-terminated so a literal may be aliased into a CString field.
pub fn buildStringConstant(fc: *FunctionCodegen, value: []const u8) !llvm.c.LLVMValueRef {
    const api = fc.api;
    const global_name = try allocPrintZ(fc.allocator, "kira.capi.str.{d}.{d}", .{ fc.function_decl.id, fc.string_counter });
    defer fc.allocator.free(global_name);
    const array_ty = api.LLVMArrayType2(fc.types.i8, value.len + 1);
    const global = api.LLVMAddGlobal(fc.module_ref, array_ty, global_name.ptr);
    api.LLVMSetLinkage(global, llvm.c.LLVMPrivateLinkage);
    api.LLVMSetGlobalConstant(global, 1);
    api.LLVMSetInitializer(global, api.LLVMConstStringInContext2(fc.types.context, value.ptr, value.len, 0));
    const zero = api.LLVMConstInt(fc.types.i32, 0, 0);
    var indices = [_]llvm.c.LLVMValueRef{ zero, zero };
    const data_ptr = api.LLVMConstInBoundsGEP2(array_ty, global, &indices, indices.len);
    var fields = [_]llvm.c.LLVMValueRef{ data_ptr, api.LLVMConstInt(fc.types.i64, value.len, 0) };
    return api.LLVMConstNamedStruct(fc.types.string_ty, &fields, fields.len);
}
