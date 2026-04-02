pub fn Id(comptime _: type) type {
    return struct {
        value: u32,

        pub fn init(value: u32) @This() {
            return .{ .value = value };
        }
    };
}

pub const ModuleId = Id(struct {});
pub const SymbolId = Id(struct {});
pub const LibraryId = Id(struct {});
pub const BridgeId = Id(struct {});
