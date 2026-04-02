const hybrid = @import("kira_hybrid_definition");

pub const NativeBridge = struct {
    pub fn bind(_: NativeBridge, _: hybrid.BridgeDescriptor) !void {
        return error.NotImplemented;
    }
};
