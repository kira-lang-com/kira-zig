const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const builtins = @import("builtins.zig");
const ownership = @import("ownership.zig");
const native_layout = @import("native_layout.zig");
const helper_impl = @import("vm_helpers.zig");
const value_impl = @import("vm_values.zig");

const ArrayObject = ownership.ArrayObject;
const ClosureObject = ownership.ClosureObject;

const NativeStateBox = extern struct { type_id: u64, payload: usize, runtime_payload: usize };

const ExportedNativeClosure = struct {
    native_ptr: usize,
    captures: []runtime_abi.Value,
};

const NativeLayoutStats = struct {
    arrays_current: usize = 0,
    arrays_peak: usize = 0,
    arrays_allocated: usize = 0,
    arrays_freed: usize = 0,
    structs_current: usize = 0,
    structs_peak: usize = 0,
    structs_allocated: usize = 0,
    structs_freed: usize = 0,
    native_state_recovers: usize = 0,
    native_state_materializations: usize = 0,
};

pub const NativeCallHook = *const fn (?*anyopaque, u32, []const runtime_abi.Value) anyerror!runtime_abi.Value;
pub const ResolveFunctionHook = *const fn (?*anyopaque, u32) anyerror!usize;

pub const Hooks = struct { context: ?*anyopaque = null, call_native: ?NativeCallHook = null, resolve_function: ?ResolveFunctionHook = null, copy_struct_args_by_value: bool = true };

pub const Vm = struct {
    allocator: std.mem.Allocator,
    heap: ownership.Heap,
    native_layout_stats: NativeLayoutStats = .{},
    native_state_materialized_types: std.StringHashMap(usize),
    exported_native_closures: std.AutoHashMap(usize, ExportedNativeClosure),
    last_error_buffer: [256]u8 = [_]u8{0} ** 256,
    last_error_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{
            .allocator = allocator,
            .heap = ownership.Heap.init(allocator),
            .native_state_materialized_types = std.StringHashMap(usize).init(allocator),
            .exported_native_closures = std.AutoHashMap(usize, ExportedNativeClosure).init(allocator),
        };
    }

    pub fn deinit(self: *Vm) void {
        var exported_iterator = self.exported_native_closures.iterator();
        while (exported_iterator.next()) |entry| {
            const exported = entry.value_ptr.*;
            for (exported.captures) |capture| self.heap.dropValue(capture);
            self.allocator.free(exported.captures);
            const byte_len = 16 + exported.captures.len * @sizeOf(runtime_abi.BridgeValue);
            const word_count = @max(1, std.math.divCeil(usize, byte_len, @sizeOf(u64)) catch unreachable);
            const words: [*]u64 = @ptrFromInt(exported.native_ptr);
            self.allocator.free(words[0..word_count]);
        }
        self.exported_native_closures.deinit();
        self.heap.deinit();
        self.native_state_materialized_types.deinit();
    }

    pub fn managedObjectCount(self: *const Vm) usize {
        return self.heap.count();
    }

    pub fn emitMemoryReport(self: *const Vm, label: []const u8) void {
        const heap_stats = self.heap.stats;
        const native_stats = self.native_layout_stats;
        std.debug.print(
            "Kira runtime memory report ({s}): heap arrays current={d} peak={d} allocated={d} freed={d} structs current={d} peak={d} allocated={d} freed={d} closures current={d} peak={d} allocated={d} freed={d} strings current={d} peak={d} allocated={d} freed={d} nativeArrays current={d} peak={d} allocated={d} freed={d} nativeStructs current={d} peak={d} allocated={d} freed={d} nativeStateRecovers={d} nativeStateMaterializations={d}\n",
            .{
                label,
                heap_stats.arrays_current,
                heap_stats.arrays_peak,
                heap_stats.arrays_allocated,
                heap_stats.arrays_freed,
                heap_stats.structs_current,
                heap_stats.structs_peak,
                heap_stats.structs_allocated,
                heap_stats.structs_freed,
                heap_stats.closures_current,
                heap_stats.closures_peak,
                heap_stats.closures_allocated,
                heap_stats.closures_freed,
                heap_stats.strings_current,
                heap_stats.strings_peak,
                heap_stats.strings_allocated,
                heap_stats.strings_freed,
                native_stats.arrays_current,
                native_stats.arrays_peak,
                native_stats.arrays_allocated,
                native_stats.arrays_freed,
                native_stats.structs_current,
                native_stats.structs_peak,
                native_stats.structs_allocated,
                native_stats.structs_freed,
                native_stats.native_state_recovers,
                native_stats.native_state_materializations,
            },
        );
    }

    pub fn emitMemoryDetail(self: *const Vm) void {
        self.heap.emitCurrentTypeReport();
        var iterator = self.native_state_materialized_types.iterator();
        while (iterator.next()) |entry| {
            std.debug.print("Kira runtime memory detail: nativeStateType={s} materialized={d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    pub fn dropManagedValue(self: *Vm, value: runtime_abi.Value) void {
        self.heap.dropValue(value);
    }

    pub fn retainManagedValue(self: *Vm, value: runtime_abi.Value) void {
        _ = self;
        _ = value;
    }

    pub fn beginNativeBoundary(self: *Vm) !void {
        try self.heap.beginBoundaryPinScope();
    }

    pub fn endNativeBoundary(self: *Vm) void {
        self.heap.endBoundaryPinScope();
    }

    pub fn pinNativeBoundaryValue(self: *Vm, value: runtime_abi.Value) !void {
        try self.heap.pinBoundaryValue(value);
    }

    pub fn runMain(self: *Vm, module: *const bytecode.Module, writer: anytype) anyerror!void {
        const entry_function_id = module.entry_function_id orelse {
            self.rememberError("bytecode module has no runtime entrypoint");
            return error.RuntimeFailure;
        };
        const result = try self.runFunctionById(module, entry_function_id, &.{}, writer, .{});
        self.heap.dropValue(result);
    }

    pub fn runFunctionById(
        self: *Vm,
        module: *const bytecode.Module,
        function_id: u32,
        args: []const runtime_abi.Value,
        writer: anytype,
        hooks: Hooks,
    ) anyerror!runtime_abi.Value {
        const function_decl = module.findFunctionById(function_id) orelse {
            self.rememberError("bytecode function id is out of range");
            return error.RuntimeFailure;
        };
        return self.runFunction(module, function_decl, args, writer, hooks);
    }

    pub fn lastError(self: *const Vm) ?[]const u8 {
        if (self.last_error_len == 0) return null;
        return self.last_error_buffer[0..self.last_error_len];
    }

    pub fn materializeNativeStruct(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) !usize {
        runtime_abi.emitExecutionTrace("BRIDGE", "MATERIALIZE", "native->runtime type={s} ptr=0x{x}", .{ type_name, native_ptr });
        return self.copyStructFromNativeLayout(module, type_name, native_ptr);
    }

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
                    capture_value = .{ .raw_ptr = try self.copyStructFromNativeLayout(module, capture_ty.name orelse {
                        self.rememberError("native closure capture type is missing a name");
                        return error.RuntimeFailure;
                    }, capture_value.raw_ptr) };
                    capture_is_owned = true;
                } else if (capture_ty.kind == .raw_ptr) {
                    capture_value = try self.materializeCallbackValueFromNative(module, capture_ty, capture_value);
                    capture_is_owned = true;
                }
            } else if (external_capture_types) |capture_types| {
                if (index >= capture_types.len) {
                    self.rememberError("native closure capture metadata is incomplete");
                    return error.RuntimeFailure;
                }
                const capture_ty = capture_types[index];
                if (capture_ty.kind == .ffi_struct and capture_value == .raw_ptr and capture_value.raw_ptr != 0) {
                    capture_value = .{ .raw_ptr = try self.copyStructFromNativeLayout(module, capture_ty.name orelse {
                        self.rememberError("native closure capture type is missing a name");
                        return error.RuntimeFailure;
                    }, capture_value.raw_ptr) };
                    capture_is_owned = true;
                } else if (capture_ty.kind == .raw_ptr) {
                    capture_value = try self.materializeCallbackValueFromNative(module, capture_ty, capture_value);
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

    pub fn lowerStructToNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, runtime_ptr: usize) !usize {
        runtime_abi.emitExecutionTrace("BRIDGE", "COPY", "runtime->native type={s} ptr=0x{x}", .{ type_name, runtime_ptr });
        return self.copyStructToNativeLayout(module, type_name, runtime_ptr);
    }

    pub fn writeStructToNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, runtime_ptr: usize, native_ptr: usize) !void {
        runtime_abi.emitExecutionTrace("BRIDGE", "COPY", "sync runtime->native type={s} src=0x{x} dst=0x{x}", .{ type_name, runtime_ptr, native_ptr });
        try self.copyStructToNativeLayoutInto(module, type_name, runtime_ptr, native_ptr);
    }

    pub fn copyArrayToNativeLayout(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef, runtime_array_ptr: usize) anyerror!usize {
        const source: *const ArrayObject = @ptrFromInt(runtime_array_ptr);
        const object = try self.allocator.create(ArrayObject);
        const items = try self.allocator.alloc(runtime_abi.BridgeValue, @max(source.len, 1));
        for (items) |*item| item.* = runtime_abi.bridgeValueFromValue(.{ .void = {} });
        object.* = .{
            .len = source.len,
            .items = items.ptr,
        };
        self.recordNativeArrayAlloc();
        errdefer self.destroyArrayNativeLayout(module, array_ty, @intFromPtr(object));

        const element_ty = try self.arrayElementType(module, array_ty);
        for (source.items[0..source.len], 0..) |item, index| {
            const value = runtime_abi.bridgeValueToValue(item);
            items[index] = runtime_abi.bridgeValueFromValue(try self.copyValueToNativeLayout(module, element_ty, value));
        }
        return @intFromPtr(object);
    }

    pub fn copyArrayFromNativeLayout(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef, native_array_ptr: usize) anyerror!usize {
        const source: *const ArrayObject = @ptrFromInt(native_array_ptr);
        const object = try self.allocator.create(ArrayObject);
        errdefer self.allocator.destroy(object);
        const items = try self.allocator.alloc(runtime_abi.BridgeValue, @max(source.len, 1));
        const element_ty = try self.arrayElementType(module, array_ty);
        for (items) |*item| item.* = runtime_abi.bridgeValueFromValue(.{ .void = {} });
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| self.heap.dropValue(runtime_abi.bridgeValueToValue(item));
            self.allocator.free(items);
        }
        for (source.items[0..source.len], 0..) |item, index| {
            const value = runtime_abi.bridgeValueToValue(item);
            items[index] = runtime_abi.bridgeValueFromValue(try self.copyValueFromNativeLayout(module, element_ty, value));
            initialized += 1;
        }
        object.* = .{
            .len = source.len,
            .items = items.ptr,
        };
        return try self.heap.registerArray(object);
    }

    pub fn syncArrayFromNativeLayout(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef, runtime_array_ptr: usize, native_array_ptr: usize) anyerror!void {
        const source: *const ArrayObject = @ptrFromInt(native_array_ptr);
        const destination: *ArrayObject = @ptrFromInt(runtime_array_ptr);

        const items = try self.allocator.alloc(runtime_abi.BridgeValue, @max(source.len, 1));
        const element_ty = try self.arrayElementType(module, array_ty);
        for (items) |*item| item.* = runtime_abi.bridgeValueFromValue(.{ .void = {} });
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| self.heap.dropValue(runtime_abi.bridgeValueToValue(item));
            self.allocator.free(items);
        }
        for (source.items[0..source.len], 0..) |item, index| {
            const value = runtime_abi.bridgeValueToValue(item);
            items[index] = runtime_abi.bridgeValueFromValue(try self.copyValueFromNativeLayout(module, element_ty, value));
            initialized += 1;
        }

        const old_items = destination.items[0..@max(destination.len, 1)];
        for (old_items[0..destination.len]) |item| self.heap.dropValue(runtime_abi.bridgeValueToValue(item));
        self.allocator.free(old_items);
        destination.len = source.len;
        destination.items = items.ptr;
    }

    pub fn syncStructFromNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, runtime_ptr: usize, native_ptr: usize) !void {
        runtime_abi.emitExecutionTrace("BRIDGE", "COPY", "sync native->runtime type={s} src=0x{x} dst=0x{x}", .{ type_name, native_ptr, runtime_ptr });
        try self.copyStructFromNativeLayoutInto(module, type_name, runtime_ptr, native_ptr);
    }

    pub fn destroyArrayNativeLayout(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef, native_array_ptr: usize) void {
        if (native_array_ptr == 0) return;
        const object: *ArrayObject = @ptrFromInt(native_array_ptr);
        const items = object.items[0..@max(object.len, 1)];
        const element_ty = self.arrayElementType(module, array_ty) catch .{ .kind = .raw_ptr };
        for (items[0..object.len]) |item| {
            self.destroyNativeLayoutValue(module, element_ty, runtime_abi.bridgeValueToValue(item));
        }
        self.allocator.free(items);
        self.allocator.destroy(object);
        self.recordNativeArrayFree();
    }

    pub fn destroyStructNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
        if (native_ptr == 0) return;
        self.destroyStructNativeLayoutFields(module, type_name, native_ptr);
        const layout = native_layout.structLayout(module, type_name) catch return;
        const word_count = @max(1, std.math.divCeil(usize, layout.size, @sizeOf(u64)) catch unreachable);
        const words: [*]u64 = @ptrFromInt(native_ptr);
        self.allocator.free(words[0..word_count]);
        self.recordNativeStructFree();
    }

    pub fn destroyNativeLayoutValue(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) void {
        switch (ty.kind) {
            .ffi_struct => {
                if (value == .raw_ptr) {
                    if (ty.name) |name| self.destroyStructNativeLayout(module, name, value.raw_ptr);
                }
            },
            .array => {
                if (value == .raw_ptr) self.destroyArrayNativeLayout(module, ty, value.raw_ptr);
            },
            .enum_instance, .construct_any => self.heap.dropValue(value),
            else => {},
        }
    }

    fn runFunction(
        self: *Vm,
        module: *const bytecode.Module,
        function_decl: bytecode.Function,
        args: []const runtime_abi.Value,
        writer: anytype,
        hooks: Hooks,
    ) anyerror!runtime_abi.Value {
        const registers = try self.allocator.alloc(runtime_abi.Value, function_decl.register_count);
        const register_owned = try self.allocator.alloc(bool, function_decl.register_count);
        defer {
            self.releaseTrackedSlots(registers, register_owned);
            self.allocator.free(register_owned);
            self.allocator.free(registers);
        }
        const locals = try self.allocator.alloc(runtime_abi.Value, function_decl.local_count);
        const local_owned = try self.allocator.alloc(bool, function_decl.local_count);
        defer {
            self.releaseTrackedSlots(locals, local_owned);
            self.allocator.free(local_owned);
            self.allocator.free(locals);
        }
        const label_offsets = try helper_impl.buildLabelOffsets(self.allocator, function_decl.instructions);
        defer self.allocator.free(label_offsets);

        for (registers) |*slot| slot.* = .{ .void = {} };
        for (locals) |*slot| slot.* = .{ .void = {} };
        @memset(register_owned, false);
        @memset(local_owned, false);
        for (function_decl.local_types, 0..) |local_ty, index| {
            if (local_ty.kind != .ffi_struct) continue;
            if (index < function_decl.param_count) {
                // A borrow/`borrow mut` struct parameter ALIASES the caller's struct (so
                // mutations propagate); it gets no private copy destination. In hybrid mode
                // (copy_struct_args_by_value=false) no struct param is copied. Only an
                // owned/move/copy struct param in pure-VM mode needs a fresh destination.
                const mode = ownershipModeAt(function_decl.param_ownership, index);
                if (!hooks.copy_struct_args_by_value or mode == .borrow_read or mode == .borrow_mut) continue;
            }
            const type_name = local_ty.name orelse {
                self.rememberError("struct local type is missing a name");
                return error.RuntimeFailure;
            };
            self.setSlotOwned(&locals[index], &local_owned[index], .{ .raw_ptr = try self.allocateStruct(module, type_name) });
        }
        if (args.len != function_decl.param_count) {
            self.rememberError("bytecode function call used the wrong number of arguments");
            return error.RuntimeFailure;
        }
        for (args, 0..) |arg, index| {
            if (function_decl.local_types[index].kind == .ffi_struct) {
                if (arg != .raw_ptr or arg.raw_ptr == 0) {
                    self.rememberFmt(
                        "struct argument requires a valid pointer (function={s}, arg={d}, tag={s})",
                        .{ function_decl.name, index, @tagName(arg) },
                    );
                    return error.RuntimeFailure;
                }
                const struct_mode = ownershipModeAt(function_decl.param_ownership, index);
                if (struct_mode == .borrow_read or struct_mode == .borrow_mut) {
                    // Alias the caller's struct: a `borrow mut` callee mutates it in place and
                    // the caller observes the change (matches the LLVM/native backend). The slot
                    // is non-owning, so it is not freed at frame exit — the caller still owns it.
                    self.setSlotBorrowed(&locals[index], &local_owned[index], arg);
                } else if (hooks.copy_struct_args_by_value) {
                    const type_name = function_decl.local_types[index].name orelse {
                        self.rememberError("struct local type is missing a name");
                        return error.RuntimeFailure;
                    };
                    const type_decl = helper_impl.findType(module, type_name) orelse {
                        self.rememberError("struct type could not be resolved");
                        return error.RuntimeFailure;
                    };
                    const dst_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(locals[index].raw_ptr);
                    const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(arg.raw_ptr);
                    try self.copyStruct(module, type_decl, dst_ptr, src_ptr);
                } else self.setSlotBorrowed(&locals[index], &local_owned[index], arg);
            } else {
                switch (ownershipModeAt(function_decl.param_ownership, index)) {
                    .owned, .move => self.setSlotOwned(&locals[index], &local_owned[index], arg),
                    .borrow_read, .borrow_mut, .copy => self.setSlotBorrowed(&locals[index], &local_owned[index], arg),
                }
            }
        }

        var pc: usize = 0;
        while (pc < function_decl.instructions.len) {
            const inst = function_decl.instructions[pc];
            switch (inst) {
                .const_int => |value| self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .integer = value.value }),
                .const_float => |value| self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .float = value.value }),
                .const_string => |value| self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .string = value.value }),
                .const_bool => |value| self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .boolean = value.value }),
                .const_null_ptr => |value| self.setSlotUnmanaged(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = 0 }),
                .const_function => |value| {
                    const raw_ptr = switch (value.representation) {
                        .callable_value => value.function_id,
                        .native_callback => if (hooks.resolve_function) |resolve_function|
                            try helper_impl.resolveFunctionPointer(hooks, resolve_function, value.function_id)
                        else
                            value.function_id,
                    };
                    runtime_abi.emitExecutionTrace("CALLABLE", "CONST_FUNCTION", "dst={d} fn={d} raw=0x{x} repr={s}", .{ value.dst, value.function_id, raw_ptr, @tagName(value.representation) });
                    self.setSlotUnmanaged(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = raw_ptr });
                },
                .const_closure => |value| {
                    const closure_ptr = try self.allocateClosure(registers, value.function_id, value.captures, value.capture_ownership);
                    runtime_abi.emitExecutionTrace("CALLABLE", "CONST_CLOSURE", "dst={d} fn={d} raw=0x{x} captures={d}", .{ value.dst, value.function_id, closure_ptr, value.captures.len });
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = closure_ptr });
                },
                .alloc_struct => |value| self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = try self.allocateStruct(module, value.type_name) }),
                .alloc_enum => |value| self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = try self.allocateEnum(value.enum_type_name, registers, value.discriminant, value.payload_src) }),
                .alloc_native_state => |value| {
                    const src_value = registers[value.src];
                    if (src_value != .raw_ptr or src_value.raw_ptr == 0) {
                        self.rememberError("nativeState requires a valid Kira struct value");
                        return error.RuntimeFailure;
                    }
                    self.setSlotUnmanaged(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = try self.allocateNativeState(module, value.type_name, value.type_id, src_value.raw_ptr) });
                },
                .alloc_array => |value| {
                    const len_value = registers[value.len];
                    if (len_value != .integer or len_value.integer < 0) {
                        self.rememberError("array allocation requires a non-negative integer length");
                        return error.RuntimeFailure;
                    }
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = try self.allocateArray(@intCast(len_value.integer)) });
                },
                .add => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try value_impl.addValues(self, lhs, rhs));
                },
                .subtract => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try value_impl.subtractValues(self, lhs, rhs));
                },
                .multiply => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try value_impl.multiplyValues(self, lhs, rhs));
                },
                .divide => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try value_impl.divideValues(self, lhs, rhs));
                },
                .modulo => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try value_impl.moduloValues(self, lhs, rhs));
                },
                .compare => |value| {
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .boolean = try value_impl.compareValues(self, registers[value.lhs], registers[value.rhs], value.op) });
                },
                .unary => |value| {
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try value_impl.unaryValue(self, registers[value.src], value.op));
                },
                .store_local => |value| {
                    if (register_owned[value.src]) {
                        self.transferSlot(
                            &locals[value.local],
                            &local_owned[value.local],
                            &registers[value.src],
                            &register_owned[value.src],
                        );
                    } else {
                        const local_type = if (value.local < function_decl.local_types.len)
                            function_decl.local_types[value.local]
                        else
                            bytecode.TypeRef{ .kind = .raw_ptr };
                        if (local_type.kind == .ffi_struct) {
                            const stored = try self.cloneBorrowedLocalValue(module, local_type, registers[value.src]);
                            self.setSlotOwned(&locals[value.local], &local_owned[value.local], stored);
                        } else {
                            self.setSlotBorrowed(&locals[value.local], &local_owned[value.local], registers[value.src]);
                        }
                    }
                },
                .load_local => |value| switch (value.ownership) {
                    .move, .owned => {
                        self.transferSlot(
                            &registers[value.dst],
                            &register_owned[value.dst],
                            &locals[value.local],
                            &local_owned[value.local],
                        );
                        if (value.local < function_decl.local_types.len) {
                            const local_ty = function_decl.local_types[value.local];
                            if (local_ty.kind == .ffi_struct and locals[value.local] == .void) {
                                const type_name = local_ty.name orelse {
                                    self.rememberError("moved struct local requires a named type");
                                    return error.RuntimeFailure;
                                };
                                self.setSlotOwned(
                                    &locals[value.local],
                                    &local_owned[value.local],
                                    .{ .raw_ptr = try self.allocateStruct(module, type_name) },
                                );
                            }
                        }
                    },
                    .borrow_read, .borrow_mut, .copy => self.setSlotBorrowed(&registers[value.dst], &register_owned[value.dst], locals[value.local]),
                },
                .local_ptr => |value| self.setSlotUnmanaged(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = @intFromPtr(&locals[value.local]) }),
                .subobject_ptr => |value| {
                    const base = registers[value.base];
                    if (base != .raw_ptr or base.raw_ptr == 0) {
                        self.rememberError("subobject access requires a valid struct pointer");
                        return error.RuntimeFailure;
                    }
                    const base_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(base.raw_ptr);
                    self.setSlotUnmanaged(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = @intFromPtr(base_ptr + value.offset) });
                },
                .field_ptr => |value| {
                    const base = registers[value.base];
                    if (base != .raw_ptr or base.raw_ptr == 0) {
                        self.rememberFmt(
                            "field access requires a valid struct pointer: {s}.{d}",
                            .{ value.base_type_name, value.field_index },
                        );
                        return error.RuntimeFailure;
                    }
                    const base_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(base.raw_ptr);
                    const field_index: usize = @intCast(value.field_index);
                    const slot_ptr = base_ptr + field_index;
                    if (value.field_ty.kind == .ffi_struct) {
                        if (slot_ptr[0] != .raw_ptr or slot_ptr[0].raw_ptr == 0) {
                            self.rememberError("nested struct field storage is invalid");
                            return error.RuntimeFailure;
                        }
                        self.setSlotBorrowed(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = slot_ptr[0].raw_ptr });
                    } else {
                        self.setSlotUnmanaged(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = @intFromPtr(slot_ptr) });
                    }
                },
                .recover_native_state => |value| {
                    const state_value = registers[value.state];
                    if (state_value != .raw_ptr or state_value.raw_ptr == 0) {
                        self.rememberError("nativeRecover requires a valid native state token");
                        return error.RuntimeFailure;
                    }
                    self.setSlotUnmanaged(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = try self.recoverNativeState(module, value.type_name, state_value.raw_ptr, value.type_id) });
                },
                .native_state_field_get => |value| {
                    const state_value = registers[value.state];
                    if (state_value != .raw_ptr or state_value.raw_ptr == 0) {
                        self.rememberError("native state field read requires a valid recovered state");
                        return error.RuntimeFailure;
                    }
                    const payload: [*]const runtime_abi.BridgeValue = @ptrFromInt(state_value.raw_ptr);
                    self.setSlotBorrowed(&registers[value.dst], &register_owned[value.dst], runtime_abi.bridgeValueToValue(payload[@intCast(value.field_index)]));
                    _ = value.field_ty;
                },
                .native_state_field_set => |value| {
                    const state_value = registers[value.state];
                    if (state_value != .raw_ptr or state_value.raw_ptr == 0) {
                        self.rememberError("native state field write requires a valid recovered state");
                        return error.RuntimeFailure;
                    }
                    const payload: [*]runtime_abi.BridgeValue = @ptrFromInt(state_value.raw_ptr);
                    const field_index: usize = @intCast(value.field_index);
                    const old = runtime_abi.bridgeValueToValue(payload[field_index]);
                    const stored = if (register_owned[value.src])
                        registers[value.src]
                    else
                        try self.cloneBorrowedValueForStore(module, value.field_ty, registers[value.src]);
                    payload[field_index] = runtime_abi.bridgeValueFromValue(stored);
                    if (register_owned[value.src]) {
                        register_owned[value.src] = false;
                        registers[value.src] = .{ .void = {} };
                    }
                    self.heap.dropValue(old);
                    _ = value.field_ty;
                },
                .c_string_to_string => |value| {
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try self.copyCString(registers[value.src]));
                },
                .array_len => |value| {
                    const array_value = registers[value.array];
                    if (array_value != .raw_ptr or array_value.raw_ptr == 0) {
                        self.rememberError("array length requires a valid array handle");
                        return error.RuntimeFailure;
                    }
                    const array_ptr: *const ArrayObject = @ptrFromInt(array_value.raw_ptr);
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .integer = @intCast(array_ptr.len) });
                },
                .string_len => |value| {
                    const string_value = registers[value.string];
                    if (string_value != .string) {
                        self.rememberError("string length requires a valid string value");
                        return error.RuntimeFailure;
                    }
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .integer = @intCast(string_value.string.len) });
                },
                .array_get => |value| {
                    const array_value = registers[value.array];
                    const index_value = registers[value.index];
                    if (array_value != .raw_ptr or array_value.raw_ptr == 0 or index_value != .integer or index_value.integer < 0) {
                        self.rememberError("array load requires a valid array handle and index");
                        return error.RuntimeFailure;
                    }
                    const array_ptr: *const ArrayObject = @ptrFromInt(array_value.raw_ptr);
                    const index: usize = @intCast(index_value.integer);
                    if (index >= array_ptr.len) {
                        self.rememberError("array index is out of bounds");
                        return error.RuntimeFailure;
                    }
                    const item_value = runtime_abi.bridgeValueToValue(array_ptr.items[index]);
                    if (value.ty.kind == .ffi_struct and item_value == .raw_ptr and item_value.raw_ptr != 0) {
                        const type_name = value.ty.name orelse {
                            self.rememberError("array element struct type is missing a name");
                            return error.RuntimeFailure;
                        };
                        const copied = if (self.isManagedStructPointer(item_value.raw_ptr))
                            try self.cloneStructValue(module, type_name, item_value.raw_ptr)
                        else
                            try self.copyStructFromNativeLayout(module, type_name, item_value.raw_ptr);
                        self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = copied });
                    } else {
                        self.setSlotBorrowed(&registers[value.dst], &register_owned[value.dst], item_value);
                    }
                },
                .array_set => |value| {
                    const array_value = registers[value.array];
                    const index_value = registers[value.index];
                    if (array_value != .raw_ptr or array_value.raw_ptr == 0 or index_value != .integer or index_value.integer < 0) {
                        self.rememberError("array store requires a valid array handle and index");
                        return error.RuntimeFailure;
                    }
                    const array_ptr: *ArrayObject = @ptrFromInt(array_value.raw_ptr);
                    const index: usize = @intCast(index_value.integer);
                    if (index >= array_ptr.len) {
                        self.rememberError("array index is out of bounds");
                        return error.RuntimeFailure;
                    }
                    const stored = if (register_owned[value.src])
                        registers[value.src]
                    else
                        try self.cloneBorrowedManagedValueDynamic(module, registers[value.src]);
                    self.heap.replaceArrayItem(&array_ptr.items[index], stored);
                    if (register_owned[value.src]) {
                        register_owned[value.src] = false;
                        registers[value.src] = .{ .void = {} };
                    }
                },
                .array_append => |value| {
                    const array_value = registers[value.array];
                    if (array_value != .raw_ptr or array_value.raw_ptr == 0) {
                        self.rememberError("array append requires a valid array handle");
                        return error.RuntimeFailure;
                    }
                    const array_ptr: *ArrayObject = @ptrFromInt(array_value.raw_ptr);
                    const stored = if (register_owned[value.src])
                        registers[value.src]
                    else
                        try self.cloneBorrowedManagedValueDynamic(module, registers[value.src]);
                    try self.heap.appendArrayItem(array_ptr, stored);
                    if (register_owned[value.src]) {
                        register_owned[value.src] = false;
                        registers[value.src] = .{ .void = {} };
                    }
                },
                .enum_tag => |value| {
                    const enum_value = registers[value.src];
                    if (enum_value != .raw_ptr or enum_value.raw_ptr == 0) {
                        self.rememberError("enum tag access requires a valid enum value");
                        return error.RuntimeFailure;
                    }
                    if (!self.isManagedStructPointer(enum_value.raw_ptr)) {
                        const native_words: [*]const u64 = @ptrFromInt(enum_value.raw_ptr);
                        if (native_words[0] > std.math.maxInt(i64)) {
                            self.rememberFmt(
                                "native enum tag is out of range: ptr=0x{x} tag={d}",
                                .{ enum_value.raw_ptr, native_words[0] },
                            );
                            return error.RuntimeFailure;
                        }
                        self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .integer = @intCast(native_words[0]) });
                        continue;
                    }
                    const enum_ptr: [*]align(1) const runtime_abi.Value = @ptrFromInt(enum_value.raw_ptr);
                    if (enum_ptr[0] != .integer) {
                        self.rememberError("enum tag slot is not an integer");
                        return error.RuntimeFailure;
                    }
                    self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], enum_ptr[0]);
                },
                .enum_payload => |value| {
                    const enum_value = registers[value.src];
                    if (enum_value != .raw_ptr or enum_value.raw_ptr == 0) {
                        self.rememberError("enum payload access requires a valid enum value");
                        return error.RuntimeFailure;
                    }
                    if (!self.isManagedStructPointer(enum_value.raw_ptr)) {
                        const native_words: [*]const u64 = @ptrFromInt(enum_value.raw_ptr);
                        const payload = try self.enumPayloadFromNativeWord(module, value.payload_ty, native_words[1]);
                        self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], payload);
                        continue;
                    }
                    const enum_ptr: [*]align(1) const runtime_abi.Value = @ptrFromInt(enum_value.raw_ptr);
                    self.setSlotBorrowed(&registers[value.dst], &register_owned[value.dst], enum_ptr[1]);
                    _ = value.payload_ty;
                },
                .load_indirect => |value| {
                    const ptr = registers[value.ptr];
                    if (ptr != .raw_ptr or ptr.raw_ptr == 0) {
                        self.rememberError("indirect load requires a valid pointer");
                        return error.RuntimeFailure;
                    }
                    if (value.ty.kind == .ffi_struct) {
                        const type_name = value.ty.name orelse {
                            self.rememberError("struct load type is missing a name");
                            return error.RuntimeFailure;
                        };
                        const src_ptr = try self.resolveStructValuePointer(type_name, ptr.raw_ptr);
                        self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], .{ .raw_ptr = if (src_ptr == 0) 0 else try self.cloneStructValue(module, type_name, src_ptr) });
                    } else if (value.ty.kind == .enum_instance) {
                        const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr.raw_ptr);
                        const enum_name = value.ty.name orelse {
                            self.rememberError("enum load type is missing a name");
                            return error.RuntimeFailure;
                        };
                        self.setSlotOwned(&registers[value.dst], &register_owned[value.dst], try self.cloneEnumValue(module, enum_name, slot_ptr.*));
                    } else {
                        const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr.raw_ptr);
                        self.setSlotBorrowed(&registers[value.dst], &register_owned[value.dst], slot_ptr.*);
                    }
                },
                .store_indirect => |value| {
                    const ptr = registers[value.ptr];
                    if (ptr != .raw_ptr or ptr.raw_ptr == 0) {
                        self.rememberError("indirect store requires a valid pointer");
                        return error.RuntimeFailure;
                    }
                    if (value.ty.kind == .ffi_struct) {
                        const type_name = value.ty.name orelse {
                            self.rememberError("struct store type is missing a name");
                            return error.RuntimeFailure;
                        };
                        const dst_ptr = try self.ensureStructDestinationPointer(module, type_name, ptr.raw_ptr);
                        try self.copyStructValueInto(module, type_name, dst_ptr, registers[value.src]);
                    } else {
                        const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr.raw_ptr);
                        const stored = if (register_owned[value.src])
                            registers[value.src]
                        else
                            try self.cloneBorrowedValueForStore(module, value.ty, registers[value.src]);
                        self.heap.assignTransferred(slot_ptr, stored);
                        if (register_owned[value.src]) {
                            register_owned[value.src] = false;
                            registers[value.src] = .{ .void = {} };
                        }
                    }
                },
                .copy_indirect => |value| {
                    const dst_ptr_value = registers[value.dst_ptr];
                    const src_ptr_value = registers[value.src_ptr];
                    if (dst_ptr_value != .raw_ptr or src_ptr_value != .raw_ptr or dst_ptr_value.raw_ptr == 0 or src_ptr_value.raw_ptr == 0) {
                        self.rememberFmt(
                            "struct copy requires valid pointers: {s} dst_ok={d} src_ok={d}",
                            .{
                                value.type_name,
                                if (dst_ptr_value == .raw_ptr and dst_ptr_value.raw_ptr != 0) @as(u8, 1) else @as(u8, 0),
                                if (src_ptr_value == .raw_ptr and src_ptr_value.raw_ptr != 0) @as(u8, 1) else @as(u8, 0),
                            },
                        );
                        return error.RuntimeFailure;
                    }
                    const dst_ptr = try self.ensureStructDestinationPointer(module, value.type_name, dst_ptr_value.raw_ptr);
                    const src_ptr = try self.resolveStructValuePointer(value.type_name, src_ptr_value.raw_ptr);
                    try self.copyStructValueInto(module, value.type_name, dst_ptr, .{ .raw_ptr = src_ptr });
                },
                .branch => |value| {
                    const condition = registers[value.condition];
                    if (condition != .boolean) {
                        self.rememberError("vm branch expects a boolean condition");
                        return error.RuntimeFailure;
                    }
                    pc = try helper_impl.resolveLabelOffset(label_offsets, if (condition.boolean) value.true_label else value.false_label);
                    continue;
                },
                .jump => |value| {
                    pc = try helper_impl.resolveLabelOffset(label_offsets, value.label);
                    continue;
                },
                .label => {},
                .print => |value| try builtins.printValue(writer, module, registers[value.src], value.ty),
                .call_runtime => |value| {
                    const callee = module.findFunctionById(value.function_id) orelse {
                        self.rememberError("bytecode function id is out of range");
                        return error.RuntimeFailure;
                    };
                    const call_args = try self.collectTransferredArgs(registers, register_owned, value.args, callee.param_ownership);
                    defer self.allocator.free(call_args);
                    const result = try self.runFunction(module, callee, call_args, writer, hooks);
                    if (value.dst) |dst| self.setSlotOwned(&registers[dst], &register_owned[dst], result) else self.heap.dropValue(result);
                },
                .call_native => |value| {
                    const callback = hooks.call_native orelse {
                        self.rememberError("vm native bridge was not installed");
                        return error.RuntimeFailure;
                    };
                    const call_args = try helper_impl.collectArgs(self.allocator, registers, value.args);
                    defer self.allocator.free(call_args);
                    var result = try callback(hooks.context, value.function_id, call_args);
                    result = try self.materializeNativeResult(module, value.return_ty, result);
                    if (value.dst) |dst| self.setSlotOwned(&registers[dst], &register_owned[dst], result) else self.heap.dropValue(result);
                },
                .call_virtual => |value| {
                    const receiver_value = registers[value.receiver];
                    if (receiver_value != .raw_ptr or receiver_value.raw_ptr == 0) {
                        self.rememberError("virtual method call requires a valid class receiver");
                        return error.RuntimeFailure;
                    }
                    const actual_type_name = self.heap.getStructTypeName(receiver_value.raw_ptr) orelse value.static_type_name;
                    const resolved_method = self.resolveVirtualMethod(module, actual_type_name, value.method_name) orelse {
                        self.rememberError("virtual method could not be resolved on the concrete receiver type");
                        return error.RuntimeFailure;
                    };
                    const adjusted_receiver = if (resolved_method.receiver_offset == 0)
                        receiver_value.raw_ptr
                    else
                        @intFromPtr((@as([*]align(1) runtime_abi.Value, @ptrFromInt(receiver_value.raw_ptr)) + resolved_method.receiver_offset));
                    const explicit_args = try helper_impl.collectArgs(self.allocator, registers, value.args);
                    defer self.allocator.free(explicit_args);
                    var call_args = try self.allocator.alloc(runtime_abi.Value, explicit_args.len + 1);
                    defer self.allocator.free(call_args);
                    call_args[0] = .{ .raw_ptr = adjusted_receiver };
                    @memcpy(call_args[1..], explicit_args);

                    const result = if (module.findFunctionById(resolved_method.function_id) != null)
                        try self.runFunctionById(module, resolved_method.function_id, call_args, writer, hooks)
                    else native_result: {
                        const callback = hooks.call_native orelse {
                            self.rememberError("vm native bridge was not installed");
                            return error.RuntimeFailure;
                        };
                        var native_value = try callback(hooks.context, resolved_method.function_id, call_args);
                        native_value = try self.materializeNativeResult(module, value.return_ty, native_value);
                        break :native_result native_value;
                    };
                    if (value.dst) |dst| self.setSlotOwned(&registers[dst], &register_owned[dst], result) else self.heap.dropValue(result);
                },
                .call_value => |value| {
                    const callee_value = registers[value.callee];
                    if (callee_value != .raw_ptr) {
                        self.rememberFmt(
                            "indirect call requires a callable function value (callee_register={d}, tag={s})",
                            .{ value.callee, @tagName(callee_value) },
                        );
                        return error.RuntimeFailure;
                    }
                    const call_args = try self.collectTransferredArgs(registers, register_owned, value.args, value.param_ownership);
                    defer self.allocator.free(call_args);
                    const result = if (self.heap.getClosure(callee_value.raw_ptr)) |closure| closure_call: {
                        runtime_abi.emitExecutionTrace("CALLABLE", "INVOKE_CLOSURE", "raw=0x{x} fn={d} captures={d}", .{ callee_value.raw_ptr, closure.function_id, closure.captures.len });
                        var closure_args = try self.allocator.alloc(runtime_abi.Value, call_args.len + closure.captures.len);
                        defer self.allocator.free(closure_args);
                        @memcpy(closure_args[0..call_args.len], call_args);
                        @memcpy(closure_args[call_args.len..], closure.captures);
                        if (!closure.is_native) {
                            break :closure_call try self.runFunctionById(module, closure.function_id, closure_args, writer, hooks);
                        }
                        const callback = hooks.call_native orelse {
                            self.rememberError("native closure call requires a native call hook");
                            return error.RuntimeFailure;
                        };
                        break :closure_call try callback(hooks.context, closure.function_id, closure_args);
                    } else if (callee_value.raw_ptr <= std.math.maxInt(u32)) direct: {
                        const function_id: u32 = @intCast(callee_value.raw_ptr);
                        if (module.findFunctionById(function_id) != null) {
                            break :direct try self.runFunctionById(module, function_id, call_args, writer, hooks);
                        }
                        const callback = hooks.call_native orelse {
                            self.rememberError("vm native bridge was not installed");
                            return error.RuntimeFailure;
                        };
                        break :direct try callback(hooks.context, function_id, call_args);
                    } else {
                        self.rememberError("indirect call received an unmanaged raw pointer that is not a runtime closure");
                        return error.RuntimeFailure;
                    };
                    if (value.dst) |dst| self.setSlotOwned(&registers[dst], &register_owned[dst], result) else self.heap.dropValue(result);
                },
                .ret => |value| {
                    const result = if (value.src) |src| registers[src] else runtime_abi.Value{ .void = {} };
                    if (value.src) |src| {
                        if (register_owned[src]) {
                            register_owned[src] = false;
                            registers[src] = .{ .void = {} };
                        }
                    }
                    return result;
                },
            }
            pc += 1;
        }
        return .{ .void = {} };
    }

    pub fn rememberError(self: *Vm, message: []const u8) void {
        const length = @min(message.len, self.last_error_buffer.len);
        @memcpy(self.last_error_buffer[0..length], message[0..length]);
        self.last_error_len = length;
    }

    fn rememberFmt(self: *Vm, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.bufPrint(&self.last_error_buffer, fmt, args) catch {
            self.last_error_len = 0;
            return;
        };
        self.last_error_len = message.len;
    }

    fn setSlotOwned(self: *Vm, slot: *runtime_abi.Value, owned: *bool, value: runtime_abi.Value) void {
        const old = slot.*;
        const old_owned = owned.*;
        slot.* = value;
        owned.* = self.heap.isManagedValue(value);
        if (old_owned) self.heap.dropValue(old);
    }

    fn setSlotBorrowed(self: *Vm, slot: *runtime_abi.Value, owned: *bool, value: runtime_abi.Value) void {
        const old = slot.*;
        const old_owned = owned.*;
        slot.* = value;
        owned.* = false;
        if (old_owned) self.heap.dropValue(old);
    }

    fn setSlotUnmanaged(self: *Vm, slot: *runtime_abi.Value, owned: *bool, value: runtime_abi.Value) void {
        const old = slot.*;
        const old_owned = owned.*;
        slot.* = value;
        owned.* = false;
        if (old_owned) self.heap.dropValue(old);
    }

    fn transferSlot(
        self: *Vm,
        dst: *runtime_abi.Value,
        dst_owned: *bool,
        src: *runtime_abi.Value,
        src_owned: *bool,
    ) void {
        const old = dst.*;
        const old_owned = dst_owned.*;
        dst.* = src.*;
        dst_owned.* = src_owned.*;
        if (src_owned.*) {
            src.* = .{ .void = {} };
            src_owned.* = false;
        }
        if (old_owned) self.heap.dropValue(old);
    }

    fn collectTransferredArgs(
        self: *Vm,
        registers: []runtime_abi.Value,
        register_owned: []bool,
        argument_registers: []const u32,
        param_ownership: []const bytecode.OwnershipMode,
    ) ![]runtime_abi.Value {
        const values = try self.allocator.alloc(runtime_abi.Value, argument_registers.len);
        for (argument_registers, 0..) |register_index, index| {
            values[index] = registers[register_index];
            switch (ownershipModeAt(param_ownership, index)) {
                .owned, .move => {
                    if (register_owned[register_index]) {
                        register_owned[register_index] = false;
                        registers[register_index] = .{ .void = {} };
                    }
                },
                .borrow_read, .borrow_mut, .copy => {},
            }
        }
        return values;
    }

    fn ownershipModeAt(values: []const bytecode.OwnershipMode, index: usize) bytecode.OwnershipMode {
        if (index < values.len) return values[index];
        return .owned;
    }

    fn releaseTrackedSlots(self: *Vm, slots: []runtime_abi.Value, owned: []const bool) void {
        for (slots, owned) |slot, is_owned| if (is_owned) self.heap.dropValue(slot);
    }

    fn copyCString(self: *Vm, value: runtime_abi.Value) !runtime_abi.Value {
        if (value != .raw_ptr or value.raw_ptr == 0) return .{ .string = "" };
        const source: [*:0]const u8 = @ptrFromInt(value.raw_ptr);
        const bytes = std.mem.span(source);
        if (bytes.len == 0) return .{ .string = "" };
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        try self.heap.registerString(owned);
        return .{ .string = owned };
    }

    fn allocateClosure(
        self: *Vm,
        registers: []const runtime_abi.Value,
        function_id: u32,
        capture_registers: []const u32,
        capture_ownership: []const bytecode.OwnershipMode,
    ) !usize {
        const closure = try self.allocator.create(ClosureObject);
        const captures = try self.allocator.alloc(runtime_abi.Value, capture_registers.len);
        for (captures) |*capture| capture.* = .{ .void = {} };
        for (capture_registers, 0..) |reg, index| {
            switch (captureOwnershipAt(capture_ownership, index)) {
                .owned, .move, .copy => self.heap.assignTransferred(&captures[index], registers[reg]),
                .borrow_read, .borrow_mut => self.heap.assignBorrowed(&captures[index], registers[reg]),
            }
        }
        closure.* = .{ .function_id = function_id, .captures = captures };
        return self.heap.registerClosure(closure);
    }

    fn captureOwnershipAt(capture_ownership: []const bytecode.OwnershipMode, index: usize) bytecode.OwnershipMode {
        if (index < capture_ownership.len) return capture_ownership[index];
        return .borrow_read;
    }

    fn allocateStruct(self: *Vm, module: *const bytecode.Module, type_name: []const u8) !usize {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const fields = try self.allocator.alloc(runtime_abi.Value, type_decl.fields.len);
        for (type_decl.fields, 0..) |field_decl, index| {
            fields[index] = try self.zeroValueForType(module, field_decl.ty);
        }
        return self.heap.registerStruct(type_name, fields);
    }

    fn allocateNativeState(self: *Vm, module: *const bytecode.Module, type_name: []const u8, type_id: u64, src_payload: usize) !usize {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("native state type could not be resolved");
            return error.RuntimeFailure;
        };
        const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(src_payload);
        const native_payload = try self.allocator.alloc(runtime_abi.BridgeValue, type_decl.fields.len);
        for (type_decl.fields, 0..) |field_decl, index| {
            const native_value = try self.preserveNativeStateValue(module, field_decl.ty, src_ptr[index]);
            native_payload[index] = runtime_abi.bridgeValueFromValue(native_value);
        }

        const box = try self.allocator.create(NativeStateBox);
        box.* = .{
            .type_id = type_id,
            .payload = @intFromPtr(native_payload.ptr),
            .runtime_payload = 0,
        };
        return @intFromPtr(box);
    }

    fn recoverNativeState(self: *Vm, module: *const bytecode.Module, type_name: []const u8, state_token: usize, expected_type_id: u64) !usize {
        self.native_layout_stats.native_state_recovers += 1;
        const box: *NativeStateBox = @ptrFromInt(state_token);
        if (box.type_id != expected_type_id) {
            self.rememberError("nativeRecover used a userdata token for the wrong state type");
            return error.RuntimeFailure;
        }
        if (box.runtime_payload == 0 and box.payload != 0) {
            self.native_layout_stats.native_state_materializations += 1;
            const result = try self.native_state_materialized_types.getOrPut(type_name);
            if (!result.found_existing) result.value_ptr.* = 0;
            result.value_ptr.* += 1;
            box.runtime_payload = try self.materializeNativeStatePayload(module, type_name, box.payload);
            self.destroyNativeStatePayload(module, type_name, box.payload);
            box.payload = 0;
        }
        if (box.runtime_payload == 0) {
            self.rememberError("nativeRecover used a userdata token with no state payload");
            return error.RuntimeFailure;
        }
        return box.runtime_payload;
    }

    fn materializeNativeStatePayload(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_payload_ptr: usize) !usize {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("native state type could not be resolved");
            return error.RuntimeFailure;
        };
        const native_payload: [*]const runtime_abi.BridgeValue = @ptrFromInt(native_payload_ptr);
        const runtime_payload = try self.allocator.alloc(runtime_abi.BridgeValue, type_decl.fields.len);
        for (type_decl.fields, 0..) |field_decl, index| {
            const value = try self.materializeNativeStateValue(module, field_decl.ty, runtime_abi.bridgeValueToValue(native_payload[index]));
            runtime_payload[index] = runtime_abi.bridgeValueFromValue(value);
        }
        return @intFromPtr(runtime_payload.ptr);
    }

    fn preserveNativeStateValue(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) !runtime_abi.Value {
        return switch (ty.kind) {
            .ffi_struct, .array, .enum_instance, .construct_any, .raw_ptr => try self.copyValueToNativeLayout(module, ty, value),
            else => value,
        };
    }

    fn materializeNativeStateValue(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) !runtime_abi.Value {
        return switch (ty.kind) {
            .ffi_struct, .array, .enum_instance, .construct_any => try self.copyValueFromNativeLayout(module, ty, value),
            .raw_ptr => try self.materializeCallbackValueFromNative(module, ty, value),
            else => value,
        };
    }

    fn destroyNativeStatePayload(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_payload_ptr: usize) void {
        if (native_payload_ptr == 0) return;
        const type_decl = helper_impl.findType(module, type_name) orelse return;
        const native_payload: [*]const runtime_abi.BridgeValue = @ptrFromInt(native_payload_ptr);
        for (type_decl.fields, 0..) |field_decl, index| {
            self.destroyPreservedNativeStateValue(module, field_decl.ty, runtime_abi.bridgeValueToValue(native_payload[index]));
        }
        self.allocator.free(native_payload[0..type_decl.fields.len]);
    }

    fn destroyPreservedNativeStateValue(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) void {
        switch (ty.kind) {
            .ffi_struct => {
                if (value != .raw_ptr or value.raw_ptr == 0) return;
                self.destroyStructNativeLayout(module, ty.name orelse return, value.raw_ptr);
            },
            .array => {
                if (value != .raw_ptr or value.raw_ptr == 0) return;
                self.destroyArrayNativeLayout(module, ty, value.raw_ptr);
            },
            .enum_instance => {
                if (value != .raw_ptr or value.raw_ptr == 0) return;
                self.destroyEnumNativeLayout(module, ty.name orelse return, value.raw_ptr);
            },
            .construct_any => self.heap.dropValue(value),
            else => {},
        }
    }

    fn zeroValueForType(self: *Vm, module: *const bytecode.Module, value_type: bytecode.TypeRef) anyerror!runtime_abi.Value {
        return switch (value_type.kind) {
            .void => .{ .void = {} },
            .integer => .{ .integer = 0 },
            .float => .{ .float = 0.0 },
            .string => .{ .string = "" },
            .boolean => .{ .boolean = false },
            .construct_any, .array, .raw_ptr, .enum_instance => .{ .raw_ptr = 0 },
            .ffi_struct => blk: {
                const nested_name = value_type.name orelse {
                    self.rememberError("struct field type is missing a name");
                    return error.RuntimeFailure;
                };
                break :blk .{ .raw_ptr = try self.allocateStruct(module, nested_name) };
            },
        };
    }

    fn allocateArray(self: *Vm, len: usize) !usize {
        const object = try self.allocator.create(ArrayObject);
        const items = try self.allocator.alloc(runtime_abi.BridgeValue, if (len == 0) 1 else len);
        for (items) |*item| item.* = runtime_abi.bridgeValueFromValue(.{ .void = {} });
        object.* = .{
            .len = len,
            .items = items.ptr,
        };
        return self.heap.registerArray(object);
    }

    fn arrayElementType(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef) !bytecode.TypeRef {
        _ = self;
        const name = array_ty.name orelse return .{ .kind = .raw_ptr };
        return resolveTypeText(module, name);
    }

    fn copyValueToNativeLayout(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) anyerror!runtime_abi.Value {
        return switch (ty.kind) {
            .ffi_struct => blk: {
                if (value != .raw_ptr or value.raw_ptr == 0) break :blk .{ .raw_ptr = 0 };
                break :blk .{ .raw_ptr = try self.copyStructToNativeLayout(module, ty.name orelse {
                    self.rememberError("array element struct type is missing a name");
                    return error.RuntimeFailure;
                }, value.raw_ptr) };
            },
            .array => blk: {
                if (value != .raw_ptr or value.raw_ptr == 0) break :blk .{ .raw_ptr = 0 };
                break :blk .{ .raw_ptr = try self.copyArrayToNativeLayout(module, ty, value.raw_ptr) };
            },
            .enum_instance => blk: {
                if (value != .raw_ptr or value.raw_ptr == 0) break :blk .{ .raw_ptr = 0 };
                break :blk .{ .raw_ptr = try self.copyEnumToNativeLayout(module, ty.name orelse {
                    self.rememberError("enum type is missing a name");
                    return error.RuntimeFailure;
                }, value.raw_ptr) };
            },
            .construct_any => blk: {
                break :blk value;
            },
            .raw_ptr => blk: {
                if (ty.name) |name| {
                    if (isCallbackTypeName(name) and value == .raw_ptr and value.raw_ptr != 0 and self.heap.getClosure(value.raw_ptr) != null) {
                        break :blk .{ .raw_ptr = try self.exportRuntimeClosureToNative(module, value.raw_ptr) };
                    }
                }
                break :blk value;
            },
            else => value,
        };
    }

    fn resolveTypeText(module: *const bytecode.Module, text: []const u8) bytecode.TypeRef {
        if (std.mem.eql(u8, text, "Void")) return .{ .kind = .void };
        if (std.mem.eql(u8, text, "Bool")) return .{ .kind = .boolean, .name = "Bool" };
        if (std.mem.eql(u8, text, "String")) return .{ .kind = .string };
        if (std.mem.eql(u8, text, "Float") or std.mem.eql(u8, text, "F64")) return .{ .kind = .float, .name = "F64" };
        if (std.mem.eql(u8, text, "F32")) return .{ .kind = .float, .name = "F32" };
        if (std.mem.eql(u8, text, "Int") or std.mem.eql(u8, text, "I64")) return .{ .kind = .integer, .name = "I64" };
        if (std.mem.eql(u8, text, "I8") or std.mem.eql(u8, text, "I16") or std.mem.eql(u8, text, "I32") or
            std.mem.eql(u8, text, "U8") or std.mem.eql(u8, text, "U16") or std.mem.eql(u8, text, "U32"))
        {
            return .{ .kind = .integer, .name = text };
        }
        if (std.mem.eql(u8, text, "RawPtr") or std.mem.endsWith(u8, text, "_ptr")) return .{ .kind = .raw_ptr, .name = text };
        if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') return .{ .kind = .array, .name = text[1 .. text.len - 1] };
        if (helper_impl.findType(module, text) != null) return .{ .kind = .ffi_struct, .name = text };
        for (module.enums) |enum_decl| {
            if (std.mem.eql(u8, enum_decl.name, text)) return .{ .kind = .enum_instance, .name = text };
        }
        return .{ .kind = .raw_ptr, .name = text };
    }

    fn copyValueFromNativeLayout(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) anyerror!runtime_abi.Value {
        return switch (ty.kind) {
            .ffi_struct => blk: {
                if (value != .raw_ptr or value.raw_ptr == 0) break :blk .{ .raw_ptr = 0 };
                break :blk .{ .raw_ptr = try self.copyStructFromNativeLayout(module, ty.name orelse {
                    self.rememberError("array element struct type is missing a name");
                    return error.RuntimeFailure;
                }, value.raw_ptr) };
            },
            .array => blk: {
                if (value != .raw_ptr or value.raw_ptr == 0) break :blk .{ .raw_ptr = 0 };
                break :blk .{ .raw_ptr = try self.copyArrayFromNativeLayout(module, ty, value.raw_ptr) };
            },
            .enum_instance => blk: {
                if (value != .raw_ptr or value.raw_ptr == 0) break :blk .{ .raw_ptr = 0 };
                break :blk .{ .raw_ptr = try self.copyEnumFromNativeLayout(module, ty.name orelse {
                    self.rememberError("enum type is missing a name");
                    return error.RuntimeFailure;
                }, value.raw_ptr) };
            },
            .construct_any => blk: {
                break :blk value;
            },
            .raw_ptr => try self.materializeCallbackValueFromNative(module, ty, value),
            else => value,
        };
    }

    pub fn materializeCallbackValueFromNative(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) anyerror!runtime_abi.Value {
        if (ty.kind != .raw_ptr) return value;
        const name = ty.name orelse return value;
        if (!isCallbackTypeName(name)) return value;
        if (value != .raw_ptr or value.raw_ptr == 0) return value;
        if (self.heap.getClosure(value.raw_ptr) != null) return value;
        if (!runtime_abi.isTaggedNativeClosurePointer(value.raw_ptr)) return value;
        return .{ .raw_ptr = try self.materializeNativeClosure(module, value.raw_ptr, null) };
    }

    pub fn exportRuntimeClosureToNative(self: *Vm, module: *const bytecode.Module, closure_ptr: usize) !usize {
        if (self.exported_native_closures.get(closure_ptr)) |existing| {
            return runtime_abi.tagNativeClosurePointer(existing.native_ptr);
        }

        const closure = self.heap.getClosure(closure_ptr) orelse {
            self.rememberError("callback value is not a valid runtime closure");
            return error.RuntimeFailure;
        };
        const function_decl = module.findFunctionById(closure.function_id) orelse {
            self.rememberError("runtime closure function could not be resolved");
            return error.RuntimeFailure;
        };
        if (closure.captures.len > function_decl.param_count) {
            self.rememberError("runtime closure capture metadata is inconsistent");
            return error.RuntimeFailure;
        }

        const param_count: usize = function_decl.param_count;
        const capture_types = function_decl.local_types[param_count - closure.captures.len .. param_count];
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
            const lowered = try self.copyValueToNativeLayout(module, capture_types[index], capture);
            retained_captures[index] = lowered;
            slots[index] = runtime_abi.bridgeValueFromValue(lowered);
        }

        try self.exported_native_closures.put(closure_ptr, .{
            .native_ptr = raw_ptr,
            .captures = retained_captures,
        });
        return runtime_abi.tagNativeClosurePointer(raw_ptr);
    }

    fn allocateEnum(self: *Vm, enum_type_name: []const u8, registers: []const runtime_abi.Value, discriminant: u32, payload_src: ?u32) !usize {
        const slots = try self.allocator.alloc(runtime_abi.Value, 2);
        slots[0] = .{ .integer = @as(i64, @intCast(discriminant)) };
        slots[1] = if (payload_src) |src| registers[src] else .{ .void = {} };
        return self.heap.registerStruct(enum_type_name, slots);
    }

    fn typeFieldCount(self: *Vm, module: *const bytecode.Module, type_name: []const u8) ?usize {
        _ = self;
        const type_decl = helper_impl.findType(module, type_name) orelse return null;
        return type_decl.fields.len;
    }

    fn managedStructTypeName(self: *Vm, ptr: usize) ?[]const u8 {
        return self.heap.getStructTypeName(ptr);
    }

    fn isManagedStructPointer(self: *Vm, ptr: usize) bool {
        return self.managedStructTypeName(ptr) != null;
    }

    fn isCallbackTypeName(name: []const u8) bool {
        return std.mem.indexOf(u8, name, "->") != null;
    }

    fn resolveStructValuePointer(self: *Vm, expected_type_name: []const u8, ptr: usize) !usize {
        if (ptr == 0) {
            self.rememberError("struct value pointer is null");
            return error.RuntimeFailure;
        }
        if (self.isManagedStructPointer(ptr)) return ptr;
        _ = expected_type_name;

        const slot_ptr: *const runtime_abi.Value = @ptrFromInt(ptr);
        const value = slot_ptr.*;
        if (value != .raw_ptr) {
            // Some lowered paths hand us a direct pointer to inline struct field storage
            // instead of a slot containing a managed struct pointer. Treat that as an
            // already-resolved struct pointer and let downstream field access validate it.
            return ptr;
        }
        if (value.raw_ptr == 0) return 0;
        if (!self.isManagedStructPointer(value.raw_ptr)) {
            self.rememberError("struct pointer slot does not contain a managed struct value");
            return error.RuntimeFailure;
        }
        return value.raw_ptr;
    }

    fn ensureStructDestinationPointer(self: *Vm, module: *const bytecode.Module, expected_type_name: []const u8, ptr: usize) !usize {
        if (ptr == 0) {
            self.rememberError("struct destination pointer is null");
            return error.RuntimeFailure;
        }
        if (self.isManagedStructPointer(ptr)) return ptr;
        if (self.managedStructTypeName(ptr)) |_| {
            self.rememberError("struct destination type does not match the expected type");
            return error.RuntimeFailure;
        }

        const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr);
        if (slot_ptr.* == .raw_ptr and slot_ptr.raw_ptr != 0) {
            if (!self.isManagedStructPointer(slot_ptr.raw_ptr)) {
                self.rememberError("struct destination slot does not contain a managed struct value");
                return error.RuntimeFailure;
            }
            return slot_ptr.raw_ptr;
        }

        const old = slot_ptr.*;
        slot_ptr.* = .{ .raw_ptr = try self.allocateStruct(module, expected_type_name) };
        self.heap.dropValue(old);
        return slot_ptr.raw_ptr;
    }

    fn copyStructValueInto(
        self: *Vm,
        module: *const bytecode.Module,
        type_name: []const u8,
        dst_raw_ptr: usize,
        src_value: runtime_abi.Value,
    ) !void {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const dst_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(dst_raw_ptr);
        if (src_value == .raw_ptr and src_value.raw_ptr != 0) {
            if (self.isManagedStructPointer(src_value.raw_ptr)) {
                const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(src_value.raw_ptr);
                try self.copyStruct(module, type_decl, dst_ptr, src_ptr);
            } else {
                try self.copyStructFromNativeLayoutInto(module, type_name, dst_raw_ptr, src_value.raw_ptr);
            }
            return;
        }
        if (src_value == .raw_ptr and src_value.raw_ptr == 0) {
            const default_ptr = try self.allocateStruct(module, type_name);
            defer self.heap.dropValue(.{ .raw_ptr = default_ptr });
            const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(default_ptr);
            try self.copyStruct(module, type_decl, dst_ptr, src_ptr);
            return;
        }
        self.rememberError("struct copy source must be a struct value");
        return error.RuntimeFailure;
    }

    fn cloneStructValue(self: *Vm, module: *const bytecode.Module, type_name: []const u8, src_raw_ptr: usize) !usize {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const fresh = try self.allocateStruct(module, type_name);
        errdefer self.heap.dropValue(.{ .raw_ptr = fresh });
        const dst_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(fresh);
        const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(src_raw_ptr);
        try self.copyStruct(module, type_decl, dst_ptr, src_ptr);
        return fresh;
    }

    fn cloneBorrowedValueForStore(
        self: *Vm,
        module: *const bytecode.Module,
        value_type: bytecode.TypeRef,
        value: runtime_abi.Value,
    ) anyerror!runtime_abi.Value {
        if (!self.heap.isManagedValue(value)) return value;
        return switch (value_type.kind) {
            .array => try self.cloneArrayValueDeep(module, try self.arrayElementType(module, value_type), value),
            .enum_instance => try self.cloneEnumValue(module, value_type.name orelse {
                self.rememberError("enum store type is missing a name");
                return error.RuntimeFailure;
            }, value),
            .ffi_struct => blk: {
                if (value != .raw_ptr or value.raw_ptr == 0) break :blk value;
                const type_name = value_type.name orelse {
                    self.rememberError("struct store type is missing a name");
                    return error.RuntimeFailure;
                };
                const copied = if (self.isManagedStructPointer(value.raw_ptr))
                    try self.cloneStructValue(module, type_name, value.raw_ptr)
                else
                    try self.copyStructFromNativeLayout(module, type_name, value.raw_ptr);
                break :blk runtime_abi.Value{ .raw_ptr = copied };
            },
            .string => if (value.string.len == 0) value else blk: {
                const owned = try self.allocator.dupe(u8, value.string);
                errdefer self.allocator.free(owned);
                try self.heap.registerString(owned);
                break :blk runtime_abi.Value{ .string = owned };
            },
            .raw_ptr => blk: {
                const name = value_type.name orelse break :blk value;
                if (!isCallbackTypeName(name) or value != .raw_ptr or value.raw_ptr == 0) break :blk value;
                break :blk runtime_abi.Value{ .raw_ptr = try self.cloneClosureValue(module, value.raw_ptr) };
            },
            else => value,
        };
    }

    fn cloneClosureValue(self: *Vm, module: *const bytecode.Module, closure_ptr: usize) anyerror!usize {
        const source = self.heap.getClosure(closure_ptr) orelse {
            self.rememberError("callback store source is not a valid closure");
            return error.RuntimeFailure;
        };
        const captures = try self.allocator.alloc(runtime_abi.Value, source.captures.len);
        for (captures) |*capture| capture.* = .{ .void = {} };
        var initialized: usize = 0;
        errdefer {
            self.heap.dropSlots(captures[0..initialized]);
            self.allocator.free(captures);
        }

        const function_decl = module.findFunctionById(source.function_id);
        const capture_types = if (function_decl) |decl| blk: {
            if (source.captures.len > decl.param_count) {
                self.rememberError("closure capture metadata is inconsistent");
                return error.RuntimeFailure;
            }
            const start = decl.param_count - source.captures.len;
            break :blk decl.local_types[start..decl.param_count];
        } else null;

        for (source.captures, 0..) |capture, index| {
            const cloned = if (capture_types) |types|
                try self.cloneBorrowedValueForStore(module, types[index], capture)
            else
                capture;
            self.heap.assignTransferred(&captures[index], cloned);
            initialized += 1;
        }

        const clone = try self.allocator.create(ClosureObject);
        errdefer self.allocator.destroy(clone);
        clone.* = .{
            .function_id = source.function_id,
            .is_native = source.is_native,
            .captures = captures,
        };
        return self.heap.registerClosure(clone);
    }

    fn cloneBorrowedManagedValueDynamic(self: *Vm, module: *const bytecode.Module, value: runtime_abi.Value) anyerror!runtime_abi.Value {
        if (!self.heap.isManagedValue(value)) return value;
        return switch (value) {
            .string => |bytes| if (bytes.len == 0) value else blk: {
                const owned = try self.allocator.dupe(u8, bytes);
                errdefer self.allocator.free(owned);
                try self.heap.registerString(owned);
                break :blk runtime_abi.Value{ .string = owned };
            },
            .raw_ptr => |ptr| blk: {
                if (self.heap.getClosure(ptr) != null) {
                    break :blk runtime_abi.Value{ .raw_ptr = try self.cloneClosureValue(module, ptr) };
                }
                if (self.heap.getArray(ptr)) |array| {
                    break :blk runtime_abi.Value{ .raw_ptr = try self.cloneArrayValueDynamic(module, array) };
                }
                if (self.heap.getStructTypeName(ptr)) |type_name| {
                    if (helper_impl.findType(module, type_name) != null) {
                        break :blk runtime_abi.Value{ .raw_ptr = try self.cloneStructValue(module, type_name, ptr) };
                    }
                    if (enumTypeExists(module, type_name)) {
                        break :blk try self.cloneEnumValue(module, type_name, value);
                    }
                }
                break :blk value;
            },
            else => value,
        };
    }

    fn cloneArrayValueDynamic(self: *Vm, module: *const bytecode.Module, source: *const ArrayObject) anyerror!usize {
        const object = try self.allocator.create(ArrayObject);
        errdefer self.allocator.destroy(object);
        const items = try self.allocator.alloc(runtime_abi.BridgeValue, @max(source.len, 1));
        for (items) |*item| item.* = runtime_abi.bridgeValueFromValue(.{ .void = {} });
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| self.heap.dropValue(runtime_abi.bridgeValueToValue(item));
            self.allocator.free(items);
        }
        for (source.items[0..source.len], 0..) |item, index| {
            const cloned = try self.cloneBorrowedManagedValueDynamic(module, runtime_abi.bridgeValueToValue(item));
            items[index] = runtime_abi.bridgeValueFromValue(cloned);
            initialized += 1;
        }
        object.* = .{
            .len = source.len,
            .items = items.ptr,
        };
        return self.heap.registerArray(object);
    }

    fn enumTypeExists(module: *const bytecode.Module, type_name: []const u8) bool {
        for (module.enums) |enum_decl| {
            if (std.mem.eql(u8, enum_decl.name, type_name)) return true;
        }
        return false;
    }

    fn cloneBorrowedLocalValue(
        self: *Vm,
        module: *const bytecode.Module,
        value_type: bytecode.TypeRef,
        value: runtime_abi.Value,
    ) !runtime_abi.Value {
        if (value_type.kind != .ffi_struct or value != .raw_ptr or value.raw_ptr == 0) return value;
        const type_name = value_type.name orelse {
            self.rememberError("local struct type is missing a name");
            return error.RuntimeFailure;
        };
        const copied = if (self.isManagedStructPointer(value.raw_ptr))
            try self.cloneStructValue(module, type_name, value.raw_ptr)
        else
            try self.copyStructFromNativeLayout(module, type_name, value.raw_ptr);
        return .{ .raw_ptr = copied };
    }

    fn resolveVirtualMethod(
        self: *Vm,
        module: *const bytecode.Module,
        actual_type_name: []const u8,
        method_name: []const u8,
    ) ?bytecode.MethodMember {
        _ = self;
        const type_decl = helper_impl.findType(module, actual_type_name) orelse return null;
        for (type_decl.methods) |method_decl| {
            if (std.mem.eql(u8, method_decl.name, method_name)) return method_decl;
        }
        return null;
    }

    fn copyStruct(
        self: *Vm,
        module: *const bytecode.Module,
        type_decl: bytecode.TypeDecl,
        dst_ptr: [*]align(1) runtime_abi.Value,
        src_ptr: [*]align(1) runtime_abi.Value,
    ) !void {
        for (type_decl.fields, 0..) |field_decl, index| {
            if (field_decl.ty.kind == .ffi_struct) {
                const nested_name = field_decl.ty.name orelse {
                    self.rememberError("struct field type is missing a name");
                    return error.RuntimeFailure;
                };
                const nested_type = helper_impl.findType(module, nested_name) orelse {
                    self.rememberError("struct type could not be resolved");
                    return error.RuntimeFailure;
                };
                if (src_ptr[index] != .raw_ptr) {
                    self.rememberFmt(
                        "nested struct copy source must be a pointer: {s}.{s}",
                        .{ type_decl.name, field_decl.name },
                    );
                    return error.RuntimeFailure;
                }
                if (dst_ptr[index] != .raw_ptr or dst_ptr[index].raw_ptr == 0) {
                    const old = dst_ptr[index];
                    dst_ptr[index] = .{ .raw_ptr = try self.allocateStruct(module, nested_name) };
                    self.heap.dropValue(old);
                }
                if (src_ptr[index].raw_ptr == 0) {
                    // Treat null nested pointers as zero/default nested structs.
                    const old = dst_ptr[index];
                    dst_ptr[index] = .{ .raw_ptr = try self.allocateStruct(module, nested_name) };
                    self.heap.dropValue(old);
                    continue;
                }
                const nested_dst: [*]align(1) runtime_abi.Value = @ptrFromInt(dst_ptr[index].raw_ptr);
                const nested_src: [*]align(1) runtime_abi.Value = @ptrFromInt(src_ptr[index].raw_ptr);
                try self.copyStruct(module, nested_type, nested_dst, nested_src);
            } else if (field_decl.ty.kind == .array and self.heap.isManagedValue(src_ptr[index])) {
                // Affine value semantics: copying a struct deep-clones its array
                // fields so the copy and the original share no backing storage.
                const element_ty = try self.arrayElementType(module, field_decl.ty);
                const cloned = try self.cloneArrayValueDeep(module, element_ty, src_ptr[index]);
                const old = dst_ptr[index];
                dst_ptr[index] = cloned;
                self.heap.dropValue(old);
            } else if (field_decl.ty.kind == .enum_instance and src_ptr[index] == .raw_ptr and src_ptr[index].raw_ptr != 0) {
                const type_name = field_decl.ty.name orelse {
                    self.rememberError("enum field type is missing a name");
                    return error.RuntimeFailure;
                };
                const old = dst_ptr[index];
                dst_ptr[index] = self.cloneEnumValue(module, type_name, src_ptr[index]) catch |err| {
                    if (err == error.RuntimeFailure) {
                        if (self.lastError()) |message| {
                            var previous: [256]u8 = undefined;
                            const previous_len = @min(message.len, previous.len);
                            @memcpy(previous[0..previous_len], message[0..previous_len]);
                            self.rememberFmt(
                                "{s}; owner={s}.{s}",
                                .{ previous[0..previous_len], type_decl.name, field_decl.name },
                            );
                        }
                    }
                    return err;
                };
                self.heap.dropValue(old);
            } else {
                const old = dst_ptr[index];
                dst_ptr[index] = src_ptr[index];
                self.heap.dropValue(old);
            }
        }
    }

    /// Deep-clone a managed array value so the result shares no backing storage
    /// with the source. Struct and nested-array elements are cloned recursively;
    /// primitive/string elements are retained. Implements affine copy semantics
    /// for array-typed struct fields (see copyStruct).
    fn cloneArrayValueDeep(
        self: *Vm,
        module: *const bytecode.Module,
        element_ty: bytecode.TypeRef,
        src_value: runtime_abi.Value,
    ) anyerror!runtime_abi.Value {
        if (src_value != .raw_ptr or src_value.raw_ptr == 0) return src_value;
        const src_array: *const ArrayObject = @ptrFromInt(src_value.raw_ptr);
        const len = src_array.len;
        const dst_ptr = try self.allocateArray(len);
        const dst_array: *ArrayObject = @ptrFromInt(dst_ptr);
        var index: usize = 0;
        while (index < len) : (index += 1) {
            const element = runtime_abi.bridgeValueToValue(src_array.items[index]);
            const cloned = switch (element_ty.kind) {
                .ffi_struct => blk: {
                    if (element != .raw_ptr or element.raw_ptr == 0) break :blk element;
                    const nested_name = element_ty.name orelse break :blk element;
                    if (!self.isManagedStructPointer(element.raw_ptr)) {
                        break :blk runtime_abi.Value{ .raw_ptr = try self.copyStructFromNativeLayout(module, nested_name, element.raw_ptr) };
                    }
                    const fresh = try self.allocateStruct(module, nested_name);
                    const nested_type = helper_impl.findType(module, nested_name) orelse {
                        self.heap.dropValue(.{ .raw_ptr = fresh });
                        self.rememberError("array element struct type could not be resolved");
                        return error.RuntimeFailure;
                    };
                    const fresh_fields: [*]align(1) runtime_abi.Value = @ptrFromInt(fresh);
                    const src_fields: [*]align(1) runtime_abi.Value = @ptrFromInt(element.raw_ptr);
                    try self.copyStruct(module, nested_type, fresh_fields, src_fields);
                    break :blk runtime_abi.Value{ .raw_ptr = fresh };
                },
                .array => try self.cloneArrayValueDeep(module, try self.arrayElementType(module, element_ty), element),
                .enum_instance => blk: {
                    if (element != .raw_ptr or element.raw_ptr == 0) break :blk element;
                    const enum_name = element_ty.name orelse break :blk element;
                    break :blk try self.cloneEnumValue(module, enum_name, element);
                },
                else => element,
            };
            dst_array.items[index] = runtime_abi.bridgeValueFromValue(cloned);
        }
        return .{ .raw_ptr = dst_ptr };
    }

    fn cloneEnumValue(self: *Vm, module: *const bytecode.Module, type_name: []const u8, value: runtime_abi.Value) anyerror!runtime_abi.Value {
        if (value != .raw_ptr or value.raw_ptr == 0) return value;
        if (!self.isManagedStructPointer(value.raw_ptr)) {
            var native_candidate = value.raw_ptr;
            var depth: usize = 0;
            while (depth < 8) : (depth += 1) {
                const native_words: [*]const u64 = @ptrFromInt(native_candidate);
                if (self.enumNativeVariant(module, type_name, native_words[0])) |_| {
                    return .{ .raw_ptr = try self.copyEnumFromNativeLayout(module, type_name, native_candidate) };
                }
                const next_candidate: usize = @intCast(native_words[0]);
                if (next_candidate == 0 or next_candidate == native_candidate or next_candidate % @alignOf(u64) != 0) break;
                native_candidate = next_candidate;
            }
        }
        const src: [*]align(1) const runtime_abi.Value = @ptrFromInt(value.raw_ptr);
        if (src[0] == .raw_ptr and src[0].raw_ptr != 0 and src[0].raw_ptr != value.raw_ptr) {
            return self.cloneEnumValue(module, type_name, src[0]);
        }
        if (src[0] != .integer) {
            const native_words: [*]const u64 = @ptrFromInt(value.raw_ptr);
            var chain_candidate: usize = value.raw_ptr;
            var chain_words = [_]u64{0} ** 4;
            var chain_index: usize = 0;
            while (chain_index < chain_words.len) : (chain_index += 1) {
                const chain_ptr: [*]const u64 = @ptrFromInt(chain_candidate);
                chain_words[chain_index] = chain_ptr[0];
                const next_candidate: usize = @intCast(chain_ptr[0]);
                if (next_candidate == 0 or next_candidate == chain_candidate or next_candidate % @alignOf(u64) != 0) break;
                chain_candidate = next_candidate;
            }
            self.rememberFmt(
                "enum clone requires an integer tag slot: type={s} ptr=0x{x} first_word=0x{x} chain=0x{x},0x{x},0x{x},0x{x}",
                .{ type_name, value.raw_ptr, native_words[0], chain_words[0], chain_words[1], chain_words[2], chain_words[3] },
            );
            return error.RuntimeFailure;
        }
        const payload_ty = self.enumPayloadType(module, type_name, @intCast(src[0].integer)) orelse bytecode.TypeRef{ .kind = .void };
        const slots = try self.allocator.alloc(runtime_abi.Value, 2);
        errdefer self.allocator.free(slots);
        slots[0] = src[0];
        slots[1] = switch (payload_ty.kind) {
            .ffi_struct => blk: {
                if (src[1] != .raw_ptr or src[1].raw_ptr == 0) break :blk src[1];
                break :blk .{ .raw_ptr = try self.cloneStructValue(module, payload_ty.name orelse type_name, src[1].raw_ptr) };
            },
            .array => try self.cloneArrayValueDeep(module, try self.arrayElementType(module, payload_ty), src[1]),
            .enum_instance => try self.cloneEnumValue(module, payload_ty.name orelse type_name, src[1]),
            else => src[1],
        };
        return .{ .raw_ptr = try self.heap.registerStruct(type_name, slots) };
    }

    pub fn copyEnumToNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, runtime_ptr: usize) anyerror!usize {
        const src: [*]align(1) const runtime_abi.Value = @ptrFromInt(runtime_ptr);
        if (src[0] != .integer) {
            self.rememberError("enum native copy requires an integer tag slot");
            return error.RuntimeFailure;
        }
        const words = try self.allocator.alloc(u64, 2);
        errdefer self.allocator.free(words);
        const discriminant: u32 = @intCast(src[0].integer);
        const payload_ty = self.enumPayloadType(module, type_name, discriminant) orelse {
            self.rememberFmt(
                "enum native copy could not resolve discriminant: type={s} tag={d} ptr=0x{x}",
                .{ type_name, discriminant, runtime_ptr },
            );
            return error.RuntimeFailure;
        };
        words[0] = @as(u64, @intCast(discriminant));
        words[1] = try self.enumPayloadToNativeWord(module, payload_ty, src[1]);
        return @intFromPtr(words.ptr);
    }

    pub fn copyEnumFromNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) anyerror!usize {
        if (self.isManagedStructPointer(native_ptr)) {
            const cloned = try self.cloneEnumValue(module, type_name, .{ .raw_ptr = native_ptr });
            return if (cloned == .raw_ptr) cloned.raw_ptr else 0;
        }
        const resolved_ptr = try self.resolveNativeEnumLayoutPointer(module, type_name, native_ptr);
        const words: [*]const u64 = @ptrFromInt(resolved_ptr);
        const native_variant = self.enumNativeVariant(module, type_name, words[0]) orelse {
            const runtime_slots: [*]align(1) const runtime_abi.Value = @ptrFromInt(resolved_ptr);
            if (runtime_slots[0] == .integer) {
                const discriminant: u32 = @intCast(runtime_slots[0].integer);
                if (self.enumPayloadType(module, type_name, discriminant)) |payload_ty| {
                    const slots = try self.allocator.alloc(runtime_abi.Value, 2);
                    errdefer self.allocator.free(slots);
                    slots[0] = runtime_slots[0];
                    slots[1] = switch (payload_ty.kind) {
                        .ffi_struct => blk: {
                            if (runtime_slots[1] != .raw_ptr or runtime_slots[1].raw_ptr == 0) break :blk runtime_slots[1];
                            break :blk .{ .raw_ptr = try self.cloneStructValue(module, payload_ty.name orelse type_name, runtime_slots[1].raw_ptr) };
                        },
                        .array => try self.cloneArrayValueDeep(module, try self.arrayElementType(module, payload_ty), runtime_slots[1]),
                        .enum_instance => try self.cloneEnumValue(module, payload_ty.name orelse type_name, runtime_slots[1]),
                        else => runtime_slots[1],
                    };
                    return self.heap.registerStruct(type_name, slots);
                }
            }
            self.rememberFmt(
                "enum native copy found an invalid discriminant: type={s} tag={d} ptr=0x{x}",
                .{ type_name, words[0], resolved_ptr },
            );
            return error.RuntimeFailure;
        };
        const slots = try self.allocator.alloc(runtime_abi.Value, 2);
        errdefer self.allocator.free(slots);
        slots[0] = .{ .integer = @intCast(native_variant.discriminant) };
        slots[1] = try self.enumPayloadFromNativeWord(module, native_variant.payload_ty, words[1]);
        return self.heap.registerStruct(type_name, slots);
    }

    fn resolveNativeEnumLayoutPointer(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) anyerror!usize {
        var candidate = native_ptr;
        var depth: usize = 0;
        while (depth < 4) : (depth += 1) {
            const words: [*]const u64 = @ptrFromInt(candidate);
            if (self.enumNativeVariant(module, type_name, words[0]) != null) return candidate;
            const next_candidate: usize = @intCast(words[0]);
            if (next_candidate == 0 or next_candidate == candidate or next_candidate % @alignOf(u64) != 0) break;
            candidate = next_candidate;
        }
        return native_ptr;
    }

    pub fn destroyEnumNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
        if (native_ptr == 0) return;
        const words: [*]u64 = @ptrFromInt(native_ptr);
        if (self.enumNativeVariant(module, type_name, words[0])) |native_variant| {
            self.destroyEnumNativePayload(module, native_variant.payload_ty, words[1]);
        }
        const native_words: []u64 = words[0..2];
        self.allocator.free(native_words);
    }

    const EnumNativeVariant = struct {
        discriminant: u32,
        payload_ty: bytecode.TypeRef,
    };

    fn enumNativeVariant(self: *Vm, module: *const bytecode.Module, type_name: []const u8, word: u64) ?EnumNativeVariant {
        if (word > std.math.maxInt(u32)) return null;
        const discriminant: u32 = @intCast(word);
        const payload_ty = self.enumPayloadType(module, type_name, discriminant) orelse return null;
        return .{
            .discriminant = discriminant,
            .payload_ty = payload_ty,
        };
    }

    fn enumPayloadType(self: *Vm, module: *const bytecode.Module, type_name: []const u8, discriminant: u32) ?bytecode.TypeRef {
        _ = self;
        for (module.enums) |enum_decl| {
            if (!std.mem.eql(u8, enum_decl.name, type_name)) continue;
            for (enum_decl.variants) |variant| {
                if (variant.discriminant == discriminant) return variant.payload_ty orelse bytecode.TypeRef{ .kind = .void };
            }
        }
        return null;
    }

    fn enumPayloadToNativeWord(self: *Vm, module: *const bytecode.Module, payload_ty: bytecode.TypeRef, value: runtime_abi.Value) anyerror!u64 {
        return switch (payload_ty.kind) {
            .void => 0,
            .integer => if (value == .integer) @as(u64, @bitCast(value.integer)) else 0,
            .boolean => if (value == .boolean and value.boolean) 1 else 0,
            .float => if (value == .float) @as(u64, @bitCast(value.float)) else 0,
            .string => blk: {
                if (value != .string) break :blk 0;
                const boxed = try self.allocator.create(runtime_abi.BridgeString);
                boxed.* = .{ .ptr = if (value.string.len == 0) null else value.string.ptr, .len = value.string.len };
                break :blk @intFromPtr(boxed);
            },
            .raw_ptr, .construct_any => if (value == .raw_ptr) value.raw_ptr else 0,
            .ffi_struct, .array, .enum_instance => blk: {
                const copied = try self.copyValueToNativeLayout(module, payload_ty, value);
                break :blk if (copied == .raw_ptr) copied.raw_ptr else 0;
            },
        };
    }

    fn enumPayloadFromNativeWord(self: *Vm, module: *const bytecode.Module, payload_ty: bytecode.TypeRef, word: u64) anyerror!runtime_abi.Value {
        return switch (payload_ty.kind) {
            .void => .{ .void = {} },
            .integer => .{ .integer = @as(i64, @bitCast(word)) },
            .boolean => .{ .boolean = word != 0 },
            .float => .{ .float = @as(f64, @bitCast(word)) },
            .string => blk: {
                if (word == 0) break :blk runtime_abi.Value{ .string = "" };
                const boxed: *const runtime_abi.BridgeString = @ptrFromInt(@as(usize, @intCast(word)));
                break :blk runtime_abi.Value{ .string = if (boxed.ptr) |ptr| ptr[0..boxed.len] else "" };
            },
            .raw_ptr, .construct_any => .{ .raw_ptr = @intCast(word) },
            .ffi_struct, .array, .enum_instance => try self.copyValueFromNativeLayout(module, payload_ty, .{ .raw_ptr = @intCast(word) }),
        };
    }

    fn destroyEnumNativePayload(self: *Vm, module: *const bytecode.Module, payload_ty: bytecode.TypeRef, word: u64) void {
        if (word == 0) return;
        switch (payload_ty.kind) {
            .ffi_struct => self.destroyStructNativeLayout(module, payload_ty.name orelse return, @intCast(word)),
            .array => self.destroyArrayNativeLayout(module, payload_ty, @intCast(word)),
            .enum_instance => self.destroyEnumNativeLayout(module, payload_ty.name orelse return, @intCast(word)),
            .string => self.allocator.destroy(@as(*runtime_abi.BridgeString, @ptrFromInt(@as(usize, @intCast(word))))),
            else => {},
        }
    }

    fn materializeNativeResult(
        self: *Vm,
        module: *const bytecode.Module,
        return_ty: bytecode.TypeRef,
        value: runtime_abi.Value,
    ) !runtime_abi.Value {
        if (return_ty.kind != .ffi_struct) return value;
        if (value != .raw_ptr or value.raw_ptr == 0) {
            self.rememberError("native struct result requires a valid pointer");
            return error.RuntimeFailure;
        }
        return .{ .raw_ptr = try self.copyStructFromNativeLayout(module, return_ty.name orelse {
            self.rememberError("native struct result is missing a type name");
            return error.RuntimeFailure;
        }, value.raw_ptr) };
    }

    pub fn copyStructFromNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) anyerror!usize {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const fields = try self.allocator.alloc(runtime_abi.Value, type_decl.fields.len);
        for (fields) |*field| field.* = .{ .void = {} };
        var initialized: usize = 0;
        errdefer {
            for (fields[0..initialized]) |field| self.heap.dropValue(field);
            self.allocator.free(fields);
        }
        for (type_decl.fields, 0..) |field_decl, index| {
            fields[index] = try helper_impl.readNativeFieldValue(self, module, type_name, field_decl, index, native_ptr);
            initialized += 1;
        }
        return self.heap.registerStructWithOrigin(type_name, fields, .native_materialize);
    }

    fn copyStructFromNativeLayoutInto(self: *Vm, module: *const bytecode.Module, type_name: []const u8, runtime_ptr: usize, native_ptr: usize) anyerror!void {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const fields: [*]align(1) runtime_abi.Value = @ptrFromInt(runtime_ptr);
        for (type_decl.fields, 0..) |field_decl, index| {
            const offset = try native_layout.fieldOffset(module, type_name, index);
            const address = native_ptr + offset;
            switch (field_decl.ty.kind) {
                .ffi_struct => {
                    const nested_name = field_decl.ty.name orelse {
                        self.rememberError("nested struct field type is missing a name");
                        return error.RuntimeFailure;
                    };
                    if (fields[index] != .raw_ptr or fields[index].raw_ptr == 0) {
                        const old = fields[index];
                        fields[index] = .{ .raw_ptr = try self.allocateStruct(module, nested_name) };
                        self.heap.dropValue(old);
                    }
                    try self.copyStructFromNativeLayoutInto(module, nested_name, fields[index].raw_ptr, address);
                },
                .array => {
                    const native_array_ptr = (@as(*const usize, @ptrFromInt(address))).*;
                    if (native_array_ptr == 0) {
                        const old = fields[index];
                        fields[index] = .{ .raw_ptr = 0 };
                        self.heap.dropValue(old);
                        continue;
                    }
                    if (fields[index] == .raw_ptr and fields[index].raw_ptr != 0) {
                        try self.syncArrayFromNativeLayout(module, field_decl.ty, fields[index].raw_ptr, native_array_ptr);
                        continue;
                    }
                    const old = fields[index];
                    fields[index] = .{ .raw_ptr = try self.copyArrayFromNativeLayout(module, field_decl.ty, native_array_ptr) };
                    self.heap.dropValue(old);
                },
                else => {
                    const old = fields[index];
                    fields[index] = try helper_impl.readNativeFieldValue(self, module, type_name, field_decl, index, native_ptr);
                    self.heap.dropValue(old);
                },
            }
        }
    }

    fn copyStructToNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, runtime_ptr: usize) anyerror!usize {
        const layout = try native_layout.structLayout(module, type_name);
        const word_count = @max(1, std.math.divCeil(usize, layout.size, @sizeOf(u64)) catch unreachable);
        const words = try self.allocator.alloc(u64, word_count);
        @memset(std.mem.sliceAsBytes(words), 0);
        self.recordNativeStructAlloc();
        errdefer self.destroyStructNativeLayout(module, type_name, @intFromPtr(words.ptr));
        try self.copyStructToNativeLayoutInto(module, type_name, runtime_ptr, @intFromPtr(words.ptr));
        return @intFromPtr(words.ptr);
    }

    pub fn copyStructToNativeLayoutInto(self: *Vm, module: *const bytecode.Module, type_name: []const u8, runtime_ptr: usize, native_ptr: usize) anyerror!void {
        const type_decl = helper_impl.findType(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const fields: [*]align(1) const runtime_abi.Value = @ptrFromInt(runtime_ptr);
        for (type_decl.fields, 0..) |field_decl, index| {
            const offset = try native_layout.fieldOffset(module, type_name, index);
            try helper_impl.writeNativeFieldValue(self, module, field_decl.ty, fields[index], native_ptr + offset);
        }
    }

    fn destroyStructNativeLayoutFields(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
        const type_decl = helper_impl.findType(module, type_name) orelse return;
        for (type_decl.fields, 0..) |field_decl, index| {
            const offset = native_layout.fieldOffset(module, type_name, index) catch continue;
            const address = native_ptr + offset;
            switch (field_decl.ty.kind) {
                .array => {
                    const array_ptr = (@as(*const usize, @ptrFromInt(address))).*;
                    self.destroyArrayNativeLayout(module, field_decl.ty, array_ptr);
                },
                .ffi_struct => if (field_decl.ty.name) |nested_name| {
                    self.destroyStructNativeLayoutFields(module, nested_name, address);
                },
                .enum_instance => {
                    const enum_ptr = (@as(*const usize, @ptrFromInt(address))).*;
                    self.destroyEnumNativeLayout(module, field_decl.ty.name orelse return, enum_ptr);
                },
                .construct_any => {},
                else => {},
            }
        }
    }

    fn recordNativeArrayAlloc(self: *Vm) void {
        self.native_layout_stats.arrays_current += 1;
        self.native_layout_stats.arrays_allocated += 1;
        self.native_layout_stats.arrays_peak = @max(self.native_layout_stats.arrays_peak, self.native_layout_stats.arrays_current);
    }

    fn recordNativeArrayFree(self: *Vm) void {
        if (self.native_layout_stats.arrays_current > 0) self.native_layout_stats.arrays_current -= 1;
        self.native_layout_stats.arrays_freed += 1;
    }

    fn recordNativeStructAlloc(self: *Vm) void {
        self.native_layout_stats.structs_current += 1;
        self.native_layout_stats.structs_allocated += 1;
        self.native_layout_stats.structs_peak = @max(self.native_layout_stats.structs_peak, self.native_layout_stats.structs_current);
    }

    fn recordNativeStructFree(self: *Vm) void {
        if (self.native_layout_stats.structs_current > 0) self.native_layout_stats.structs_current -= 1;
        self.native_layout_stats.structs_freed += 1;
    }
};

test "executes nested runtime calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = &.{},
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{} } },
                    .{ .ret = .{ .src = null } },
                }),
            },
            .{
                .id = 1,
                .name = "helper",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_int = .{ .dst = 0, .value = 42 } },
                    .{ .print = .{ .src = 0, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try vm.runMain(&module, &stream);
    try std.testing.expectEqualStrings("42\n", stream.buffered());
}

test "materializes native closure struct captures using external metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const backend_fields = [_]bytecode.Field{
        .{ .name = "id", .ty = .{ .kind = .integer, .name = "U32" } },
    };
    const pipeline_fields = [_]bytecode.Field{
        .{ .name = "handle", .ty = .{ .kind = .ffi_struct, .name = "BackendPipelineHandle" } },
        .{ .name = "id", .ty = .{ .kind = .integer, .name = "U32" } },
    };
    const types = [_]bytecode.TypeDecl{
        .{ .name = "BackendPipelineHandle", .fields = @constCast(&backend_fields) },
        .{ .name = "RenderPipeline", .fields = @constCast(&pipeline_fields) },
    };
    const module = bytecode.Module{
        .types = @constCast(&types),
        .functions = &.{},
        .entry_function_id = null,
    };

    const native_pipeline = try arena.allocator().alloc(u8, 8);
    @memset(native_pipeline, 0);
    (@as(*u32, @ptrFromInt(@intFromPtr(native_pipeline.ptr)))).* = 65537;
    (@as(*u32, @ptrFromInt(@intFromPtr(native_pipeline.ptr) + 4))).* = 65537;

    const NativeClosure = extern struct {
        function_id: i64,
        capture_count: i64,
        captures: [1]runtime_abi.BridgeValue,
    };
    const native_closure = try arena.allocator().create(NativeClosure);
    native_closure.* = .{
        .function_id = 457,
        .capture_count = 1,
        .captures = .{runtime_abi.bridgeValueFromValue(.{ .raw_ptr = @intFromPtr(native_pipeline.ptr) })},
    };
    const capture_types = [_]bytecode.TypeRef{
        .{ .kind = .ffi_struct, .name = "RenderPipeline" },
    };

    const closure_ptr = try vm.materializeNativeClosure(&module, @intFromPtr(native_closure), &capture_types);
    const closure = vm.heap.getClosure(closure_ptr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), closure.captures.len);
    try std.testing.expect(closure.captures[0] == .raw_ptr);

    const pipeline_values: [*]const runtime_abi.Value = @ptrFromInt(closure.captures[0].raw_ptr);
    try std.testing.expect(pipeline_values[0] == .raw_ptr);
    try std.testing.expect(pipeline_values[1] == .integer);
    try std.testing.expectEqual(@as(i64, 65537), pipeline_values[1].integer);

    const handle_values: [*]const runtime_abi.Value = @ptrFromInt(pipeline_values[0].raw_ptr);
    try std.testing.expect(handle_values[0] == .integer);
    try std.testing.expectEqual(@as(i64, 65537), handle_values[0].integer);

    try std.testing.expectEqual(@as(usize, 2), vm.heap.stats.structs_current);
    vm.dropManagedValue(.{ .raw_ptr = closure_ptr });
    try std.testing.expectEqual(@as(usize, 0), vm.heap.stats.structs_current);
}

test "materializes tagged native closure captures as runtime closures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const callback_capture_ty = bytecode.TypeRef{ .kind = .raw_ptr, .name = "(borrow FoundationUiContext) -> FoundationView" };
    const outer_local_types = [_]bytecode.TypeRef{
        .{ .kind = .raw_ptr, .name = "GraphicsFrame" },
        callback_capture_ty,
    };
    const inner_local_types = [_]bytecode.TypeRef{
        .{ .kind = .raw_ptr, .name = "FoundationUiContext" },
    };
    const functions = [_]bytecode.Function{
        .{
            .id = 100,
            .name = "innerBuilder",
            .param_count = 1,
            .register_count = 0,
            .local_count = 1,
            .local_types = @constCast(&inner_local_types),
            .instructions = &.{},
        },
        .{
            .id = 200,
            .name = "outerFrame",
            .param_count = 2,
            .register_count = 0,
            .local_count = 2,
            .local_types = @constCast(&outer_local_types),
            .instructions = &.{},
        },
    };
    const module = bytecode.Module{
        .functions = @constCast(&functions),
        .entry_function_id = null,
    };

    const NativeInnerClosure = extern struct {
        function_id: i64,
        capture_count: i64,
    };
    const inner = try arena.allocator().create(NativeInnerClosure);
    inner.* = .{
        .function_id = 100,
        .capture_count = 0,
    };

    const NativeOuterClosure = extern struct {
        function_id: i64,
        capture_count: i64,
        captures: [1]runtime_abi.BridgeValue,
    };
    const outer = try arena.allocator().create(NativeOuterClosure);
    outer.* = .{
        .function_id = 200,
        .capture_count = 1,
        .captures = .{runtime_abi.bridgeValueFromValue(.{ .raw_ptr = runtime_abi.tagNativeClosurePointer(@intFromPtr(inner)) })},
    };

    const outer_ptr = try vm.materializeNativeClosure(&module, runtime_abi.tagNativeClosurePointer(@intFromPtr(outer)), null);
    const outer_closure = vm.heap.getClosure(outer_ptr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), outer_closure.captures.len);
    try std.testing.expect(outer_closure.captures[0] == .raw_ptr);

    const inner_ptr = outer_closure.captures[0].raw_ptr;
    const inner_closure = vm.heap.getClosure(inner_ptr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 100), inner_closure.function_id);
    try std.testing.expectEqual(@as(usize, 0), inner_closure.captures.len);

    vm.dropManagedValue(.{ .raw_ptr = outer_ptr });
}

test "materializes callback fields when copying native structs to runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const callback_ty = bytecode.TypeRef{ .kind = .raw_ptr, .name = "(borrow mut GraphicsFrame) -> Void" };
    const frame_handler_locals = [_]bytecode.TypeRef{
        .{ .kind = .raw_ptr, .name = "GraphicsFrame" },
    };
    const fields = [_]bytecode.Field{
        .{ .name = "frameHandler", .ty = callback_ty },
    };
    const types = [_]bytecode.TypeDecl{
        .{ .name = "GraphicsApplication", .fields = @constCast(&fields) },
    };
    const functions = [_]bytecode.Function{
        .{
            .id = 300,
            .name = "frameHandler",
            .param_count = 1,
            .register_count = 0,
            .local_count = 1,
            .local_types = @constCast(&frame_handler_locals),
            .instructions = &.{},
        },
    };
    const module = bytecode.Module{
        .types = @constCast(&types),
        .functions = @constCast(&functions),
        .entry_function_id = null,
    };

    const NativeClosure = extern struct {
        function_id: i64,
        capture_count: i64,
    };
    const native_closure = try arena.allocator().create(NativeClosure);
    native_closure.* = .{
        .function_id = 300,
        .capture_count = 0,
    };

    const layout = try native_layout.structLayout(&module, "GraphicsApplication");
    const word_count = @max(1, std.math.divCeil(usize, layout.size, @sizeOf(u64)) catch unreachable);
    const native_words = try arena.allocator().alloc(u64, word_count);
    @memset(native_words, 0);
    const native_app_ptr = @intFromPtr(native_words.ptr);
    const handler_offset = try native_layout.fieldOffset(&module, "GraphicsApplication", 0);
    (@as(*usize, @ptrFromInt(native_app_ptr + handler_offset))).* = runtime_abi.tagNativeClosurePointer(@intFromPtr(native_closure));

    const runtime_app_ptr = try vm.copyStructFromNativeLayout(&module, "GraphicsApplication", native_app_ptr);
    const runtime_fields: [*]const runtime_abi.Value = @ptrFromInt(runtime_app_ptr);
    try std.testing.expect(runtime_fields[0] == .raw_ptr);
    try std.testing.expect(!runtime_abi.isTaggedNativeClosurePointer(runtime_fields[0].raw_ptr));
    const closure = vm.heap.getClosure(runtime_fields[0].raw_ptr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 300), closure.function_id);
    try std.testing.expectEqual(@as(usize, 0), closure.captures.len);

    vm.dropManagedValue(.{ .raw_ptr = runtime_app_ptr });
}

test "hybrid_native_bridge_materialization_cleanup" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const point_fields = [_]bytecode.Field{
        .{ .name = "x", .ty = .{ .kind = .integer, .name = "I64" } },
        .{ .name = "y", .ty = .{ .kind = .integer, .name = "I64" } },
    };
    const batch_fields = [_]bytecode.Field{
        .{ .name = "points", .ty = .{ .kind = .array, .name = "Point" } },
    };
    const types = [_]bytecode.TypeDecl{
        .{ .name = "Point", .fields = @constCast(&point_fields) },
        .{ .name = "Batch", .fields = @constCast(&batch_fields) },
    };
    const module = bytecode.Module{
        .types = @constCast(&types),
        .functions = &.{},
        .entry_function_id = null,
    };

    const point_ptr = try vm.allocateStruct(&module, "Point");
    const point_fields_ptr: [*]runtime_abi.Value = @ptrFromInt(point_ptr);
    point_fields_ptr[0] = .{ .integer = 11 };
    point_fields_ptr[1] = .{ .integer = 22 };

    const array_ptr = try vm.allocateArray(0);
    const array_object: *ArrayObject = @ptrFromInt(array_ptr);
    try vm.heap.appendArrayItem(array_object, .{ .raw_ptr = point_ptr });
    vm.dropManagedValue(.{ .raw_ptr = point_ptr });

    const native_array_ptr = try vm.copyArrayToNativeLayout(&module, .{ .kind = .array, .name = "Point" }, array_ptr);
    vm.destroyArrayNativeLayout(&module, .{ .kind = .array, .name = "Point" }, native_array_ptr);

    const batch_ptr = try vm.allocateStruct(&module, "Batch");
    const batch_fields_ptr: [*]runtime_abi.Value = @ptrFromInt(batch_ptr);
    batch_fields_ptr[0] = .{ .raw_ptr = array_ptr };
    vm.retainManagedValue(.{ .raw_ptr = array_ptr });

    const native_batch_ptr = try vm.copyStructToNativeLayout(&module, "Batch", batch_ptr);
    vm.destroyStructNativeLayout(&module, "Batch", native_batch_ptr);

    vm.dropManagedValue(.{ .raw_ptr = batch_ptr });
    vm.dropManagedValue(.{ .raw_ptr = array_ptr });
    try std.testing.expectEqual(@as(usize, 0), vm.heap.count());
}

test "hybrid_native_bridge_repeated_materialization_cleanup" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const point_fields = [_]bytecode.Field{
        .{ .name = "x", .ty = .{ .kind = .integer, .name = "I64" } },
        .{ .name = "y", .ty = .{ .kind = .integer, .name = "I64" } },
    };
    const batch_fields = [_]bytecode.Field{
        .{ .name = "points", .ty = .{ .kind = .array, .name = "Point" } },
        .{ .name = "weights", .ty = .{ .kind = .array, .name = "I64" } },
    };
    const types = [_]bytecode.TypeDecl{
        .{ .name = "Point", .fields = @constCast(&point_fields) },
        .{ .name = "Batch", .fields = @constCast(&batch_fields) },
    };
    const module = bytecode.Module{
        .types = @constCast(&types),
        .functions = &.{},
        .entry_function_id = null,
    };

    for (0..200) |iteration| {
        const points_ptr = try vm.allocateArray(0);
        const points: *ArrayObject = @ptrFromInt(points_ptr);
        const weights_ptr = try vm.allocateArray(0);
        const weights: *ArrayObject = @ptrFromInt(weights_ptr);

        for (0..12) |index| {
            const point_ptr = try vm.allocateStruct(&module, "Point");
            const fields: [*]runtime_abi.Value = @ptrFromInt(point_ptr);
            fields[0] = .{ .integer = @intCast(iteration + index) };
            fields[1] = .{ .integer = @intCast((iteration + 1) * (index + 1)) };
            try vm.heap.appendArrayItem(points, .{ .raw_ptr = point_ptr });
            vm.dropManagedValue(.{ .raw_ptr = point_ptr });
            try vm.heap.appendArrayItem(weights, .{ .integer = @intCast(index) });
        }

        const native_points = try vm.copyArrayToNativeLayout(&module, .{ .kind = .array, .name = "Point" }, points_ptr);
        vm.destroyArrayNativeLayout(&module, .{ .kind = .array, .name = "Point" }, native_points);
        const native_weights = try vm.copyArrayToNativeLayout(&module, .{ .kind = .array, .name = "I64" }, weights_ptr);
        vm.destroyArrayNativeLayout(&module, .{ .kind = .array, .name = "I64" }, native_weights);

        const batch_ptr = try vm.allocateStruct(&module, "Batch");
        const batch_fields_ptr: [*]runtime_abi.Value = @ptrFromInt(batch_ptr);
        batch_fields_ptr[0] = .{ .raw_ptr = points_ptr };
        batch_fields_ptr[1] = .{ .raw_ptr = weights_ptr };
        vm.retainManagedValue(.{ .raw_ptr = points_ptr });
        vm.retainManagedValue(.{ .raw_ptr = weights_ptr });
        const native_batch = try vm.copyStructToNativeLayout(&module, "Batch", batch_ptr);
        vm.destroyStructNativeLayout(&module, "Batch", native_batch);

        vm.dropManagedValue(.{ .raw_ptr = batch_ptr });
        vm.dropManagedValue(.{ .raw_ptr = points_ptr });
        vm.dropManagedValue(.{ .raw_ptr = weights_ptr });
        try std.testing.expectEqual(@as(usize, 0), vm.heap.count());
    }
}

test "hybrid_runtime_array_append_cleanup_stress" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const module = bytecode.Module{
        .types = &.{},
        .functions = &.{},
        .entry_function_id = null,
    };

    for (0..300) |iteration| {
        const array_ptr = try vm.allocateArray(0);
        const array: *ArrayObject = @ptrFromInt(array_ptr);
        for (0..64) |index| {
            try vm.heap.appendArrayItem(array, .{ .integer = @intCast(iteration + index) });
        }

        const native_array_ptr = try vm.copyArrayToNativeLayout(&module, .{ .kind = .array, .name = "I64" }, array_ptr);
        const native_array: *ArrayObject = @ptrFromInt(native_array_ptr);
        for (0..32) |index| {
            const old_items = native_array.items[0..@max(native_array.len, 1)];
            const new_len = native_array.len + 1;
            const new_items = try vm.allocator.alloc(runtime_abi.BridgeValue, new_len);
            for (old_items[0..native_array.len], 0..) |item, item_index| {
                new_items[item_index] = item;
            }
            new_items[native_array.len] = runtime_abi.bridgeValueFromValue(.{ .integer = @intCast(index) });
            vm.allocator.free(old_items);
            native_array.items = new_items.ptr;
            native_array.len = new_len;
        }
        try vm.syncArrayFromNativeLayout(&module, .{ .kind = .array, .name = "I64" }, array_ptr, native_array_ptr);
        vm.destroyArrayNativeLayout(&module, .{ .kind = .array, .name = "I64" }, native_array_ptr);
        vm.dropManagedValue(.{ .raw_ptr = array_ptr });
        try std.testing.expectEqual(@as(usize, 0), vm.heap.count());
    }
}

test "hybrid_recursive_aggregate_sync_cleanup_stress" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const point_fields = [_]bytecode.Field{
        .{ .name = "x", .ty = .{ .kind = .integer, .name = "I64" } },
        .{ .name = "y", .ty = .{ .kind = .integer, .name = "I64" } },
    };
    const row_fields = [_]bytecode.Field{
        .{ .name = "points", .ty = .{ .kind = .array, .name = "Point" } },
    };
    const scene_fields = [_]bytecode.Field{
        .{ .name = "rows", .ty = .{ .kind = .array, .name = "Row" } },
    };
    const types = [_]bytecode.TypeDecl{
        .{ .name = "Point", .fields = @constCast(&point_fields) },
        .{ .name = "Row", .fields = @constCast(&row_fields) },
        .{ .name = "Scene", .fields = @constCast(&scene_fields) },
    };
    const module = bytecode.Module{
        .types = @constCast(&types),
        .functions = &.{},
        .entry_function_id = null,
    };

    for (0..150) |iteration| {
        const rows_ptr = try vm.allocateArray(0);
        const rows: *ArrayObject = @ptrFromInt(rows_ptr);
        for (0..5) |row_index| {
            const points_ptr = try vm.allocateArray(0);
            const points: *ArrayObject = @ptrFromInt(points_ptr);
            for (0..8) |point_index| {
                const point_ptr = try vm.allocateStruct(&module, "Point");
                const fields: [*]runtime_abi.Value = @ptrFromInt(point_ptr);
                fields[0] = .{ .integer = @intCast(iteration + row_index) };
                fields[1] = .{ .integer = @intCast(point_index) };
                try vm.heap.appendArrayItem(points, .{ .raw_ptr = point_ptr });
                vm.dropManagedValue(.{ .raw_ptr = point_ptr });
            }

            const row_ptr = try vm.allocateStruct(&module, "Row");
            const row_fields_ptr: [*]runtime_abi.Value = @ptrFromInt(row_ptr);
            row_fields_ptr[0] = .{ .raw_ptr = points_ptr };
            vm.retainManagedValue(.{ .raw_ptr = points_ptr });
            try vm.heap.appendArrayItem(rows, .{ .raw_ptr = row_ptr });
            vm.dropManagedValue(.{ .raw_ptr = row_ptr });
            vm.dropManagedValue(.{ .raw_ptr = points_ptr });
        }

        const scene_ptr = try vm.allocateStruct(&module, "Scene");
        const scene_fields_ptr: [*]runtime_abi.Value = @ptrFromInt(scene_ptr);
        scene_fields_ptr[0] = .{ .raw_ptr = rows_ptr };
        vm.retainManagedValue(.{ .raw_ptr = rows_ptr });

        const native_scene = try vm.copyStructToNativeLayout(&module, "Scene", scene_ptr);
        for (0..10) |_| {
            try vm.syncStructFromNativeLayout(&module, "Scene", scene_ptr, native_scene);
        }
        vm.destroyStructNativeLayout(&module, "Scene", native_scene);

        vm.dropManagedValue(.{ .raw_ptr = scene_ptr });
        vm.dropManagedValue(.{ .raw_ptr = rows_ptr });
        try std.testing.expectEqual(@as(usize, 0), vm.heap.count());
    }
}

test "hybrid_native_state_field_set_releases_replaced_managed_values" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const handle_fields = [_]bytecode.Field{
        .{ .name = "id", .ty = .{ .kind = .integer, .name = "I64" } },
    };
    const state_fields = [_]bytecode.Field{
        .{ .name = "handle", .ty = .{ .kind = .ffi_struct, .name = "Handle" } },
    };
    const types = [_]bytecode.TypeDecl{
        .{ .name = "Handle", .fields = @constCast(&handle_fields) },
        .{ .name = "State", .fields = @constCast(&state_fields) },
    };
    const local_types = [_]bytecode.TypeRef{
        .{ .kind = .raw_ptr, .name = "RawPtr" },
    };
    const instructions = [_]bytecode.Instruction{
        .{ .load_local = .{ .dst = 0, .local = 0 } },
        .{ .recover_native_state = .{ .dst = 1, .state = 0, .type_name = "State", .type_id = 77 } },
        .{ .alloc_struct = .{ .dst = 2, .type_name = "Handle" } },
        .{ .native_state_field_set = .{
            .state = 1,
            .field_index = 0,
            .src = 2,
            .field_ty = .{ .kind = .ffi_struct, .name = "Handle" },
        } },
        .{ .ret = .{} },
    };
    const module = bytecode.Module{
        .types = @constCast(&types),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "replaceHandle",
                .param_count = 1,
                .register_count = 3,
                .local_count = 1,
                .local_types = @constCast(&local_types),
                .instructions = @constCast(&instructions),
            },
        }),
        .entry_function_id = null,
    };

    const native_payload = try vm.allocator.alloc(runtime_abi.BridgeValue, 1);
    native_payload[0] = runtime_abi.bridgeValueFromValue(.{ .raw_ptr = 0 });
    const box = try vm.allocator.create(NativeStateBox);
    box.* = .{
        .type_id = 77,
        .payload = @intFromPtr(native_payload.ptr),
        .runtime_payload = 0,
    };
    defer {
        if (box.runtime_payload != 0) {
            const runtime_payload: [*]runtime_abi.BridgeValue = @ptrFromInt(box.runtime_payload);
            vm.heap.dropValue(runtime_abi.bridgeValueToValue(runtime_payload[0]));
            vm.allocator.free(@as([]runtime_abi.BridgeValue, runtime_payload[0..1]));
        }
        vm.allocator.free(native_payload);
        vm.allocator.destroy(box);
    }

    var buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    for (0..200) |_| {
        const result = try vm.runFunctionById(&module, 0, &.{.{ .raw_ptr = @intFromPtr(box) }}, &writer, .{});
        vm.dropManagedValue(result);
        try std.testing.expectEqual(@as(usize, 1), vm.heap.count());
    }
}

test "prints struct values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{
                .name = "Color",
                .fields = @constCast(&[_]bytecode.Field{
                    .{ .name = "r", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "g", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "b", .ty = .{ .kind = .integer, .name = "I64" } },
                }),
            },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 8,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Color" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Color", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 255 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .field_ptr = .{ .dst = 3, .base = 0, .base_type_name = "Color", .field_index = 1, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 4, .value = 0 } },
                    .{ .store_indirect = .{ .ptr = 3, .src = 4, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .field_ptr = .{ .dst = 5, .base = 0, .base_type_name = "Color", .field_index = 2, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 6, .value = 0 } },
                    .{ .store_indirect = .{ .ptr = 5, .src = 6, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .print = .{ .src = 0, .ty = .{ .kind = .ffi_struct, .name = "Color" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try vm.runMain(&module, &stream);
    try std.testing.expectEqualStrings("Color(r: 255, g: 0, b: 0)\n", stream.buffered());
}

test "resolves function constants through hooks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = &.{},
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_function = .{ .dst = 0, .function_id = 7 } },
                    .{ .ret = .{ .src = 0 } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer: [1]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding.writer, .{
        .resolve_function = struct {
            fn resolve(_: ?*anyopaque, function_id: u32) !usize {
                return 0x1000 + function_id;
            }
        }.resolve,
    });

    try std.testing.expectEqual(@as(usize, 0x1007), result.raw_ptr);
}

test "copies struct arguments by value for runtime calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{
                .name = "Pair",
                .fields = @constCast(&[_]bytecode.Field{
                    .{ .name = "left", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "right", .ty = .{ .kind = .integer, .name = "I64" } },
                }),
            },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 6,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Pair" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Pair" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 1 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .store_local = .{ .local = 0, .src = 0 } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .field_ptr = .{ .dst = 3, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .load_indirect = .{ .dst = 4, .ptr = 3, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = 4 } },
                }),
            },
            .{
                .id = 1,
                .name = "mutate",
                .param_count = 1,
                .register_count = 3,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Pair" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 99 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer_6: [1]u8 = undefined;
    var discarding_6: std.Io.Writer.Discarding = .init(&discard_buffer_6);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding_6.writer, .{});
    try std.testing.expectEqual(@as(i64, 1), result.integer);
}

test "copyStruct tolerates null nested ffi struct pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{
                .name = "Child",
                .fields = @constCast(&[_]bytecode.Field{.{ .name = "x", .ty = .{ .kind = .integer, .name = "I64" } }}),
            },
            .{
                .name = "Parent",
                .fields = @constCast(&[_]bytecode.Field{.{ .name = "child", .ty = .{ .kind = .ffi_struct, .name = "Child" } }}),
            },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 7,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Parent" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Parent" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Parent", .field_index = 0, .field_ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .const_null_ptr = .{ .dst = 2 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .ret = .{ .src = null } },
                }),
            },
            .{
                .id = 1,
                .name = "touch",
                .param_count = 1,
                .register_count = 4,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Parent" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Parent", .field_index = 0, .field_ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .load_indirect = .{ .dst = 2, .ptr = 1, .ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .field_ptr = .{ .dst = 3, .base = 2, .base_type_name = "Child", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 7 } },
                    .{ .store_indirect = .{ .ptr = 3, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer_2: [1]u8 = undefined;
    var discarding_2: std.Io.Writer.Discarding = .init(&discard_buffer_2);
    try vm.runMain(&module, &discarding_2.writer);
}

test "construct any values survive nested runtime calls without leaking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const any_widget = bytecode.TypeRef{
        .kind = .construct_any,
        .name = "any Widget",
        .construct_constraint = .{ .construct_name = "Widget" },
    };
    const module = bytecode.Module{
        .constructs = @constCast(&[_]bytecode.Construct{.{ .name = "Widget" }}),
        .construct_implementations = @constCast(&[_]bytecode.ConstructImplementation{
            .{ .type_name = "Button", .construct_constraint = .{ .construct_name = "Widget" }, .fields = &.{}, .has_content = false, .lifecycle_hooks = &.{} },
            .{ .type_name = "Label", .construct_constraint = .{ .construct_name = "Widget" }, .fields = &.{}, .has_content = false, .lifecycle_hooks = &.{} },
        }),
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{ .name = "Button", .fields = &.{} },
            .{ .name = "Label", .fields = &.{} },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 2,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Button" } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Label" } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .ret = .{ .src = null } },
                }),
            },
            .{
                .id = 1,
                .name = "forward",
                .param_count = 1,
                .return_type = any_widget,
                .register_count = 2,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{any_widget}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .call_runtime = .{ .function_id = 2, .args = &.{0}, .dst = 1 } },
                    .{ .ret = .{ .src = 1 } },
                }),
            },
            .{
                .id = 2,
                .name = "identity",
                .param_count = 1,
                .return_type = any_widget,
                .register_count = 1,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{any_widget}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .ret = .{ .src = 0 } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer_7: [1]u8 = undefined;
    var discarding_7: std.Io.Writer.Discarding = .init(&discard_buffer_7);
    try vm.runMain(&module, &discarding_7.writer);
    try std.testing.expectEqual(@as(usize, 0), vm.heap.count());
}

test "native state recovery mutates persistent payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{.{
            .name = "CounterState",
            .fields = @constCast(&[_]bytecode.Field{.{ .name = "count", .ty = .{ .kind = .integer, .name = "I64" } }}),
        }}),
        .functions = @constCast(&[_]bytecode.Function{.{
            .id = 0,
            .name = "main",
            .param_count = 0,
            .register_count = 9,
            .local_count = 0,
            .local_types = &.{},
            .instructions = @constCast(&[_]bytecode.Instruction{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "CounterState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "CounterState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "CounterState", .type_id = 77 } },
                .{ .field_ptr = .{ .dst = 3, .base = 2, .base_type_name = "CounterState", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .const_int = .{ .dst = 4, .value = 9 } },
                .{ .store_indirect = .{ .ptr = 3, .src = 4, .ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .recover_native_state = .{ .dst = 5, .state = 1, .type_name = "CounterState", .type_id = 77 } },
                .{ .field_ptr = .{ .dst = 6, .base = 5, .base_type_name = "CounterState", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .load_indirect = .{ .dst = 7, .ptr = 6, .ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .ret = .{ .src = 7 } },
            }),
        }}),
        .entry_function_id = 0,
    };

    var discard_buffer_3: [1]u8 = undefined;
    var discarding_3: std.Io.Writer.Discarding = .init(&discard_buffer_3);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding_3.writer, .{});
    try std.testing.expectEqual(@as(i64, 9), result.integer);
}

test "native state field set clones borrowed callbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const callback_ty = bytecode.TypeRef{ .kind = .raw_ptr, .name = "() -> I64" };
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{.{
            .name = "CallbackState",
            .fields = @constCast(&[_]bytecode.Field{.{ .name = "callback", .ty = callback_ty }}),
        }}),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .return_type = .{ .kind = .integer, .name = "I64" },
                .register_count = 6,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{callback_ty}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_closure = .{ .dst = 0, .function_id = 1, .captures = &.{} } },
                    .{ .store_local = .{ .local = 0, .src = 0 } },
                    .{ .load_local = .{ .dst = 1, .local = 0 } },
                    .{ .alloc_struct = .{ .dst = 2, .type_name = "CallbackState" } },
                    .{ .alloc_native_state = .{ .dst = 3, .src = 2, .type_name = "CallbackState", .type_id = 91 } },
                    .{ .native_state_field_set = .{ .state = 3, .field_index = 0, .src = 1, .field_ty = callback_ty } },
                    .{ .load_local = .{ .dst = 0, .local = 0, .ownership = .move } },
                    .{ .const_int = .{ .dst = 0, .value = 0 } },
                    .{ .native_state_field_get = .{ .dst = 4, .state = 3, .field_index = 0, .field_ty = callback_ty } },
                    .{ .call_value = .{ .callee = 4, .args = &.{}, .dst = 5 } },
                    .{ .ret = .{ .src = 5 } },
                }),
            },
            .{
                .id = 1,
                .name = "callback",
                .param_count = 0,
                .return_type = .{ .kind = .integer, .name = "I64" },
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_int = .{ .dst = 0, .value = 42 } },
                    .{ .ret = .{ .src = 0 } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer: [1]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding.writer, .{});
    try std.testing.expectEqual(@as(i64, 42), result.integer);
    try std.testing.expectEqual(@as(usize, 0), vm.heap.count());
}

test "native state preserves nested enum values inside arrays of structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const layer_array_ty = bytecode.TypeRef{ .kind = .array, .name = "Layer" };
    const mode_enum_ty = bytecode.TypeRef{ .kind = .enum_instance, .name = "Mode" };
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{
                .name = "Layer",
                .fields = @constCast(&[_]bytecode.Field{.{ .name = "payload", .ty = mode_enum_ty }}),
            },
            .{
                .name = "State",
                .fields = @constCast(&[_]bytecode.Field{.{ .name = "layers", .ty = layer_array_ty }}),
            },
        }),
        .enums = @constCast(&[_]bytecode.EnumTypeDecl{.{
            .name = "Mode",
            .variants = @constCast(&[_]bytecode.EnumVariantDecl{
                .{ .name = "None", .discriminant = 0 },
                .{ .name = "Surface", .discriminant = 1 },
            }),
        }}),
        .functions = @constCast(&[_]bytecode.Function{.{
            .id = 0,
            .name = "main",
            .param_count = 0,
            .return_type = .{ .kind = .integer, .name = "I64" },
            .register_count = 13,
            .local_count = 0,
            .local_types = &.{},
            .instructions = @constCast(&[_]bytecode.Instruction{
                .{ .const_int = .{ .dst = 0, .value = 1 } },
                .{ .alloc_struct = .{ .dst = 1, .type_name = "State" } },
                .{ .field_ptr = .{ .dst = 2, .base = 1, .base_type_name = "State", .field_index = 0, .field_ty = layer_array_ty } },
                .{ .alloc_array = .{ .dst = 3, .len = 0 } },
                .{ .alloc_struct = .{ .dst = 4, .type_name = "Layer" } },
                .{ .field_ptr = .{ .dst = 5, .base = 4, .base_type_name = "Layer", .field_index = 0, .field_ty = mode_enum_ty } },
                .{ .alloc_enum = .{ .dst = 6, .enum_type_name = "Mode", .discriminant = 1 } },
                .{ .store_indirect = .{ .ptr = 5, .src = 6, .ty = mode_enum_ty } },
                .{ .array_append = .{ .array = 3, .src = 4 } },
                .{ .store_indirect = .{ .ptr = 2, .src = 3, .ty = layer_array_ty } },
                .{ .alloc_native_state = .{ .dst = 7, .src = 1, .type_name = "State", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 8, .state = 7, .type_name = "State", .type_id = 77 } },
                .{ .field_ptr = .{ .dst = 9, .base = 8, .base_type_name = "State", .field_index = 0, .field_ty = layer_array_ty } },
                .{ .load_indirect = .{ .dst = 10, .ptr = 9, .ty = layer_array_ty } },
                .{ .array_get = .{ .dst = 11, .array = 10, .index = 0, .ty = .{ .kind = .ffi_struct, .name = "Layer" } } },
                .{ .field_ptr = .{ .dst = 12, .base = 11, .base_type_name = "Layer", .field_index = 0, .field_ty = mode_enum_ty } },
                .{ .load_indirect = .{ .dst = 6, .ptr = 12, .ty = mode_enum_ty } },
                .{ .enum_tag = .{ .dst = 0, .src = 6 } },
                .{ .ret = .{ .src = 0 } },
            }),
        }}),
        .entry_function_id = 0,
    };

    var discard_buffer_4: [1]u8 = undefined;
    var discarding_4: std.Io.Writer.Discarding = .init(&discard_buffer_4);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding_4.writer, .{});
    try std.testing.expectEqual(@as(i64, 1), result.integer);
}

test "native state preserves direct enum struct fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const mode_enum_ty = bytecode.TypeRef{ .kind = .enum_instance, .name = "Mode" };
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{.{
            .name = "State",
            .fields = @constCast(&[_]bytecode.Field{.{ .name = "mode", .ty = mode_enum_ty }}),
        }}),
        .enums = @constCast(&[_]bytecode.EnumTypeDecl{.{
            .name = "Mode",
            .variants = @constCast(&[_]bytecode.EnumVariantDecl{
                .{ .name = "None", .discriminant = 0 },
                .{ .name = "Surface", .discriminant = 1 },
            }),
        }}),
        .functions = @constCast(&[_]bytecode.Function{.{
            .id = 0,
            .name = "main",
            .param_count = 0,
            .return_type = .{ .kind = .integer, .name = "I64" },
            .register_count = 8,
            .local_count = 0,
            .local_types = &.{},
            .instructions = @constCast(&[_]bytecode.Instruction{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "State" } },
                .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "State", .field_index = 0, .field_ty = mode_enum_ty } },
                .{ .alloc_enum = .{ .dst = 2, .enum_type_name = "Mode", .discriminant = 1 } },
                .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = mode_enum_ty } },
                .{ .alloc_native_state = .{ .dst = 3, .src = 0, .type_name = "State", .type_id = 81 } },
                .{ .recover_native_state = .{ .dst = 4, .state = 3, .type_name = "State", .type_id = 81 } },
                .{ .field_ptr = .{ .dst = 5, .base = 4, .base_type_name = "State", .field_index = 0, .field_ty = mode_enum_ty } },
                .{ .load_indirect = .{ .dst = 6, .ptr = 5, .ty = mode_enum_ty } },
                .{ .enum_tag = .{ .dst = 7, .src = 6 } },
                .{ .ret = .{ .src = 7 } },
            }),
        }}),
        .entry_function_id = 0,
    };

    var discard_buffer: [1]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding.writer, .{});
    try std.testing.expectEqual(@as(i64, 1), result.integer);
}

test "native state recovery validates the expected type id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{.{
            .name = "CounterState",
            .fields = @constCast(&[_]bytecode.Field{.{ .name = "count", .ty = .{ .kind = .integer, .name = "I64" } }}),
        }}),
        .functions = @constCast(&[_]bytecode.Function{.{
            .id = 0,
            .name = "main",
            .param_count = 0,
            .register_count = 3,
            .local_count = 0,
            .local_types = &.{},
            .instructions = @constCast(&[_]bytecode.Instruction{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "CounterState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "CounterState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "CounterState", .type_id = 88 } },
                .{ .ret = .{ .src = null } },
            }),
        }}),
        .entry_function_id = 0,
    };

    var discard_buffer_5: [1]u8 = undefined;
    var discarding_5: std.Io.Writer.Discarding = .init(&discard_buffer_5);
    try std.testing.expectError(error.RuntimeFailure, vm.runFunctionById(&module, 0, &.{}, &discarding_5.writer, .{}));
    try std.testing.expect(std.mem.indexOf(u8, vm.lastError().?, "wrong state type") != null);
}
