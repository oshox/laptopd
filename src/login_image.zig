//! `laptopd login-image [--if-missing]` — picks a random cached wallpaper for
//! the SDDM login screen, different from what the desktop and lock screen are
//! showing, and copies it to a world-readable spot outside $HOME (the home is
//! encrypted and locked at the login screen, so a link into it won't do).
//! Run at logout by laptopd-login-image.service's ExecStop, so it only does
//! local work: no network, no sway required (a dead sway just means the
//! panel-size check uses the built-in fallback).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sway = @import("sway.zig");
const state = @import("state.zig");
const image_info = @import("image_info.zig");

const default_target = "/var/lib/laptopd/login-background";
const probe_bytes: usize = 256 * 1024;
const max_image_bytes: usize = 32 * 1024 * 1024;

fn hasImageExt(name: []const u8) bool {
    for ([_][]const u8{ ".jpg", ".jpeg", ".png" }) |ext| {
        if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Random element of `candidates` that is not in `exclude`; null if none is eligible.
fn pick(rand: std.Random, candidates: []const []const u8, exclude: []const []const u8) ?[]const u8 {
    var eligible: usize = 0;
    for (candidates) |c| {
        if (!contains(exclude, c)) eligible += 1;
    }
    if (eligible == 0) return null;
    var n = rand.uintLessThan(usize, eligible);
    for (candidates) |c| {
        if (contains(exclude, c)) continue;
        if (n == 0) return c;
        n -= 1;
    }
    unreachable;
}

fn copyFile(io: Io, gpa: Allocator, src: []const u8, dest: []const u8) !void {
    const size = (try Io.Dir.cwd().statFile(io, src, .{})).size;
    if (size == 0 or size > max_image_bytes) return error.BadSize;
    const buf = try gpa.alloc(u8, @intCast(size));
    defer gpa.free(buf);
    const data = try Io.Dir.cwd().readFile(io, src, buf);

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{dest});
    defer gpa.free(tmp);
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    var f = try Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
    {
        defer f.close(io);
        var wbuf: [8192]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.writeAll(data);
        try w.interface.flush();
    }
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), dest, io);
}

pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    var if_missing = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--if-missing")) if_missing = true;
    }

    const target_path = environ.get("LOGIN_IMAGE_PATH") orelse default_target;
    if (if_missing) {
        if (Io.Dir.cwd().statFile(io, target_path, .{})) |_| return 0 else |_| {}
    }

    const home = environ.get("HOME") orelse {
        std.debug.print("laptopd login-image: $HOME is unset\n", .{});
        return 1;
    };
    const dir = environ.get("WALLPAPER_DIR") orelse try std.fmt.allocPrint(gpa, "{s}/Pictures/wallpapers", .{home});
    const current_file = try std.fmt.allocPrint(gpa, "{s}/.local/state/wallpaper/current", .{home});

    // Everything the desktop / lock screen is showing right now is off limits.
    var state_buf: [8192]u8 = undefined;
    const content = Io.Dir.cwd().readFile(io, current_file, &state_buf) catch "";
    const prev = try state.parseState(gpa, content);
    var exclude: std.ArrayList([]const u8) = .empty;
    for (prev) |p| try exclude.append(gpa, p.file);

    const size = blk: {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        break :blk if (sway.getOutputs(io, gpa, arena.allocator())) |outs| sway.target(outs) else sway.fallback;
    };

    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    const head = try gpa.alloc(u8, probe_bytes);
    var candidates: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!hasImageExt(entry.name)) continue;
        const bytes = d.readFile(io, entry.name, head) catch continue;
        const info = image_info.probe(bytes) orelse continue;
        if (!image_info.fits(info, size.width, size.height, image_info.default_max_crop)) continue;
        try candidates.append(gpa, try gpa.dupe(u8, entry.name));
    }

    var seed: [8]u8 = undefined;
    Io.random(io, &seed);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
    // Nothing eligible: keep whatever login image is already there.
    const chosen = pick(prng.random(), candidates.items, exclude.items) orelse return 0;

    const src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, chosen });
    copyFile(io, gpa, src, target_path) catch |err| {
        std.debug.print("laptopd login-image: copy to {s} failed: {t}\n", .{ target_path, err });
        return 1;
    };
    return 0;
}

const testing = std.testing;

test "pick never returns an excluded image" {
    const cands = [_][]const u8{ "a.jpg", "b.jpg", "c.jpg" };
    const excl = [_][]const u8{ "a.jpg", "c.jpg" };
    var prng = std.Random.DefaultPrng.init(5);
    for (0..50) |_| {
        try testing.expectEqualStrings("b.jpg", pick(prng.random(), &cands, &excl).?);
    }
}

test "pick covers every eligible image over many draws" {
    const cands = [_][]const u8{ "a.jpg", "b.jpg", "c.jpg", "d.jpg" };
    const excl = [_][]const u8{"a.jpg"};
    var seen = [_]bool{false} ** 4;
    var prng = std.Random.DefaultPrng.init(11);
    for (0..200) |_| {
        const p = pick(prng.random(), &cands, &excl).?;
        for (cands, 0..) |c, i| {
            if (std.mem.eql(u8, c, p)) seen[i] = true;
        }
    }
    try testing.expect(!seen[0] and seen[1] and seen[2] and seen[3]);
}

test "pick returns null when everything is excluded or there is nothing" {
    var prng = std.Random.DefaultPrng.init(1);
    const cands = [_][]const u8{"a.jpg"};
    try testing.expectEqual(@as(?[]const u8, null), pick(prng.random(), &cands, &cands));
    try testing.expectEqual(@as(?[]const u8, null), pick(prng.random(), &.{}, &.{}));
}

test "hasImageExt accepts only formats SDDM's Qt can load from our sniffer" {
    try testing.expect(hasImageExt("a.JPG"));
    try testing.expect(hasImageExt("a.png"));
    try testing.expect(!hasImageExt("a.webp"));
    try testing.expect(!hasImageExt("a.jxl"));
}
