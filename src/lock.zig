//! `laptopd lock` — runs swaylock showing, on each output, the wallpaper that
//! output currently has on the desktop (from the wallpaper state file).
//! Called by swayidle for the idle timeout, `loginctl lock-session` and
//! before-sleep, so it must be fast and self-contained: no sway IPC, no
//! network, just read the state file and start swaylock. Any problem falls
//! back to a plain `swaylock -f` (which uses ~/.config/swaylock/config).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proc = @import("proc.zig");
const state = @import("state.zig");

const swaylock = "/usr/bin/swaylock";

/// Builds `swaylock -f [-i <output>:<path>]...` from the state entries whose
/// image still exists. `ctx.exists(path)` reports whether a file is there.
fn buildArgs(gpa: Allocator, entries: []const state.Prev, ctx: anytype) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(gpa, swaylock);
    try args.append(gpa, "-f");
    for (entries) |e| {
        if (e.path.len == 0 or !ctx.exists(e.path)) continue;
        try args.append(gpa, "-i");
        if (std.mem.eql(u8, e.output, state.wildcard)) {
            try args.append(gpa, e.path);
        } else {
            try args.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{s}", .{ e.output, e.path }));
        }
    }
    return args.items;
}

const FsCtx = struct {
    io: Io,
    fn exists(self: FsCtx, path: []const u8) bool {
        Io.Dir.accessAbsolute(self.io, path, .{}) catch return false;
        return true;
    }
};

fn alreadyLocked(io: Io, gpa: Allocator) bool {
    var uid_buf: [16]u8 = undefined;
    const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{std.os.linux.getuid()}) catch return false;
    var r = proc.run(io, gpa, &.{ "/usr/bin/pgrep", "-xu", uid, "swaylock" }) catch return false;
    defer r.deinit(gpa);
    return r.exited_zero;
}

pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map) !u8 {
    if (alreadyLocked(io, gpa)) return 0;

    const plain: []const []const u8 = &.{ swaylock, "-f" };
    const home = environ.get("HOME") orelse {
        _ = proc.runInherited(io, plain) catch {};
        return 0;
    };
    const current_file = try std.fmt.allocPrint(gpa, "{s}/.local/state/wallpaper/current", .{home});
    var buf: [8192]u8 = undefined;
    const content = Io.Dir.cwd().readFile(io, current_file, &buf) catch "";
    const entries = state.parseState(gpa, content) catch &[_]state.Prev{};
    const args = buildArgs(gpa, entries, FsCtx{ .io = io }) catch plain;

    const ok = proc.runInherited(io, args) catch false;
    // A bad image path makes swaylock exit non-zero without locking; make
    // sure the screen still ends up locked.
    if (!ok and args.len > plain.len) _ = proc.runInherited(io, plain) catch {};
    return 0;
}

const testing = std.testing;

const FakeFs = struct {
    present: []const []const u8,
    fn exists(self: FakeFs, path: []const u8) bool {
        for (self.present) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }
};

test "buildArgs gives each output its own image" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = try state.parseState(arena.allocator(), "eDP-1\t/w/a.jpg\nDP-3\t/w/b.jpg\n");
    const args = try buildArgs(arena.allocator(), entries, FakeFs{ .present = &.{ "/w/a.jpg", "/w/b.jpg" } });
    const want = [_][]const u8{ swaylock, "-f", "-i", "eDP-1:/w/a.jpg", "-i", "DP-3:/w/b.jpg" };
    try testing.expectEqual(want.len, args.len);
    for (want, args) |w, g| try testing.expectEqualStrings(w, g);
}

test "buildArgs treats a legacy bare path as an all-outputs image" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = try state.parseState(arena.allocator(), "/w/old.jpg");
    const args = try buildArgs(arena.allocator(), entries, FakeFs{ .present = &.{"/w/old.jpg"} });
    try testing.expectEqual(@as(usize, 4), args.len);
    try testing.expectEqualStrings("/w/old.jpg", args[3]);
}

test "buildArgs skips images that no longer exist and falls back to a plain lock" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = try state.parseState(arena.allocator(), "eDP-1\t/w/gone.jpg\n");
    const args = try buildArgs(arena.allocator(), entries, FakeFs{ .present = &.{} });
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("-f", args[1]);
    const empty = try buildArgs(arena.allocator(), &.{}, FakeFs{ .present = &.{} });
    try testing.expectEqual(@as(usize, 2), empty.len);
}
