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
    pin_count: usize = 0,
    kind: ObjectKind,
};

const PinFrame = struct {
    pinned: std.AutoHashMapUnmanaged(usize, void) = .{},
};

pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: std.AutoHashMap(usize, ObjectRecord),
    pin_frames: std.ArrayListUnmanaged(PinFrame) = .empty,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{
            .allocator = allocator,
            .objects = std.AutoHashMap(usize, ObjectRecord).init(allocator),
            .pin_frames = .empty,
        };
    }

    pub fn deinit(self: *Heap) void {
        while (self.pin_frames.items.len != 0) self.endBoundaryPinScope();
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

    pub fn beginBoundaryPinScope(self: *Heap) !void {
        try self.pin_frames.append(self.allocator, .{});
    }

    pub fn endBoundaryPinScope(self: *Heap) void {
        if (self.pin_frames.items.len == 0) return;
        const frame = self.pin_frames.pop().?;
        var iterator = frame.pinned.iterator();
        while (iterator.next()) |entry| self.unpinPtr(entry.key_ptr.*);
        var mutable = frame;
        mutable.pinned.deinit(self.allocator);
    }

    pub fn pinBoundaryValue(self: *Heap, value: runtime_abi.Value) !void {
        if (self.pin_frames.items.len == 0) return;
        var visited: std.AutoHashMapUnmanaged(usize, void) = .{};
        defer visited.deinit(self.allocator);
        const frame = &self.pin_frames.items[self.pin_frames.items.len - 1];
        try self.pinValueRecursive(value, frame, &visited);
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
        if (record_ptr.ref_count == 0) return;
        record_ptr.ref_count -= 1;
        if (record_ptr.ref_count != 0 or record_ptr.pin_count != 0) {
            return;
        }
        const removed = self.objects.fetchRemove(ptr) orelse return;
        self.destroy(removed.value.kind);
    }

    fn pinValueRecursive(self: *Heap, value: runtime_abi.Value, frame: *PinFrame, visited: *std.AutoHashMapUnmanaged(usize, void)) !void {
        if (value != .raw_ptr or value.raw_ptr == 0) return;
        const ptr = value.raw_ptr;
        const record = self.objects.getPtr(ptr) orelse return;
        if (visited.contains(ptr)) return;
        try visited.put(self.allocator, ptr, {});
        if (!frame.pinned.contains(ptr)) {
            try frame.pinned.put(self.allocator, ptr, {});
            record.pin_count += 1;
        }
        switch (record.kind) {
            .array => |object| {
                for (object.items[0..object.len]) |item| try self.pinValueRecursive(runtime_abi.bridgeValueToValue(item), frame, visited);
            },
            .closure => |closure| {
                for (closure.captures) |capture| try self.pinValueRecursive(capture, frame, visited);
            },
            .struct_fields => |fields| {
                for (fields) |field| try self.pinValueRecursive(field, frame, visited);
            },
        }
    }

    fn unpinPtr(self: *Heap, ptr: usize) void {
        if (ptr == 0) return;
        const record_ptr = self.objects.getPtr(ptr) orelse return;
        if (record_ptr.pin_count == 0) return;
        record_ptr.pin_count -= 1;
        if (record_ptr.pin_count != 0 or record_ptr.ref_count != 0) return;
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

test "boundary pin scopes preserve managed graphs until unpinned" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const nested_fields = try std.testing.allocator.alloc(runtime_abi.Value, 1);
    nested_fields[0] = .{ .integer = 7 };
    const nested_ptr = try heap.registerStruct(nested_fields);

    const fields = try std.testing.allocator.alloc(runtime_abi.Value, 1);
    fields[0] = .{ .raw_ptr = nested_ptr };
    const root_ptr = try heap.registerStruct(fields);

    heap.releaseValue(.{ .raw_ptr = nested_ptr });
    try heap.beginBoundaryPinScope();
    defer heap.endBoundaryPinScope();
    try heap.pinBoundaryValue(.{ .raw_ptr = root_ptr });

    heap.releaseValue(.{ .raw_ptr = root_ptr });
    try std.testing.expectEqual(@as(usize, 2), heap.count());
}

test "unpin destroys zero-ref objects" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const fields = try std.testing.allocator.alloc(runtime_abi.Value, 1);
    fields[0] = .{ .integer = 1 };
    const ptr = try heap.registerStruct(fields);

    try heap.beginBoundaryPinScope();
    try heap.pinBoundaryValue(.{ .raw_ptr = ptr });
    heap.releaseValue(.{ .raw_ptr = ptr });
    try std.testing.expectEqual(@as(usize, 1), heap.count());
    heap.endBoundaryPinScope();

    try std.testing.expectEqual(@as(usize, 0), heap.count());
}
