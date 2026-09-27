#include "common.glsl"

layout(binding = 0) uniform sampler2D image;

// Position the origin to the upper left, as cell_text.f.glsl does.
layout(origin_upper_left) in vec4 gl_FragCoord;

in vec2 tex_coord;
in float scroll_clip;

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // A displaced slice draws only inside the animated region's rows.
    if (scroll_clip > 0.5) {
        float band_top = grid_padding.x + scroll_anim.y * cell_size.y;
        float band_bot = grid_padding.x + (scroll_anim.z + 1.0) * cell_size.y;
        if (gl_FragCoord.y < band_top || gl_FragCoord.y >= band_bot) discard;
    }

    vec4 rgba = texture(image, tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= vec3(rgba.a);

    out_FragColor = rgba;
}
