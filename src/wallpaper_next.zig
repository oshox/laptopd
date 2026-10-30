//! `laptopd wallpaper-next` — sets a random cached wallpaper photo. Offline,
//! instant — called at sway session start and right before the internal
//! panel goes dark (staged while dark so the swap itself is never seen).
//! Safe on an empty/missing cache: leaves the current wallpaper untouched.

const std = @import("std");
const proc = @import("proc.zig");
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

fn randomIndex(io: Io, n: usize) usize {
    if (n <= 1) return 0;
    var buf: [8]u8 = undefined;
    Io.random(io, &buf);
    const v = std.mem.readInt(u64, &buf, .little);
    return @intCast(v % n);
}

/// Picks a random cached wallpaper (avoiding a repeat of the current one
/// when more than one candidate exists) and applies it via `swaymsg`.
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
            // Missing/unreadable cache dir — leave the current wallpaper
            // untouched, matching the original's silent no-op.
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

    var current_buf: [4096]u8 = undefined;
    const current = Io.Dir.cwd().readFile(io, current_file, &current_buf) catch "";

    var pick: []const u8 = candidates.items[0];
    if (candidates.items.len > 1) {
        var pool: std.ArrayList([]const u8) = .empty;
        for (candidates.items) |c| {
            if (!std.mem.eql(u8, c, current)) try pool.append(gpa, c);
        }
        const chosen_from = if (pool.items.len > 0) pool.items else candidates.items;
        pick = chosen_from[randomIndex(io, chosen_from.len)];
    } else {
        pick = candidates.items[randomIndex(io, candidates.items.len)];
    }

    const pick_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, pick });

    var r = proc.run(io, gpa, &.{ "/usr/bin/swaymsg", "output", "*", "bg", pick_path, "fill" }) catch return 0;
    defer r.deinit(gpa);
    if (!r.exited_zero) return 0;

    var f = Io.Dir.cwd().createFile(io, current_file, .{ .truncate = true }) catch return 0;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = f.writer(io, &wbuf);
    w.interface.writeAll(pick_path) catch {};
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

test "hasWallpaperExt matches a bare extension with no basename, like bash's *.jpg glob does" {
    // find -iname '*.jpg' matches ".jpg" too (the '*' matches zero chars) —
    // parity with that, not a design choice made independently here.
    try testing.expect(hasWallpaperExt(".jpg"));
}

test "randomIndex never returns out of range and handles n<=1" {
    try testing.expectEqual(@as(usize, 0), randomIndex(testing.io, 0));
    try testing.expectEqual(@as(usize, 0), randomIndex(testing.io, 1));
    for (0..50) |_| {
        const idx = randomIndex(testing.io, 5);
        try testing.expect(idx < 5);
    }
}
