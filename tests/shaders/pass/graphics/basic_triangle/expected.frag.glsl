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

in vec4 kira_varying_color;
layout(location = 0) out vec4 kira_frag_color;

FragmentOut BasicTriangle__fragment__entry(VertexOut input) {
    FragmentOut out;
    out.color = input.color;
    return out;
}

void main() {
    VertexOut kira_input;
    kira_input.color = kira_varying_color;
    FragmentOut kira_output = BasicTriangle__fragment__entry(kira_input);
    kira_frag_color = kira_output.color;
}
