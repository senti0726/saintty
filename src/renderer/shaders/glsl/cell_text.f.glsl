#include "common.glsl"

// Position the origin to the upper left, so the scroll clip below can be
// compared against the same coordinates the region is expressed in.
layout(origin_upper_left) in vec4 gl_FragCoord;

layout(binding = 0) uniform sampler2DRect atlas_grayscale;
layout(binding = 1) uniform sampler2DRect atlas_color;

// The bg cells buffer, for its pin mask (see cell_bg.f.glsl).
layout(binding = 1, std430) readonly buffer bg_cells {
    uint bg_colors[];
};

in CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
    flat float scroll_clip;
} in_data;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

void main() {
    // Scroll animation: clip text to the scrolling region.
    //
    // The vertex stage can only drop *whole* rows, so a row displaced by a
    // fraction of a cell was drawn in full and spilled past the region edge:
    // over nvim's status bar, and past the last line, where a row arriving
    // from off-screen appeared beyond its final position and then slid back
    // to it instead of entering from the edge. Clipping per fragment is what
    // makes a row slide in from the boundary rather than materialise outside
    // it.
    // Only rows the vertex stage actually displaced may be clipped. Testing
    // the band alone erased every glyph outside the scrolling region --
    // tmux's status line, nvim's bars, a prompt box an application keeps
    // pinned to the bottom -- for as long as any offset was live, so they
    // vanished and reappeared on every scrolled frame.
    bool recolor = false;
    if (in_data.scroll_clip > 0.5) {
        float band_top = grid_padding.x + scroll_anim.y * cell_size.y;
        float band_bot = grid_padding.x + (scroll_anim.z + 1.0) * cell_size.y;
        if (gl_FragCoord.y < band_top || gl_FragCoord.y >= band_bot) discard;
        // Sliding text passes UNDER a pinned cell, not over it.
        if (scroll_anim_cols.w > 0.0) {
            uvec2 gsz = unpack2u16(grid_size_packed_2u16);
            ivec2 cell = ivec2(floor((gl_FragCoord.xy - grid_padding.wx) / cell_size));
            uint m = 0u;
            if (cell.x >= 0 && cell.y >= 0 && cell.x < int(gsz.x) && cell.y < int(gsz.y)) {
                uint pidx = uint(scroll_anim_cols.w) + uint(cell.y) * gsz.x + uint(cell.x);
                m = bg_colors[pidx];
            }
            bool pin = (m & 0xFFu) != 0u;
            // Byte 1: the pin holds its text (see ScrollAnim.markPinnedText).
            bool held = ((m >> 8u) & 0xFFu) != 0u;
            // Text sliding across a colour-only bar is drawn in the bar's
            // own text colour: in yazi's light bar a name in its normal light
            // colour vanished, and with j held the list is always part-way
            // into a slide, so the hovered name was never readable. The bar
            // colour is the cell's background (not displaced: pinned); on a
            // light bar the text goes dark (the terminal's background colour),
            // on a dark one it stays as it is.
            if (pin && !held && in_data.scroll_clip < 2.5 && cell.x >= 0 && cell.y >= 0 &&
                cell.x < int(gsz.x) && cell.y < int(gsz.y)) {
                vec4 bar = load_color(unpack4u8(bg_colors[uint(cell.y) * gsz.x + uint(cell.x)]), true);
                float lum = dot(bar.rgb, vec3(0.2126, 0.7152, 0.0722));
                if (bar.a > 0.5 && lum > 0.35) recolor = true;
            }
            if (in_data.scroll_clip > 2.5) {
                // A colour-only pin's own text (yazi's hovered name, drawn in
                // the bar's colours): only where it is over the bar. Off it,
                // the underlay draws the same name in its normal colours.
                if (!pin) discard;
            } else if (in_data.scroll_clip > 1.5) {
                // What the overlay hides: never over the overlay itself.
                if (pin) discard;
            } else if (held) {
                discard;
            }
        }
    }

    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    switch (in_data.atlas) {
        default:
        case ATLAS_GRAYSCALE:
        {
            // Our input color is always linear.
            vec4 color = in_data.color;
            if (recolor) color = vec4(load_color(unpack4u8(bg_color_packed_4u8), true).rgb, 1.0);

            // If we're not doing linear blending, then we need to
            // re-apply the gamma encoding to our color manually.
            //
            // Since the alpha is premultiplied, we need to divide
            // it out before unlinearizing and re-multiply it after.
            if (!use_linear_blending) {
                color.rgb /= vec3(color.a);
                color = unlinearize(color);
                color.rgb *= vec3(color.a);
            }

            // Fetch our alpha mask for this pixel.
            float a = texture(atlas_grayscale, in_data.tex_coord).r;

            // Linear blending weight correction corrects the alpha value to
            // produce blending results which match gamma-incorrect blending.
            if (use_linear_correction) {
                // Short explanation of how this works:
                //
                // We get the luminances of the foreground and background colors,
                // and then unlinearize them and perform blending on them. This
                // gives us our desired luminance, which we derive our new alpha
                // value from by mapping the range [bg_l, fg_l] to [0, 1], since
                // our final blend will be a linear interpolation from bg to fg.
                //
                // This yields virtually identical results for grayscale blending,
                // and very similar but non-identical results for color blending.
                vec4 bg = in_data.bg_color;
                float fg_l = luminance(color.rgb);
                float bg_l = luminance(bg.rgb);
                // To avoid numbers going haywire, we don't apply correction
                // when the bg and fg luminances are within 0.001 of each other.
                if (abs(fg_l - bg_l) > 0.001) {
                    float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
                    a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
                }
            }

            // Multiply our whole color by the alpha mask.
            // Since we use premultiplied alpha, this is
            // the correct way to apply the mask.
            color *= a;

            out_FragColor = color;
            return;
        }

        case ATLAS_COLOR:
        {
            // For now, we assume that color glyphs
            // are already premultiplied linear colors.
            vec4 color = texture(atlas_color, in_data.tex_coord);

            // If we are doing linear blending, we can return this right away.
            if (use_linear_blending) {
                out_FragColor = color;
                return;
            }

            // Otherwise we need to unlinearize the color. Since the alpha is
            // premultiplied, we need to divide it out before unlinearizing.
            color.rgb /= vec3(color.a);
            color = unlinearize(color);
            color.rgb *= vec3(color.a);

            out_FragColor = color;
            return;
        }
    }
}
