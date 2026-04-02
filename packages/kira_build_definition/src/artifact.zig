pub const ArtifactKind = enum {
    bytecode,
    native_object,
    native_library,
    executable,
    hybrid_manifest,
    documentation,
};

pub const Artifact = struct {
    kind: ArtifactKind,
    path: []const u8,
};
