#include "common.glsl"

// The position of the glyph in the texture (x, y)
layout(location = 0) in uvec2 glyph_pos;

// The size of the glyph in the texture (w, h)
layout(location = 1) in uvec2 glyph_size;

// The left and top bearings for the glyph (x, y)
layout(location = 2) in ivec2 bearings;

// The grid coordinates (x, y) where x < columns and y < rows
layout(location = 3) in uvec2 grid_pos;

// The color of the rendered text glyph.
layout(location = 4) in uvec4 color;

// Which atlas this glyph is in.
layout(location = 5) in uint atlas;

// Misc glyph properties.
layout(location = 6) in uint glyph_bools;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

// Masks for the `glyph_bools` attribute
const uint NO_MIN_CONTRAST = 1u;
const uint IS_CURSOR_GLYPH = 2u;
// A row the scroll animation carried out of its region, kept to fill the band
// its lag uncovers (generic.zig `scroll_ghost`). Its grid y is relative to the
// current model and lies OUTSIDE the region -- above it as a wrapped u16 --
// so it is displaced unconditionally, clipped to the region like any
// displaced row, and never drawn once the animation is over.
const uint SCROLL_GHOST = 4u;

out CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
    // 1.0 when this glyph belongs to a row the scroll animation displaced, so
    // the fragment stage knows to clip it to the region. Rows outside the
    // region never move and must be left alone -- clipping them too erases
    // exactly the things an application parks outside its margins.
    flat float scroll_clip;
} out_data;

layout(binding = 1, std430) readonly buffer bg_cells {
    uint bg_colors[];
};

void main() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    uvec2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    bool ghost = (glyph_bools & SCROLL_GHOST) != 0u;
    float gy = float(grid_pos.y);
    if (ghost && gy >= 32768.0) gy -= 65536.0;

    // Convert the grid x, y into world space x, y by accounting for cell size
    vec2 cell_pos = cell_size * vec2(float(grid_pos.x), gy);

    // Scroll animation: rows inside the animated region are drawn offset from
    // where they now live in the model, so a scroll can be shown part-way
    // through. Rows outside the region -- tmux's status line, for one -- must
    // not move, which is why this is bounded rather than a whole-grid shift.
    bool scroll_clipped = false;
    out_data.scroll_clip = 0.0;
    // A glyph on a pinned cell (see cell_bg.f.glsl) stays where it is.
    bool pinned = false;
    if (!ghost && scroll_anim.x != 0.0 && scroll_anim_cols.w > 0.0 &&
        grid_pos.x < grid_size.x && grid_pos.y < grid_size.y) {
        uint pidx = uint(scroll_anim_cols.w) + uint(grid_pos.y) * grid_size.x + uint(grid_pos.x);
        pinned = (bg_colors[pidx] & 0xFFu) != 0u;
    }
    if (!pinned && scroll_anim.x != 0.0 &&
        (ghost || (gy >= scroll_anim.y && gy <= scroll_anim.z)) &&
        float(grid_pos.x) >= scroll_anim_cols.x &&
        float(grid_pos.x) <= scroll_anim_cols.y) {
        cell_pos.y += scroll_anim.x;
        out_data.scroll_clip = 1.0;

        // A row displaced past the edge of the region must not be drawn: it
        // would land on rows that are deliberately stationary, painting
        // glyphs over tmux's status line. The background pass leaves a blank
        // line there instead.
        float displaced = gy + scroll_anim.x / cell_size.y;
        if (displaced < scroll_anim.y - 0.999 || displaced > scroll_anim.z + 0.999) {
            scroll_clipped = true;
        }
    } else if (ghost) {
        // No animation, or outside its columns: a ghost has no place to be.
        scroll_clipped = true;
    }

    int vid = gl_VertexID;

    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the cell this vertex is in
    // based on the vertex ID.
    //
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    //
    // 0 = top-left  (0, 0)
    // 1 = top-right (1, 0)
    // 2 = bot-left  (0, 1)
    // 3 = bot-right (1, 1)
    vec2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    out_data.atlas = atlas;

    //              === Grid Cell ===
    //      +X
    // 0,0--...->
    //   |
    //   . offset.x = bearings.x
    // +Y.               .|.
    //   .               | |
    //   |   cell_pos -> +-------+   _.
    //   v             ._|       |_. _|- offset.y = cell_size.y - bearings.y
    //                 | | .###. | |
    //                 | | #...# | |
    //   glyph_size.y -+ | ##### | |
    //                 | | #.... | +- bearings.y
    //                 |_| .#### | |
    //                   |       |_|
    //                   +-------+
    //                     |_._|
    //                       |
    //                  glyph_size.x
    //
    // In order to get the top left of the glyph, we compute an offset based on
    // the bearings. The Y bearing is the distance from the bottom of the cell
    // to the top of the glyph, so we subtract it from the cell height to get
    // the y offset. The X bearing is the distance from the left of the cell
    // to the left of the glyph, so it works as the x offset directly.

    vec2 size = vec2(glyph_size);
    vec2 offset = vec2(bearings);

    offset.y = cell_size.y - offset.y;

    // Calculate the final position of the cell which uses our glyph size
    // and glyph offset to create the correct bounding box for the glyph.
    cell_pos = cell_pos + size * corner + offset;
    gl_Position = projection_matrix * vec4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

    // Push a scroll-clipped glyph outside the clip volume so it is discarded
    // before rasterization, rather than drawing over a stationary row.
    if (scroll_clipped) gl_Position = vec4(-2.0, -2.0, -2.0, 1.0);

    // Calculate the texture coordinate in pixels. This is NOT normalized
    // (between 0.0 and 1.0), and does not need to be, since the texture will
    // be sampled with pixel coordinate mode.
    out_data.tex_coord = vec2(glyph_pos) + vec2(glyph_size) * corner;

    // Get our color. We always fetch a linearized version to
    // make it easier to handle minimum contrast calculations.
    out_data.color = load_color(color, true);
    // Get the BG color. A ghost row is not on the grid, so it has no cell
    // background to read (its index would be out of bounds): use none, and
    // take the global background below.
    out_data.bg_color = ghost ? vec4(0.0) : load_color(
            unpack4u8(bg_colors[grid_pos.y * grid_size.x + grid_pos.x]),
            true
        );
    // Blend it with the global bg color
    vec4 global_bg = load_color(
            unpack4u8(bg_color_packed_4u8),
            true
        );
    out_data.bg_color += global_bg * vec4(1.0 - out_data.bg_color.a);

    // If we have a minimum contrast, we need to check if we need to
    // change the color of the text to ensure it has enough contrast
    // with the background.
    if (min_contrast > 1.0f && (glyph_bools & NO_MIN_CONTRAST) == 0) {
        // Ensure our minimum contrast
        out_data.color = contrasted_color(min_contrast, out_data.color, out_data.bg_color);
    }

    // Check if current position is under cursor (including wide cursor)
    bool is_cursor_pos = ((grid_pos.x == cursor_pos.x) || (cursor_wide && (grid_pos.x == (cursor_pos.x + 1)))) && (grid_pos.y == cursor_pos.y);

    // If this cell is the cursor cell, but we're not processing
    // the cursor glyph itself, then we need to change the color.
    if ((glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos && !ghost) {
        out_data.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }
}
