//! wasm32 C-ABI adapter thunks for array element destroy/clone callbacks.
//!
//! The runtime element callbacks kira_array_release/kira_array_store_release take a
//! `void (*)(void *)` and kira_array_clone takes a `void *(*)(void *)`. Several of the
//! per-type/dispatcher helpers the backend hands to those callbacks are declared with
//! the Kira register ABI instead — `(i64) -> void` (kira_destroy_closure,
//! kira_capi_dynamic_destroy) and `(i64) -> i64` (kira_clone_<T>, kira_capi_closure_clone,
//! kira_capi_dynamic_clone). On 64-bit targets a pointer and an i64 share the same ABI, so
//! the raw helper can be passed directly. On wasm32 a `void *` is an i32 and an i64 is a
//! distinct wasm value type, so `call_indirect` — which structurally type-checks the callee
//! against the call site's declared function type — traps with `null function or function
//! signature mismatch` when the runtime invokes an `(i64)->…` helper through a `void*`
//! pointer.
//!
//! These thunks bridge the two ABIs: a `(ptr)->void` / `(ptr)->ptr` wrapper that
//! PtrToInt-widens the incoming pointer to the helper's i64 parameter and IntToPtr-narrows
//! the i64 result back to a pointer. The incoming value is a real heap block address (32-bit
//! on wasm32), so the widen is a zero-extension and the narrow is exact. Only generated when
//! the target actually differs from a pointer (wasm32); on 64-bit `needed()` is false and the
//! backend keeps passing the raw helper, so behavior there is byte-identical.
//!
//! Declaration and body emission are split to match the CGU model of the dtor helpers they
//! wrap: every CGU declares the thunk symbol (so per-function CGUs resolve it as an extern),
//! but only the support CGU emits the body.
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");

/// True when a C `void *` and the i64 register ABI are distinct value types, i.e. the wasm32
/// targets whose pointers are 32-bit. Identity everywhere else.
pub fn needed(types: capi.Types) bool {
    return types.usize_ty != types.i64;
}

/// Declare a `(ptr)->void` thunk symbol (no body). Pairs with `definePtrVoid`.
pub fn declarePtrVoid(
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    name: [:0]const u8,
) capi.RuntimeDecls.Decl {
    var param = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
    const ty = api.LLVMFunctionType(types.void_ty, &param, param.len, 0);
    return .{ .ty = ty, .fn_value = api.LLVMAddFunction(module_ref, name.ptr, ty) };
}

/// Declare a `(ptr)->ptr` thunk symbol (no body). Pairs with `definePtrPtr`.
pub fn declarePtrPtr(
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    name: [:0]const u8,
) capi.RuntimeDecls.Decl {
    var param = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
    const ty = api.LLVMFunctionType(types.ptr_ty, &param, param.len, 0);
    return .{ .ty = ty, .fn_value = api.LLVMAddFunction(module_ref, name.ptr, ty) };
}

/// Emit the body of a `(ptr)->void` thunk: PtrToInt-widen the pointer arg to i64 and forward
/// to `target` (an `(i64)->void` destroy helper of type `target_ty`).
pub fn definePtrVoid(
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    thunk: capi.RuntimeDecls.Decl,
    target: llvm.c.LLVMValueRef,
    target_ty: llvm.c.LLVMTypeRef,
) void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, thunk.fn_value, "entry");
    api.LLVMPositionBuilderAtEnd(builder, entry);
    const arg = api.LLVMGetParam(thunk.fn_value, 0);
    const as_i64 = api.LLVMBuildPtrToInt(builder, arg, types.i64, "cb.p2i");
    var args = [_]llvm.c.LLVMValueRef{as_i64};
    _ = api.LLVMBuildCall2(builder, target_ty, target, &args, args.len, "");
    _ = api.LLVMBuildRetVoid(builder);
}

/// Emit the body of a `(ptr)->ptr` thunk: PtrToInt-widen the arg, forward to `target` (an
/// `(i64)->i64` clone helper of type `target_ty`), and IntToPtr-narrow the i64 result.
pub fn definePtrPtr(
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    thunk: capi.RuntimeDecls.Decl,
    target: llvm.c.LLVMValueRef,
    target_ty: llvm.c.LLVMTypeRef,
) void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, thunk.fn_value, "entry");
    api.LLVMPositionBuilderAtEnd(builder, entry);
    const arg = api.LLVMGetParam(thunk.fn_value, 0);
    const as_i64 = api.LLVMBuildPtrToInt(builder, arg, types.i64, "cb.p2i");
    var args = [_]llvm.c.LLVMValueRef{as_i64};
    const result = api.LLVMBuildCall2(builder, target_ty, target, &args, args.len, "cb.call");
    const as_ptr = api.LLVMBuildIntToPtr(builder, result, types.ptr_ty, "cb.i2p");
    _ = api.LLVMBuildRet(builder, as_ptr);
}
