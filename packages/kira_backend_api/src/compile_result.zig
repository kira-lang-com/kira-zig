pub const ArtifactKind = enum {
    bytecode,
    native_object,
    hybrid_bundle,
};

pub const CompileResult = struct {
    kind: ArtifactKind,
    artifact_bytes: []const u8,
};
