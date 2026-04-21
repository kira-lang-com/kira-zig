const std = @import("std");

pub const Type = enum {
    void,
    integer,
    float,
    boolean,
    string,
    c_string,
    raw_ptr,
    callback,
    ffi_struct,
    named,
    array,
    native_state,
    native_state_view,
    unknown,
};

pub const ResolvedType = struct {
    kind: Type,
    name: ?[]const u8 = null,

    pub fn eql(self: ResolvedType, other: ResolvedType) bool {
        if (self.kind != other.kind) return false;
        if (self.name == null or other.name == null) return true;
        if (self.name == null and other.name == null) return true;
        return std.mem.eql(u8, self.name.?, other.name.?);
    }

    pub fn plain(kind: Type) ResolvedType {
        return .{ .kind = kind };
    }
};
