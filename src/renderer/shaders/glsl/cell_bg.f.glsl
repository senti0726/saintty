#include "common.glsl"

// Position the origin to the upper left
layout(origin_upper_left) in vec4 gl_FragCoord;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

layout(binding = 1, std430) readonly buffer bg_cells {
    uint cells[];
};

vec4 cell_bg() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    ivec2 grid_pos = ivec2(floor((gl_FragCoord.xy - grid_padding.wx) / cell_size));

    // Scroll animation: the text pass shifts cells inside the region, so the
    // background must sample the same shifted cell or text slides over a
    // stationary background. Undo the shift to find which cell is under this
    // pixel. Rows that shift out of the region are the gap left behind by the
    // scroll and draw as nothing.
    // A pinned cell (an overlay the scroll passes under: a selection bar, a
    // label) keeps its own background, undisplaced. The mask rides after
    // the bg cells at offset `scroll_anim_cols.w`.
    bool pinned_here = false;
    if (scroll_anim.x != 0.0 && scroll_anim_cols.w > 0.0 &&
        grid_pos.x >= 0 && grid_pos.y >= 0 &&
        grid_pos.x < int(grid_size.x) && grid_pos.y < int(grid_size.y)) {
        uint pidx = uint(scroll_anim_cols.w) + uint(grid_pos.y) * grid_size.x + uint(grid_pos.x);
        pinned_here = (cells[pidx] & 0xFFu) != 0u;
    }
    if (!pinned_here && scroll_anim.x != 0.0 &&
        float(grid_pos.y) >= scroll_anim.y &&
        float(grid_pos.y) <= scroll_anim.z &&
        float(grid_pos.x) >= scroll_anim_cols.x &&
        float(grid_pos.x) <= scroll_anim_cols.y) {
        float shifted = (gl_FragCoord.y - grid_padding.x - scroll_anim.x) / cell_size.y;
        int gy = int(floor(shifted));
        // Rows displaced past the edge of the region are the gap the scroll
        // left behind, and the gap must read as a blank line.
        //
        // Returning nothing is right: the full-screen `bg_color` pass has
        // already painted the global background underneath, and this pass
        // blends over it, so a transparent fragment here is exactly what a
        // cell with the default background looks like. It is *not* a hole
        // through to the desktop.
        //
        // Clamping to the edge row instead replicates that row's colors down
        // the whole gap, which turns tmux's blue copy-mode row into a solid
        // blue block the height of the scroll.
        //
        // Unless the renderer kept that row: the rows a scroll carried out of
        // the region are drawn in the band (ghost rows, cell_text), and their
        // backgrounds are appended after the grid's own as an extended grid
        // with `scroll_anim.w` rows above row 0 and below the last. Without
        // them, kept text lost its highlight -- inline code, table headers --
        // for as long as it was in the band.
        if (gy < int(scroll_anim.y) || gy > int(scroll_anim.z)) {
            int g = int(scroll_anim.w);
            if (g > 0 && gy >= -g && gy < int(grid_size.y) + g &&
                grid_pos.x >= 0 && grid_pos.x < int(grid_size.x)) {
                uint idx = grid_size.x * grid_size.y +
                    uint(gy + g) * grid_size.x + uint(grid_pos.x);
                return load_color(
                        unpack4u8(cells[idx]),
                        (bools & USE_LINEAR_BLENDING) != 0
                    );
            }
            return vec4(0.0);
        }
        // A pinned cell is drawn in place (above); its slid copy is not.
        // What slides away from under it is what the overlay hid: the
        // colour the scroll carried into that cell, kept from the frame
        // before (the grid after the mask; see generic.zig
        // `scroll_pin_under`). Drawing nothing there showed a black box the
        // size of Claude Code's label, or of yazi's bar, beside the real one
        // on every fast scroll.
        if (scroll_anim_cols.w > 0.0 && grid_pos.x >= 0 && grid_pos.x < int(grid_size.x)) {
            uint sidx = uint(scroll_anim_cols.w) + uint(gy) * grid_size.x + uint(grid_pos.x);
            if ((cells[sidx] & 0xFFu) != 0u) {
                uint uidx = sidx + grid_size.x * grid_size.y;
                return load_color(
                        unpack4u8(cells[uidx]),
                        (bools & USE_LINEAR_BLENDING) != 0
                    );
            }
        }
        grid_pos.y = gy;
    }
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    vec4 bg = vec4(0.0);

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > grid_size.x - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = int(grid_size.x) - 1;
        } else {
            return bg;
        }
    }

    // Clamp y position if we should extend, otherwise discard if out of bounds.
    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.y > grid_size.y - 1) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = int(grid_size.y) - 1;
        } else {
            return bg;
        }
    }

    // Load the color for the cell.
    vec4 cell_color = load_color(
            unpack4u8(cells[grid_pos.y * grid_size.x + grid_pos.x]),
            use_linear_blending
        );

    return cell_color;
}

void main() {
    out_FragColor = cell_bg();
}
