//! `laptopd wallpaper-next` — sets a random cached wallpaper photo on every
//! active output, a different one per output when the cache is big enough.
//! Offline, instant — called at sway session start and right before the
//! internal panel goes dark (staged while dark so the swap itself is never
//! seen). With an empty/missing cache it falls back to the pre-randomizer
//! wallpaper, `~/.config/background.jpg`.
//!
//! `restore` (also `laptopd wallpaper-restore`) re-applies the saved state.
//!
//! State: `~/.local/state/wallpaper/current` holds one `<output>\t<path>`
//! line per output (a bare path from older versions is read as output `*`),
//! used to avoid repeating each output's previous image.

const std = @import("std");
const proc = @import("proc.zig");
const sway = @import("sway.zig");
const state = @import("state.zig");
const wildcard = state.wildcard;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".jxl", ".webp" };

fn hasWallpaperExt(name: []const u8) bool {
    for (extensions) |ext| {
        if (name.len < ext.len) continue;
        const tail = name[name.len - ext.len ..];
        if (std.ascii.eqlIgnoreCase(tail, ext)) return true;
    }
    return false;
}

/// Chooses one candidate per output. Preference order for each output:
/// an image no other output got and that it didn't just show; then any
/// unused image; then (cache smaller than output count) any image but its
/// previous one; finally anything.
fn assign(gpa: Allocator, rand: std.Random, candidates: []const []const u8, previous: []const []const u8) ![]const []const u8 {
    std.debug.assert(candidates.len > 0);
    const order = try gpa.dupe([]const u8, candidates);
    rand.shuffle([]const u8, order);
    const used = try gpa.alloc(bool, order.len);
    @memset(used, false);
    const picks = try gpa.alloc([]const u8, previous.len);

    for (previous, 0..) |prev, i| {
        var chosen: ?usize = null;
        for (order, 0..) |c, j| {
            if (!used[j] and !std.mem.eql(u8, c, prev)) {
                chosen = j;
                break;
            }
        }
        if (chosen == null) {
            for (order, 0..) |_, j| {
                if (!used[j]) {
                    chosen = j;
                    break;
                }
            }
        }
        if (chosen == null) {
            for (order, 0..) |c, j| {
                if (!std.mem.eql(u8, c, prev)) {
                    chosen = j;
                    break;
                }
            }
        }
        const j = chosen orelse i % order.len;
        used[j] = true;
        picks[i] = order[j];
    }
    return picks;
}

fn swaymsgBg(io: Io, gpa: Allocator, output: []const u8, path: []const u8) bool {
    var r = proc.run(io, gpa, &.{ "/usr/bin/swaymsg", "output", output, "bg", path, "fill" }) catch return false;
    defer r.deinit(gpa);
    return r.exited_zero;
}

/// The wallpaper configured before the randomizer existed
/// (`~/.config/background.jpg`, what sway's config sets). Used explicitly
/// whenever there is no random pick to show, so the fallback is that image
/// and not whatever happens to be on screen. WALLPAPER_DEFAULT overrides.
fn applyDefault(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, home: []const u8) void {
    const path = environ.get("WALLPAPER_DEFAULT") orelse
        (std.fmt.allocPrint(gpa, "{s}/.config/background.jpg", .{home}) catch return);
    Io.Dir.accessAbsolute(io, path, .{}) catch return;
    _ = swaymsgBg(io, gpa, wildcard, path);
}

/// Serializes everything that sets wallpapers (rotation at session start and
/// the sway-reload restore can fire at the same moment). Blocking, but the
/// critical sections are a few local `swaymsg` calls. The caller closes the
/// returned file to release; null (couldn't lock) means carry on unlocked.
fn lockApply(io: Io, state_dir: []const u8, gpa: Allocator) ?Io.File {
    const path = std.fmt.allocPrint(gpa, "{s}/apply.lock", .{state_dir}) catch return null;
    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return null;
    const rc = std.os.linux.flock(f.handle, std.posix.LOCK.EX);
    if (std.posix.errno(rc) != .SUCCESS) {
        f.close(io);
        return null;
    }
    return f;
}

/// `laptopd wallpaper-restore` — re-applies the wallpapers recorded in the
/// state file. Sway's `exec_always` runs it on every config reload, which
/// otherwise resets the background to the static default in sway's config.
/// A missing state file (or images that are gone) leaves that default alone.
pub fn restore(io: Io, gpa: Allocator, environ: *std.process.Environ.Map) !u8 {
    const home = environ.get("HOME") orelse {
        std.debug.print("laptopd wallpaper-restore: $HOME is unset\n", .{});
        return 1;
    };
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.local/state/wallpaper", .{home});
    const current_file = try std.fmt.allocPrint(gpa, "{s}/current", .{state_dir});
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};
    const lock = lockApply(io, state_dir, gpa);
    defer if (lock) |l| l.close(io);

    var buf: [8192]u8 = undefined;
    const content = Io.Dir.cwd().readFile(io, current_file, &buf) catch "";
    const entries = try state.parseState(gpa, content);

    var first = true;
    for (entries) |e| {
        Io.Dir.accessAbsolute(io, e.path, .{}) catch continue;
        // `output *` first (from the first usable entry) so outputs plugged
        // in later also get a wallpaper, then each output's own on top.
        if (first) {
            if (!swaymsgBg(io, gpa, wildcard, e.path)) return 0;
            first = false;
        }
        if (!std.mem.eql(u8, e.output, wildcard)) _ = swaymsgBg(io, gpa, e.output, e.path);
    }
    // No state, or every saved image is gone.
    if (first) applyDefault(io, gpa, environ, home);
    return 0;
}

/// Picks random cached wallpapers (avoiding a repeat of each output's
/// current one when possible) and applies them via `swaymsg`.
/// Always returns 0 — a missing cache, an unreadable directory, or a
/// failed `swaymsg` call are all silent no-ops, nothing to report.
pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map) !u8 {
    const home = environ.get("HOME") orelse {
        std.debug.print("laptopd wallpaper-next: $HOME is unset\n", .{});
        return 1;
    };
    const dir = environ.get("WALLPAPER_DIR") orelse blk: {
        break :blk try std.fmt.allocPrint(gpa, "{s}/Pictures/wallpapers", .{home});
    };
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.local/state/wallpaper", .{home});
    const current_file = try std.fmt.allocPrint(gpa, "{s}/current", .{state_dir});

    Io.Dir.cwd().createDirPath(io, state_dir) catch {};
    const lock = lockApply(io, state_dir, gpa);
    defer if (lock) |l| l.close(io);

    var candidates: std.ArrayList([]const u8) = .empty;
    {
        var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
            // Missing/unreadable cache dir: nothing to rotate through.
            applyDefault(io, gpa, environ, home);
            return 0;
        };
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!hasWallpaperExt(entry.name)) continue;
            try candidates.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }

    if (candidates.items.len == 0) {
        applyDefault(io, gpa, environ, home);
        return 0;
    }

    // Outputs to paint: every active one, or just `*` if sway can't tell us.
    var names: std.ArrayList([]const u8) = .empty;
    if (sway.getOutputs(io, gpa, gpa)) |outs| {
        for (outs) |o| {
            if (o.active) try names.append(gpa, o.name);
        }
    }
    const per_output = names.items.len > 0;
    if (!per_output) try names.append(gpa, wildcard);

    var state_buf: [8192]u8 = undefined;
    const content = Io.Dir.cwd().readFile(io, current_file, &state_buf) catch "";
    const prev_entries = try state.parseState(gpa, content);
    const previous = try gpa.alloc([]const u8, names.items.len);
    for (names.items, 0..) |n, i| previous[i] = state.previousFor(prev_entries, n);

    var seed: [8]u8 = undefined;
    Io.random(io, &seed);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
    const picks = try assign(gpa, prng.random(), candidates.items, previous);

    const paths = try gpa.alloc([]const u8, picks.len);
    for (picks, 0..) |p, i| paths[i] = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, p });

    // `output *` first so an output plugged in later still gets a rotated
    // image, then each output's own pick on top (skipped for a single output).
    if (!swaymsgBg(io, gpa, wildcard, paths[0])) return 0;
    if (per_output and names.items.len > 1) {
        for (names.items, paths) |n, p| _ = swaymsgBg(io, gpa, n, p);
    }

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (names.items, paths) |n, p| try out.writer.print("{s}\t{s}\n", .{ n, p });

    var f = Io.Dir.cwd().createFile(io, current_file, .{ .truncate = true }) catch return 0;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = f.writer(io, &wbuf);
    w.interface.writeAll(out.written()) catch {};
    w.interface.flush() catch {};
    return 0;
}

const testing = std.testing;

test "hasWallpaperExt matches known extensions case-insensitively" {
    try testing.expect(hasWallpaperExt("bing_abc123.jpg"));
    try testing.expect(hasWallpaperExt("apod_2026-08-15.JPG"));
    try testing.expect(hasWallpaperExt("photo.WebP"));
    try testing.expect(hasWallpaperExt("shot.jxl"));
}

test "hasWallpaperExt rejects non-image files" {
    try testing.expect(!hasWallpaperExt("readme.txt"));
    try testing.expect(!hasWallpaperExt("noext"));
}

test "hasWallpaperExt matches a bare extension with no basename, like a *.jpg glob does" {
    try testing.expect(hasWallpaperExt(".jpg"));
}

test "assign gives each output a distinct image and avoids the previous one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cands = [_][]const u8{ "a.jpg", "b.jpg", "c.jpg", "d.jpg" };
    const prev = [_][]const u8{ "a.jpg", "b.jpg" };
    var prng = std.Random.DefaultPrng.init(1);
    for (0..100) |_| {
        const picks = try assign(arena.allocator(), prng.random(), &cands, &prev);
        try testing.expectEqual(@as(usize, 2), picks.len);
        try testing.expect(!std.mem.eql(u8, picks[0], picks[1]));
        try testing.expect(!std.mem.eql(u8, picks[0], "a.jpg"));
        try testing.expect(!std.mem.eql(u8, picks[1], "b.jpg"));
    }
}

test "assign reuses images when there are fewer candidates than outputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cands = [_][]const u8{"only.jpg"};
    const prev = [_][]const u8{ "", "only.jpg", "" };
    var prng = std.Random.DefaultPrng.init(7);
    const picks = try assign(arena.allocator(), prng.random(), &cands, &prev);
    try testing.expectEqual(@as(usize, 3), picks.len);
    for (picks) |p| try testing.expectEqualStrings("only.jpg", p);
}

test "assign avoids the previous image on a single output when it can" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cands = [_][]const u8{ "a.jpg", "b.jpg" };
    const prev = [_][]const u8{"a.jpg"};
    var prng = std.Random.DefaultPrng.init(3);
    for (0..50) |_| {
        const picks = try assign(arena.allocator(), prng.random(), &cands, &prev);
        try testing.expectEqualStrings("b.jpg", picks[0]);
    }
}
