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

uniform sampler2D albedo;

in vec2 kira_varying_uv;
layout(location = 0) out vec4 kira_frag_color;

FragmentOut TexturedQuad__fragment__entry(VertexToFragment input) {
    FragmentOut out;
    vec4 sampled = texture(albedo, input.uv);
    if (use_tint) {
        out.color = (sampled * surface.tint);
    } else {
        out.color = sampled;
    }
    return out;
}

void main() {
    VertexToFragment kira_input;
    kira_input.uv = kira_varying_uv;
    FragmentOut kira_output = TexturedQuad__fragment__entry(kira_input);
    kira_frag_color = kira_output.color;
}
