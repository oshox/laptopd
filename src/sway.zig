//! Shared sway IPC helpers: the `swaymsg -t get_outputs` query and the
//! "which display are we fitting wallpapers to" rule used by
//! wallpaper-fetch, wallpaper-next and display-watch.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proc = @import("proc.zig");

pub const Mode = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const Output = struct {
    name: []const u8 = "",
    active: bool = true,
    power: ?bool = null,
    /// Physical pixels (what swaybg renders at), not scaled logical size.
    current_mode: ?Mode = null,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

/// Used when sway can't be queried (e.g. SWAYSOCK missing in a transient
/// unit): the gram16's built-in panel.
pub const fallback: Size = .{ .width = 2560, .height = 1600 };

/// The built-in panel is `eDP-1` on this machine, but match by prefix so a
/// different connector index doesn't silently break things.
pub fn isInternal(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "eDP-");
}

/// Parses `get_outputs` JSON. Strings are copied into `arena`, so the result
/// outlives `json`.
pub fn parseOutputs(arena: Allocator, json: []const u8) ![]Output {
    return std.json.parseFromSliceLeaky([]Output, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Runs `swaymsg -t get_outputs`. Returns null if sway is unreachable or the
/// reply is malformed. The result is owned by `arena`.
pub fn getOutputs(io: Io, gpa: Allocator, arena: Allocator) ?[]Output {
    var r = proc.run(io, gpa, &.{ "/usr/bin/swaymsg", "-t", "get_outputs" }) catch return null;
    defer r.deinit(gpa);
    if (!r.exited_zero) return null;
    return parseOutputs(arena, r.stdout) catch null;
}

/// The size wallpapers should fit: the built-in panel's mode if it has one,
/// otherwise the largest active output, otherwise `fallback`.
pub fn target(outputs: []const Output) Size {
    for (outputs) |o| {
        if (!isInternal(o.name)) continue;
        if (o.current_mode) |m| {
            if (m.width > 0 and m.height > 0) return .{ .width = m.width, .height = m.height };
        }
    }
    var best: ?Size = null;
    for (outputs) |o| {
        if (!o.active) continue;
        const m = o.current_mode orelse continue;
        if (m.width == 0 or m.height == 0) continue;
        const area = @as(u64, m.width) * m.height;
        if (best == null or area > @as(u64, best.?.width) * best.?.height) {
            best = .{ .width = m.width, .height = m.height };
        }
    }
    return best orelse fallback;
}

const testing = std.testing;

const sample_two =
    \\[
    \\  {"name":"eDP-1","active":true,"power":true,"scale":1.25,
    \\   "current_mode":{"width":2560,"height":1600,"refresh":144000,"picture_aspect_ratio":"none"}},
    \\  {"name":"DP-3","active":true,"power":true,
    \\   "current_mode":{"width":3840,"height":2160,"refresh":60000}}
    \\]
;

test "parseOutputs reads name, power and mode, ignoring unknown fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outs = try parseOutputs(arena.allocator(), sample_two);
    try testing.expectEqual(@as(usize, 2), outs.len);
    try testing.expectEqualStrings("eDP-1", outs[0].name);
    try testing.expectEqual(@as(u32, 2560), outs[0].current_mode.?.width);
    try testing.expectEqual(@as(?bool, true), outs[1].power);
}

test "target prefers the internal panel over a larger external display" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outs = try parseOutputs(arena.allocator(), sample_two);
    const t = target(outs);
    try testing.expectEqual(@as(u32, 2560), t.width);
    try testing.expectEqual(@as(u32, 1600), t.height);
}

test "target falls back to the largest active output when there is no internal panel" {
    const sample =
        \\[{"name":"DP-1","active":true,"current_mode":{"width":1920,"height":1080}},
        \\ {"name":"DP-2","active":true,"current_mode":{"width":3840,"height":2160}},
        \\ {"name":"DP-3","active":false,"current_mode":{"width":7680,"height":4320}}]
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outs = try parseOutputs(arena.allocator(), sample);
    const t = target(outs);
    try testing.expectEqual(@as(u32, 3840), t.width);
}

test "target uses the built-in fallback when nothing has a mode" {
    const t = target(&.{});
    try testing.expectEqual(fallback.width, t.width);
    try testing.expectEqual(fallback.height, t.height);
}

test "parseOutputs tolerates a disabled output with a null mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outs = try parseOutputs(arena.allocator(), "[{\"name\":\"DP-9\",\"active\":false,\"current_mode\":null}]");
    try testing.expect(!outs[0].active);
    try testing.expectEqual(@as(?Mode, null), outs[0].current_mode);
}
