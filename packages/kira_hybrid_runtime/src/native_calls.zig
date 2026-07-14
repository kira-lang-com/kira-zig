const std = @import("std");
const bytecode = @import("kira_bytecode");
const hybrid = @import("kira_hybrid_definition");
const runtime_abi = @import("kira_runtime_abi");

pub fn callNative(self: anytype, function_id: u32, args: []const runtime_abi.Value) !runtime_abi.Value {
    try self.vm.beginNativeBoundary();
    defer self.vm.endNativeBoundary();

    const function_decl = findFunction(self.manifest.functions, function_id) orelse return error.UnknownFunction;
    if (std.c.getenv("KIRA_DBG") != null) {
        const kname = if (self.module.findFunctionById(function_id)) |fd| fd.name else "<none>";
        std.debug.print("DBG callNative fn={s} kira={s}({d}) args={d} ret={s}\n", .{ function_decl.exported_name orelse "?", kname, function_id, args.len, @tagName(function_decl.return_type.kind) });
    }
    const lowered_args = try self.allocator.alloc(runtime_abi.Value, args.len);
    defer self.allocator.free(lowered_args);
    const native_arg_ptrs = try self.allocator.alloc(usize, args.len);
    defer self.allocator.free(native_arg_ptrs);
    @memset(native_arg_ptrs, 0);
    defer {
        for (native_arg_ptrs, 0..) |native_ptr, index| {
            if (native_ptr == 0 or index >= function_decl.param_types.len) continue;
            const param_type = function_decl.param_types[index];
            if (ownershipTransfersToCallee(paramOwnershipAt(function_decl.param_ownership, index)) and param_type.kind != .enum_instance) continue;
            switch (param_type.kind) {
                .ffi_struct => if (param_type.name) |name| {
                    self.vm.destroyStructNativeLayout(&self.module, name, native_ptr);
                },
                .array => self.vm.destroyArrayNativeLayout(
                    &self.module,
                    convertManifestTypeRef(param_type),
                    native_ptr,
                ),
                .enum_instance => if (param_type.name) |name| {
                    self.vm.destroyEnumNativeLayout(&self.module, name, native_ptr);
                },
                else => {},
            }
        }
    }

    for (args, 0..) |arg, index| {
        try self.vm.pinNativeBoundaryValue(arg);
        lowered_args[index] = arg;
        if (index >= function_decl.param_types.len) continue;
        const param_type = function_decl.param_types[index];
        if (arg != .raw_ptr or arg.raw_ptr == 0) continue;
        switch (param_type.kind) {
            .raw_ptr => {
                if (param_type.name) |name| {
                    if (isCallbackTypeName(name) and self.vm.heap.getClosure(arg.raw_ptr) != null) {
                        // A closure whose body is native-executed is stripped from the
                        // VM bytecode module in hybrid mode, so the export bridge cannot
                        // recover its capture types from the module. Supply them from the
                        // manifest (which retains every function's metadata). The outer
                        // slice is freed here; the TypeRef `.name` fields alias
                        // manifest-owned strings and are consumed synchronously.
                        const ext = try resolveExportedClosureCaptureTypes(self, arg.raw_ptr);
                        defer if (ext) |slice| self.allocator.free(slice);
                        lowered_args[index] = .{ .raw_ptr = try self.vm.exportRuntimeClosureToNative(&self.module, arg.raw_ptr, ext) };
                    }
                }
            },
            .ffi_struct => {
                native_arg_ptrs[index] = try self.vm.lowerStructToNativeLayout(
                    &self.module,
                    param_type.name orelse return error.RuntimeFailure,
                    arg.raw_ptr,
                );
                lowered_args[index] = .{ .raw_ptr = native_arg_ptrs[index] };
            },
            .array => {
                native_arg_ptrs[index] = try self.vm.copyArrayToNativeLayout(
                    &self.module,
                    convertManifestTypeRef(param_type),
                    arg.raw_ptr,
                );
                lowered_args[index] = .{ .raw_ptr = native_arg_ptrs[index] };
            },
            .enum_instance => {
                native_arg_ptrs[index] = try self.vm.copyEnumToNativeLayout(
                    &self.module,
                    param_type.name orelse return error.RuntimeFailure,
                    arg.raw_ptr,
                );
                lowered_args[index] = .{ .raw_ptr = native_arg_ptrs[index] };
            },
            else => {},
        }
    }

    if (std.c.getenv("KIRA_DBG") != null) std.debug.print("DBG callNative fn={d} -> bridge.call START\n", .{function_id});
    const result = try self.bridge.call(function_id, lowered_args);
    if (std.c.getenv("KIRA_DBG") != null) std.debug.print("DBG callNative fn={d} -> bridge.call DONE tag={s}\n", .{ function_id, @tagName(result) });
    self.vm.retainManagedValue(result);
    // The borrow-mut sync-back below is fallible; release the retain on error so the managed
    // return value is not leaked. On success the caller owns the retained result.
    errdefer self.vm.dropManagedValue(result);
    for (native_arg_ptrs, 0..) |native_ptr, index| {
        if (native_ptr == 0) continue;
        if (!ownershipSyncsBack(paramOwnershipAt(function_decl.param_ownership, index))) continue;
        const param_type = function_decl.param_types[index];
        switch (param_type.kind) {
            .ffi_struct => try self.vm.syncStructFromNativeLayout(
                &self.module,
                param_type.name orelse return error.RuntimeFailure,
                args[index].raw_ptr,
                native_ptr,
            ),
            .array => try self.vm.syncArrayFromNativeLayout(
                &self.module,
                convertManifestTypeRef(param_type),
                args[index].raw_ptr,
                native_ptr,
            ),
            else => {},
        }
    }

    return result;
}

pub fn callNativeFunction(self: anytype, function_id: u32, args: []const runtime_abi.Value) !runtime_abi.Value {
    try self.vm.beginNativeBoundary();
    defer self.vm.endNativeBoundary();

    const result = try self.bridge.call(function_id, args);
    self.vm.retainManagedValue(result);
    return result;
}

/// Recover the capture types for a runtime closure whose body is native-executed
/// (and therefore stripped from the VM bytecode module in hybrid mode) so the
/// export bridge can lower its captures. Returns null — leaving the bridge's own
/// module lookup to resolve the types — when the body still lives in the VM module,
/// when the closure/function is unknown, or when the manifest lacks enough
/// parameter metadata. The caller owns and frees the returned slice; the element
/// `.name` fields alias manifest-owned strings and must not be freed.
fn resolveExportedClosureCaptureTypes(self: anytype, closure_ptr: usize) !?[]bytecode.TypeRef {
    const closure = self.vm.heap.getClosure(closure_ptr) orelse return null;
    // Runtime-executed bodies remain in the VM module; the bridge resolves them.
    if (self.module.findFunctionById(closure.function_id) != null) return null;
    const function_decl = findFunction(self.manifest.functions, closure.function_id) orelse return null;
    if (function_decl.param_types.len < closure.captures.len) return null;
    const capture_types = try self.allocator.alloc(bytecode.TypeRef, closure.captures.len);
    const start = function_decl.param_types.len - closure.captures.len;
    for (capture_types, 0..) |*ty, index| {
        ty.* = convertManifestTypeRef(function_decl.param_types[start + index]);
    }
    return capture_types;
}

fn findFunction(functions: []const hybrid.FunctionManifest, function_id: u32) ?hybrid.FunctionManifest {
    for (functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl;
    }
    return null;
}

fn convertManifestTypeRef(value: hybrid.TypeRef) bytecode.TypeRef {
    return .{
        .kind = switch (value.kind) {
            .void => .void,
            .integer => .integer,
            .float => .float,
            .string => .string,
            .boolean => .boolean,
            .construct_any => .construct_any,
            .array => .array,
            .raw_ptr => .raw_ptr,
            .ffi_struct => .ffi_struct,
            .enum_instance => .enum_instance,
        },
        .name = value.name,
        .construct_constraint = if (value.construct_constraint) |constraint| .{ .construct_name = constraint.construct_name } else null,
    };
}

fn isCallbackTypeName(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "->") != null;
}

fn paramOwnershipAt(param_ownership: []const hybrid.OwnershipMode, index: usize) hybrid.OwnershipMode {
    if (index < param_ownership.len) return param_ownership[index];
    return .owned;
}

fn ownershipTransfersToCallee(mode: hybrid.OwnershipMode) bool {
    return switch (mode) {
        .owned, .move => true,
        .borrow_read, .borrow_mut, .copy => false,
    };
}

fn ownershipSyncsBack(mode: hybrid.OwnershipMode) bool {
    return mode == .borrow_mut;
}
