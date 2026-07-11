//! Async-task lowering for the LLVM backend (deferred execution).
//!
//! `task_spawn` packs the eagerly-evaluated scalar args into a malloc'd
//! `KiraBridgeValue` array and hands the C task runtime (runtime_helpers.c) a
//! per-callee thunk `void thunk(void *ctx, KiraBridgeValue *out)`; the thunk —
//! and therefore the deferred call — runs when the task is first driven
//! (`kira_task_await` joins, `kira_task_detach` drives and discards). Joining
//! a cancelled task or joining twice aborts inside the C runtime (the native
//! trap), mirroring the VM's RuntimeFailure semantics.
//!
//! Thunks are generated once per (callee, dispatch-kind) and deduped by symbol
//! name. A native callee's thunk unpacks the bridge args and calls the LLVM
//! function directly; a hybrid runtime callee's thunk forwards the bridge
//! array to `kira_hybrid_call_runtime` unchanged.
//!
//! Scalar-only: semantics (KSEM159) restricts task args/results to
//! Int/Float/Bool, so packing is 16-byte tag+payload stores with no ownership
//! transfer.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const calls = @import("backend_capi_calls.zig");
const backend_runtime_utils = @import("backend_runtime_utils.zig");
const runtime_abi = @import("kira_runtime_abi");

const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;
const functionById = backend_runtime_utils.functionById;
const functionExecutionById = backend_runtime_utils.functionExecutionById;
const resolveExecution = @import("backend_utils.zig").resolveExecution;

// extern KiraBridgeValue: tag u8 + 7 pad + 16-byte payload union (the payload
// holds a {ptr,len} string view, so the union is 16 bytes, NOT 8).
const bridge_value_size = 24;
const payload_offset = 8;

const tag_void: u64 = 0;
const tag_integer: u64 = 1;
const tag_float: u64 = 2;
const tag_boolean: u64 = 4;

/// Get-or-declare one of the C task runtime entry points.
fn taskRuntimeDecl(fc: *FunctionCodegen, name: [:0]const u8, ty: llvm.c.LLVMTypeRef) llvm.c.LLVMValueRef {
    if (fc.api.LLVMGetNamedFunction(fc.module_ref, name)) |existing| return existing;
    return fc.api.LLVMAddFunction(fc.module_ref, name, ty);
}

fn spawnFnType(fc: *FunctionCodegen) llvm.c.LLVMTypeRef {
    var params = [_]llvm.c.LLVMTypeRef{ fc.types.ptr_ty, fc.types.ptr_ty };
    return fc.api.LLVMFunctionType(fc.types.ptr_ty, &params, params.len, 0);
}

fn unaryTaskFnType(fc: *FunctionCodegen) llvm.c.LLVMTypeRef {
    var params = [_]llvm.c.LLVMTypeRef{fc.types.ptr_ty};
    return fc.api.LLVMFunctionType(fc.types.void_ty, &params, params.len, 0);
}

fn awaitFnType(fc: *FunctionCodegen) llvm.c.LLVMTypeRef {
    var params = [_]llvm.c.LLVMTypeRef{ fc.types.ptr_ty, fc.types.ptr_ty };
    return fc.api.LLVMFunctionType(fc.types.void_ty, &params, params.len, 0);
}

fn allocArgsFnType(fc: *FunctionCodegen) llvm.c.LLVMTypeRef {
    var params = [_]llvm.c.LLVMTypeRef{fc.types.i32};
    return fc.api.LLVMFunctionType(fc.types.ptr_ty, &params, params.len, 0);
}

fn thunkFnType(fc: *FunctionCodegen) llvm.c.LLVMTypeRef {
    var params = [_]llvm.c.LLVMTypeRef{ fc.types.ptr_ty, fc.types.ptr_ty };
    return fc.api.LLVMFunctionType(fc.types.void_ty, &params, params.len, 0);
}

/// Address of bridge slot `index`'s tag byte (base + index*16).
fn bridgeTagPtr(fc: *FunctionCodegen, base: llvm.c.LLVMValueRef, index: usize) llvm.c.LLVMValueRef {
    var offsets = [_]llvm.c.LLVMValueRef{fc.api.LLVMConstInt(fc.types.i64, index * bridge_value_size, 0)};
    return fc.api.LLVMBuildInBoundsGEP2(fc.builder, fc.types.i8, base, &offsets, offsets.len, "task.tag.ptr");
}

/// Address of bridge slot `index`'s payload (base + index*16 + 8).
fn bridgePayloadPtr(fc: *FunctionCodegen, base: llvm.c.LLVMValueRef, index: usize) llvm.c.LLVMValueRef {
    var offsets = [_]llvm.c.LLVMValueRef{fc.api.LLVMConstInt(fc.types.i64, index * bridge_value_size + payload_offset, 0)};
    return fc.api.LLVMBuildInBoundsGEP2(fc.builder, fc.types.i8, base, &offsets, offsets.len, "task.payload.ptr");
}

fn isScalarReturnKind(kind: ir.ValueType.Kind) bool {
    return kind == .integer or kind == .float or kind == .boolean;
}

fn scalarTag(kind: ir.ValueType.Kind) u64 {
    return switch (kind) {
        .integer => tag_integer,
        .float => tag_float,
        .boolean => tag_boolean,
        else => tag_void,
    };
}

/// Store the scalar in `value` (typed by `kind`) into bridge slot `index`.
fn storeBridgeScalar(fc: *FunctionCodegen, base: llvm.c.LLVMValueRef, index: usize, kind: ir.ValueType.Kind, value: llvm.c.LLVMValueRef) void {
    const api = fc.api;
    _ = api.LLVMBuildStore(fc.builder, api.LLVMConstInt(fc.types.i8, scalarTag(kind), 0), bridgeTagPtr(fc, base, index));
    const payload_ptr = bridgePayloadPtr(fc, base, index);
    switch (kind) {
        .float => _ = api.LLVMBuildStore(fc.builder, value, payload_ptr),
        .boolean => _ = api.LLVMBuildStore(fc.builder, api.LLVMBuildZExt(fc.builder, value, fc.types.i8, "task.bool.zext"), payload_ptr),
        else => _ = api.LLVMBuildStore(fc.builder, value, payload_ptr),
    }
}

/// Load the scalar of type `kind` from bridge slot `index`.
fn loadBridgeScalar(fc: *FunctionCodegen, base: llvm.c.LLVMValueRef, index: usize, kind: ir.ValueType.Kind) llvm.c.LLVMValueRef {
    const api = fc.api;
    const payload_ptr = bridgePayloadPtr(fc, base, index);
    return switch (kind) {
        .float => api.LLVMBuildLoad2(fc.builder, fc.types.double_ty, payload_ptr, "task.payload.f64"),
        .boolean => blk: {
            const byte = api.LLVMBuildLoad2(fc.builder, fc.types.i8, payload_ptr, "task.payload.byte");
            break :blk api.LLVMBuildICmp(fc.builder, llvm.c.LLVMIntNE, byte, api.LLVMConstInt(fc.types.i8, 0, 0), "task.payload.bool");
        },
        else => api.LLVMBuildLoad2(fc.builder, fc.types.i64, payload_ptr, "task.payload.i64"),
    };
}

/// Get-or-generate the thunk `void thunk(ctx, out)` that runs the deferred
/// call for `callee_id`. `runtime_dispatch` selects the hybrid trampoline path.
fn taskThunk(fc: *FunctionCodegen, callee_id: u32, callee_decl: ir.Function, runtime_dispatch: bool) !llvm.c.LLVMValueRef {
    const api = fc.api;
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "kira.task.thunk.{s}.{d}", .{ if (runtime_dispatch) "rt" else "nat", callee_id }) catch unreachable;
    if (api.LLVMGetNamedFunction(fc.module_ref, name)) |existing| return existing;

    const thunk = api.LLVMAddFunction(fc.module_ref, name, thunkFnType(fc));
    api.LLVMSetLinkage(thunk, llvm.c.LLVMInternalLinkage);
    const saved_block = api.LLVMGetInsertBlock(fc.builder);
    const entry = api.LLVMAppendBasicBlockInContext(fc.types.context, thunk, "entry");
    api.LLVMPositionBuilderAtEnd(fc.builder, entry);

    const ctx = api.LLVMGetParam(thunk, 0);
    const out = api.LLVMGetParam(thunk, 1);

    if (runtime_dispatch) {
        // Hybrid: the ctx already IS a bridge array — forward it unchanged.
        const trampoline_ty = blk: {
            var params = [_]llvm.c.LLVMTypeRef{ fc.types.i32, fc.types.ptr_ty, fc.types.i32, fc.types.ptr_ty };
            break :blk api.LLVMFunctionType(fc.types.void_ty, &params, params.len, 0);
        };
        const trampoline = taskRuntimeDecl(fc, "kira_hybrid_call_runtime", trampoline_ty);
        var call_args = [_]llvm.c.LLVMValueRef{
            api.LLVMConstInt(fc.types.i32, callee_id, 0),
            ctx,
            api.LLVMConstInt(fc.types.i32, callee_decl.param_types.len, 0),
            out,
        };
        _ = api.LLVMBuildCall2(fc.builder, trampoline_ty, trampoline, &call_args, call_args.len, "");
    } else {
        // Native: unpack the scalar args and call the LLVM function directly.
        const callee_fn = fc.functions.get(callee_id) orelse return error.MissingFunctionDeclaration;
        const fn_ty = try fc.types.functionType(fc.allocator, callee_decl);
        const args = try fc.allocator.alloc(llvm.c.LLVMValueRef, callee_decl.param_types.len);
        defer fc.allocator.free(args);
        for (callee_decl.param_types, 0..) |param_ty, index| {
            args[index] = loadBridgeScalar(fc, ctx, index, param_ty.kind);
        }
        const result = api.LLVMBuildCall2(fc.builder, fn_ty, callee_fn, args.ptr, @intCast(args.len), "");
        const return_kind = callee_decl.return_type.kind;
        if (isScalarReturnKind(return_kind)) {
            storeBridgeScalar(fc, out, 0, return_kind, result);
        } else {
            // Void (or implicitly-void / unknown) result: the LLVM call value is
            // void and must not be stored — complete the task with a void tag.
            _ = api.LLVMBuildStore(fc.builder, api.LLVMConstInt(fc.types.i8, tag_void, 0), bridgeTagPtr(fc, out, 0));
        }
    }
    _ = api.LLVMBuildRetVoid(fc.builder);

    api.LLVMPositionBuilderAtEnd(fc.builder, saved_block);
    return thunk;
}

pub fn lowerTaskSpawn(fc: *FunctionCodegen, v: ir.TaskSpawn) !void {
    const api = fc.api;
    const program = fc.request.program.programPtr().*;
    const callee_decl = functionById(program, v.callee) orelse return error.UnknownFunction;
    const callee_execution = functionExecutionById(program, v.callee) orelse return error.UnknownFunction;
    const runtime_dispatch = switch (resolveExecution(callee_execution, fc.request.mode)) {
        .native => false,
        .runtime => true,
        .inherited => unreachable,
    };

    if (v.suspendable) {
        if (runtime_dispatch) return error.UnsupportedExecutableFeature;
        // State-machine body: allocate the frame (calloc'd → resume state 0),
        // seed the args into slots 2.., and hand the C executor the body
        // function itself — it drives by status until complete.
        const alloc_ty = allocArgsFnType(fc);
        const alloc_fn = taskRuntimeDecl(fc, "kira_task_alloc_args", alloc_ty);
        var alloc_args = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i32, v.frame_slots, 0)};
        const frame = api.LLVMBuildCall2(fc.builder, alloc_ty, alloc_fn, &alloc_args, alloc_args.len, "task.frame");
        for (v.args, 0..) |arg, index| {
            // The transformed callee's own params collapsed to the frame
            // pointer, so type the seeded slots by the argument registers.
            const kind = if (arg < fc.register_types.len) fc.register_types[arg].kind else ir.ValueType.Kind.integer;
            storeBridgeScalar(fc, frame, ir.frame_first_data_slot + index, kind, fc.registers[arg]);
        }
        const body_fn = fc.functions.get(v.callee) orelse return error.MissingFunctionDeclaration;
        const spawn_ty = spawnFnType(fc);
        const spawn_fn = taskRuntimeDecl(fc, "kira_task_spawn_suspendable", spawn_ty);
        var spawn_args = [_]llvm.c.LLVMValueRef{ body_fn, frame };
        const handle = api.LLVMBuildCall2(fc.builder, spawn_ty, spawn_fn, &spawn_args, spawn_args.len, "task.handle");
        fc.registers[v.dst] = api.LLVMBuildPtrToInt(fc.builder, handle, fc.types.i64, "task.handle.int");
        return;
    }

    // Pack the eagerly-evaluated scalar args into a malloc'd bridge array
    // (owned + freed by the C task runtime).
    const alloc_ty = allocArgsFnType(fc);
    const alloc_fn = taskRuntimeDecl(fc, "kira_task_alloc_args", alloc_ty);
    var alloc_args = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i32, v.args.len, 0)};
    const ctx = api.LLVMBuildCall2(fc.builder, alloc_ty, alloc_fn, &alloc_args, alloc_args.len, "task.args");
    for (v.args, 0..) |arg, index| {
        const kind = if (index < callee_decl.param_types.len) callee_decl.param_types[index].kind else ir.ValueType.Kind.integer;
        storeBridgeScalar(fc, ctx, index, kind, fc.registers[arg]);
    }

    const thunk = try taskThunk(fc, v.callee, callee_decl, runtime_dispatch);
    const spawn_ty = spawnFnType(fc);
    const spawn_fn = taskRuntimeDecl(fc, "kira_task_spawn", spawn_ty);
    var spawn_args = [_]llvm.c.LLVMValueRef{ thunk, ctx };
    const handle = api.LLVMBuildCall2(fc.builder, spawn_ty, spawn_fn, &spawn_args, spawn_args.len, "task.handle");
    fc.registers[v.dst] = api.LLVMBuildPtrToInt(fc.builder, handle, fc.types.i64, "task.handle.int");
}

pub fn lowerTaskSpawnReady(fc: *FunctionCodegen, v: ir.TaskSpawnReady) !void {
    const api = fc.api;
    // Stack bridge value; the C runtime copies it into the task.
    const slot = api.LLVMBuildAlloca(fc.builder, api.LLVMArrayType2(fc.types.i8, bridge_value_size), "task.ready.slot");
    storeBridgeScalar(fc, slot, 0, v.ty.kind, fc.registers[v.value]);
    const ready_ty = unaryTaskFnTypeReturningPtr(fc);
    const ready_fn = taskRuntimeDecl(fc, "kira_task_spawn_ready", ready_ty);
    var ready_args = [_]llvm.c.LLVMValueRef{slot};
    const handle = api.LLVMBuildCall2(fc.builder, ready_ty, ready_fn, &ready_args, ready_args.len, "task.handle");
    fc.registers[v.dst] = api.LLVMBuildPtrToInt(fc.builder, handle, fc.types.i64, "task.handle.int");
}

fn unaryTaskFnTypeReturningPtr(fc: *FunctionCodegen) llvm.c.LLVMTypeRef {
    var params = [_]llvm.c.LLVMTypeRef{fc.types.ptr_ty};
    return fc.api.LLVMFunctionType(fc.types.ptr_ty, &params, params.len, 0);
}

pub fn lowerTaskAwait(fc: *FunctionCodegen, v: ir.TaskAwait) !void {
    const api = fc.api;
    const task_ptr = api.LLVMBuildIntToPtr(fc.builder, fc.registers[v.task], fc.types.ptr_ty, "task.ptr");
    const out = api.LLVMBuildAlloca(fc.builder, api.LLVMArrayType2(fc.types.i8, bridge_value_size), "task.out");
    const await_ty = awaitFnType(fc);
    const await_fn = taskRuntimeDecl(fc, "kira_task_await", await_ty);
    var await_args = [_]llvm.c.LLVMValueRef{ task_ptr, out };
    _ = api.LLVMBuildCall2(fc.builder, await_ty, await_fn, &await_args, await_args.len, "");
    fc.registers[v.dst] = if (v.ty.kind == .void)
        api.LLVMConstInt(fc.types.i64, 0, 0)
    else
        loadBridgeScalar(fc, out, 0, v.ty.kind);
}

pub fn lowerTaskCancel(fc: *FunctionCodegen, v: ir.TaskCancel) void {
    const api = fc.api;
    const task_ptr = api.LLVMBuildIntToPtr(fc.builder, fc.registers[v.task], fc.types.ptr_ty, "task.ptr");
    const cancel_ty = unaryTaskFnType(fc);
    const cancel_fn = taskRuntimeDecl(fc, "kira_task_cancel", cancel_ty);
    var cancel_args = [_]llvm.c.LLVMValueRef{task_ptr};
    _ = api.LLVMBuildCall2(fc.builder, cancel_ty, cancel_fn, &cancel_args, cancel_args.len, "");
}

pub fn lowerTaskDetach(fc: *FunctionCodegen, v: ir.TaskDetach) void {
    const api = fc.api;
    const task_ptr = api.LLVMBuildIntToPtr(fc.builder, fc.registers[v.task], fc.types.ptr_ty, "task.ptr");
    const detach_ty = unaryTaskFnType(fc);
    const detach_fn = taskRuntimeDecl(fc, "kira_task_detach", detach_ty);
    var detach_args = [_]llvm.c.LLVMValueRef{task_ptr};
    _ = api.LLVMBuildCall2(fc.builder, detach_ty, detach_fn, &detach_args, detach_args.len, "");
}

pub fn lowerTaskYield(fc: *FunctionCodegen) void {
    const api = fc.api;
    const yield_ty = api.LLVMFunctionType(fc.types.void_ty, null, 0, 0);
    const yield_fn = taskRuntimeDecl(fc, "kira_task_yield", yield_ty);
    _ = api.LLVMBuildCall2(fc.builder, yield_ty, yield_fn, null, 0, "");
}

/// Frame slots use the same 16-byte tag+payload layout as task args, with a
/// runtime frame base held in a register (i64 → ptr).
pub fn lowerFrameGet(fc: *FunctionCodegen, v: ir.FrameGet) void {
    const api = fc.api;
    const base = api.LLVMBuildIntToPtr(fc.builder, fc.registers[v.frame], fc.types.ptr_ty, "frame.ptr");
    fc.registers[v.dst] = loadBridgeScalar(fc, base, v.slot, v.ty.kind);
}

pub fn lowerFrameSet(fc: *FunctionCodegen, v: ir.FrameSet) void {
    const api = fc.api;
    const base = api.LLVMBuildIntToPtr(fc.builder, fc.registers[v.frame], fc.types.ptr_ty, "frame.ptr");
    storeBridgeScalar(fc, base, v.slot, v.ty.kind, fc.registers[v.src]);
}

pub fn lowerTaskSleep(fc: *FunctionCodegen, v: ir.TaskSleep) void {
    const api = fc.api;
    const sleep_ty = blk: {
        var params = [_]llvm.c.LLVMTypeRef{fc.types.i64};
        break :blk api.LLVMFunctionType(fc.types.void_ty, &params, params.len, 0);
    };
    const sleep_fn = taskRuntimeDecl(fc, "kira_task_sleep", sleep_ty);
    var sleep_args = [_]llvm.c.LLVMValueRef{fc.registers[v.milliseconds]};
    _ = api.LLVMBuildCall2(fc.builder, sleep_ty, sleep_fn, &sleep_args, sleep_args.len, "");
}

pub fn lowerTaskIsComplete(fc: *FunctionCodegen, v: ir.TaskIsComplete) void {
    const api = fc.api;
    const task_ptr = api.LLVMBuildIntToPtr(fc.builder, fc.registers[v.task], fc.types.ptr_ty, "task.ptr");
    const check_ty = blk: {
        var params = [_]llvm.c.LLVMTypeRef{fc.types.ptr_ty};
        break :blk api.LLVMFunctionType(fc.types.i64, &params, params.len, 0);
    };
    const check_fn = taskRuntimeDecl(fc, "kira_task_is_complete", check_ty);
    var check_args = [_]llvm.c.LLVMValueRef{task_ptr};
    const raw = api.LLVMBuildCall2(fc.builder, check_ty, check_fn, &check_args, check_args.len, "task.done.raw");
    fc.registers[v.dst] = api.LLVMBuildICmp(fc.builder, llvm.c.LLVMIntNE, raw, api.LLVMConstInt(fc.types.i64, 0, 0), "task.done");
}
