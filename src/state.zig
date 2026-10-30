//! The wallpaper state file, `~/.local/state/wallpaper/current`: one
//! `<output>\t<path>` line per output (a bare path from older versions is
//! read as output `*`). Written by wallpaper-next; read by wallpaper-next
//! (to avoid repeats), `lock` (lock screen images) and `login-image`
//! (to pick something different).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const wildcard = "*";

pub const Prev = struct {
    output: []const u8,
    /// Full path of the image that output last showed.
    path: []const u8,
    /// File name (no directory) of the same image.
    file: []const u8,
};

/// Parses the state file. Slices point into `content`; only the list itself
/// is allocated.
pub fn parseState(gpa: Allocator, content: []const u8) ![]Prev {
    var list: std.ArrayList(Prev) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        const output, const path = if (std.mem.indexOfScalar(u8, line, '\t')) |t|
            .{ line[0..t], line[t + 1 ..] }
        else
            .{ wildcard, line };
        try list.append(gpa, .{ .output = output, .path = path, .file = std.fs.path.basename(path) });
    }
    return list.items;
}

/// What `output` showed last time: its own entry, else the legacy `*` entry.
pub fn previousFor(prev: []const Prev, output: []const u8) []const u8 {
    for (prev) |p| {
        if (std.mem.eql(u8, p.output, output)) return p.file;
    }
    for (prev) |p| {
        if (std.mem.eql(u8, p.output, wildcard)) return p.file;
    }
    return "";
}

const testing = std.testing;

test "parseState reads per-output lines and the legacy single-path format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const modern = try parseState(a, "eDP-1\t/p/wp/a.jpg\nDP-3\t/p/wp/b.jpg\n");
    try testing.expectEqual(@as(usize, 2), modern.len);
    try testing.expectEqualStrings("eDP-1", modern[0].output);
    try testing.expectEqualStrings("/p/wp/a.jpg", modern[0].path);
    try testing.expectEqualStrings("b.jpg", modern[1].file);

    const legacy = try parseState(a, "/home/x/Pictures/wallpapers/old.jpg");
    try testing.expectEqual(@as(usize, 1), legacy.len);
    try testing.expectEqualStrings("*", legacy[0].output);
    try testing.expectEqualStrings("old.jpg", legacy[0].file);

    try testing.expectEqual(@as(usize, 0), (try parseState(a, "")).len);
}

test "previousFor prefers the exact output, then the legacy entry, then nothing" {
    const prev = [_]Prev{
        .{ .output = "eDP-1", .path = "/x/a.jpg", .file = "a.jpg" },
        .{ .output = "*", .path = "/x/legacy.jpg", .file = "legacy.jpg" },
    };
    try testing.expectEqualStrings("a.jpg", previousFor(&prev, "eDP-1"));
    try testing.expectEqualStrings("legacy.jpg", previousFor(&prev, "DP-3"));
    try testing.expectEqualStrings("", previousFor(&.{}, "eDP-1"));
}
