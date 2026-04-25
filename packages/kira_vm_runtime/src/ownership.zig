const std = @import("std");
const runtime_abi = @import("kira_runtime_abi");

pub const ArrayObject = extern struct {
    len: usize,
    items: [*]runtime_abi.BridgeValue,
};

pub const ClosureObject = struct {
    function_id: u32,
    captures: []runtime_abi.Value,
};

const ObjectKind = union(enum) {
    array: *ArrayObject,
    closure: *ClosureObject,
    struct_fields: []runtime_abi.Value,
};

const ObjectRecord = struct {
    ref_count: usize,
    kind: ObjectKind,
};

pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: std.AutoHashMap(usize, ObjectRecord),

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator, .objects = std.AutoHashMap(usize, ObjectRecord).init(allocator) };
    }

    pub fn deinit(self: *Heap) void {
        while (self.objects.count() != 0) {
            var iterator = self.objects.iterator();
            if (iterator.next()) |entry| self.releasePtr(entry.key_ptr.*);
        }
        self.objects.deinit();
    }

    pub fn registerArray(self: *Heap, object: *ArrayObject) !usize {
        const ptr = @intFromPtr(object);
        try self.objects.put(ptr, .{ .ref_count = 1, .kind = .{ .array = object } });
        return ptr;
    }

    pub fn registerClosure(self: *Heap, object: *ClosureObject) !usize {
        const ptr = @intFromPtr(object);
        try self.objects.put(ptr, .{ .ref_count = 1, .kind = .{ .closure = object } });
        return ptr;
    }

    pub fn registerStruct(self: *Heap, fields: []runtime_abi.Value) !usize {
        const ptr = @intFromPtr(fields.ptr);
        try self.objects.put(ptr, .{ .ref_count = 1, .kind = .{ .struct_fields = fields } });
        return ptr;
    }

    pub fn count(self: *const Heap) usize {
        return self.objects.count();
    }

    pub fn retainValue(self: *Heap, value: runtime_abi.Value) void {
        if (value == .raw_ptr) self.retainPtr(value.raw_ptr);
    }

    pub fn releaseValue(self: *Heap, value: runtime_abi.Value) void {
        if (value == .raw_ptr) self.releasePtr(value.raw_ptr);
    }

    pub fn isManagedValue(self: *const Heap, value: runtime_abi.Value) bool {
        return value == .raw_ptr and self.objects.contains(value.raw_ptr);
    }

    pub fn assignOwned(self: *Heap, slot: *runtime_abi.Value, value: runtime_abi.Value) void {
        const old = slot.*;
        slot.* = value;
        self.releaseValue(old);
    }

    pub fn assignBorrowed(self: *Heap, slot: *runtime_abi.Value, value: runtime_abi.Value) void {
        self.retainValue(value);
        const old = slot.*;
        slot.* = value;
        self.releaseValue(old);
    }

    pub fn releaseSlots(self: *Heap, slots: []runtime_abi.Value) void {
        for (slots) |*slot| self.assignOwned(slot, .{ .void = {} });
    }

    pub fn replaceArrayItem(self: *Heap, slot: *runtime_abi.BridgeValue, value: runtime_abi.Value) void {
        self.retainValue(value);
        const old = runtime_abi.bridgeValueToValue(slot.*);
        slot.* = runtime_abi.bridgeValueFromValue(value);
        self.releaseValue(old);
    }

    fn retainPtr(self: *Heap, ptr: usize) void {
        if (ptr == 0) return;
        if (self.objects.getPtr(ptr)) |record| record.ref_count += 1;
    }

    fn releasePtr(self: *Heap, ptr: usize) void {
        if (ptr == 0) return;
        const record_ptr = self.objects.getPtr(ptr) orelse return;
        if (record_ptr.ref_count > 1) {
            record_ptr.ref_count -= 1;
            return;
        }
        const removed = self.objects.fetchRemove(ptr) orelse return;
        self.destroy(removed.value.kind);
    }

    fn destroy(self: *Heap, kind: ObjectKind) void {
        switch (kind) {
            .array => |object| {
                const items = object.items[0..@max(object.len, 1)];
                for (items[0..object.len]) |item| self.releaseValue(runtime_abi.bridgeValueToValue(item));
                self.allocator.free(items);
                self.allocator.destroy(object);
            },
            .closure => |closure| {
                self.releaseSlots(closure.captures);
                self.allocator.free(closure.captures);
                self.allocator.destroy(closure);
            },
            .struct_fields => |fields| {
                self.releaseSlots(fields);
                self.allocator.free(fields);
            },
        }
    }
};
