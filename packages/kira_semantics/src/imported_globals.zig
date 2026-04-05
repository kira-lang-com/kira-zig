const std = @import("std");

pub const ImportedGlobals = struct {
    constructs: []const []const u8 = &.{},
    callables: []const []const u8 = &.{},

    pub fn hasConstruct(self: ImportedGlobals, name: []const u8) bool {
        return contains(self.constructs, name);
    }

    pub fn hasCallable(self: ImportedGlobals, name: []const u8) bool {
        return contains(self.callables, name);
    }

    fn contains(values: []const []const u8, name: []const u8) bool {
        for (values) |value| {
            if (std.mem.eql(u8, value, name)) return true;
        }
        return false;
    }
};
