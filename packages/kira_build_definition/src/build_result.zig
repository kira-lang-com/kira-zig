const Artifact = @import("artifact.zig").Artifact;

pub const BuildResult = struct {
    artifacts: []const Artifact,
};
