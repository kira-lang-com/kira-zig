//! Native closure/callback bridge for the VM.
//!
//! The closure-direction half of the VM <-> native representation boundary:
//! importing a native closure block into a managed runtime `ClosureObject`
//! (`materializeNativeClosure`), exporting a managed closure into a native
//! closure block (`exportRuntimeClosureToNative`), and the callback-typed
//! `raw_ptr` arms that decide whether a pointer crossing the boundary is a
//! closure to translate. Extracted from `vm_native_bridge.zig` (Core Law #5);
//! the struct/array/enum native-layout copies stay there. Functions take the
//! owning `Vm` as their first parameter, and `vm_native_bridge.zig` re-exports
//! the three public entry points so `native_bridge.*` call sites and the `Vm`
//! facade wrappers are unchanged.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const ownership = @import("ownership.zig");
const vm_mod = @import("vm.zig");
const bridge = @import("vm_native_bridge.zig");

const Vm = vm_mod.Vm;
const ClosureObject = ownership.ClosureObject;

pub fn materializeNativeClosure(self: *Vm, module: *const bytecode.Module, native_ptr: usize, external_capture_types: ?[]const bytecode.TypeRef) !usize {
    if (native_ptr == 0) return 0;
    if (self.heap.getClosure(native_ptr) != null) return native_ptr;
    const raw_native_ptr = runtime_abi.untagNativeClosurePointer(native_ptr);
    const function_id_ptr: *const i64 = @ptrFromInt(raw_native_ptr);
    const capture_count_ptr: *const i64 = @ptrFromInt(raw_native_ptr + 8);
    const function_id_i64 = function_id_ptr.*;
    const capture_count_i64 = capture_count_ptr.*;
    if (function_id_i64 < 0 or function_id_i64 > std.math.maxInt(u32)) {
        return native_ptr;
    }
    if (capture_count_i64 < 0) {
        self.rememberError("native closure capture count is negative");
        return error.RuntimeFailure;
    }

    const capture_count: usize = @intCast(capture_count_i64);
    const function_id: u32 = @intCast(function_id_i64);
    const function_decl = module.findFunctionById(function_id);
    const native_slots: [*]const runtime_abi.BridgeValue = @ptrFromInt(raw_native_ptr + 16);
    const closure = try self.allocator.create(ClosureObject);
    errdefer self.allocator.destroy(closure);
    const captures = try self.allocator.alloc(runtime_abi.Value, capture_count);
    for (captures) |*capture| capture.* = .{ .void = {} };
    var initialized: usize = 0;
    errdefer {
        self.heap.dropSlots(captures[0..initialized]);
        self.allocator.free(captures);
    }
    for (0..capture_count) |index| {
        var capture_value = runtime_abi.bridgeValueToValue(native_slots[index]);
        var capture_is_owned = false;
        if (function_decl) |decl| {
            const param_index = decl.param_count - @as(u32, @intCast(capture_count)) + @as(u32, @intCast(index));
            const capture_ty = decl.local_types[param_index];
            if (capture_ty.kind == .ffi_struct and capture_value == .raw_ptr and capture_value.raw_ptr != 0) {
                capture_value = .{ .raw_ptr = try bridge.copyStructFromNativeLayout(self, module, capture_ty.name orelse {
                    self.rememberError("native closure capture type is missing a name");
                    return error.RuntimeFailure;
                }, capture_value.raw_ptr) };
                capture_is_owned = true;
            } else if (capture_ty.kind == .raw_ptr) {
                capture_value = try materializeCallbackValueFromNative(self, module, capture_ty, capture_value);
                capture_is_owned = true;
            }
        } else if (external_capture_types) |capture_types| {
            if (index >= capture_types.len) {
                self.rememberError("native closure capture metadata is incomplete");
                return error.RuntimeFailure;
            }
            const capture_ty = capture_types[index];
            if (capture_ty.kind == .ffi_struct and capture_value == .raw_ptr and capture_value.raw_ptr != 0) {
                capture_value = .{ .raw_ptr = try bridge.copyStructFromNativeLayout(self, module, capture_ty.name orelse {
                    self.rememberError("native closure capture type is missing a name");
                    return error.RuntimeFailure;
                }, capture_value.raw_ptr) };
                capture_is_owned = true;
            } else if (capture_ty.kind == .raw_ptr) {
                capture_value = try materializeCallbackValueFromNative(self, module, capture_ty, capture_value);
                capture_is_owned = true;
            }
        }
        if (capture_is_owned) {
            self.heap.assignTransferred(&captures[index], capture_value);
        } else {
            self.heap.assignBorrowed(&captures[index], capture_value);
        }
        initialized += 1;
    }
    closure.* = .{
        .function_id = function_id,
        .is_native = function_decl == null,
        .captures = captures,
    };
    runtime_abi.emitExecutionTrace("BRIDGE", "MATERIALIZE", "native->runtime closure fn={d} captures={d} ptr=0x{x}", .{ closure.function_id, capture_count, raw_native_ptr });
    return self.heap.registerClosure(closure);
}

pub fn materializeCallbackValueFromNative(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) anyerror!runtime_abi.Value {
    if (ty.kind != .raw_ptr) return value;
    const name = ty.name orelse return value;
    if (!Vm.isCallbackTypeName(name)) return value;
    if (value != .raw_ptr or value.raw_ptr == 0) return value;
    if (self.heap.getClosure(value.raw_ptr) != null) return value;
    if (!runtime_abi.isTaggedNativeClosurePointer(value.raw_ptr)) return value;
    return .{ .raw_ptr = try materializeNativeClosure(self, module, value.raw_ptr, null) };
}

/// The callback (`raw_ptr`) arm of `copyValueToNativeLayout`: export a managed
/// runtime closure stored in a callback-typed field into a native closure block,
/// otherwise pass the pointer through unchanged.
pub fn copyCallbackValueToNativeLayout(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) anyerror!runtime_abi.Value {
    if (ty.name) |name| {
        if (Vm.isCallbackTypeName(name) and value == .raw_ptr and value.raw_ptr != 0 and self.heap.getClosure(value.raw_ptr) != null) {
            return .{ .raw_ptr = try exportRuntimeClosureToNative(self, module, value.raw_ptr, null) };
        }
    }
    return value;
}

pub fn exportRuntimeClosureToNative(self: *Vm, module: *const bytecode.Module, closure_ptr: usize, external_capture_types: ?[]const bytecode.TypeRef) !usize {
    // No pointer-keyed dedup: a consumed closure's pointer can be reused by a
    // later, different closure, so caching by `closure_ptr` would hand the new
    // closure the stale native block (FF1 — captured closures crossing the bridge
    // dispatching to the wrong body). Always export a fresh block.
    const closure = self.heap.getClosure(closure_ptr) orelse {
        self.rememberError("callback value is not a valid runtime closure");
        return error.RuntimeFailure;
    };
    // Resolve the closure body's capture types. A runtime-executed body lives in
    // the VM bytecode module, so `findFunctionById` finds it. But in hybrid mode
    // a native-executed body is *stripped* from the VM module (compiler.zig:
    // `resolved_execution == .native and mode == .hybrid_runtime => continue`),
    // so the module lookup misses even though the closure is valid. For that path
    // the manifest-backed caller supplies the metadata via `external_capture_types`
    // — the export-direction mirror of `materializeNativeClosure`'s import-side
    // `external_capture_types` fallback. header[0] still carries `function_id`, so
    // native dispatches `kira_native_fn_{id}` correctly regardless of which branch
    // resolved the types.
    const capture_types: []const bytecode.TypeRef = blk: {
        if (module.findFunctionById(closure.function_id)) |function_decl| {
            if (closure.captures.len > function_decl.param_count) {
                self.rememberError("runtime closure capture metadata is inconsistent");
                return error.RuntimeFailure;
            }
            const param_count: usize = function_decl.param_count;
            break :blk function_decl.local_types[param_count - closure.captures.len .. param_count];
        } else if (external_capture_types) |ext| {
            if (ext.len != closure.captures.len) {
                self.rememberError("runtime closure capture metadata is inconsistent");
                return error.RuntimeFailure;
            }
            break :blk ext;
        } else {
            self.rememberError("runtime closure function could not be resolved");
            return error.RuntimeFailure;
        }
    };
    const byte_len = 16 + closure.captures.len * @sizeOf(runtime_abi.BridgeValue);
    const word_count = @max(1, std.math.divCeil(usize, byte_len, @sizeOf(u64)) catch unreachable);
    const words = try self.allocator.alloc(u64, word_count);
    errdefer self.allocator.free(words);
    @memset(words, 0);

    const raw_ptr = @intFromPtr(words.ptr);
    const header: [*]u64 = @ptrFromInt(raw_ptr);
    header[0] = closure.function_id;
    header[1] = closure.captures.len;

    const retained_captures = try self.allocator.alloc(runtime_abi.Value, closure.captures.len);
    errdefer self.allocator.free(retained_captures);
    const slots: [*]runtime_abi.BridgeValue = @ptrFromInt(raw_ptr + 16);
    for (closure.captures, 0..) |capture, index| {
        const lowered = try bridge.copyValueToNativeLayout(self, module, capture_types[index], capture);
        retained_captures[index] = lowered;
        slots[index] = runtime_abi.bridgeValueFromValue(lowered);
    }

    try self.exported_native_closures.append(self.allocator, .{
        .native_ptr = raw_ptr,
        .captures = retained_captures,
    });
    return runtime_abi.tagNativeClosurePointer(raw_ptr);
}
