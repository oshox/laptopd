# laptopd

Zig multicall daemon for the laptop (gram16), modelled on [htpcd](../htpcd). Zig 0.16.0, no dependencies.
CI publishes `ghcr.io/oshox/laptopd:latest` (`FROM scratch`), imported by [laptop-setup](../laptop-setup) with
`COPY --from=ghcr.io/oshox/laptopd:latest /usr/ /usr/`.

## Subcommands
| Command | What |
|---|---|
| `wallpaper-fetch` | Tops up `~/Pictures/wallpapers` from Bing's daily archive and NASA APOD (no key; `NASA_API_KEY` optional). Rate-limited to ~once/20h, flock-guarded, prunes to 40 files. Keeps only JPEG/PNG images at least as large as the internal panel (read from sway, 2560×1600 if unreachable) that need at most 20% cropping to fill it (`WALLPAPER_MAX_CROP`), and names files by real type. Also drops previously fetched `bing_*`/`apod_*` files that no longer fit; other files in the folder are never touched. |
| `wallpaper-next` | Sets a random cached wallpaper on each active output, a different image per output when possible and never repeating an output's last one (`output * bg` first, so outputs plugged in later get one too). No-op on an empty cache. |
| `display-watch` | Resident user daemon: when the internal panel (`eDP-*`) goes dark (lid close / DPMS off), runs `wallpaper-next`, then `wallpaper-fetch` in a transient unit — so the swap is never seen. |

`wallpaper-next` and `wallpaper-fetch` are also argv[0] aliases (symlinks to the binary) so sway config can call them
directly. `WALLPAPER_DIR` overrides the cache dir; state lives in `~/.local/state/wallpaper/` (`current` is one `output<TAB>path` line per output).

Image layout: `/usr/bin/laptopd` + alias symlinks, `/usr/lib/systemd/user/laptopd-display-watch.service`.
The user unit is enabled by a symlink in `~/.config/systemd/user/default.target.wants/` (laptop-config), and
`config.d/92-wallpaper.conf` there rotates once at sway start.

## Build
`podman build -t laptopd:local .` runs a Debug build (full analysis), `zig build test`, then a `ReleaseSafe`
`x86_64-linux` build; a failing test means no image. With a local Zig 0.16: `zig build test`.

## Adding automation
1. `src/<name>.zig` with `pub fn run(...)`.
2. A branch in `src/main.zig`, a line in `usage`, and an `@import` in its `test {}` block.
3. A unit under `dist/usr/lib/systemd/{system,user}/` if it needs one, and an enable link in laptop-config
   (user) or a `systemctl enable` in laptop-setup (system).
4. Resident daemons take `init.gpa`; oneshots take the arena (see `main.zig`).

Runtime tools it calls (must exist in laptop-setup): `swaymsg`, `systemd-run`.

The GHCR package must be made **Public** once after the first CI run (see the comment in `build.yml`).
