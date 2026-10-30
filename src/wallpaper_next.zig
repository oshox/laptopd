//! `laptopd wallpaper-next` — sets a random cached wallpaper photo on every
//! active output, a different one per output when the cache is big enough.
//! Offline, instant — called at sway session start and right before the
//! internal panel goes dark (staged while dark so the swap itself is never
//! seen). Safe on an empty/missing cache: leaves the current wallpaper
//! untouched.
//!
//! State: `~/.local/state/wallpaper/current` holds one `<output>\t<path>`
//! line per output (a bare path from older versions is read as output `*`),
//! used to avoid repeating each output's previous image.

const std = @import("std");
const proc = @import("proc.zig");
const sway = @import("sway.zig");
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

const wildcard = "*";

const Prev = struct {
    output: []const u8,
    /// File name (no directory) of the image that output last showed.
    file: []const u8,
};

/// Parses the state file. Slices point into `content`; only the list itself
/// is allocated.
fn parseState(gpa: Allocator, content: []const u8) ![]Prev {
    var list: std.ArrayList(Prev) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        const entry: Prev = if (std.mem.indexOfScalar(u8, line, '\t')) |t|
            .{ .output = line[0..t], .file = std.fs.path.basename(line[t + 1 ..]) }
        else
            .{ .output = wildcard, .file = std.fs.path.basename(line) };
        try list.append(gpa, entry);
    }
    return list.items;
}

/// What `output` showed last time: its own entry, else the legacy `*` entry.
fn previousFor(prev: []const Prev, output: []const u8) []const u8 {
    for (prev) |p| {
        if (std.mem.eql(u8, p.output, output)) return p.file;
    }
    for (prev) |p| {
        if (std.mem.eql(u8, p.output, wildcard)) return p.file;
    }
    return "";
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

    var candidates: std.ArrayList([]const u8) = .empty;
    {
        var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
            // Missing/unreadable cache dir — leave the current wallpaper untouched.
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

    if (candidates.items.len == 0) return 0;

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
    const state = Io.Dir.cwd().readFile(io, current_file, &state_buf) catch "";
    const prev_entries = try parseState(gpa, state);
    const previous = try gpa.alloc([]const u8, names.items.len);
    for (names.items, 0..) |n, i| previous[i] = previousFor(prev_entries, n);

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

test "parseState reads per-output lines and the legacy single-path format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const modern = try parseState(a, "eDP-1\t/p/wp/a.jpg\nDP-3\t/p/wp/b.jpg\n");
    try testing.expectEqual(@as(usize, 2), modern.len);
    try testing.expectEqualStrings("eDP-1", modern[0].output);
    try testing.expectEqualStrings("b.jpg", modern[1].file);

    const legacy = try parseState(a, "/home/x/Pictures/wallpapers/old.jpg");
    try testing.expectEqual(@as(usize, 1), legacy.len);
    try testing.expectEqualStrings("*", legacy[0].output);
    try testing.expectEqualStrings("old.jpg", legacy[0].file);

    try testing.expectEqual(@as(usize, 0), (try parseState(a, "")).len);
}

test "previousFor prefers the exact output, then the legacy entry, then nothing" {
    const prev = [_]Prev{
        .{ .output = "eDP-1", .file = "a.jpg" },
        .{ .output = "*", .file = "legacy.jpg" },
    };
    try testing.expectEqualStrings("a.jpg", previousFor(&prev, "eDP-1"));
    try testing.expectEqualStrings("legacy.jpg", previousFor(&prev, "DP-3"));
    try testing.expectEqualStrings("", previousFor(&.{}, "eDP-1"));
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
