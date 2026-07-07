//! Shared VM data types.
//!
//! Plain data definitions used by `Vm` and the native bridge: the C-ABI
//! `NativeStateBox` token, the exported-closure registry entry, and the
//! native-layout allocation statistics. Split from vm.zig so the `Vm` struct
//! file stays focused on behavior; vm.zig re-exports the public names, so
//! `vm_mod.NativeStateBox` / `vm_mod.ExportedNativeClosure` references are
//! unchanged.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");

/// VM-side native-state token.
///
/// The leading three fields (`type_id`, `payload`, `runtime_payload`) are the C-ABI prefix
/// shared with the native backend's `KiraNativeState` in
/// `packages/kira_native_bridge/src/runtime_helpers.c`. Everything after that prefix is
/// VM-internal metadata used to clean up Zig-allocated payloads at shutdown
/// (see `deinitTrackedNativeStates`); the native backend never reads those fields.
///
/// Tokens are NOT cast across backends: VM tokens are always allocated and read here
/// (`allocateNativeState`/`recoverNativeState`), and their `payload`/`runtime_payload` hold
/// Zig `BridgeValue`/`Value` arrays, whereas the C path's payload is a raw byte buffer with
/// incompatible semantics. The `comptime` block below enforces the shared prefix layout so the
/// two structs cannot silently drift apart at the C-visible boundary.
pub const NativeStateBox = extern struct {
    type_id: u64,
    payload: usize,
    runtime_payload: usize,
    module: *const bytecode.Module,
    type_name_ptr: [*]const u8,
    type_name_len: usize,
    field_count: usize,

    comptime {
        // Must match the 3-field `KiraNativeState` C struct prefix exactly.
        std.debug.assert(@offsetOf(NativeStateBox, "type_id") == 0);
        std.debug.assert(@offsetOf(NativeStateBox, "payload") == @sizeOf(u64));
        std.debug.assert(@offsetOf(NativeStateBox, "runtime_payload") == @sizeOf(u64) + @sizeOf(usize));
    }

    pub fn init(module: *const bytecode.Module, type_name: []const u8, type_id: u64, field_count: usize, payload: usize) NativeStateBox {
        return .{
            .type_id = type_id,
            .payload = payload,
            .runtime_payload = 0,
            .module = module,
            .type_name_ptr = type_name.ptr,
            .type_name_len = type_name.len,
            .field_count = field_count,
        };
    }

    pub fn typeName(self: *const NativeStateBox) []const u8 {
        return self.type_name_ptr[0..self.type_name_len];
    }
};

pub const ExportedNativeClosure = struct {
    native_ptr: usize,
    captures: []runtime_abi.Value,
};

pub const NativeLayoutStats = struct {
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
