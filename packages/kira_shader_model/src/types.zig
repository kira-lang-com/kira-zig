const std = @import("std");

pub const Stage = enum {
    vertex,
    fragment,
    compute,
};

pub const InterfaceDirection = enum {
    input,
    output,
};

pub const ScalarType = enum {
    bool,
    int,
    uint,
    float,
};

pub const VectorType = struct {
    scalar: ScalarType,
    width: u8,
};

pub const MatrixType = struct {
    columns: u8,
    rows: u8,
};

pub const TextureDimension = enum {
    texture_2d,
    texture_cube,
    depth_2d,
};

pub const SamplerKind = enum {
    filtering,
    comparison,
};

pub const AccessMode = enum {
    read,
    read_write,
};

pub const Interpolation = enum {
    perspective,
    linear,
    flat,
};

pub const Builtin = enum {
    position,
    vertex_index,
    instance_index,
    front_facing,
    frag_coord,
    thread_id,
    local_id,
    group_id,
    local_index,
};

pub const Type = union(enum) {
    void: void,
    scalar: ScalarType,
    vector: VectorType,
    matrix: MatrixType,
    struct_ref: []const u8,
    texture: TextureDimension,
    sampler: SamplerKind,
    runtime_array: *const Type,
};

pub fn builtinAllowed(builtin: Builtin, stage: Stage, direction: InterfaceDirection) bool {
    return switch (builtin) {
        .position => (stage == .vertex and direction == .output) or (stage == .fragment and direction == .input),
        .vertex_index, .instance_index => stage == .vertex and direction == .input,
        .front_facing, .frag_coord => stage == .fragment and direction == .input,
        .thread_id, .local_id, .group_id, .local_index => stage == .compute and direction == .input,
    };
}

test "builtin legality follows stage direction rules" {
    try std.testing.expect(builtinAllowed(.position, .vertex, .output));
    try std.testing.expect(!builtinAllowed(.position, .vertex, .input));
    try std.testing.expect(builtinAllowed(.position, .fragment, .input));
    try std.testing.expect(builtinAllowed(.thread_id, .compute, .input));
    try std.testing.expect(!builtinAllowed(.thread_id, .fragment, .input));
}
