//! `poll()`-based readiness check, shared by anything that needs a
//! bounded-wait read on a raw fd (serial port, Unix socket) — a wall-clock
//! check *between* read calls is not a timeout if the read call itself can
//! block indefinitely; this is what actually bounds it. Extracted after
//! `hdrplayback.zig`'s mpv-socket read loop hung forever waiting on data
//! that was never coming (an unrecognized JSON command mpv silently never
//! replied to) — its loop rechecked a deadline only *between* reads, so a
//! single blocking read with nothing to read never returned at all. Caught
//! live testing against a real mpv instance, not by any unit test.
//! `serial.zig` already had this right; this is that same primitive, made
//! reusable so future socket/fd code doesn't have to relearn it.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

/// Returns true if `fd` is ready to act on — either real data (POLLIN) or
/// the peer having closed (POLLHUP) — within `timeout_ms`
/// (0 = poll once, non-blocking; negative would block forever and is not
/// accepted here — every caller has a real deadline).
///
/// POLLHUP matters as much as POLLIN here: a subprocess pipe whose writer
/// exits with zero output (e.g. a shell that does nothing but `exit 0`)
/// closes with no data ever written, and the kernel is not guaranteed to
/// also set POLLIN alongside POLLHUP in that case — checking POLLIN alone
/// left a real EOF invisible to callers, who'd see a timeout instead and
/// never learn the child was gone. A subsequent `read()` on a HUP'd fd
/// returns 0 immediately regardless, which is exactly the EOF signal
/// `audiowatch.zig`'s `waitForLine` needs. Caught by
/// `audiowatch.zig`'s own EOF test, not by anything hardware-dependent.
pub fn pollReadable(fd: posix.fd_t, timeout_ms: i32) !bool {
    std.debug.assert(timeout_ms >= 0);
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = try posix.poll(&fds, timeout_ms);
    return n > 0 and (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0;
}

/// Stands in for "wait basically forever" in a poll() timeout — every
/// caller in this project uses a finite deadline model (never a true -1
/// infinite block), so a watcher that wants to wait for its next event
/// with no real deadline just passes this (~24.8 days) rather than
/// introducing a second timeout semantics alongside the bounded one.
pub const forever_ms: i32 = std.math.maxInt(i32);

/// Reads one line (up to '\n', trimmed of a trailing '\r') from `file`,
/// waiting up to `timeout_ms` total across possibly-many partial reads.
/// Returns null on timeout or EOF, without erroring — same
/// "caller decides what that means" shape throughout this project.
///
/// Reads one byte at a time behind a poll() gate — not a buffered
/// multi-byte `Io.Reader` read, even though poll() already confirmed
/// readiness before each one. That combination hung indefinitely on a
/// Unix socket in `hdrplayback.zig` (see that file's history); byte-at-a-
/// time was the fix there and is now the one pattern this project uses
/// for every fd-with-timeout read, serial port or subprocess pipe alike,
/// rather than trusting a second read strategy with an unverified risk
/// profile. Proven live against real Arduino hardware and a real mpv
/// socket before being pulled out into this shared form.
pub fn readLineFromFile(io: Io, file: Io.File, buf: []u8, timeout_ms: i64) !?[]const u8 {
    var len: usize = 0;
    const deadline_ns = Io.Timestamp.now(io, .awake).nanoseconds + timeout_ms * std.time.ns_per_ms;

    while (true) {
        const remaining_ns = deadline_ns - Io.Timestamp.now(io, .awake).nanoseconds;
        if (remaining_ns <= 0) return null;
        const remaining_ms: i32 = @intCast(@min(@divFloor(remaining_ns, std.time.ns_per_ms), std.math.maxInt(i32)));
        if (!(try pollReadable(file.handle, remaining_ms))) return null;

        var byte: [1]u8 = undefined;
        // EOF is signaled by error.EndOfStream, never a 0 return — the
        // read never returns 0 here, confirmed by hitting exactly this
        // wrong assumption live (see this file's own EOF test, and the
        // POLLHUP fix above it that was needed to even reach this code on
        // a real EOF in the first place).
        const n = file.readStreaming(io, &.{&byte}) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (n == 0) return null;
        if (byte[0] == '\n') {
            if (len > 0 and buf[len - 1] == '\r') len -= 1;
            return buf[0..len];
        }
        if (len < buf.len) {
            buf[len] = byte[0];
            len += 1;
        }
    }
}

const testing = std.testing;

test "pollReadable returns false immediately when nothing is ready" {
    // stdin in a test runner has no pending input.
    const ready = try pollReadable(posix.STDIN_FILENO, 0);
    try testing.expect(!ready);
}

test "readLineFromFile reads a line written by a real child process" {
    // Real subprocess pipe, not a fixture — this is the exact shape
    // audiowatch.zig/cecwatch.zig use it for (reading lines from a
    // long-running subprocess), so it's exercised the same way here.
    const io = testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "echo hello-line" },
        .stdout = .pipe,
    });
    defer _ = child.wait(io) catch {};
    var buf: [64]u8 = undefined;
    const line = try readLineFromFile(io, child.stdout.?, &buf, 2000);
    try testing.expect(line != null);
    try testing.expectEqualStrings("hello-line", line.?);
}

test "readLineFromFile returns null on EOF with no trailing newline" {
    const io = testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdout = .pipe,
    });
    defer _ = child.wait(io) catch {};
    var buf: [64]u8 = undefined;
    const line = try readLineFromFile(io, child.stdout.?, &buf, 2000);
    try testing.expectEqual(@as(?[]const u8, null), line);
}
