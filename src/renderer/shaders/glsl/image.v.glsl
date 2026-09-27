#include "common.glsl"

layout(binding = 0) uniform sampler2D image;

layout(location = 0) in vec2 grid_pos;
layout(location = 1) in vec2 cell_offset;
layout(location = 2) in vec4 source_rect;
layout(location = 3) in vec2 dest_size;
layout(location = 4) in vec2 flags;

out vec2 tex_coord;
// 1 when this slice is displaced by the scroll animation, so the fragment
// shader clips it to the region, as cell_text does for glyphs.
out float scroll_clip;

void main() {
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

    // The texture coordinates start at our source x/y
    // and add the width/height depending on the corner.
    tex_coord = source_rect.xy;
    tex_coord += source_rect.zw * corner;

    // Normalize the coordinates.
    tex_coord /= textureSize(image, 0);

    // The position of our image starts at the top-left of the grid cell and
    // adds the source rect width/height components.
    vec2 image_pos = (cell_size * grid_pos) + cell_offset;
    image_pos += dest_size * corner;

    // Carry the scroll animation, exactly as cell_text.v.glsl does for glyphs.
    //
    // WHY THIS IS NEEDED: an image is positioned by GRID CELL — the Kitty
    // protocol anchors a placement to a row/column, and image.nvim's
    // unicode-placeholder method makes that anchoring the terminal's job. So
    // when a region of the screen is displaced by a fraction of a row, the
    // figures in that region have to move with it or they stay pinned to the
    // model position while the paragraph they belong to slides away underneath.
    //
    // Without this, scrolling a figure-heavy markdown buffer (a CSAPP chapter,
    // which is what this was found on) leaves the picture standing still for
    // the length of the animation while the text moves, then snaps. Because
    // the image is composited by the terminal ABOVE the cell grid, the result
    // reads as a ghost trail smeared off the figure, text landing inside it,
    // and — where the placement is re-transmitted mid-animation — the same
    // figure stamped twice at two different heights.
    //
    // The region test is deliberately the same shape as the one in
    // cell_text.v.glsl so the two cannot disagree about what is moving:
    // scroll_anim is (offset_px, top_row, bottom_row, unused) and
    // scroll_anim_cols is (left_col, right_col, unused, unused). Rows outside
    // the region must not move — tmux's status line is kept outside the
    // scrolling margins precisely so it stays put.
    //
    // grid_pos is the placement's top-left cell, so an image is treated as
    // moving or not as a whole. That is the right call for a figure inside a
    // scrolling viewport, which is every case this fires on; an image
    // straddling the top edge of the region is displaced with the region
    // rather than torn in half.
    //
    // NOTE: this is the OpenGL path, which is the only one this machine uses.
    // shaders.metal carries the same uniform for the cell shaders and would
    // need the equivalent edit for the macOS renderer.
    //
    // A GHOST slice (flags.x) is an image row the scroll carried out of the
    // region, kept so the image slides out of view the way text does instead
    // of its edge row vanishing. It lies outside the region by construction,
    // is always displaced, and is drawn only while the animation runs.
    //
    // Every displaced slice is clipped to the region's band (see
    // image.f.glsl): an image's last row pushed past the region's edge would
    // otherwise be drawn over the status line below it.
    bool ghost = flags.x != 0.0;
    scroll_clip = 0.0;
    if (scroll_anim.x != 0.0 &&
        (ghost || (grid_pos.y >= scroll_anim.y && grid_pos.y <= scroll_anim.z)) &&
        grid_pos.x >= scroll_anim_cols.x &&
        grid_pos.x <= scroll_anim_cols.y) {
        image_pos.y += scroll_anim.x;
        scroll_clip = 1.0;
    } else if (ghost) {
        // No animation, or outside its columns: nowhere to be.
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        return;
    }

    gl_Position = projection_matrix * vec4(image_pos.xy, 1.0, 1.0);
}
