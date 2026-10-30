//! Thin subprocess helpers shared by the oneshot subcommands that still need
//! to shell out (to `wg`, `systemctl`, `swaymsg`, etc. — external tools with
//! no Zig-native equivalent, as opposed to the rtorrent SCGI/XML-RPC socket,
//! which gets its own client in rtorrent.zig instead of shelling to a CLI).

const std = @import("std");
const Io = std.Io;

/// A completed subprocess's outcome: whether it exited with status 0, and
/// its captured stdout/stderr (gpa-owned — call `deinit` when done).
pub const Result = struct {
    exited_zero: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Runs argv[0] with the given args, waits, and captures both streams.
/// A nonzero exit or being killed by a signal both count as "not exited
/// zero" — callers that need to distinguish should inspect `term` instead.
pub fn run(io: Io, gpa: std.mem.Allocator, argv: []const []const u8) !Result {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    const zero = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .exited_zero = zero, .stdout = res.stdout, .stderr = res.stderr };
}

/// Like `run`, but pipes `stdin_data` to the child first — for tools like
/// `cec-client -s` that take their commands on stdin rather than argv.
/// Writes and closes stdin before reading stdout, which is safe as long as
/// `stdin_data` is small enough not to fill the pipe buffer before the
/// child starts draining it (true for every caller here: a handful of
/// short CEC command lines, not a stream).
pub fn runWithStdin(io: Io, gpa: std.mem.Allocator, argv: []const []const u8, stdin_data: []const u8) !Result {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    {
        var wbuf: [256]u8 = undefined;
        var w = child.stdin.?.writer(io, &wbuf);
        try w.interface.writeAll(stdin_data);
        try w.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var out_aw: Io.Writer.Allocating = .init(gpa);
    defer out_aw.deinit();
    var err_aw: Io.Writer.Allocating = .init(gpa);
    defer err_aw.deinit();
    {
        var rbuf: [4096]u8 = undefined;
        var r = child.stdout.?.reader(io, &rbuf);
        _ = r.interface.streamRemaining(&out_aw.writer) catch {};
    }
    {
        var rbuf: [4096]u8 = undefined;
        var r = child.stderr.?.reader(io, &rbuf);
        _ = r.interface.streamRemaining(&err_aw.writer) catch {};
    }

    const term = try child.wait(io);
    const zero = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{
        .exited_zero = zero,
        .stdout = try gpa.dupe(u8, out_aw.written()),
        .stderr = try gpa.dupe(u8, err_aw.written()),
    };
}

/// Runs argv[0] with stdout/stderr *inherited* (streamed straight to this
/// process's own, i.e. the journal under systemd) rather than captured —
/// for long-running, chatty commands like `dkms build`/`insmod`/
/// `rpm-ostree upgrade` where the original bash scripts let output flow
/// through live rather than buffering it. Returns only the exit status.
pub fn runInherited(io: Io, argv: []const []const u8) !bool {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const testing = std.testing;

test "run captures stdout and reports success for a zero exit" {
    var r = try run(testing.io, testing.allocator, &.{ "/bin/echo", "-n", "hello" });
    defer r.deinit(testing.allocator);
    try testing.expect(r.exited_zero);
    try testing.expectEqualStrings("hello", r.stdout);
}

test "run reports failure for a nonzero exit" {
    var r = try run(testing.io, testing.allocator, &.{ "/bin/sh", "-c", "exit 1" });
    defer r.deinit(testing.allocator);
    try testing.expect(!r.exited_zero);
}

test "runWithStdin pipes input through to the child and captures its echo" {
    var r = try runWithStdin(testing.io, testing.allocator, &.{"/bin/cat"}, "hello from stdin");
    defer r.deinit(testing.allocator);
    try testing.expect(r.exited_zero);
    try testing.expectEqualStrings("hello from stdin", r.stdout);
}

test "runInherited reports exit status without capturing output" {
    try testing.expect(try runInherited(testing.io, &.{ "/bin/sh", "-c", "exit 0" }));
    try testing.expect(!try runInherited(testing.io, &.{ "/bin/sh", "-c", "exit 1" }));
}
