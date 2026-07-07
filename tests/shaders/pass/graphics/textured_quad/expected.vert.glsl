#version 330 core

struct VertexIn {
    vec3 position;
    vec2 uv;
};

struct FragmentOut {
    vec4 color;
};

struct CameraUniform {
    mat4 view_projection;
};

struct SurfaceUniform {
    vec4 tint;
};

struct VertexToFragment {
    vec4 clip_position;
    vec2 uv;
};

const bool use_tint = true;

layout(std140) uniform camera_Block {
    mat4 view_projection;
} camera;

layout(std140) uniform surface_Block {
    vec4 tint;
} surface;

uniform sampler2D kira_albedo_linear;

layout(location = 0) in vec3 kira_attr_position;
layout(location = 1) in vec2 kira_attr_uv;
out vec2 kira_varying_uv;

VertexToFragment TexturedQuad__vertex__entry(VertexIn kira_input_param) {
    VertexToFragment kira_out;
    kira_out.clip_position = (camera.view_projection * vec4(kira_input_param.position, 1.0));
    kira_out.uv = kira_input_param.uv;
    return kira_out;
}

void main() {
    VertexIn kira_input;
    kira_input.position = kira_attr_position;
    kira_input.uv = kira_attr_uv;
    VertexToFragment kira_output = TexturedQuad__vertex__entry(kira_input);
    gl_Position = kira_output.clip_position;
    kira_varying_uv = kira_output.uv;
}
