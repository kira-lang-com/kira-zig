// Per-type ownership helper generation for the LLVM C-API backend: emits
// kira_destroy_<T> / kira_release_contents_<T> and the deep-clone helpers
// kira_clone_<T> / kira_clone_contents_<T> (plus the shared kira_destroy_raw_ptr
// declaration and the kira_destroy_closure declaration), mirroring
// backend_text_ir_core's appendReleaseDefinitions / appendCloneDefinitions.
// Split out of backend_capi_drop.zig (Core Law #5); the runtime cleanup-slot drop
// driver that consumes these helpers stays in backend_capi_drop.zig.
const std = @import("std");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const capi = @import("backend_capi.zig");

const findTypeDecl = utils.findTypeDecl;
const allocPrintZ = utils.allocPrintZ;
const fresh_any = @import("backend_capi_fresh_any.zig");
// Per-struct destroy/release/clone body builders (pass 2 of build()); split out
// under Core Law #5.
const struct_dtors = @import("backend_capi_struct_dtors.zig");
// Inner-array wrapper key collection + mangling (nested-array element leak);
// bodies are built in the same module after this map's declarations exist.
const array_dtors = @import("backend_capi_array_dtors.zig");
// wasm32 C-ABI adapter thunks: wrap the i64-ABI clone/destroy helpers so they can be
// passed as `void*(*)(void*)` / `void(*)(void*)` array element callbacks without a
// call_indirect signature-mismatch trap. Identity (no thunk) on 64-bit targets.
const wasm_cb = @import("backend_capi_wasm_cb_adapters.zig");
pub const TypeHelpers = struct {
    release_contents: capi.RuntimeDecls.Decl,
    destroy: capi.RuntimeDecls.Decl,
    clone_contents: capi.RuntimeDecls.Decl,
    clone: capi.RuntimeDecls.Decl,
    // The C-ABI-safe form of `clone` to pass as a kira_array_clone element callback.
    // Equal to `clone` on 64-bit; a `(ptr)->ptr` thunk over it on wasm32.
    clone_cb: capi.RuntimeDecls.Decl,
};

// Typed enum teardown/deep-clone (leak class #4: the 16-byte string-payload box
// and its cloned buffer were shared by kira_enum_clone and never freed).
// Generated per enum type that has at least one String-payload variant; bodies
// live in backend_capi_enum_dtors.zig. Same signatures as kira_destroy_raw_ptr /
// kira_enum_clone, so every call site can substitute them 1:1.
pub const EnumHelpers = struct {
    destroy: capi.RuntimeDecls.Decl,
    clone: capi.RuntimeDecls.Decl,
};

// Typed array-of-array element teardown/deep-clone (the nested-array element
// leak): one destroy/clone pair per INNER array type ("[Int]", "[Message]", ...)
// reachable in the program. `kira_destroy_arr_<K>` / `kira_clone_arr_<K>` free /
// deep-copy a boxed inner array (its storage + owned contents) as an element
// callback for kira_array_release / kira_array_clone. Bodies live in
// backend_capi_array_dtors.zig. NATIVE only — hybrid inner arrays are VM-owned,
// so the map is empty and elementDestroy/elementClone fall back to today's pair.
pub const ArrayHelpers = struct {
    destroy: capi.RuntimeDecls.Decl,
    clone: capi.RuntimeDecls.Decl,
};

pub const Destructors = struct {
    map: std.StringHashMapUnmanaged(TypeHelpers) = .{},
    // Per-enum typed helpers (string-payload enums, NATIVE only — a hybrid enum's
    // payload box may be VM-written and must not be freed/cloned with libc).
    // Empty in hybrid, so every accessor falls back to the generic shallow pair.
    enum_map: std.StringHashMapUnmanaged(EnumHelpers) = .{},
    // Per-inner-array-type teardown/clone wrappers (nested-array element leak,
    // NATIVE only). Keyed by the inner array's bracketed text ("[Int]", ...) —
    // the OUTER array's element name. Empty in hybrid, so elementDestroy/
    // elementClone fall back to the tag-safe closure pair (kira_array_release
    // itself already defers on hybrid).
    array_map: std.StringHashMapUnmanaged(ArrayHelpers) = .{},
    destroy_raw_ptr: capi.RuntimeDecls.Decl,
    destroy_struct_ptr: capi.RuntimeDecls.Decl,
    // Tag-safe owned-closure drop (kira_destroy_closure(i64)): frees a heap closure
    // block, no-ops a callable-value function id. Used for owned closure parameters.
    destroy_closure: capi.RuntimeDecls.Decl,
    // Deep-copy a 16-byte heap enum block (kira_enum_clone(ptr)->ptr): null->null, else
    // malloc+memcpy. An owned enum field is cloned on struct copy and freed on struct
    // destroy, so each struct copy owns an independent enum (no aliasing/double-free).
    enum_clone: capi.RuntimeDecls.Decl,
    // Deep-copy a string byte buffer (kira_capi_string_clone(ptr, len) -> ptr):
    // null->null, else malloc+memcpy. Strings are deep values in the native
    // ownership model: every string entering an aggregate (struct field, array
    // element, native-state slot, enum payload, closure capture) is cloned so the
    // aggregate owns an independent buffer, and every string read out of an
    // aggregate is cloned so the reader owns one too. There are no string moves
    // and no aliasing — each buffer has exactly one owner.
    string_clone: capi.RuntimeDecls.Decl,
    // Per-closure typed capture teardown/deep-clone dispatchers (bodies built in
    // backend_capi_closure_dtors.zig after the type helpers exist, declared here
    // so release_contents/clone_contents can reference them). Both are TAG-SAFE:
    // only a value carrying the closure high bit is freed/copied, so calling them
    // on a plain FFI raw pointer (CString, userdata handle) is a no-op/pass-through.
    closure_release: capi.RuntimeDecls.Decl,
    closure_clone: capi.RuntimeDecls.Decl,
    // Runtime-typed dispatchers for type-erased values (construct_any / Any) and
    // native-state interiors, switching on the kira_struct_alloc type-id header /
    // KiraNativeState.type_id (bodies in backend_capi_dynamic_dtors.zig). Unknown
    // ids no-op (destroy) / alias (clone) — the SAME id lookup decides both, so a
    // value is deep-cloned everywhere iff it is deep-destroyed everywhere.
    struct_type_id: capi.RuntimeDecls.Decl,
    dynamic_destroy: capi.RuntimeDecls.Decl,
    dynamic_clone: capi.RuntimeDecls.Decl,
    state_interior_release: capi.RuntimeDecls.Decl,
    // C-ABI-safe (`void*`-parameter) forms of the i64-ABI dispatchers/closure helpers used
    // as kira_array_release / kira_array_clone element callbacks. Equal to their base
    // decls on 64-bit; wasm32 `(ptr)->void` / `(ptr)->ptr` thunks over them otherwise, so
    // the runtime's call_indirect type-checks against the exact `void(*)(void*)` /
    // `void*(*)(void*)` typedef and does not trap.
    destroy_closure_cb: capi.RuntimeDecls.Decl,
    closure_clone_cb: capi.RuntimeDecls.Decl,
    dynamic_destroy_cb: capi.RuntimeDecls.Decl,
    dynamic_clone_cb: capi.RuntimeDecls.Decl,
    // Whether string struct fields are freed by kira_release_contents_<T>. True on
    // the pure-native path. In HYBRID a native struct's string field may have been
    // written by the VM bridge with a VM-owned buffer, so release must not free it
    // (conservative: leak, never a cross-allocator free).
    release_strings: bool,
    // Whether closures are deep values on this path (fields/elements own their
    // blocks: release frees them, clone deep-copies them). Native only — hybrid
    // closure blocks may be VM-allocated and are torn down through the VM hook.
    deep_closures: bool,
    // Functions PROVEN to return a fresh owned construct_any on every path
    // (backend_capi_fresh_any.zig). Plain-call results of these are tracked as
    // .struct_ptr drops; everything else keeps the untracked alias default.
    fresh_any_returns: fresh_any.FreshAnyReturns = .{},

    pub fn deinit(self: *Destructors, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.enum_map.deinit(allocator);
        self.array_map.deinit(allocator);
        self.fresh_any_returns.deinit(allocator);
    }

    // Should the CALLER track `callee_id`'s construct_any result as an owned
    // .struct_ptr drop? Native only — hybrid Any results may be VM-owned.
    pub fn tracksFreshAnyResult(self: Destructors, callee_id: u32) bool {
        return self.deep_closures and self.fresh_any_returns.contains(callee_id);
    }

    // Typed enum destroy for `ty` (frees a string-payload box + buffer with the
    // block), or the shallow kira_destroy_raw_ptr when no typed helper exists.
    // Fallback pairs with the shallow clone below: shallow-cloned enums share
    // their payload box, so only typed clones may be typed-destroyed.
    pub fn enumDestroyFn(self: Destructors, ty: ir.ValueType) capi.RuntimeDecls.Decl {
        if (ty.name) |name| {
            if (self.enum_map.get(name)) |helpers| return helpers.destroy;
        }
        return self.destroy_raw_ptr;
    }

    pub fn enumCloneFn(self: Destructors, ty: ir.ValueType) capi.RuntimeDecls.Decl {
        if (ty.name) |name| {
            if (self.enum_map.get(name)) |helpers| return helpers.clone;
        }
        return self.enum_clone;
    }

    // Typed struct destroy (kira_destroy_<T>: shell + contents) for a struct-typed
    // value, or the shallow kira_destroy_raw_ptr (block-only free) when no helper
    // exists. Used for struct-payload enum variants, whose payload slot holds the
    // shell pointer directly (moved in by enumPayloadAsI64).
    pub fn structDestroyFn(self: Destructors, ty: ir.ValueType) capi.RuntimeDecls.Decl {
        if (ty.name) |name| {
            if (self.map.get(name)) |helpers| return helpers.destroy;
        }
        return self.destroy_raw_ptr;
    }

    // Typed struct deep-clone (kira_clone_<T>(i64)->i64), or null when no helper
    // exists (every declared struct has one, so callers may treat null as
    // "unreachable"). Paired with structDestroyFn for struct-payload enum clones.
    pub fn structCloneFn(self: Destructors, ty: ir.ValueType) ?capi.RuntimeDecls.Decl {
        if (ty.name) |name| {
            if (self.map.get(name)) |helpers| return helpers.clone;
        }
        return null;
    }

    // The per-element destroy function for an array type, or null for primitive
    // elements (whose buffer is freed without a per-element callback). When the
    // element type is not a struct decl, fall back to the tag-safe closure release
    // (native only): the runtime invokes the callback only on RAW_PTR-tagged
    // elements, and the release itself frees only values carrying the closure high
    // bit — so [Callback] element blocks are reclaimed while integer/float/FFI
    // pointer elements are untouched.
    // kira_destroy_closure (not the dynamic dispatcher): the fallback frees
    // TAGGED closure elements only. Type-erased ([Any]/[Widget]) elements are
    // left untouched (conservative leak) — pairing a typed element destroy with
    // the required deep element clone would deep-copy widget trees on every
    // borrowed array store, a per-frame memory explosion (rolled back).
    pub fn elementDestroy(self: Destructors, program: *const ir.Program, array_ty: ir.ValueType) ?llvm.c.LLVMValueRef {
        if (self.structHelpers(program, array_ty)) |helpers| return helpers.destroy.fn_value;
        // An array of an enum: each RAW_PTR-tagged element points at a heap
        // 16-byte enum block the array owns (elements move in — buildElementBridge
        // packs the pointer and lowerArraySet/Append escape the source). Without
        // this branch the enum block AND any owned payload (string box, struct
        // shell, construct_any tree) fell through to the tag-safe closure no-op
        // and leaked. Native only: a hybrid enum block may be VM-owned.
        if (self.arrayEnumElement(program, array_ty)) |enum_ty| return self.enumDestroyFn(enum_ty).fn_value;
        // An array whose element is itself an array: each RAW_PTR-tagged element
        // is a boxed inner array the outer array owns. The typed wrapper releases
        // it (box + storage + its own owned contents); without it the inner array
        // fell through to the tag-safe closure no-op and leaked. Native only —
        // the map is empty on hybrid (VM-owned inner arrays).
        if (self.arrayElementWrapper(array_ty)) |helpers| return helpers.destroy.fn_value;
        if (arrayContainsDirectConstructAny(array_ty) and self.deep_closures) return self.dynamic_destroy_cb.fn_value;
        if (self.deep_closures) return self.destroy_closure_cb.fn_value;
        return null;
    }

    pub fn elementClone(self: Destructors, program: *const ir.Program, array_ty: ir.ValueType) ?llvm.c.LLVMValueRef {
        if (self.structHelpers(program, array_ty)) |helpers| return helpers.clone_cb.fn_value;
        // Paired with elementDestroy's enum branch: a struct copy / borrowed→owned
        // promotion of an array of enums deep-copies each element block (and its
        // owned payload) so the copy owns it independently. A contains-any enum is
        // move-only (KIR002) so this clone is never reached for it at runtime, and
        // its typed clone traps on the construct_any variant (backend_capi_enum_dtors).
        if (self.arrayEnumElement(program, array_ty)) |enum_ty| return self.enumCloneFn(enum_ty).fn_value;
        // Paired with elementDestroy's array-element branch: a struct copy /
        // borrowed→owned promotion of an array of arrays deep-copies each inner
        // array (and its owned contents) so the copy owns it independently — never
        // an alias. Same array_map, so deep-cloned iff deep-destroyed.
        if (self.arrayElementWrapper(array_ty)) |helpers| return helpers.clone.fn_value;
        if (arrayContainsDirectConstructAny(array_ty) and self.deep_closures) return self.dynamic_clone_cb.fn_value;
        if (self.deep_closures) return self.closure_clone_cb.fn_value;
        return null;
    }

    // When `array_ty`'s element is itself an array (its element-text name is
    // bracketed, e.g. "[Int]"), the typed inner-array teardown/clone wrapper pair
    // — or null when there is none (hybrid: empty map; or a plain array). Native
    // only by construction: the map is only populated on the pure-native path.
    fn arrayElementWrapper(self: Destructors, array_ty: ir.ValueType) ?ArrayHelpers {
        const name = array_ty.name orelse return null;
        if (name.len < 2 or name[0] != '[' or name[name.len - 1] != ']') return null;
        return self.array_map.get(name);
    }

    // When `array_ty`'s element resolves to a declared enum, the enum ValueType to
    // feed enumDestroyFn/enumCloneFn (typed teardown/clone). Native only — hybrid
    // keeps VM-owned enum blocks (empty enum_map falls back to the shallow pair,
    // but we must not even free the block with libc, so gate on deep_closures).
    fn arrayEnumElement(self: Destructors, program: *const ir.Program, array_ty: ir.ValueType) ?ir.ValueType {
        if (!self.deep_closures) return null;
        const name = array_ty.name orelse return null;
        for (program.enums) |enum_decl| {
            if (std.mem.eql(u8, enum_decl.name, name)) return ir.ValueType{ .kind = .enum_instance, .name = name };
        }
        return null;
    }

    fn structHelpers(self: Destructors, program: *const ir.Program, array_ty: ir.ValueType) ?TypeHelpers {
        const name = array_ty.name orelse return null;
        const type_decl = findTypeDecl(program, name) orelse return null;
        if (type_decl.ffi) |ffi_info| {
            switch (ffi_info) {
                .ffi_struct => {},
                else => return null,
            }
        }
        return self.map.get(type_decl.name);
    }

    fn arrayContainsDirectConstructAny(array_ty: ir.ValueType) bool {
        if (array_ty.kind != .array) return false;
        const name = array_ty.name orelse return false;
        return std.mem.startsWith(u8, name, "any ");
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    struct_types: *const std.StringHashMapUnmanaged(llvm.c.LLVMTypeRef),
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    mode: backend_api.BackendMode,
    // When true, only DECLARE the helper symbols (name + type, no bodies) and
    // return the populated Destructors. Used by per-function incremental CGUs,
    // whose calls resolve against the support CGU's definitions at link time.
    // The default (false) path is byte-identical to before this knob existed:
    // every declaration still happens, then every body is emitted.
    declare_only: bool,
) !Destructors {
    var ptr_param = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
    const void_ptr_ty = api.LLVMFunctionType(types.void_ty, &ptr_param, ptr_param.len, 0);

    const destroy_raw = api.LLVMAddFunction(module_ref, "kira_destroy_raw_ptr", void_ptr_ty);
    const destroy_struct = api.LLVMAddFunction(module_ref, "kira_destroy_struct_ptr", void_ptr_ty);
    var closure_param = [_]llvm.c.LLVMTypeRef{types.i64};
    const void_i64_ty = api.LLVMFunctionType(types.void_ty, &closure_param, closure_param.len, 0);
    const destroy_closure = api.LLVMAddFunction(module_ref, "kira_destroy_closure", void_i64_ty);
    const ptr_ptr_ty = api.LLVMFunctionType(types.ptr_ty, &ptr_param, ptr_param.len, 0);
    const enum_clone = api.LLVMAddFunction(module_ref, "kira_enum_clone", ptr_ptr_ty);
    var sclone_params = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.i64 };
    const sclone_ty = api.LLVMFunctionType(types.ptr_ty, &sclone_params, sclone_params.len, 0);
    const string_clone = api.LLVMAddFunction(module_ref, "kira_capi_string_clone", sclone_ty);
    // Per-closure capture teardown/deep-clone dispatchers. Declared here so the
    // type helpers below can reference them; bodies are generated afterwards in
    // backend_capi_closure_dtors.zig (they need this map's kira_destroy_<T> /
    // kira_clone_<T> declarations for typed captures).
    const closure_release = api.LLVMAddFunction(module_ref, "kira_capi_closure_release", void_ptr_ty);
    var cclone_param = [_]llvm.c.LLVMTypeRef{types.i64};
    const cclone_ty = api.LLVMFunctionType(types.i64, &cclone_param, cclone_param.len, 0);
    const closure_clone = api.LLVMAddFunction(module_ref, "kira_capi_closure_clone", cclone_ty);
    // Runtime-typed dynamic dispatchers (bodies in backend_capi_dynamic_dtors.zig).
    // kira_struct_type_id reuses the RuntimeDecls declaration (re-declaring the
    // symbol would make LLVM rename it and break the link).
    var ddestroy_param = [_]llvm.c.LLVMTypeRef{types.i64};
    const ddestroy_ty = api.LLVMFunctionType(types.void_ty, &ddestroy_param, ddestroy_param.len, 0);
    const dynamic_destroy = api.LLVMAddFunction(module_ref, "kira_capi_dynamic_destroy", ddestroy_ty);
    const dynamic_clone = api.LLVMAddFunction(module_ref, "kira_capi_dynamic_clone", cclone_ty);
    const state_interior_release = api.LLVMAddFunction(module_ref, "kira_capi_state_interior_release", void_ptr_ty);

    // wasm32 C-ABI callback thunks over the i64-ABI dispatchers/closure helpers. On 64-bit
    // a pointer and an i64 share the ABI so the raw helper is passed directly (no thunk);
    // on wasm32 the runtime's `void*(*)(void*)` / `void(*)(void*)` element callbacks would
    // trap call_indirect on an `(i64)->…` helper, so we hand it a `(ptr)->…` thunk instead.
    // Declared here (in every CGU); bodies emitted below only in the support CGU.
    const destroy_closure_decl = capi.RuntimeDecls.Decl{ .ty = void_i64_ty, .fn_value = destroy_closure };
    const closure_clone_decl = capi.RuntimeDecls.Decl{ .ty = cclone_ty, .fn_value = closure_clone };
    const dynamic_destroy_decl = capi.RuntimeDecls.Decl{ .ty = ddestroy_ty, .fn_value = dynamic_destroy };
    const dynamic_clone_decl = capi.RuntimeDecls.Decl{ .ty = cclone_ty, .fn_value = dynamic_clone };
    const wasm_cb_abi = wasm_cb.needed(types);
    const destroy_closure_cb = if (wasm_cb_abi) wasm_cb.declarePtrVoid(api, module_ref, types, "kira_destroy_closure_wcb") else destroy_closure_decl;
    const closure_clone_cb = if (wasm_cb_abi) wasm_cb.declarePtrPtr(api, module_ref, types, "kira_capi_closure_clone_wcb") else closure_clone_decl;
    const dynamic_destroy_cb = if (wasm_cb_abi) wasm_cb.declarePtrVoid(api, module_ref, types, "kira_capi_dynamic_destroy_wcb") else dynamic_destroy_decl;
    const dynamic_clone_cb = if (wasm_cb_abi) wasm_cb.declarePtrPtr(api, module_ref, types, "kira_capi_dynamic_clone_wcb") else dynamic_clone_decl;

    var result = Destructors{
        .destroy_raw_ptr = .{ .ty = void_ptr_ty, .fn_value = destroy_raw },
        .destroy_struct_ptr = .{ .ty = void_ptr_ty, .fn_value = destroy_struct },
        .destroy_closure = .{ .ty = void_i64_ty, .fn_value = destroy_closure },
        .enum_clone = .{ .ty = ptr_ptr_ty, .fn_value = enum_clone },
        .string_clone = .{ .ty = sclone_ty, .fn_value = string_clone },
        .closure_release = .{ .ty = void_ptr_ty, .fn_value = closure_release },
        .closure_clone = .{ .ty = cclone_ty, .fn_value = closure_clone },
        .struct_type_id = runtime.struct_type_id,
        .dynamic_destroy = dynamic_destroy_decl,
        .dynamic_clone = dynamic_clone_decl,
        .state_interior_release = .{ .ty = void_ptr_ty, .fn_value = state_interior_release },
        .destroy_closure_cb = destroy_closure_cb,
        .closure_clone_cb = closure_clone_cb,
        .dynamic_destroy_cb = dynamic_destroy_cb,
        .dynamic_clone_cb = dynamic_clone_cb,
        .release_strings = mode != .hybrid,
        .deep_closures = mode != .hybrid,
        .fresh_any_returns = try fresh_any.compute(allocator, program),
    };

    const builder = api.LLVMCreateBuilderInContext(types.context);
    defer api.LLVMDisposeBuilder(builder);

    // Fixed-helper bodies. A declare-only CGU stops after the declarations above
    // and the type/enum-helper declarations below; it references every helper as
    // an extern resolved against the support CGU at link time.
    if (!declare_only) {
    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, destroy_raw, "entry");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        var args = [_]llvm.c.LLVMValueRef{api.LLVMGetParam(destroy_raw, 0)};
        _ = api.LLVMBuildCall2(builder, runtime.free.ty, runtime.free.fn_value, &args, args.len, "");
        _ = api.LLVMBuildRetVoid(builder);
    }
    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, destroy_struct, "entry");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        var args = [_]llvm.c.LLVMValueRef{api.LLVMGetParam(destroy_struct, 0)};
        _ = api.LLVMBuildCall2(builder, runtime.struct_free.ty, runtime.struct_free.fn_value, &args, args.len, "");
        _ = api.LLVMBuildRetVoid(builder);
    }

    // kira_enum_clone: an enum value is a heap 16-byte block { i64 tag, i64 payload }
    // (see lowerAllocEnum). Deep-copy it so a struct copy owns an independent enum; a
    // null field clones to null. The payload is copied verbatim (a heap string/struct
    // payload would still be shared — enums in the layout corpus carry inline payloads).
    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, enum_clone, "entry");
        const copy_block = api.LLVMAppendBasicBlockInContext(types.context, enum_clone, "copy");
        const null_block = api.LLVMAppendBasicBlockInContext(types.context, enum_clone, "nullret");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        const src = api.LLVMGetParam(enum_clone, 0);
        const is_null = api.LLVMBuildICmp(builder, llvm.c.LLVMIntEQ, src, api.LLVMConstNull(types.ptr_ty), "ec.isnull");
        _ = api.LLVMBuildCondBr(builder, is_null, null_block, copy_block);
        api.LLVMPositionBuilderAtEnd(builder, null_block);
        _ = api.LLVMBuildRet(builder, api.LLVMConstNull(types.ptr_ty));
        api.LLVMPositionBuilderAtEnd(builder, copy_block);
        var margs = [_]llvm.c.LLVMValueRef{types.sizeArg(builder, api.LLVMConstInt(types.i64, 16, 0))};
        const dst = api.LLVMBuildCall2(builder, runtime.malloc.ty, runtime.malloc.fn_value, &margs, margs.len, "ec.dst");
        var cargs = [_]llvm.c.LLVMValueRef{ dst, src, types.sizeArg(builder, api.LLVMConstInt(types.i64, 16, 0)) };
        _ = api.LLVMBuildCall2(builder, runtime.memcpy.ty, runtime.memcpy.fn_value, &cargs, cargs.len, "");
        _ = api.LLVMBuildRet(builder, dst);
    }

    // kira_capi_string_clone(ptr, len) -> ptr: heap-duplicate a string byte buffer.
    // null -> null (an unset field); len 0 -> malloc(1) so the result is a real
    // allocation that free() accepts. The single deep-copy primitive behind the
    // strings-are-deep-values ownership model.
    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, string_clone, "entry");
        const copy_block = api.LLVMAppendBasicBlockInContext(types.context, string_clone, "copy");
        const null_block = api.LLVMAppendBasicBlockInContext(types.context, string_clone, "nullret");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        const src = api.LLVMGetParam(string_clone, 0);
        const len = api.LLVMGetParam(string_clone, 1);
        const is_null = api.LLVMBuildICmp(builder, llvm.c.LLVMIntEQ, src, api.LLVMConstNull(types.ptr_ty), "sc.isnull");
        _ = api.LLVMBuildCondBr(builder, is_null, null_block, copy_block);
        api.LLVMPositionBuilderAtEnd(builder, null_block);
        _ = api.LLVMBuildRet(builder, api.LLVMConstNull(types.ptr_ty));
        api.LLVMPositionBuilderAtEnd(builder, copy_block);
        const is_zero = api.LLVMBuildICmp(builder, llvm.c.LLVMIntEQ, len, api.LLVMConstInt(types.i64, 0, 0), "sc.zero");
        const alloc_len = api.LLVMBuildSelect(builder, is_zero, api.LLVMConstInt(types.i64, 1, 0), len, "sc.alloclen");
        var margs = [_]llvm.c.LLVMValueRef{types.sizeArg(builder, alloc_len)};
        const dst = api.LLVMBuildCall2(builder, runtime.malloc.ty, runtime.malloc.fn_value, &margs, margs.len, "sc.dst");
        var cargs = [_]llvm.c.LLVMValueRef{ dst, src, types.sizeArg(builder, len) };
        _ = api.LLVMBuildCall2(builder, runtime.memcpy.ty, runtime.memcpy.fn_value, &cargs, cargs.len, "");
        _ = api.LLVMBuildRet(builder, dst);
    }

    // wasm32 C-ABI callback thunk bodies (the target dispatchers/closure helpers are
    // declared above; their own bodies are emitted later in this support CGU by
    // closure_dtors/dynamic_dtors — an extern reference until then is fine within one
    // module). No-op on 64-bit, where wasm_cb_abi is false and no thunk was declared.
    if (wasm_cb_abi) {
        wasm_cb.definePtrVoid(api, builder, types, destroy_closure_cb, destroy_closure, void_i64_ty);
        wasm_cb.definePtrPtr(api, builder, types, closure_clone_cb, closure_clone, cclone_ty);
        wasm_cb.definePtrVoid(api, builder, types, dynamic_destroy_cb, dynamic_destroy, ddestroy_ty);
        wasm_cb.definePtrPtr(api, builder, types, dynamic_clone_cb, dynamic_clone, cclone_ty);
    }
    }

    // Pass 1: declare all type helpers so bodies can reference each other.
    for (program.types) |type_decl| {
        if (type_decl.ffi) |ffi_info| {
            if (ffi_info != .ffi_struct) continue;
        }
        const rc_name = try allocPrintZ(allocator, "kira_release_contents_{s}", .{type_decl.name});
        defer allocator.free(rc_name);
        const d_name = try allocPrintZ(allocator, "kira_destroy_{s}", .{type_decl.name});
        defer allocator.free(d_name);
        const cc_name = try allocPrintZ(allocator, "kira_clone_contents_{s}", .{type_decl.name});
        defer allocator.free(cc_name);
        const c_name = try allocPrintZ(allocator, "kira_clone_{s}", .{type_decl.name});
        defer allocator.free(c_name);
        var i64_param = [_]llvm.c.LLVMTypeRef{types.i64};
        const clone_ty = api.LLVMFunctionType(types.i64, &i64_param, i64_param.len, 0);
        const clone_decl = capi.RuntimeDecls.Decl{ .ty = clone_ty, .fn_value = api.LLVMAddFunction(module_ref, c_name.ptr, clone_ty) };
        // C-ABI-safe clone callback for kira_array_clone element cloning. On wasm32 the
        // `(i64)->i64` kira_clone_<T> traps a `void*(*)(void*)` call_indirect, so declare a
        // `(ptr)->ptr` thunk over it (body in pass 2); identity on 64-bit.
        const clone_cb = if (wasm_cb_abi) blk: {
            const cb_name = try allocPrintZ(allocator, "kira_clone_wcb_{s}", .{type_decl.name});
            defer allocator.free(cb_name);
            break :blk wasm_cb.declarePtrPtr(api, module_ref, types, cb_name);
        } else clone_decl;
        try result.map.put(allocator, type_decl.name, .{
            .release_contents = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, rc_name.ptr, void_ptr_ty) },
            .destroy = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, d_name.ptr, void_ptr_ty) },
            .clone_contents = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, cc_name.ptr, void_ptr_ty) },
            .clone = clone_decl,
            .clone_cb = clone_cb,
        });
    }

    // Typed enum helper declarations (bodies in backend_capi_enum_dtors.zig):
    // one destroy/clone pair per enum with a String-payload variant, so the
    // struct helpers below (and every other enum site) can substitute them for
    // the shallow kira_destroy_raw_ptr / kira_enum_clone pair. Native only —
    // hybrid keeps the shallow pair (payload boxes may be VM-managed).
    if (mode != .hybrid) {
        for (program.enums) |enum_decl| {
            // An enum needs the typed pair when a payload owns heap beyond the
            // 16-byte block itself: a String payload (box + buffer), a nested enum
            // payload (its block + whatever IT owns), a struct payload (its shell +
            // contents via kira_destroy_<T>/kira_clone_<T>), or a construct_any
            // payload (a type-erased tree freed via kira_capi_dynamic_destroy; the
            // clone arm traps because a contains-any enum is move-only — KIR002 —
            // and never cloned). Same variant filter as buildDestroy/buildClone in
            // backend_capi_enum_dtors.zig, keeping the deep-cloned <=> deep-
            // destroyed pairing invariant.
            var needs_typed = false;
            for (enum_decl.variants) |variant| {
                const pt = variant.payload_ty orelse continue;
                switch (pt.kind) {
                    .string, .enum_instance, .ffi_struct, .construct_any, .array => needs_typed = true,
                    else => {},
                }
            }
            if (!needs_typed) continue;
            const ed_name = try allocPrintZ(allocator, "kira_destroy_enum_{s}", .{enum_decl.name});
            defer allocator.free(ed_name);
            const ecl_name = try allocPrintZ(allocator, "kira_clone_enum_{s}", .{enum_decl.name});
            defer allocator.free(ecl_name);
            try result.enum_map.put(allocator, enum_decl.name, .{
                .destroy = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, ed_name.ptr, void_ptr_ty) },
                .clone = .{ .ty = ptr_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, ecl_name.ptr, ptr_ptr_ty) },
            });
        }
    }

    // Typed inner-array wrapper declarations (bodies in backend_capi_array_dtors.zig):
    // one destroy/clone pair per inner array type ("[Int]", "[Message]", ...)
    // reachable in the program, so elementDestroy/elementClone can free / deep-copy
    // a `[[T]]`'s boxed inner arrays (and their owned contents). Declared here so a
    // per-function CGU that drops/clones a nested array resolves the extern against
    // the support CGU's body. Native only — hybrid inner arrays are VM-owned.
    if (mode != .hybrid) {
        const keys = try array_dtors.collectKeys(allocator, program);
        defer allocator.free(keys);
        for (keys) |key| {
            const mangled = try array_dtors.mangle(allocator, key);
            defer allocator.free(mangled);
            const ad_name = try allocPrintZ(allocator, "kira_destroy_arr_{s}", .{mangled});
            defer allocator.free(ad_name);
            const ac_name = try allocPrintZ(allocator, "kira_clone_arr_{s}", .{mangled});
            defer allocator.free(ac_name);
            try result.array_map.put(allocator, key, .{
                .destroy = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, ad_name.ptr, void_ptr_ty) },
                .clone = .{ .ty = ptr_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, ac_name.ptr, ptr_ptr_ty) },
            });
        }
    }

    // Pass 2: build bodies (skipped for declare-only CGUs).
    if (!declare_only) {
        for (program.types) |type_decl| {
            if (type_decl.ffi) |ffi_info| {
                if (ffi_info != .ffi_struct) continue;
            }
            const struct_ty = struct_types.get(type_decl.name) orelse continue;
            const helpers = result.map.get(type_decl.name).?;
            try struct_dtors.buildReleaseContents(api, builder, types, runtime, result, program, struct_ty, type_decl, helpers.release_contents.fn_value);
            try struct_dtors.buildDestroy(api, builder, types, runtime, struct_ty, helpers.release_contents, helpers.destroy.fn_value);
            try struct_dtors.buildCloneContents(api, builder, types, runtime, result, program, struct_ty, type_decl, helpers.clone_contents.fn_value);
            try struct_dtors.buildClone(api, builder, types, runtime, struct_ty, type_decl.name, helpers.clone_contents, helpers.clone.fn_value);
            // Emit the wasm32 `(ptr)->ptr` thunk body over kira_clone_<T> (declared in pass 1).
            if (wasm_cb_abi) wasm_cb.definePtrPtr(api, builder, types, helpers.clone_cb, helpers.clone.fn_value, helpers.clone.ty);
        }
    }

    return result;
}
