# laptopd

Zig multicall daemon for the laptop (gram16), modelled on [htpcd](../htpcd). Zig 0.16.0, no dependencies.
CI publishes `ghcr.io/oshox/laptopd:latest` (`FROM scratch`), imported by [laptop-setup](../laptop-setup) with
`COPY --from=ghcr.io/oshox/laptopd:latest /usr/ /usr/`.

## Subcommands
| Command | What |
|---|---|
| `wallpaper-fetch` | Tops up `~/Pictures/wallpapers` from Bing's daily archive and NASA APOD (no key; `NASA_API_KEY` optional). Rate-limited to ~once/20h, flock-guarded, prunes to 40 files. Keeps only JPEG/PNG images at least as large as the internal panel (read from sway, 2560×1600 if unreachable) that need at most 20% cropping to fill it (`WALLPAPER_MAX_CROP`), and names files by real type. Also drops previously fetched `bing_*`/`apod_*` files that no longer fit; other files in the folder are never touched. |
| `wallpaper-next` | Sets a random cached wallpaper on each active output, a different image per output when possible and never repeating an output's last one (`output * bg` first, so outputs plugged in later get one too). No-op on an empty cache. |
| `wallpaper-restore` | Re-applies the wallpapers saved in the state file. Sway runs it with `exec_always`, so a config reload shows the current wallpaper instead of the static default in sway's config. Serialized with `wallpaper-next` by a lock. |
| `lock` | Runs `swaylock -f` with each output's current desktop wallpaper (`-i <output>:<path>`), falling back to a plain `swaylock -f`. Does no sway IPC or network, so it is safe inside swayidle's before-sleep. A second call while locked is a no-op. |
| `login-image` | Picks a random cached image that fits the panel and is not currently on the desktop/lock screen, and copies it to `/var/lib/laptopd/login-background` for SDDM (a copy, because the encrypted home is locked at the login screen). `--if-missing` only acts when there is none yet. Local files only. |
| `display-watch` | Resident user daemon: when the internal panel (`eDP-*`) goes dark (lid close / DPMS off), runs `wallpaper-next`, then `wallpaper-fetch` in a transient unit — so the swap is never seen. |

`wallpaper-next`, `wallpaper-restore` and `wallpaper-fetch` are also argv[0] aliases (symlinks to the binary) so sway config can call them
directly. `WALLPAPER_DIR` overrides the cache dir; state lives in `~/.local/state/wallpaper/` (`current` is one `output<TAB>path` line per output).

Image layout: `/usr/bin/laptopd` + alias symlinks, `/usr/lib/systemd/user/laptopd-display-watch.service` and `laptopd-login-image.service`
(the latter runs `login-image` as its `ExecStop`, i.e. when the user manager stops at logout or shutdown, never on suspend).
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

## Suspend / lid close
- `display-watch` and the sway startup hook launch `wallpaper-fetch` with `systemd-run --property=RuntimeMaxSec=180`,
  so a download interrupted by suspend is killed rather than hanging (the lock is released with the process).
- The 20 h rate-limit stamp is written only if Bing or APOD answered, so a fetch that ran offline retries at the next trigger.
- Leftover `*.tmp` files from killed downloads are removed after an hour.
- `lock`, `wallpaper-next` and `login-image` are local and quick; none touch the network.
