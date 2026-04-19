#version 330 core

struct VertexIn {
    vec2 position;
};

struct FragmentOut {
    vec4 color;
};

struct VertexOut {
    vec4 clip_position;
    vec4 color;
};

layout(location = 0) in vec2 kira_attr_position;
out vec4 kira_varying_color;

VertexOut BasicTriangle__vertex__entry(VertexIn input) {
    VertexOut out;
    out.clip_position = vec4(input.position, 0, 1);
    out.color = vec4(1, 0.25, 0.25, 1);
    return out;
}

void main() {
    VertexIn kira_input;
    kira_input.position = kira_attr_position;
    VertexOut kira_output = BasicTriangle__vertex__entry(kira_input);
    gl_Position = kira_output.clip_position;
    kira_varying_color = kira_output.color;
}
