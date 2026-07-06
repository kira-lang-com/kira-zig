// Per-closure capture teardown and deep clone for the LLVM C-API backend
// (native leak class #2: kira_destroy_closure used to free only the block and
// leak every captured heap value).
//
// A closure block is { i64 fn_id; i64 count; [count x %kira.bridge.value] }.
// Capture types and ownership are known statically at every const_closure site,
// so this module pre-scans the program (one shape per closure function_id) and
// generates two dispatch functions that switch on the block's fn_id:
//
//   kira_capi_closure_release(ptr)  — frees the block's OWNED captures with
//     their typed destructors (string buffer, kira_destroy_<T>,
//     kira_array_release, enum block, nested closure), then frees the block.
//     Installed as the kira_destroy_closure hook by a global constructor, so
//     every existing owned-closure drop point (scope exit, loop overwrite,
//     struct-field release, array-element release) tears captures down too.
//   kira_capi_closure_clone(i64) -> i64 — tag-safe deep copy. A callable-value
//     or plain raw pointer (high bit clear) passes through unchanged; a tagged
//     block is copied and its owned captures are deep-cloned, so two owners
//     never share capture storage (pairs with the release above; mirrors the
//     strings-are-deep-values consumer-clone rule).
//
// Ownership per capture follows the IR capture_ownership modes, matching the
// VM's allocateClosure: owned/move captures were transferred in (the creating
// frame escaped them), copy captures were deep-cloned in, borrow captures are
// non-owning aliases — released and cloned NEVER touch a borrow capture.
// Strings are the exception: every string capture is a deep clone (strings are
// deep values), so string captures are always owned and always freed.
//
// NATIVE ONLY. Hybrid closure blocks can be VM-allocated and VM-owned; the
// hybrid runtime installs its own destroy hook and no constructor is emitted.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const utils = @import("backend_utils.zig");
const destructors = @import("backend_capi_destructors.zig");

const inferRegisterTypes = utils.inferRegisterTypes;

pub const ClosureShape = struct {
    function_id: u32,
    capture_types: []ir.ValueType,
    capture_ownership: []ir.OwnershipMode,
};

// Matches the VM's captureOwnershipAt: a missing entry is a borrow (never freed).
fn ownershipAt(shape: ClosureShape, index: usize) ir.OwnershipMode {
    if (index < shape.capture_ownership.len) return shape.capture_ownership[index];
    return .borrow_read;
}

// The block owns this capture's heap value (release frees it, clone deep-copies
// it). Strings are always cloned in at capture time, so always owned.
fn blockOwnsCapture(shape: ClosureShape, index: usize) bool {
    const ty = shape.capture_types[index];
    if (ty.kind == .string) return true;
    return switch (ownershipAt(shape, index)) {
        .owned, .move, .copy => true,
        .borrow_read, .borrow_mut => false,
    };
}

// One shape per closure function_id (every const_closure site for the same
// lambda has identical capture types/ownership — they come from the lambda's
// capture list).
pub fn collectShapes(allocator: std.mem.Allocator, program: *const ir.Program) ![]ClosureShape {
    var seen = std.AutoHashMapUnmanaged(u32, void){};
    defer seen.deinit(allocator);
    var shapes = std.array_list.Managed(ClosureShape).init(allocator);
    errdefer shapes.deinit();
    for (program.functions) |function_decl| {
        if (function_decl.is_extern) continue;
        var register_types: ?[]ir.ValueType = null;
        defer if (register_types) |rt| allocator.free(rt);
        for (function_decl.instructions) |instruction| {
            const v = switch (instruction) {
                .const_closure => |value| value,
                else => continue,
            };
            if (seen.contains(v.function_id)) continue;
            try seen.put(allocator, v.function_id, {});
            if (register_types == null) {
                register_types = try inferRegisterTypes(allocator, program.*, function_decl);
            }
            const rt = register_types.?;
            const capture_types = try allocator.alloc(ir.ValueType, v.captures.len);
            for (v.captures, 0..) |reg, i| {
                capture_types[i] = if (reg < rt.len) rt[reg] else .{ .kind = .raw_ptr };
            }
            try shapes.append(.{
                .function_id = v.function_id,
                .capture_types = capture_types,
                .capture_ownership = try allocator.dupe(ir.OwnershipMode, v.capture_ownership),
            });
        }
    }
    return shapes.toOwnedSlice();
}

pub fn freeShapes(allocator: std.mem.Allocator, shapes: []ClosureShape) void {
    for (shapes) |shape| {
        allocator.free(shape.capture_types);
        allocator.free(shape.capture_ownership);
    }
    allocator.free(shapes);
}

// GEP to capture slot `index`'s bridge-value field (2 = payload, 3 = extra).
fn captureField(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    block_ptr: llvm.c.LLVMValueRef,
    index: usize,
    field: u32,
) llvm.c.LLVMValueRef {
    var base_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i64, 16, 0)};
    const slots = api.LLVMBuildInBoundsGEP2(b, types.i8, block_ptr, &base_idx, base_idx.len, "cd.slots");
    var slot_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i64, @intCast(index), 0)};
    const slot = api.LLVMBuildInBoundsGEP2(b, types.bridge_ty, slots, &slot_idx, slot_idx.len, "cd.slot");
    var field_idx = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(types.i32, 0, 0), api.LLVMConstInt(types.i32, field, 0) };
    return api.LLVMBuildInBoundsGEP2(b, types.bridge_ty, slot, &field_idx, field_idx.len, "cd.slot.field");
}

// Build the bodies of kira_capi_closure_release / kira_capi_closure_clone
// (declared in destructors.build so struct release/clone helpers could already
// reference them) and, when `install_hook` is set, a global constructor that
// installs the release function as the kira_destroy_closure hook.
pub fn build(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
    shapes: []const ClosureShape,
    install_hook: bool,
) !void {
    const builder = api.LLVMCreateBuilderInContext(types.context);
    defer api.LLVMDisposeBuilder(builder);

    try buildRelease(allocator, api, builder, types, program, runtime, dtors, shapes);
    try buildClone(allocator, api, builder, types, program, runtime, dtors, shapes);
    if (install_hook) try emitInstallCtor(api, builder, module_ref, types, dtors.closure_release.fn_value);
}

fn buildRelease(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
    shapes: []const ClosureShape,
) !void {
    const fn_value = dtors.closure_release.fn_value;
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const dispatch = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "dispatch");
    const free_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "free");
    const done = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "done");

    api.LLVMPositionBuilderAtEnd(b, entry);
    const block_ptr = api.LLVMGetParam(fn_value, 0);
    const is_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, block_ptr, api.LLVMConstNull(types.ptr_ty), "cr.isnull");
    _ = api.LLVMBuildCondBr(b, is_null, done, dispatch);

    api.LLVMPositionBuilderAtEnd(b, dispatch);
    const fn_id = api.LLVMBuildLoad2(b, types.i64, block_ptr, "cr.fnid");
    const switch_inst = api.LLVMBuildSwitch(b, fn_id, free_block, @intCast(shapes.len));

    for (shapes) |shape| {
        var owns_any = false;
        for (0..shape.capture_types.len) |i| {
            if (blockOwnsCapture(shape, i)) owns_any = true;
        }
        if (!owns_any) continue; // default case (plain free) already covers it
        const case_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "cr.case");
        api.LLVMAddCase(switch_inst, api.LLVMConstInt(types.i64, shape.function_id, 0), case_block);
        api.LLVMPositionBuilderAtEnd(b, case_block);
        for (shape.capture_types, 0..) |ty, i| {
            if (!blockOwnsCapture(shape, i)) continue;
            const payload_ptr = captureField(api, b, types, block_ptr, i, 2);
            const payload = api.LLVMBuildLoad2(b, types.i64, payload_ptr, "cr.payload");
            switch (ty.kind) {
                .string => {
                    // The capture owns a deep clone of the byte buffer; free it.
                    const buf = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "cr.strbuf");
                    var args = [_]llvm.c.LLVMValueRef{buf};
                    _ = api.LLVMBuildCall2(b, runtime.free.ty, runtime.free.fn_value, &args, args.len, "");
                },
                .ffi_struct => {
                    const name = ty.name orelse continue;
                    const helpers = dtors.map.get(name) orelse continue;
                    const ptr = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "cr.struct");
                    var args = [_]llvm.c.LLVMValueRef{ptr};
                    _ = api.LLVMBuildCall2(b, helpers.destroy.ty, helpers.destroy.fn_value, &args, args.len, "");
                },
                .array => {
                    const ptr = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "cr.arr");
                    const elem = dtors.elementDestroy(program, ty);
                    var args = [_]llvm.c.LLVMValueRef{ ptr, elem orelse api.LLVMConstNull(types.ptr_ty) };
                    _ = api.LLVMBuildCall2(b, runtime.array_release.ty, runtime.array_release.fn_value, &args, args.len, "");
                },
                .enum_instance => {
                    // Free the enum block; a typed helper (string-payload enum)
                    // frees the payload box + buffer too.
                    const ptr = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "cr.enum");
                    const destroy = dtors.enumDestroyFn(ty);
                    var args = [_]llvm.c.LLVMValueRef{ptr};
                    _ = api.LLVMBuildCall2(b, destroy.ty, destroy.fn_value, &args, args.len, "");
                },
                .raw_ptr => {
                    // A nested closure (tag-safe: a plain FFI pointer capture is
                    // a no-op). Recurses back through this dispatch via the hook.
                    var args = [_]llvm.c.LLVMValueRef{payload};
                    _ = api.LLVMBuildCall2(b, dtors.destroy_closure.ty, dtors.destroy_closure.fn_value, &args, args.len, "");
                },
                // construct_any is untyped at runtime — conservative: leak.
                else => {},
            }
        }
        _ = api.LLVMBuildBr(b, free_block);
    }

    api.LLVMPositionBuilderAtEnd(b, free_block);
    var free_args = [_]llvm.c.LLVMValueRef{block_ptr};
    _ = api.LLVMBuildCall2(b, runtime.free.ty, runtime.free.fn_value, &free_args, free_args.len, "");
    _ = api.LLVMBuildBr(b, done);

    api.LLVMPositionBuilderAtEnd(b, done);
    _ = api.LLVMBuildRetVoid(b);
    _ = allocator;
}

fn buildClone(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
    shapes: []const ClosureShape,
) !void {
    const fn_value = dtors.closure_clone.fn_value;
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const copy_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "copy");
    const passthrough = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "passthrough");

    const tag_bit = api.LLVMConstInt(types.i64, 0x8000000000000000, 0);
    const untag_mask = api.LLVMConstInt(types.i64, 0x7FFFFFFFFFFFFFFF, 0);

    api.LLVMPositionBuilderAtEnd(b, entry);
    const value = api.LLVMGetParam(fn_value, 0);
    // Only a tagged heap closure block is cloned; a callable-value function id
    // or a plain raw pointer passes through unchanged (tag-safe like
    // kira_destroy_closure).
    const tag = api.LLVMBuildAnd(b, value, tag_bit, "cc.tag");
    const untagged = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, tag, api.LLVMConstInt(types.i64, 0, 0), "cc.untagged");
    _ = api.LLVMBuildCondBr(b, untagged, passthrough, copy_block);

    api.LLVMPositionBuilderAtEnd(b, passthrough);
    _ = api.LLVMBuildRet(b, value);

    api.LLVMPositionBuilderAtEnd(b, copy_block);
    const raw = api.LLVMBuildAnd(b, value, untag_mask, "cc.raw");
    const src = api.LLVMBuildIntToPtr(b, raw, types.ptr_ty, "cc.src");
    const fn_id = api.LLVMBuildLoad2(b, types.i64, src, "cc.fnid");
    var count_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i64, 1, 0)};
    const count_slot = api.LLVMBuildInBoundsGEP2(b, types.i64, src, &count_idx, count_idx.len, "cc.count.slot");
    const count = api.LLVMBuildLoad2(b, types.i64, count_slot, "cc.count");
    const bridge_size = api.LLVMSizeOf(types.bridge_ty);
    const captures_size = api.LLVMBuildMul(b, count, bridge_size, "cc.capsize");
    const total = api.LLVMBuildAdd(b, api.LLVMConstInt(types.i64, 16, 0), captures_size, "cc.size");
    var malloc_args = [_]llvm.c.LLVMValueRef{total};
    const dst = api.LLVMBuildCall2(b, runtime.malloc.ty, runtime.malloc.fn_value, &malloc_args, malloc_args.len, "cc.dst");
    var memcpy_args = [_]llvm.c.LLVMValueRef{ dst, src, total };
    _ = api.LLVMBuildCall2(b, runtime.memcpy.ty, runtime.memcpy.fn_value, &memcpy_args, memcpy_args.len, "");

    const ret_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "cc.ret");
    const switch_inst = api.LLVMBuildSwitch(b, fn_id, ret_block, @intCast(shapes.len));

    for (shapes) |shape| {
        var owns_any = false;
        for (0..shape.capture_types.len) |i| {
            if (blockOwnsCapture(shape, i)) owns_any = true;
        }
        if (!owns_any) continue; // shallow block copy is already a full clone
        const case_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "cc.case");
        api.LLVMAddCase(switch_inst, api.LLVMConstInt(types.i64, shape.function_id, 0), case_block);
        api.LLVMPositionBuilderAtEnd(b, case_block);
        for (shape.capture_types, 0..) |ty, i| {
            if (!blockOwnsCapture(shape, i)) continue;
            const payload_ptr = captureField(api, b, types, dst, i, 2);
            const payload = api.LLVMBuildLoad2(b, types.i64, payload_ptr, "cc.payload");
            switch (ty.kind) {
                .string => {
                    const extra_ptr = captureField(api, b, types, dst, i, 3);
                    const len = api.LLVMBuildLoad2(b, types.i64, extra_ptr, "cc.strlen");
                    const buf = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "cc.strbuf");
                    var args = [_]llvm.c.LLVMValueRef{ buf, len };
                    const cloned = api.LLVMBuildCall2(b, dtors.string_clone.ty, dtors.string_clone.fn_value, &args, args.len, "cc.strclone");
                    const cloned_int = api.LLVMBuildPtrToInt(b, cloned, types.i64, "cc.strclone.int");
                    _ = api.LLVMBuildStore(b, cloned_int, payload_ptr);
                },
                .ffi_struct => {
                    const name = ty.name orelse continue;
                    const helpers = dtors.map.get(name) orelse continue;
                    var args = [_]llvm.c.LLVMValueRef{payload};
                    const cloned = api.LLVMBuildCall2(b, helpers.clone.ty, helpers.clone.fn_value, &args, args.len, "cc.structclone");
                    _ = api.LLVMBuildStore(b, cloned, payload_ptr);
                },
                .array => {
                    const ptr = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "cc.arr");
                    const elem = dtors.elementClone(program, ty);
                    var args = [_]llvm.c.LLVMValueRef{ ptr, elem orelse api.LLVMConstNull(types.ptr_ty) };
                    const cloned = api.LLVMBuildCall2(b, runtime.array_clone.ty, runtime.array_clone.fn_value, &args, args.len, "cc.arrclone");
                    const cloned_int = api.LLVMBuildPtrToInt(b, cloned, types.i64, "cc.arrclone.int");
                    _ = api.LLVMBuildStore(b, cloned_int, payload_ptr);
                },
                .enum_instance => {
                    const ptr = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "cc.enum");
                    const clone_fn = dtors.enumCloneFn(ty);
                    var args = [_]llvm.c.LLVMValueRef{ptr};
                    const cloned = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &args, args.len, "cc.enumclone");
                    const cloned_int = api.LLVMBuildPtrToInt(b, cloned, types.i64, "cc.enumclone.int");
                    _ = api.LLVMBuildStore(b, cloned_int, payload_ptr);
                },
                .raw_ptr => {
                    // A nested closure deep-clones recursively (tag-safe
                    // pass-through for plain FFI pointer captures).
                    var args = [_]llvm.c.LLVMValueRef{payload};
                    const cloned = api.LLVMBuildCall2(b, dtors.closure_clone.ty, fn_value, &args, args.len, "cc.nested");
                    _ = api.LLVMBuildStore(b, cloned, payload_ptr);
                },
                else => {},
            }
        }
        _ = api.LLVMBuildBr(b, ret_block);
    }

    api.LLVMPositionBuilderAtEnd(b, ret_block);
    const dst_int = api.LLVMBuildPtrToInt(b, dst, types.i64, "cc.dstint");
    const tagged = api.LLVMBuildOr(b, dst_int, tag_bit, "cc.tagged");
    _ = api.LLVMBuildRet(b, tagged);
    _ = allocator;
}

// A global constructor (llvm.global_ctors) that installs the generated release
// function as the runtime's closure-destroy hook. A constructor (not host-main
// code) so dylib artifacts loaded by platform runners get it too.
fn emitInstallCtor(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    release_fn: llvm.c.LLVMValueRef,
) !void {
    var install_param = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
    const install_ty = api.LLVMFunctionType(types.void_ty, &install_param, install_param.len, 0);
    const install_decl = api.LLVMAddFunction(module_ref, "kira_hybrid_install_closure_destroy", install_ty);

    const ctor_ty = api.LLVMFunctionType(types.void_ty, null, 0, 0);
    const ctor_fn = api.LLVMAddFunction(module_ref, "kira.capi.closure.dtor.install", ctor_ty);
    api.LLVMSetLinkage(ctor_fn, llvm.c.LLVMInternalLinkage);
    const entry = api.LLVMAppendBasicBlockInContext(types.context, ctor_fn, "entry");
    api.LLVMPositionBuilderAtEnd(b, entry);
    var install_args = [_]llvm.c.LLVMValueRef{release_fn};
    _ = api.LLVMBuildCall2(b, install_ty, install_decl, &install_args, install_args.len, "");
    _ = api.LLVMBuildRetVoid(b);

    var ctor_fields = [_]llvm.c.LLVMTypeRef{ types.i32, types.ptr_ty, types.ptr_ty };
    const ctor_entry_ty = api.LLVMStructTypeInContext(types.context, &ctor_fields, ctor_fields.len, 0);
    var entry_vals = [_]llvm.c.LLVMValueRef{
        api.LLVMConstInt(types.i32, 65535, 0),
        ctor_fn,
        api.LLVMConstPointerNull(types.ptr_ty),
    };
    const ctor_entry = api.LLVMConstNamedStruct(ctor_entry_ty, &entry_vals, entry_vals.len);
    var array_vals = [_]llvm.c.LLVMValueRef{ctor_entry};
    const ctor_array = api.LLVMConstArray2(ctor_entry_ty, &array_vals, array_vals.len);
    const ctors_global = api.LLVMAddGlobal(module_ref, api.LLVMArrayType2(ctor_entry_ty, 1), "llvm.global_ctors");
    api.LLVMSetLinkage(ctors_global, llvm.c.LLVMAppendingLinkage);
    api.LLVMSetInitializer(ctors_global, ctor_array);
}
