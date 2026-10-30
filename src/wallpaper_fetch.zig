//! `laptopd wallpaper-fetch` — tops up the local wallpaper cache with curated
//! photography from Bing's daily image archive and NASA APOD, neither
//! requiring an API key. Safe to run repeatedly: self-rate-limits to ~once/20h
//! via a stamp file, lock-guarded so overlapping invocations (e.g. a session
//! start racing a lid-close) don't race. Never fatal — network hiccups just
//! leave the existing cache untouched.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_files: usize = 40;
const rate_limit_seconds: i64 = 20 * 3600;
const max_body_bytes: usize = 32 * 1024 * 1024; // generous ceiling for one image

const BingResponse = struct {
    images: []struct {
        urlbase: []const u8 = "",
    } = &.{},
};

const ApodResponse = struct {
    media_type: []const u8 = "",
    date: []const u8 = "unknown",
    hdurl: []const u8 = "",
    url: []const u8 = "",
};

fn fetchBody(client: *std.http.Client, gpa: Allocator, url: []const u8) ?[]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch return null;
    if (result.status != .ok) return null;
    return gpa.dupe(u8, aw.written()) catch null;
}

/// Sanitizes a Bing `urlbase` (e.g. "/th?id=OHR.Foo_EN-US1234567890") into a
/// filesystem-safe id, matching the original's
/// `id="${urlbase##*id=}"; id="${id//[^a-zA-Z0-9_.-]/_}"`.
fn sanitizeBingId(gpa: Allocator, urlbase: []const u8) ![]u8 {
    const after_id = if (std.mem.lastIndexOf(u8, urlbase, "id=")) |i| urlbase[i + 3 ..] else urlbase;
    const out = try gpa.dupe(u8, after_id);
    for (out) |*c| {
        const ok = std.ascii.isAlphanumeric(c.*) or c.* == '_' or c.* == '.' or c.* == '-';
        if (!ok) c.* = '_';
    }
    return out;
}

fn downloadToFile(client: *std.http.Client, io: Io, gpa: Allocator, url: []const u8, dest: []const u8) bool {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch return false;
    if (result.status != .ok) return false;
    const body = aw.written();
    if (body.len == 0 or body.len > max_body_bytes) return false;

    var tmp_buf: [1024]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{dest}) catch return false;
    var f = Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true }) catch return false;
    var closed = false;
    defer if (!closed) f.close(io);
    var wbuf: [8192]u8 = undefined;
    var w = f.writer(io, &wbuf);
    w.interface.writeAll(body) catch {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return false;
    };
    w.interface.flush() catch {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return false;
    };
    f.close(io);
    closed = true;
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), dest, io) catch {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return false;
    };
    return true;
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

const CacheEntry = struct {
    path: []const u8,
    mtime_ns: i128,
};

/// Deletes all but the newest `max_files` entries in `dir` by mtime.
fn pruneCache(io: Io, gpa: Allocator, dir: []const u8) void {
    var entries: std.ArrayList(CacheEntry) = .empty;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const stat = d.statFile(io, entry.name, .{}) catch continue;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, entry.name }) catch continue;
        entries.append(gpa, .{ .path = full, .mtime_ns = stat.mtime.nanoseconds }) catch continue;
    }
    if (entries.items.len <= max_files) return;

    std.mem.sort(CacheEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
            return a.mtime_ns > b.mtime_ns; // newest first
        }
    }.lessThan);

    for (entries.items[max_files..]) |e| {
        Io.Dir.deleteFileAbsolute(io, e.path) catch {};
    }
}

/// Tops up the wallpaper cache from Bing (last 8 days) and NASA APOD
/// (today, if it's an image), then prunes down to `max_files`. Rate-limited
/// to ~once/20h and lock-guarded (see the module doc comment); always
/// returns 0 — every failure path here is a documented no-op, not an error.
pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map) !u8 {
    const home = environ.get("HOME") orelse {
        std.debug.print("laptopd wallpaper-fetch: $HOME is unset\n", .{});
        return 1;
    };
    const dir = environ.get("WALLPAPER_DIR") orelse try std.fmt.allocPrint(gpa, "{s}/Pictures/wallpapers", .{home});
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.local/state/wallpaper", .{home});
    const stamp_path = try std.fmt.allocPrint(gpa, "{s}/last-fetch", .{state_dir});
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/fetch.lock", .{state_dir});
    const nasa_key = environ.get("NASA_API_KEY") orelse "DEMO_KEY";

    Io.Dir.cwd().createDirPath(io, dir) catch {};
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};

    // flock -n equivalent: non-blocking exclusive lock, silently give up if
    // another invocation already holds it (rapid sleep/wake).
    var lock_file = Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false }) catch return 0;
    defer lock_file.close(io);
    const lock_rc = std.os.linux.flock(lock_file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (std.posix.errno(lock_rc) != .SUCCESS) return 0;

    // Rate-limit: skip if fetched within the last ~20 hours.
    if (Io.Dir.cwd().statFile(io, stamp_path, .{})) |stamp_stat| {
        const now = Io.Timestamp.now(io, .real).nanoseconds;
        const age_s = @divFloor(now - stamp_stat.mtime.nanoseconds, std.time.ns_per_s);
        if (age_s < rate_limit_seconds) return 0;
    } else |_| {}

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    // --- Bing daily images (last 8 days) ---
    if (fetchBody(&client, gpa, "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-US")) |bing_json| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (std.json.parseFromSliceLeaky(BingResponse, arena.allocator(), bing_json, .{ .ignore_unknown_fields = true })) |bing| {
            for (bing.images) |img| {
                if (img.urlbase.len == 0) continue;
                const id = sanitizeBingId(gpa, img.urlbase) catch continue;
                const out = std.fmt.allocPrint(gpa, "{s}/bing_{s}.jpg", .{ dir, id }) catch continue;
                if (fileExists(io, out)) continue;
                const url = std.fmt.allocPrint(gpa, "https://www.bing.com{s}_UHD.jpg", .{img.urlbase}) catch continue;
                _ = downloadToFile(&client, io, gpa, url, out);
            }
        } else |_| {}
    }

    // --- NASA APOD (astronomy/space); skip non-image days (video etc.) ---
    const apod_url = std.fmt.allocPrint(gpa, "https://api.nasa.gov/planetary/apod?api_key={s}", .{nasa_key}) catch "";
    if (apod_url.len > 0) {
        if (fetchBody(&client, gpa, apod_url)) |apod_json| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            if (std.json.parseFromSliceLeaky(ApodResponse, arena.allocator(), apod_json, .{ .ignore_unknown_fields = true })) |apod| {
                if (std.mem.eql(u8, apod.media_type, "image")) {
                    const img_url = if (apod.hdurl.len > 0) apod.hdurl else apod.url;
                    const out = std.fmt.allocPrint(gpa, "{s}/apod_{s}.jpg", .{ dir, apod.date }) catch "";
                    if (img_url.len > 0 and out.len > 0 and !fileExists(io, out)) {
                        _ = downloadToFile(&client, io, gpa, img_url, out);
                    }
                }
            } else |_| {}
        }
    }

    pruneCache(io, gpa, dir);

    var stamp_f = Io.Dir.cwd().createFile(io, stamp_path, .{ .truncate = true }) catch return 0;
    stamp_f.close(io);
    return 0;
}

const testing = std.testing;

test "sanitizeBingId extracts the id param and replaces unsafe characters" {
    // '=' is not in bash's [^a-zA-Z0-9_.-] whitelist either, so it becomes
    // '_' same as '&' and '?' would — this is the real bash behavior, not
    // a design choice made independently here.
    const id = try sanitizeBingId(testing.allocator, "/th?id=OHR.Artemis_EN-US0683925849.jpg&rf=LaDigue");
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("OHR.Artemis_EN-US0683925849.jpg_rf_LaDigue", id);
}

test "sanitizeBingId handles a urlbase with no id= at all" {
    const id = try sanitizeBingId(testing.allocator, "plainvalue");
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("plainvalue", id);
}

test "BingResponse parses the real shape, ignoring fields we don't use" {
    const sample =
        \\{"images":[{"urlbase":"/th?id=OHR.Foo_EN-US123","copyright":"x","extra_unknown_field":1}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(BingResponse, arena.allocator(), sample, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(@as(usize, 1), parsed.images.len);
    try testing.expectEqualStrings("/th?id=OHR.Foo_EN-US123", parsed.images[0].urlbase);
}

test "ApodResponse parses an image day" {
    const sample =
        \\{"media_type":"image","date":"2026-08-15","hdurl":"https://example/hd.jpg","url":"https://example/sd.jpg"}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(ApodResponse, arena.allocator(), sample, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("image", parsed.media_type);
    try testing.expectEqualStrings("https://example/hd.jpg", parsed.hdurl);
}

test "ApodResponse defaults degrade gracefully on a video day (missing hdurl/url)" {
    const sample = "{\"media_type\":\"video\",\"date\":\"2026-08-14\"}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(ApodResponse, arena.allocator(), sample, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("video", parsed.media_type);
    try testing.expectEqual(@as(usize, 0), parsed.hdurl.len);
}
