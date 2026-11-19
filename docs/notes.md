# Notes

## How Omarchy's screensaver works (checked 2026-11-18)

- NB: there is no hypridle here. Idle is the Omarchy shell's Quickshell idle
  service (`/usr/share/omarchy/shell/plugins/services/idle/Service.qml`),
  timeouts in `~/.config/omarchy/shell.json` (`idle.screensaver` 150s,
  `idle.lock` 300s; 0 disables). On idle it runs `omarchy-launch-screensaver`,
  which opens one terminal per
  monitor (Alacritty/ghostty/foot/kitty only) with class
  `org.omarchy.screensaver` on a special workspace, running `omarchy-screensaver`.
- `omarchy-screensaver` (in `/usr/share/omarchy/bin`) loops `ttfx` (the TTE
  CLI) with `--random-effect` over `~/.config/omarchy/branding/screensaver.txt`,
  hides the cursor, and exits on any key or when the window loses focus.
- So a custom saver = a program that draws in a terminal full-screen.
- The shell watches Hyprland for windows of class `org.omarchy.screensaver`:
  while one exists the lock timer stays armed; if it closes before the lock
  deadline that counts as activity and cancels the lock. Hyprland window rules
  (`default/hypr/apps/system.lua`) make that class fullscreen/float on a
  special workspace. **Keep that class and all of this works unchanged.**
- Also triggered from the menu (`omarchy-launch-screensaver force`), and
  `omarchy-toggle-screensaver` (flag file `~/.local/state/omarchy/toggles/screensaver-off`)
  disables it.

## Making it the real screensaver: what has to be done (2026-11-18)

**Integration options** (the in-terminal program is the only part we need to swap):

1. **PATH override for Hyprland-spawned apps (least invasive; recommended).**
   `default/hypr/envs.lua` does `hl.env("PATH", bin_dir..":"..rest)` so
   `/usr/share/omarchy/bin` is first for everything Hyprland starts, including
   the screensaver terminal, which runs `-e omarchy-screensaver` by name.
   Shadowing in `~/.local/bin` therefore fails. But `~/.config/hypr/hyprland.lua`
   loads after the defaults, so one line there can `hl.env("PATH", ...)` with
   a dir holding our own `omarchy-screensaver` first. Idle, lock, menu entry,
   toggle, per-monitor launch, rules all stay Omarchy's. Cost: that dir is on
   PATH for every Hyprland-launched app (keep it containing only that script);
   an Omarchy update that renames/changes the launcher contract could break it.
2. Own idle trigger + own launcher: set `idle.screensaver` to 0, run our own
   idle watcher (needs hypridle/swayidle installed or a small ext-idle-notify
   client) and launch with the same window class. More moving parts; no.
3. Edit/patch `/usr/share/omarchy` or `omarchy dev link` a checkout: package
   managed, overwritten on update; no.

**What Omarchy's own guidelines say** (shipped as an agent skill:
`/usr/share/omarchy/default/agents/skills/omarchy/{SKILL,plugins,hooks,hyprland,contributing}.md`):
`/usr/share/omarchy` is read-only to users (updates overwrite it); customise in
`~/.config/`; use `omarchy hook install` for event automation; for built-in
shell code, `omarchy plugin clone <id>` (never edit the packaged copy). The
idle logic is the first-party service `omarchy.idle`, so a sanctioned route is
`omarchy plugin clone omarchy.idle`, then change its launch command in
`~/.config/omarchy/plugins/<user>.idle/Service.qml`. Nothing in the docs covers
replacing the screensaver specifically, and the PATH override below is not
mentioned there (it only uses the user `hyprland.lua`, which the stock config
invites for personal overrides). Trade-off: a cloned idle service freezes a
copy of upstream's idle/lock logic (misses later fixes); the PATH override
keeps upstream logic but depends on the launcher still calling
`omarchy-screensaver` by name.

**Work list**

- [ ] **Wrapper script** `omarchy-screensaver` replacement (copy the stock logic):
      wait until the terminal has resized from 24x80 (ours reads the size once
      at startup, so it would otherwise draw an 80x24 canvas in a corner),
      hide cursor via `hyprctl ... cursor invisible true` and **always** restore
      it on exit (trap), black background OSC 11, `stty -echo`, exit on any key
      or when the screensaver window loses focus, `pkill` the window class.
      Decide whether mouse movement should exit (stock doesn't; the broken
      `--mouse` flag was removed in the 2026-11-18 cleanup).
- [ ] **Interpreter**: numpy and Pillow exist only in `~/.venvs/default`, not in
      `/usr/bin/python3`, and the Hyprland-spawned terminal does not have the
      venv on PATH. Use an absolute interpreter path, or a project venv, or
      pacman `python-numpy python-pillow`.
- [ ] **Per-monitor**: the launcher starts one terminal per monitor (this
      machine: one, HDMI-A-1). Each runs its own process; seed differently so
      monitors don't show identical frames, and watch CPU (~8 ms/frame at
      200x112 px, 24 fps: roughly a fifth of a core each).
- [ ] **Terminal support**: launcher supports Alacritty, ghostty, foot, kitty
      only, at 18pt. We assume truecolor, `?2026` sync updates, half-block
      glyphs; verify on the one in use (Alacritty) only.
- [ ] **Pixel size**: 18pt gives chunky pixels (~118x46 cells at 1080p). Maybe
      a `--pixel N` knob or use the ascii/hybrid look to hide it.
- [ ] **Resize / startup**: `SIGWINCH` is handled; test a monitor hot-plug.
- [ ] **Robustness**: never leave the cursor hidden or the alt screen on; crash
      in the saver must still close the window (it does: terminal `-e` exits).
- [ ] **Testing**: everything can be tested in `tools/shoot.sh` (xctl) except
      the actual Hyprland launch/rules/focus behaviour, which needs one
      deliberate run on the live desktop (`omarchy-launch-screensaver force`
      from the menu). Do that once, with the user's OK, and say so first.
- [ ] **Reversibility**: an install script that adds/removes the one hyprland.lua
      line and the override dir; document in README.
- [ ] Idle CPU/power: consider 15-20 fps and pausing the sway animation
      during long idle.

## Brogue: findings (2026-11-18)

- Not installed. AUR has `brogue-ce` (1.15.1, SDL) and `brogue-ce-curses`
  (1.15.1, terminal), also `broguelite`; `yay` present. Brogue CE is on GitHub
  as `tmewett/BrogueCE` (AGPL); upstream builds a terminal ("curses") version.
- Search found no headless/bot mode. README says `brogue --help` lists command
  line options (not read yet); changelog mentions a built-in WebBrogue back-end,
  a `-W/--wizard` debug flag, and in debug mode pressing `P` takes control of a
  recording playback. Verify against the source once built.
- Plan: run the curses build in a pty with a fixed seed, read the screen with
  `pyte`, drive it with a bot. The game already has autoexplore (`x`), travel
  to stairs (`>`), rest (`z`) and search (`s`), so the bot mostly presses those
  and moves into the nearest hostile letter, drinks/flees when hurt, and handles
  being stuck. Use a scratch HOME so saves/scores don't pollute anything.
- The screen is already a cell grid, so this scene produces **cells**, not
  pixels. The current pipeline is pixel buffer -> cells, and `Burn`/`Grow`
  work on pixels. Needs a cell-level path: either a pixel render of the cell
  colours for burning, or a cell-based burn that ashes the glyphs.
- Fallback if bot play is fragile: replay a recorded run (`.broguerec`); needs
  a recording.
- Build locally under `vendor/` (gitignored), not a system install, unless
  the user prefers `yay -S brogue-ce-curses`. Not built yet: awaiting go-ahead.


## Observations from the prototype

- Frame cost: ~3 ms scene + ~5 ms ANSI diff at 200x112 px. 24 fps is easy.
- Terminal at 18pt gives ~118x46 cells on 1920x1080: very chunky. Scene
  reads well; blossoms/leaves are drawn 1.35x larger than the SVG's to survive.
- Decided 2026-11-18: hybrid. Bamboo as glyphs, blossoms and the rest as
  half-blocks. Scenes return (rgb, glyph mask); `render.to_cells` picks per cell.
  Glyph ink is brightened (thin foliage goes dim otherwise).
- Burn is the best part so far: fire front with noisy edge, char, grey ash,
  rising flakes. Ash stage may linger too grey/long; tune `ASH_T` in `burn.py`.

## Ideas

- **Auto-playing Brogue**: either drive real Brogue CE headless (it has a
  console build; feed it keys from a simple explore/fight bot and read the
  screen) or write a tiny roguelike-style dungeon crawler bot that looks like
  Brogue (lit rooms, torch flicker, fog, monsters). Fits the cell grid
  natively. Would be a second scene; `Show` is the place to make scenes pluggable.
- More scenes to burn: any scene can end in `Burn`.
- Rotate scenes per cycle instead of just palettes.
- Config: `~/.config/omarchy/...` style per-scene settings, scene weights.

## Coast scene (tried and dropped 2026-11-18)

Waves/wash/palms/birds, day + dusk palettes, from a reference image. Decided
it wasn't worth keeping; scene deleted. Salvaged into `attic/coast_pieces.py` (moved out of the package in the cleanup): bird
sprites, dithered banding. Kept infrastructure: scenes return `(rgb, glyph
mask)`, `Show` rotates through a list of scenes. ASCII glyphs on water ripples
looked bad (grey patches).

## Cleanup and ports (2026-11-18)

- Python moved to `python/`. Removed: `--mode` (hybrid is the only look),
  `--scene` and the multi-scene plumbing (one scene; re-add with the next
  one), `--mouse` (broken), `--once`, dead aliases and fields. Split the
  phase machine into `show.py` and the PNG still into `preview.py`. Added
  `pyproject.toml` and smoke tests (`python/tests`).
- `docs/spec.md` written for ports; C (`c/`), Go (`go/`), Zig (`zig/`) and Odin
  (`odin/`) ports were written from it by Sonnet subagents. Go 1.27.4, Zig 0.17.1 and Odin
  dev-2026-11a installed via mise (user-level).
