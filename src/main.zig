//! laptopd — one multi-call binary for this laptop's user-level automation,
//! modelled on htpcd (the htpc's equivalent).
//!
//! Dispatches on EITHER the basename of argv[0] OR argv[1]: the `wallpaper-*`
//! names are plain symlinks to this binary (so sway's config and other
//! scripts can call `wallpaper-next` directly), while `laptopd <subcommand>`
//! is the form systemd units use, since a unit's ExecStart doesn't care what
//! argv[0] says.
//!
//! Allocator convention: resident daemons (display-watch) get `init.gpa` —
//! they loop for the life of the process and must free each iteration's
//! allocations. Oneshot subcommands get `init.arena.allocator()`, which is
//! cleaned up on exit.
//!
//! Adding automation: write `src/<name>.zig` with `pub fn run`, add a branch
//! below plus a line in `usage`, list it in the `test {}` block, and drop any
//! units under `dist/usr/lib/systemd/`.
//!
//! Subcommands:
//!   wallpaper-next   set a random cached wallpaper
//!   wallpaper-fetch  top up the wallpaper cache from Bing/NASA APOD
//!   display-watch    stage a fresh wallpaper while the internal panel is dark

const std = @import("std");
const wallpapernext = @import("wallpaper_next.zig");
const wallpaperfetch = @import("wallpaper_fetch.zig");
const displaywatch = @import("display_watch.zig");

const usage =
    \\usage: laptopd <subcommand>
    \\   or: <argv0-alias>   (wallpaper-next, wallpaper-fetch)
    \\
    \\subcommands:
    \\  wallpaper-next   set a random cached wallpaper
    \\  wallpaper-fetch  top up the wallpaper cache from Bing/NASA APOD
    \\  display-watch    stage a fresh wallpaper while the internal panel is dark
    \\
;

/// Entry point. Resolves a subcommand from argv[0] or argv[1] and dispatches
/// to it, following the allocator convention in the module doc comment.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse "";
    const argv0_base = std.fs.path.basename(argv0);

    // argv[0]-recognized aliases take priority; everything else falls
    // through to argv[1] as an explicit subcommand.
    const cmd = if (isKnownAlias(argv0_base)) argv0_base else args.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };

    if (std.mem.eql(u8, cmd, "wallpaper-next")) {
        std.process.exit(wallpapernext.run(io, arena, init.environ_map) catch |err| {
            std.debug.print("laptopd wallpaper-next: unhandled error: {t}\n", .{err});
            std.process.exit(1);
        });
    }

    if (std.mem.eql(u8, cmd, "wallpaper-fetch")) {
        std.process.exit(wallpaperfetch.run(io, arena, init.environ_map) catch |err| {
            std.debug.print("laptopd wallpaper-fetch: unhandled error: {t}\n", .{err});
            std.process.exit(1);
        });
    }

    if (std.mem.eql(u8, cmd, "display-watch")) {
        std.process.exit(displaywatch.run(io, init.gpa) catch |err| {
            std.debug.print("laptopd display-watch: unhandled error: {t}\n", .{err});
            std.process.exit(1);
        });
    }

    std.debug.print("laptopd: unknown subcommand {s}\n\n{s}", .{ cmd, usage });
    std.process.exit(2);
}

/// argv[0] basenames this binary answers to directly. Kept as an exhaustive
/// allowlist (rather than "anything not literally named laptopd") so a stray
/// or misnamed symlink fails loudly via the usage message.
fn isKnownAlias(name: []const u8) bool {
    const aliases = [_][]const u8{ "wallpaper-next", "wallpaper-fetch" };
    for (aliases) |a| {
        if (std.mem.eql(u8, name, a)) return true;
    }
    return false;
}

const testing = std.testing;

test "isKnownAlias recognizes the wallpaper aliases" {
    try testing.expect(isKnownAlias("wallpaper-next"));
    try testing.expect(isKnownAlias("wallpaper-fetch"));
}

test "isKnownAlias rejects the binary's own name and unrelated names" {
    try testing.expect(!isKnownAlias("laptopd"));
    try testing.expect(!isKnownAlias("display-watch"));
    try testing.expect(!isKnownAlias(""));
}

test {
    _ = @import("proc.zig");
    _ = @import("io_wait.zig");
    _ = @import("sway.zig");
    _ = @import("image_info.zig");
    _ = @import("wallpaper_next.zig");
    _ = @import("wallpaper_fetch.zig");
    _ = @import("display_watch.zig");
}
