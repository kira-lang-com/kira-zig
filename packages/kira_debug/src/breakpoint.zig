//! breakpoint — the backend-agnostic breakpoint registry. `BreakpointTable` is a
//! pure data structure: it stores `BreakpointSpec`s, hands out monotonic u32 ids,
//! and tracks per-breakpoint metadata (an optional condition string, an enabled
//! flag, a hit count, and a resolved backend location). It knows nothing about VM
//! pcs or native addresses beyond storing the `u64` a `DebugTarget` fills in after
//! arming, so both backends and the hybrid session share one registry.
//!
//! The table owns every string it stores. `add` deep-copies the spec's embedded
//! strings (line file, function name, watch expr) and the optional condition, so a
//! caller may free its own buffers immediately after adding. `remove`/`deinit`
//! free those copies. Ids are never reused: `remove` frees the slot but the next
//! `add` still advances the counter, so a stale id from an old breakpoint can
//! never silently alias a new one.
const std = @import("std");
const debug_info = @import("debug_info.zig");

const BreakpointSpec = debug_info.BreakpointSpec;
const WatchKind = debug_info.WatchKind;

/// One registered breakpoint plus the mutable metadata the session maintains for
/// it. `resolved_location` is null until a `DebugTarget` arms the breakpoint and
/// calls `markResolved` with the concrete VM pc / native address.
pub const Entry = struct {
    /// Monotonic id, unique for the lifetime of the table (never reused).
    id: u32,
    /// The (table-owned) anchor: line, function, address, or watch.
    spec: BreakpointSpec,
    /// Optional (table-owned) condition expression; the breakpoint only stops
    /// when this evaluates truthy. Null means unconditional.
    condition: ?[]const u8,
    /// Disabled breakpoints stay registered but never stop the target.
    enabled: bool,
    /// How many times the target has reported stopping on this breakpoint.
    hit_count: u32,
    /// Backend location filled in when armed: VM pc or native address. Null until
    /// resolved (or after the underlying code is unloaded and it is re-pended).
    resolved_location: ?u64,
};

/// Stores breakpoints keyed by monotonic id. Not thread-safe; the debug session
/// serializes access. All contained strings are owned by the table.
pub const BreakpointTable = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(Entry),
    /// Next id to hand out; only ever increases.
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) BreakpointTable {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(Entry).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *BreakpointTable) void {
        for (self.entries.items) |*entry| self.freeEntry(entry);
        self.entries.deinit();
    }

    /// Register a breakpoint, deep-copying `spec`'s strings and `condition`.
    /// Returns the new breakpoint's id. The caller may free its own buffers
    /// immediately afterwards.
    pub fn add(self: *BreakpointTable, spec: BreakpointSpec, condition: ?[]const u8) !u32 {
        const owned_spec = try self.dupeSpec(spec);
        errdefer self.freeSpec(owned_spec);

        const owned_condition: ?[]const u8 = if (condition) |c|
            try self.allocator.dupe(u8, c)
        else
            null;
        errdefer if (owned_condition) |c| self.allocator.free(c);

        const id = self.next_id;
        try self.entries.append(.{
            .id = id,
            .spec = owned_spec,
            .condition = owned_condition,
            .enabled = true,
            .hit_count = 0,
            .resolved_location = null,
        });
        self.next_id += 1;
        return id;
    }

    /// Remove the breakpoint with `id`, freeing its owned strings. Returns
    /// `error.NotFound` if no such breakpoint exists. The id is not reused.
    pub fn remove(self: *BreakpointTable, id: u32) !void {
        const index = self.indexOf(id) orelse return error.NotFound;
        var entry = self.entries.orderedRemove(index);
        self.freeEntry(&entry);
    }

    /// Borrow a mutable pointer to the entry with `id`, or null if absent. The
    /// pointer is invalidated by any subsequent `add`/`remove`.
    pub fn get(self: *BreakpointTable, id: u32) ?*Entry {
        const index = self.indexOf(id) orelse return null;
        return &self.entries.items[index];
    }

    /// All entries in insertion order. Borrowed; valid until the next mutation.
    pub fn list(self: *const BreakpointTable) []Entry {
        return self.entries.items;
    }

    /// Record the concrete backend location a target resolved this breakpoint to.
    /// No-op if `id` is unknown.
    pub fn markResolved(self: *BreakpointTable, id: u32, location: u64) void {
        if (self.get(id)) |entry| entry.resolved_location = location;
    }

    /// Bump the hit count for `id`. No-op if `id` is unknown.
    pub fn recordHit(self: *BreakpointTable, id: u32) void {
        if (self.get(id)) |entry| entry.hit_count += 1;
    }

    fn indexOf(self: *const BreakpointTable, id: u32) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.id == id) return i;
        }
        return null;
    }

    fn dupeSpec(self: *BreakpointTable, spec: BreakpointSpec) !BreakpointSpec {
        return switch (spec) {
            .line => |l| .{ .line = .{ .file = try self.allocator.dupe(u8, l.file), .line = l.line } },
            .function => |name| .{ .function = try self.allocator.dupe(u8, name) },
            .address => |addr| .{ .address = addr },
            .watch => |w| .{ .watch = .{ .expr = try self.allocator.dupe(u8, w.expr), .kind = w.kind } },
        };
    }

    fn freeSpec(self: *BreakpointTable, spec: BreakpointSpec) void {
        switch (spec) {
            .line => |l| self.allocator.free(l.file),
            .function => |name| self.allocator.free(name),
            .address => {},
            .watch => |w| self.allocator.free(w.expr),
        }
    }

    fn freeEntry(self: *BreakpointTable, entry: *Entry) void {
        self.freeSpec(entry.spec);
        if (entry.condition) |c| self.allocator.free(c);
    }
};

test "add returns monotonic ids that survive removals" {
    var table = BreakpointTable.init(std.testing.allocator);
    defer table.deinit();

    const a = try table.add(.{ .line = .{ .file = "main.kira", .line = 10 } }, null);
    const b = try table.add(.{ .function = "compute" }, null);
    try std.testing.expectEqual(@as(u32, 1), a);
    try std.testing.expectEqual(@as(u32, 2), b);

    try table.remove(a);
    // Removing an id must not rewind the counter: the next id is still fresh.
    const c = try table.add(.{ .address = 0xdead }, null);
    try std.testing.expectEqual(@as(u32, 3), c);
    try std.testing.expect(c != a and c != b);
}

test "add deep-copies the spec strings and condition" {
    var table = BreakpointTable.init(std.testing.allocator);
    defer table.deinit();

    var file_buf = [_]u8{ 'a', '.', 'k' };
    var cond_buf = [_]u8{ 'x', '>', '0' };
    const id = try table.add(
        .{ .line = .{ .file = &file_buf, .line = 5 } },
        &cond_buf,
    );

    // Mutating the caller's buffers must not affect the stored copies.
    file_buf[0] = 'z';
    cond_buf[0] = 'y';

    const entry = table.get(id).?;
    try std.testing.expectEqualStrings("a.k", entry.spec.line.file);
    try std.testing.expectEqualStrings("x>0", entry.condition.?);
}

test "get returns null for unknown ids and a live pointer for known ones" {
    var table = BreakpointTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expect(table.get(42) == null);

    const id = try table.add(.{ .watch = .{ .expr = "total", .kind = .write } }, null);
    const entry = table.get(id).?;
    try std.testing.expectEqual(WatchKind.write, entry.spec.watch.kind);
    try std.testing.expect(entry.enabled);
    try std.testing.expectEqual(@as(u32, 0), entry.hit_count);
    try std.testing.expect(entry.resolved_location == null);
    try std.testing.expect(entry.condition == null);
}

test "list reflects insertion order and removals" {
    var table = BreakpointTable.init(std.testing.allocator);
    defer table.deinit();

    const a = try table.add(.{ .address = 0x1 }, null);
    _ = try table.add(.{ .address = 0x2 }, null);
    const c = try table.add(.{ .address = 0x3 }, null);

    try std.testing.expectEqual(@as(usize, 3), table.list().len);
    try table.remove(a);

    const remaining = table.list();
    try std.testing.expectEqual(@as(usize, 2), remaining.len);
    try std.testing.expectEqual(@as(u64, 0x2), remaining[0].spec.address);
    try std.testing.expectEqual(c, remaining[1].id);
}

test "remove reports NotFound for an unknown id" {
    var table = BreakpointTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.add(.{ .address = 0x10 }, null);
    try table.remove(id);
    try std.testing.expectError(error.NotFound, table.remove(id));
    try std.testing.expectError(error.NotFound, table.remove(999));
}

test "markResolved and recordHit update entry metadata" {
    var table = BreakpointTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.add(.{ .line = .{ .file = "m.kira", .line = 3 } }, null);

    table.recordHit(id);
    table.recordHit(id);
    table.markResolved(id, 0x4000);

    const entry = table.get(id).?;
    try std.testing.expectEqual(@as(u32, 2), entry.hit_count);
    try std.testing.expectEqual(@as(u64, 0x4000), entry.resolved_location.?);

    // Unknown ids are silently ignored, not a crash.
    table.recordHit(9999);
    table.markResolved(9999, 0x1);
}
