# PROGRESS — smooth-scroll fork

Volatile half of the pair. `SPEC.md` says what and why and holds the verified
facts about upstream; this file says **where we are**. Update it at the end of
every working session, before context is lost.

**If you are an agent picking this up cold: read `SPEC.md` first, then §"State"
below, then §"How to work on this".** Do not re-derive the facts in SPEC §3 —
they were expensive. Do re-verify them if `git merge-base` has moved.

---

## State

**Base:** `ghostty-org/ghostty` @ `e8aa09867` (`1.3.2-dev`), branch `smooth-scroll`
**Last updated:** 2026-08-31

| Stage | Feature | Status |
|-------|---------|--------|
| 0 | Toolchain + unmodified build | **DONE, verified** |
| 1 | Momentum | **NOT STARTED** ← next |
| 2 | Scroll-region animation | not started |
| 3 | Pixel viewport scroll | not started |

Nothing in `src/` has been modified yet. The only files this branch adds are
`SPEC.md` and `PROGRESS.md`. `git diff main --stat` should show exactly that.

### Stage 0 — done 2026-08-31

Unmodified Ghostty main builds and runs from source on this machine.

```
$ ~/dev/ghostty/zig-out/bin/ghostty --version
Ghostty 1.3.2-main-+e8aa09867
  Zig version : 0.16.0
  build mode  : .ReleaseFast
$ /usr/bin/ghostty --version
Ghostty 1.3.1-4.fc44          # packaged, untouched; rpm -V clean
```

Verified by running the binary, not by the presence of a file.

---

## How to work on this

### Build

```bash
cd ~/dev/ghostty
zig build                          # Debug — fast, use while developing
zig build -Doptimize=ReleaseFast   # slow, for actually using it
```

Zig 0.16.0 from Fedora (`dnf`), matching `minimum_zig_version` in
`build.zig.zon`. Deps are cached in `~/.cache/zig` (~210 MB) so the first build
is the slow one. Run long builds in the background and report progress.

### Run without risking your session

```bash
~/dev/ghostty/zig-out/bin/ghostty      # opens a NEW window
```

Launch it *from* a working terminal. If a change crashes on startup you still
have a terminal to fix it from. Do not point the desktop entry at the fork.

### System dependencies (already installed, recorded for a rebuild)

```bash
sudo dnf install -y blueprint-compiler gtk4-devel gtk4-layer-shell-devel \
                    libadwaita-devel oniguruma-devel zlib-ng-devel
```

**Do not use `sudo dnf builddep ghostty`.** It resolves deps for Fedora's
*packaged* 1.3.1, which is built with Zig 0.15.2 via the `zig015` COPR package.
`zig015` installs to `/usr/lib/zig/` and `/usr/bin/zig` — the same paths as
`zig` 0.16.0 — so RPM aborts the whole 41-package transaction with file
conflicts. We build **main**, which wants 0.16.0, so `zig015` is not needed at
all. The six packages above are that builddep list minus `zig015`, and they
were sufficient: the unmodified build needed nothing further.

### Verification

**Scrolling is a GUI behaviour. Compiling proves nothing.** Actually scroll.

For anything involving what an application emits (Feature 2 especially),
measure rather than assume — that is how SPEC §3.3 was established and how an
earlier wrong assumption was caught. The harness: allocate a pty with Python's
`pty` module, run `tmux attach` inside it, drive scrolls from outside with
`tmux send-keys -X -N 1 scroll-up`, and capture the master fd. Classify the
captured bytes by regex for `IL`/`DL`/`SU`/`SD`/`IND`/`DECSTBM` versus count of
printable glyphs redrawn. Note `script(1)` is **not installed** on this machine
— that path is a dead end, use Python.

To see whether the fork changed feel, compare side by side against
`/usr/bin/ghostty`, which is upstream 1.3.1 and stays installed for exactly
this reason.

---

## Session log

Newest last. Record what was learned and what was ruled out, not just what was
done.

### 2026-08-31 — stage 0, and the specs

- Established that config, not the terminal, was the original culprit: this
  machine has only a touchpad (a *precision* device), which Ghostty already
  tracks 1:1 (`mouse-scroll-multiplier = precision:1`), while tmux was
  multiplying every event by 5 and nvim by 3. Fixed downstream and committed
  to `~/dev/dotfiles` as `bfb1056`. **That is out of scope here** and should
  not be redone — this fork is for what config cannot reach.
- Surveyed the alternatives before forking: no GTK "kinetic scrolling" knob is
  reachable (Ghostty has zero scroll-animation options in its full config
  schema, and GTK's `kinetic-scrolling` is a scrolled-window/touch property
  that does not reach a GPU-rendered grid). The community fork
  `parkers0405/ghostty-pixel-scroll` implements Feature 3 only — real, but
  scoped to a case this user is never in, and bundled into a personal mega-fork
  carrying collaborative cursors and a Neovim GUI mode.
- **Corrected a wrong call made mid-investigation:** the claim that tmux
  repaints the pane, making animation impossible, was wrong. Measurement (SPEC
  §3.3) shows a clean `DECSTBM` + `CSI 1 L` with a single row redrawn. Feature
  2 is viable *because* that assumption was tested instead of trusted.
- Toolchain: hit the `zig015` file-conflict wall via `builddep`; diagnosed and
  routed around it (see above). Nothing was installed by the failed
  transaction — RPM aborts atomically.
- Stage 0 built clean and verified running.
- Wrote `SPEC.md` + this file, on branch `smooth-scroll`.

---

## Next action

**Stage 1, Momentum.** SPEC §4 Feature 1 has the design and acceptance
criteria. Concretely, the first three things to do:

1. Read `scrollCallback` (`src/Surface.zig:3456`) end to end, including all
   three dispatch branches (SPEC §3.2). Understand the `pending_scroll_y`
   accumulator before adding a second source of deltas into it.
2. Read the tick-callback pattern at `src/apprt/gtk/class/imgui_widget.zig:244`
   and its teardown at `:258`. That is the timer to copy.
3. Decide where velocity state lives — most likely beside
   `pending_scroll_x/y` at `src/Surface.zig:243`.

Open question to settle early: synthesised momentum events must reach the same
accumulator path so all three dispatch branches keep working, but
`scrollCallback` takes the `renderer_state.mutex` and can write to the pty.
Work out the thread/lock discipline for firing it from a frame-clock tick
*before* writing much code.
