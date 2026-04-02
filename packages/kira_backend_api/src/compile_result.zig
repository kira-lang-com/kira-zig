pub const ArtifactKind = enum {
    bytecode,
    native_object,
    native_library,
    executable,
    hybrid_bundle,
};

pub const Artifact = struct {
    kind: ArtifactKind,
    path: []const u8,
};

pub const CompileResult = struct {
    artifacts: []const Artifact,
};
