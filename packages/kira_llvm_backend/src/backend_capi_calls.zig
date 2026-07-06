// Call lowering for the LLVM C-API backend: direct native calls, hybrid runtime calls,
// static virtual-method dispatch, and CString→String conversion. Split out of
// backend_capi_codegen.zig (Core Law #5). Free functions over *FunctionCodegen, matching
// backend_capi_aggregate.zig / backend_capi_closures.zig / backend_capi_ffi.zig.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const drop = @import("backend_capi_drop.zig");
const ffi = @import("backend_capi_ffi.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

const functionById = utils.functionById;
const functionExecutionById = utils.functionExecutionById;
const resolveExecution = utils.resolveExecution;

// Copy a NUL-terminated C string (i64 pointer) into a fresh heap-backed %kira.string of
// explicit length. Mirrors backend_text_ir_core's c_string_to_string: strlen to size,
// malloc+memcpy to own an independent copy (the C buffer may be transient).
pub fn lowerCStringToString(fc: *FunctionCodegen, v: ir.CStringToString) !llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    const cptr = api.LLVMBuildIntToPtr(b, fc.registers[v.src], fc.types.ptr_ty, "cstr.ptr");
    var len_args = [_]llvm.c.LLVMValueRef{cptr};
    const len = api.LLVMBuildCall2(b, fc.runtime_decls.strlen.ty, fc.runtime_decls.strlen.fn_value, &len_args, len_args.len, "cstr.len");
    var malloc_args = [_]llvm.c.LLVMValueRef{len};
    const copy = api.LLVMBuildCall2(b, fc.runtime_decls.malloc.ty, fc.runtime_decls.malloc.fn_value, &malloc_args, malloc_args.len, "cstr.copy");
    var copy_args = [_]llvm.c.LLVMValueRef{ copy, cptr, len };
    _ = api.LLVMBuildCall2(b, fc.runtime_decls.memcpy.ty, fc.runtime_decls.memcpy.fn_value, &copy_args, copy_args.len, "cstr.memcpy");
    var s = api.LLVMGetUndef(fc.types.string_ty);
    s = api.LLVMBuildInsertValue(b, s, copy, 0, "cstr.s.ptr");
    s = api.LLVMBuildInsertValue(b, s, len, 1, "cstr.s.len");
    return s;
}

pub fn lowerCallVirtual(fc: *FunctionCodegen, v: ir.VirtualCall) !void {
    if (utils.findTypeDecl(fc.request.program.programPtr(), v.static_type_name)) |type_decl| {
        return lowerStaticVirtualCall(fc, v, type_decl);
    }
    return lowerConstructFamilyVirtualCall(fc, v);
}

fn lowerStaticVirtualCall(fc: *FunctionCodegen, v: ir.VirtualCall, type_decl: ir.TypeDecl) !void {
    var resolved: ?u32 = null;
    for (type_decl.methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, v.method_name)) {
            resolved = method_decl.function_id;
            break;
        }
    }
    const callee = resolved orelse return error.UnknownFunction;
    const args = try fc.allocator.alloc(u32, v.args.len + 1);
    defer fc.allocator.free(args);
    args[0] = v.receiver;
    @memcpy(args[1..], v.args);
    try lowerCall(fc, .{ .callee = callee, .args = args, .dst = v.dst });
}

fn lowerConstructFamilyVirtualCall(fc: *FunctionCodegen, v: ir.VirtualCall) !void {
    const api = fc.api;
    const b = fc.builder;
    const ctx = fc.types.context;
    const receiver_ptr = api.LLVMBuildIntToPtr(b, fc.registers[v.receiver], fc.types.ptr_ty, "vcall.recv");
    var tag_args = [_]llvm.c.LLVMValueRef{receiver_ptr};
    const tag = api.LLVMBuildCall2(b, fc.runtime_decls.struct_type_id.ty, fc.runtime_decls.struct_type_id.fn_value, &tag_args, tag_args.len, "vcall.tag");

    const return_slot = if (v.dst != null and v.return_ty.kind != .void)
        fc.entryAlloca(fc.types.llvmType(v.return_ty), "vcall.result")
    else
        null;
    const merge_block = api.LLVMAppendBasicBlockInContext(ctx, fc.function_value, "vcall.merge");
    const trap_block = api.LLVMAppendBasicBlockInContext(ctx, fc.function_value, "vcall.trap");

    // lowerCall may rewrite an owned/move ffi_struct argument's register to a
    // per-call heap shell (moveOrCloneToHeap) as a side effect. A construct-family
    // virtual call lowers the SAME argument list into one block per candidate
    // implementation (the dispatch cases are mutually-exclusive siblings), so that
    // rewrite must NOT persist from one case into the next: otherwise a borrowed
    // struct arg in case N+1 is cloned from case N's clone — a value defined in a
    // sibling block that does not dominate case N+1 — producing "instruction does not
    // dominate all uses" invalid IR. Snapshot the original argument registers (all
    // defined before the dispatch, so they dominate every case) and restore them
    // before lowering each case, so every case clones/moves from the same source.
    const saved_receiver = fc.registers[v.receiver];
    const saved_args = try fc.allocator.alloc(llvm.c.LLVMValueRef, v.args.len);
    defer fc.allocator.free(saved_args);
    for (v.args, 0..) |a, i| saved_args[i] = fc.registers[a];

    var current_test = api.LLVMGetInsertBlock(b);
    var matched: usize = 0;
    for (fc.request.program.programPtr().construct_implementations) |implementation| {
        if (!implementationSatisfiesFamily(implementation, v.static_type_name)) continue;
        const method_id = constructMethodId(fc.request.program.programPtr().*, implementation.type_name, v.method_name) orelse continue;
        matched += 1;

        api.LLVMPositionBuilderAtEnd(b, current_test);
        const case_block = api.LLVMAppendBasicBlockInContext(ctx, fc.function_value, "vcall.case");
        const next_block = api.LLVMAppendBasicBlockInContext(ctx, fc.function_value, "vcall.next");
        const expected = api.LLVMConstInt(fc.types.i64, ir.nativeStateTypeId(implementation.type_name), 0);
        const is_match = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, tag, expected, "vcall.match");
        _ = api.LLVMBuildCondBr(b, is_match, case_block, next_block);

        api.LLVMPositionBuilderAtEnd(b, case_block);
        fc.registers[v.receiver] = saved_receiver;
        for (v.args, 0..) |a, i| fc.registers[a] = saved_args[i];
        const args = try fc.allocator.alloc(u32, v.args.len + 1);
        defer fc.allocator.free(args);
        args[0] = v.receiver;
        @memcpy(args[1..], v.args);
        try lowerCall(fc, .{ .callee = method_id, .args = args, .dst = v.dst });
        // Record construct_any results HERE, exactly once — UNLESS lowerCall
        // already recorded them (fresh-Any callee): recording again here after
        // a lowerCall record would dropPriorOccupant the value that was JUST
        // stored, destroying the live result before the caller uses it (the
        // widget-dispatch use-after-free). A construct-family virtual-call
        // result is treated as single-owner: its .struct_ptr slot runs the
        // runtime-typed destroy at scope exit (KIRA_MEMORY_MODEL.md §3). Enum
        // results are recorded by lowerCall (native) / lowerRuntimeCall
        // (hybrid) themselves — the same exactly-once rule, so no enum case
        // here.
        if (v.dst) |dst| switch (v.return_ty.kind) {
            .construct_any => if (!fc.dtors.tracksFreshAnyResult(method_id)) drop.onAlloc(fc, dst),
            else => {},
        };
        if (return_slot) |slot| {
            _ = api.LLVMBuildStore(b, fc.registers[v.dst.?], slot);
        }
        _ = api.LLVMBuildBr(b, merge_block);
        current_test = next_block;
    }

    if (matched == 0) return error.UnknownFunction;
    api.LLVMPositionBuilderAtEnd(b, current_test);
    _ = api.LLVMBuildBr(b, trap_block);
    api.LLVMPositionBuilderAtEnd(b, trap_block);
    _ = api.LLVMBuildUnreachable(b);

    api.LLVMPositionBuilderAtEnd(b, merge_block);
    if (return_slot) |slot| {
        fc.registers[v.dst.?] = api.LLVMBuildLoad2(b, fc.types.llvmType(v.return_ty), slot, "vcall.result.load");
    }
}

fn implementationSatisfiesFamily(implementation: ir.ConstructImplementation, family: []const u8) bool {
    for (implementation.families) |candidate| {
        if (std.mem.eql(u8, candidate, family)) return true;
    }
    return std.mem.eql(u8, implementation.construct_constraint.construct_name, family);
}

fn constructMethodId(program: ir.Program, type_name: []const u8, method_name: []const u8) ?u32 {
    const type_decl = utils.findTypeDecl(&program, type_name) orelse return null;
    for (type_decl.methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, method_name)) return method_decl.function_id;
    }
    return null;
}

pub fn lowerCall(fc: *FunctionCodegen, call: ir.Call) !void {
    const api = fc.api;
    const callee_decl = functionById(fc.request.program.programPtr().*, call.callee) orelse return error.UnknownFunction;
    const callee_execution = functionExecutionById(fc.request.program.programPtr().*, call.callee) orelse return error.UnknownFunction;
    switch (resolveExecution(callee_execution, fc.request.mode)) {
        .native => {
            // An extern function is a real C symbol with a C ABI; marshal across the
            // boundary instead of using the Kira register ABI.
            if (callee_decl.is_extern) return ffi.lowerExternCall(fc, call, callee_decl);
            const callee_fn = fc.functions.get(call.callee) orelse return error.MissingFunctionDeclaration;
            const fn_ty = try fc.types.functionType(fc.allocator, callee_decl);
            // Rust move semantics across the boundary: an owned/move struct argument is moved
            // into the callee, which now fully owns it. Hand over a caller-stable heap shell so
            // the callee can drop it safely — moveOrCloneToHeap returns the source pointer when
            // it is already owned heap, or moves a stack-backed source into heap, and in both
            // cases stops the caller from also freeing it. Without this the callee (which now
            // owns the shell) could be handed a stack pointer and free it. Native only; hybrid
            // struct args stay VM-managed.
            if (fc.drop_enabled and fc.request.mode == .llvm_native) {
                for (call.args, 0..) |arg, i| {
                    const mode = if (i < callee_decl.param_ownership.len) callee_decl.param_ownership[i] else ir.OwnershipMode.owned;
                    switch (mode) {
                        .owned, .move => {},
                        else => continue,
                    }
                    const pt = if (i < callee_decl.param_types.len) callee_decl.param_types[i] else continue;
                    // A borrowed array (field read / borrow param) passed to an
                    // owned/move array parameter: the callee owns its parameter and
                    // frees it at exit, so hand it an independent deep clone — passing
                    // the raw pointer would free storage the caller's field still
                    // references (the popClip clipStack double-free). An owned source
                    // is escaped after the call by the loop below, so it moves as-is.
                    if (pt.kind == .array) {
                        if (!drop.isOwned(fc, arg)) {
                            const sptr = api.LLVMBuildIntToPtr(fc.builder, fc.registers[arg], fc.types.ptr_ty, "call.arr.src");
                            const elem = fc.dtors.elementClone(fc.request.program.programPtr(), pt);
                            var cargs = [_]llvm.c.LLVMValueRef{ sptr, elem orelse api.LLVMConstNull(fc.types.ptr_ty) };
                            const clone = api.LLVMBuildCall2(fc.builder, fc.runtime_decls.array_clone.ty, fc.runtime_decls.array_clone.fn_value, &cargs, cargs.len, "call.arr.clone");
                            fc.registers[arg] = api.LLVMBuildPtrToInt(fc.builder, clone, fc.types.i64, "call.arr.cloneint");
                        }
                        continue;
                    }
                    // A borrowed closure (array element read / borrow param) passed to
                    // an owned/move closure parameter: the callee's .closure param slot
                    // frees it at exit, so hand over an independent deep clone or the
                    // real owner (the array / field) frees the same block again.
                    // kira_capi_closure_clone is tag-safe — callable values and plain
                    // FFI pointers pass through. An owned source moves as-is (escaped
                    // by the loop below).
                    if (pt.kind == .raw_ptr) {
                        if (!drop.isOwned(fc, arg)) {
                            var cargs = [_]llvm.c.LLVMValueRef{fc.registers[arg]};
                            fc.registers[arg] = api.LLVMBuildCall2(fc.builder, fc.dtors.closure_clone.ty, fc.dtors.closure_clone.fn_value, &cargs, cargs.len, "call.clos.clone");
                        }
                        continue;
                    }
                    if (pt.kind != .ffi_struct) continue;
                    const name = pt.name orelse continue;
                    if (fc.dtors.map.get(name) == null) continue;
                    fc.registers[arg] = drop.moveOrCloneToHeap(fc, arg, name);
                }
            }
            const args = try fc.allocator.alloc(llvm.c.LLVMValueRef, call.args.len);
            defer fc.allocator.free(args);
            for (call.args, 0..) |arg, index| args[index] = fc.registers[arg];
            const result = api.LLVMBuildCall2(fc.builder, fn_ty, callee_fn, args.ptr, @intCast(args.len), "");
            // Ownership across the call boundary follows the callee's parameter modes: an
            // argument passed to an owned/move parameter is consumed by the callee, so the
            // caller stops tracking it (the callee — or the value's escape through the
            // callee's return — now owns it). An argument passed to a borrow parameter
            // stays owned by the caller, so it must remain tracked and be dropped here at
            // scope exit. Escaping borrow args was the cause of owned values leaking after a
            // borrow-pass (e.g. `gridScore(grid)`).
            for (call.args, 0..) |arg, i| {
                const mode = if (i < callee_decl.param_ownership.len) callee_decl.param_ownership[i] else ir.OwnershipMode.owned;
                switch (mode) {
                    // Enums are treated as Copy across the call boundary: the callee never
                    // takes ownership of an enum parameter (it has no drop slot, and a store
                    // into a struct field clones it), so the caller must KEEP ownership and
                    // free its own enum at scope exit. Escaping it would orphan the value the
                    // caller allocated — a per-call leak (every SizeMode/Alignment view arg).
                    // Strings are Copy too: the callee has no string param slot (it clones
                    // anything it keeps), so the caller keeps ownership of the buffer.
                    .owned, .move => {
                        const k = if (arg < fc.register_types.len) fc.register_types[arg].kind else ir.ValueType.Kind.integer;
                        if (k != .enum_instance and k != .string) drop.onEscape(fc, arg);
                    },
                    else => {},
                }
            }
            if (call.dst) |dst| {
                fc.registers[dst] = result;
                // An ffi_struct or array result is fresh caller-stable owned heap storage;
                // track it so the caller frees it at scope exit. A string result is always
                // a fresh owned buffer (the callee's `ret` clones untracked sources). A
                // raw_ptr result is tracked as an owned closure: the callee's `ret` clones
                // untracked closure sources, and the .closure drop is tag-safe (an extern
                // call's plain FFI pointer result is recorded but never freed).
                switch (callee_decl.return_type.kind) {
                    .ffi_struct, .array, .raw_ptr => drop.onAlloc(fc, dst),
                    // A returned enum is a fresh owned heap block (the callee's `ret`
                    // clones untracked sources — the returned-enum invariant), so the
                    // caller tracks it and frees it at scope exit via the typed enum
                    // destroy. Without this every enum-returning call leaked its block
                    // plus any nested payload chain (Result -> RenderFailure -> String).
                    .enum_instance => drop.onAlloc(fc, dst),
                    // A construct_any result is tracked only when the callee provably
                    // returns a fresh owned tree (fresh-Any analysis; the setup
                    // pre-scan allocated the .struct_ptr slot under the same
                    // condition). Alias-returning callees stay untracked (§3).
                    .construct_any => if (fc.dtors.tracksFreshAnyResult(callee_decl.id)) drop.onAlloc(fc, dst),
                    .string => drop.trackStringRegister(fc, dst),
                    else => {},
                }
            }
        },
        .runtime => try lowerRuntimeCall(fc, call, callee_decl),
        .inherited => unreachable,
    }
}

// Hybrid mode: call a VM-resident (.runtime) function via kira_hybrid_call_runtime. Args
// are packed into a [N x bridge] array; the result comes back in a bridge slot.
pub fn lowerRuntimeCall(fc: *FunctionCodegen, call: ir.Call, callee_decl: ir.Function) !void {
    if (fc.request.mode != .hybrid) return error.RuntimeCallInNativeBuild;
    const api = fc.api;
    const b = fc.builder;
    const rt = fc.runtime_decls.call_runtime orelse return error.RuntimeCallInNativeBuild;

    const args_ptr: llvm.c.LLVMValueRef = if (call.args.len == 0)
        api.LLVMConstNull(fc.types.ptr_ty)
    else blk: {
        const arr_ty = api.LLVMArrayType2(fc.types.bridge_ty, call.args.len);
        const arr = fc.entryAlloca(arr_ty, "rt.args");
        for (call.args, 0..) |arg, index| {
            var idx = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(fc.types.i32, 0, 0), api.LLVMConstInt(fc.types.i32, @intCast(index), 0) };
            const slot = api.LLVMBuildInBoundsGEP2(b, arr_ty, arr, &idx, idx.len, "rt.slot");
            // Pass struct args by pointer (box_struct=false) so a `borrow mut` arg lets the
            // VM mutate the caller's struct, not a boxed copy.
            const bv = try fc.packBridgeBoxed(fc.register_types[arg], fc.registers[arg], false);
            _ = api.LLVMBuildStore(b, bv, slot);
        }
        break :blk arr;
    };

    const result_slot = fc.entryAlloca(fc.types.bridge_ty, "rt.result");
    var rt_args = [_]llvm.c.LLVMValueRef{
        api.LLVMConstInt(fc.types.i32, call.callee, 0),
        args_ptr,
        api.LLVMConstInt(fc.types.i32, @intCast(call.args.len), 0),
        result_slot,
    };
    _ = api.LLVMBuildCall2(b, rt.ty, rt.fn_value, &rt_args, rt_args.len, "");
    if (call.dst) |dst| {
        const bv = api.LLVMBuildLoad2(b, fc.types.bridge_ty, result_slot, "rt.result.bv");
        const unpacked = try fc.unpackBridge(callee_decl.return_type, bv);
        var cloned_owned = false;
        var cloned_string = false;
        fc.registers[dst] = switch (callee_decl.return_type.kind) {
            .ffi_struct => blk: {
                const type_name = callee_decl.return_type.name orelse break :blk unpacked;
                const helpers = fc.dtors.map.get(type_name) orelse break :blk unpacked;
                var clone_args = [_]llvm.c.LLVMValueRef{unpacked};
                const cloned = api.LLVMBuildCall2(b, helpers.clone.ty, helpers.clone.fn_value, &clone_args, clone_args.len, "rt.struct.clone");
                cloned_owned = true;
                break :blk cloned;
            },
            // A VM-returned string is a view of VM-owned bytes; deep-clone so the
            // native caller owns an independent buffer (keeps the strings-always-
            // owned call-result invariant in hybrid too).
            .string => blk: {
                if (!fc.drop_enabled) break :blk unpacked;
                cloned_string = true;
                break :blk drop.cloneStringValue(fc, unpacked);
            },
            else => unpacked,
        };
        // Track for native drop ONLY when the native side owns the storage: a
        // native-owned clone produced above, or an enum block — the bridge hands
        // enums over as fresh libc-malloc'd blocks the native caller owns and
        // drops exactly once (lowerEnumToNativeOwned; see
        // HybridRuntime.cleanupPendingCallbackReturns). Everything else is the
        // VM-returned (VM-owned) pointer; tracking it would have the native
        // epilogue free VM-owned storage.
        if (cloned_owned) drop.onAlloc(fc, dst);
        if (cloned_string) drop.trackStringRegister(fc, dst);
        if (callee_decl.return_type.kind == .enum_instance) drop.onAlloc(fc, dst);
    }
}
