<h1 align="center">Saintty</h1>

<p align="center">
A fork of <a href="https://github.com/ghostty-org/ghostty">Ghostty</a> that scrolls smoothly, pixel by pixel, and stops redrawing the whole window when only one line changed. <br> Linux + GTK + OpenGL only. Built and used daily on Hyprland.
</p>

---

## What it adds

### 1. Pixel-smooth scrolling (`scroll-animation = true`)

A terminal is a grid of character cells, so stock Ghostty can only move text a whole row at a time. Saintty animates the rows in between.

The hard part is that most scrolling isn't Ghostty's own scrollback. It's an *application* (nvim, tmux, less, yazi, Claude Code) redrawing its own screen. Saintty works out which part of the screen moved, and in which direction, and slides just that region, so tmux's status line, nvim's gutter and a split pane's border stay put.

- **A spring, not a curve.** Easing curves restart on every scroll, so a held key speeds up and sags at each row. A critically damped spring keeps its speed across scrolls. Curves (`ease-out`, `material`, `linear`, …) are still there via `scroll-animation-easing`.
- **Held keys glide.** Holding `j` in nvim moves the text at the rate the input actually arrives, instead of passing nvim's per-row timing jitter straight to the screen (frame-to-frame spread 19.9 % → 11.2 %, filmed).
- **Touchpad momentum** (`mouse-scroll-momentum = true`). The fling keeps going after your fingers lift, using the velocity GTK measures.
- **No runaway wheel.** A free-spinning wheel (MX Anywhere 3S: 280–520 notches/s) used to queue seconds of scrolling that kept going after the wheel stopped (10.5 s, measured). An application can now acknowledge wheel events (`OSC 777;wheel-ack`) and Saintty keeps at most `mouse-wheel-in-flight` of them waiting. Overrun went from 10.5 s to none.
- `scroll-animation-wheel-snap`: above N notches/s, go back to plain row jumps.

### 2. Shader cache (`custom-shader-cache = true`, `gtk-damage-tracking = true`)

Ghostty runs your `custom-shader` chain over the whole window every frame. With a glow shader and a cursor effect, typing one character drew 3840×2160 pixels several times, 120 times a second.

Saintty caches each shader's output and redoes only the rows that changed, plus a margin for blur radius. The last shader in the chain (the animated one) runs only in a box around the cursor while a cursor effect is playing. Then GTK and the compositor are told which rectangle changed, instead of being handed the whole window.

| Typing with a glow + cursor-effect shader chain | GPU (terminal + compositor) |
|---|---|
| Ghostty | 33 % + 38 % |
| Saintty | 5.5 % + 3 % |

`custom-shader-cache-debug = verify` draws every frame twice (cached and uncached) and logs any pixel that differs.

### Smaller things

- Cursor shader uniforms `iTimeCursorMove`, `iTimeCursorMode`, `iTimeCursorPulse`, plus `custom-shader-animation = cursor`: animate only just after the cursor moves, then idle at zero cost.
- `OSC 777;cursor-pulse`, `OSC 777;cursor-boom` and `OSC 777;cursor-target`, so programs can trigger a shader effect at a cell.
- `scroll-animation-reserve-bottom` for apps that redraw a prompt box inside their scrolling region (Claude Code).

Everything is **off by default**. Without these options, Saintty behaves like the Ghostty commit it is based on.

## Config

```ini
scroll-animation = true
scroll-animation-duration = 120      # ms
mouse-scroll-momentum = true

custom-shader = shaders/your-glow.glsl
custom-shader = shaders/your-cursor.glsl   # the animated one goes last
custom-shader-animation = cursor
custom-shader-cache = true
custom-shader-cache-margin = 48            # >= your largest blur radius, in px
custom-shader-cache-fx-reach = 7           # cells around the cursor
gtk-damage-tracking = true
```

Each option is documented in `src/config/Config.zig`, the same as upstream options.

## Build

Needs Zig 0.16 and Ghostty's usual GTK build dependencies (see [HACKING.md](HACKING.md)).

```sh
zig build -Doptimize=ReleaseFast --prefix ~/.local
```

The binary is still called `ghostty` and reads the normal Ghostty config file. Saintty is the project's name, not a rebrand of the app.

## How it was tested

Smooth-looking isn't the same as smooth, so most of the work went into measuring:

- `tools/scroll-harness/`: drives real nvim / tmux / yazi / Claude Code sessions with virtual uinput mice, keyboards and touchpads, and scores every frame from `scroll-trace = true` logs.
- `holdfilm.py`, `lat.py`, `blink.py`: film the screen and measure what actually reached the display (key-to-pixel latency, frame gaps, stale rows).
- `SPEC.md` and `PROGRESS.md`: the design, the facts verified about upstream's renderer, and a dated log of every bug, including the wrong turns.

## Status and scope

- Linux, GTK, OpenGL only. No macOS/Metal port is planned.
- Based on `ghostty-org/ghostty` at `349f02608` (2026-09-02).
- A personal daily driver, not a supported product. Bugs are welcome as issues.

## How this was made

The code was written with [Claude Code](https://claude.com/claude-code). I directed it, and I did the testing and debugging: reporting what looked wrong, filming it, and deciding which trade-offs to keep.

## License

MIT, same as Ghostty. See [LICENSE](LICENSE). Ghostty is a trademark of its authors; Saintty is not affiliated with or endorsed by the Ghostty project. Upstream's own README is kept as [README.ghostty.md](README.ghostty.md).
