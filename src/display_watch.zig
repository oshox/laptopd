//! `laptopd display-watch` — stages a fresh wallpaper while the internal
//! panel is dark, so the swap is never seen. Subscribes to sway IPC output
//! events; on each event queries the actual output state (rather than parsing
//! event payloads) and, on an on -> off transition of the built-in panel
//! (lid close via the `bindswitch` in sway's config, or any DPMS-off), runs
//! `wallpaper-next` and dispatches `wallpaper-fetch` as its own transient
//! unit so a restart of this service can't kill a download mid-flight.
//!
//! Same two constraints as htpcd's cec-watch, which this is modelled on:
//! - The staging work runs on a detached thread so it never blocks the
//!   subscribe-read loop (a blocked read starves the pipe and sway drops the
//!   subscriber).
//! - The first state read after (re)start only records state and never
//!   swaps: `swaymsg output ... bg` is itself an output-mutating command, and
//!   firing it on every restart's resync can turn into a crash loop.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proc = @import("proc.zig");
const iowait = @import("io_wait.zig");
const sway = @import("sway.zig");

const wallpaper_next_path = "/usr/bin/wallpaper-next";
const wallpaper_fetch_path = "/usr/bin/wallpaper-fetch";

/// Pure transition rule: stage only on a genuine on -> off edge. `last` is
/// null on the first read after (re)start, which therefore never stages.
fn shouldStage(last: ?bool, now: bool) bool {
    return last != null and last.? and !now;
}

fn internalPower(outputs: []const sway.Output) ?bool {
    for (outputs) |o| {
        if (sway.isInternal(o.name) and o.power != null) return o.power;
    }
    return null;
}

fn queryPower(io: Io, gpa: Allocator) ?bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const outputs = sway.getOutputs(io, gpa, arena.allocator()) orelse return null;
    return internalPower(outputs);
}

fn timestampSuffix(io: Io, buf: []u8) []const u8 {
    const secs = @divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    return std.fmt.bufPrint(buf, "{d}", .{secs}) catch "0";
}

/// Runs entirely on a detached thread (see the header for why).
fn stageWallpaper(io: Io, gpa: Allocator) void {
    var wn_result = proc.run(io, gpa, &.{wallpaper_next_path}) catch null;
    if (wn_result) |*r| r.deinit(gpa);

    // RuntimeMaxSec: if the machine suspends mid-download the connection dies
    // and the HTTP client would wait forever; systemd kills it instead.
    var tbuf: [24]u8 = undefined;
    const unit = std.fmt.allocPrint(gpa, "wallpaper-fetch-{s}", .{timestampSuffix(io, &tbuf)}) catch return;
    defer gpa.free(unit);
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/systemd-run", "--user", "--collect", "--quiet", "--property=RuntimeMaxSec=180", "--unit", unit, wallpaper_fetch_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {}; // just the launcher; --collect means the real work outlives this wait
}

const StageArgs = struct { io: Io, gpa: Allocator };

fn stageThreadMain(args: StageArgs) void {
    stageWallpaper(args.io, args.gpa);
}

/// Queries the real panel state and, on an on -> off edge, dispatches
/// staging on a detached thread — never blocking the caller.
fn syncPower(io: Io, gpa: Allocator, last_power: *?bool) void {
    const power = queryPower(io, gpa) orelse return; // no internal panel / malformed reply — no-op
    const stage = shouldStage(last_power.*, power);
    last_power.* = power;
    if (!stage) return;

    const thread = std.Thread.spawn(.{}, stageThreadMain, .{StageArgs{ .io = io, .gpa = gpa }}) catch {
        // Thread spawn failing is rare (resource exhaustion); stage inline
        // rather than silently dropping the transition.
        stageWallpaper(io, gpa);
        return;
    };
    thread.detach();
}

/// Resident daemon. Runs until sway's subscribe pipe closes, then returns
/// non-zero so systemd's `Restart=always` reconnects to the next sway.
pub fn run(io: Io, gpa: Allocator) !u8 {
    var last_power: ?bool = null;

    // Record the starting state; never stages (last_power is null).
    syncPower(io, gpa, &last_power);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/swaymsg", "-t", "subscribe", "-m", "[\"output\"]" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    while (true) {
        var buf: [4096]u8 = undefined;
        const line = iowait.readLineFromFile(io, child.stdout.?, &buf, iowait.forever_ms) catch break;
        if (line == null) break; // swaymsg subscribe exited (sway quit/reload)
        syncPower(io, gpa, &last_power);
    }

    _ = child.wait(io) catch {};
    return 1;
}

const testing = std.testing;

test "shouldStage fires only on an on -> off edge" {
    try testing.expect(shouldStage(true, false));
    try testing.expect(!shouldStage(false, true));
    try testing.expect(!shouldStage(true, true));
    try testing.expect(!shouldStage(false, false));
}

test "shouldStage never fires on the first read after (re)start" {
    try testing.expect(!shouldStage(null, false));
    try testing.expect(!shouldStage(null, true));
}

test "internalPower finds eDP-1 among other outputs, ignoring unknown fields" {
    const sample =
        \\[
        \\  {"name":"DP-3","power":true,"make":"Some Make"},
        \\  {"name":"eDP-1","power":false,"current_mode":{"width":2880}}
        \\]
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outputs = try sway.parseOutputs(arena.allocator(), sample);
    try testing.expectEqual(@as(?bool, false), internalPower(outputs));
}

test "internalPower yields null when there is no internal panel" {
    const sample = "[{\"name\":\"DP-3\",\"power\":true}]";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outputs = try sway.parseOutputs(arena.allocator(), sample);
    try testing.expectEqual(@as(?bool, null), internalPower(outputs));
}

test "timestampSuffix produces a plain decimal string" {
    var buf: [24]u8 = undefined;
    const s = timestampSuffix(testing.io, &buf);
    try testing.expect(s.len > 0);
    for (s) |c| try testing.expect(c >= '0' and c <= '9');
}
