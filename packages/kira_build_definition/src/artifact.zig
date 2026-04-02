pub const ArtifactKind = enum {
    bytecode,
    executable,
    documentation,
};

pub const Artifact = struct {
    kind: ArtifactKind,
    path: []const u8,
};
