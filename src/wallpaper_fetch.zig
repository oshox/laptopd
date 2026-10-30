//! `laptopd wallpaper-fetch` — tops up the local wallpaper cache with curated
//! photography from Bing's daily image archive and NASA APOD, neither
//! requiring an API key. Safe to run repeatedly: self-rate-limits to ~once/20h
//! via a stamp file, lock-guarded so overlapping invocations (e.g. a session
//! start racing a lid-close) don't race. Never fatal — network hiccups just
//! leave the existing cache untouched.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sway = @import("sway.zig");
const image_info = @import("image_info.zig");

/// Override with WALLPAPER_MAX_CROP.
const default_max_crop = image_info.default_max_crop;
/// Enough to get past EXIF/ICC segments to a JPEG's SOF marker.
const probe_bytes: usize = 256 * 1024;

const Fit = struct {
    size: sway.Size,
    max_crop: f64,

    fn accepts(self: Fit, info: image_info.Info) bool {
        return image_info.fits(info, self.size.width, self.size.height, self.max_crop);
    }
};

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

/// Downloads `url`, and keeps it as `<dir>/<stem><ext>` only if it is a JPEG
/// or PNG that fits the display (see `Fit`). The extension comes from the
/// image's real type, not from the URL.
fn downloadImage(client: *std.http.Client, io: Io, gpa: Allocator, url: []const u8, dir: []const u8, stem: []const u8, fit: Fit) bool {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch return false;
    if (result.status != .ok) return false;
    const body = aw.written();
    if (body.len == 0 or body.len > max_body_bytes) return false;

    const info = image_info.probe(body[0..@min(body.len, probe_bytes)]) orelse return false;
    if (!fit.accepts(info)) return false;

    var dest_buf: [1024]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}{s}", .{ dir, stem, info.ext() }) catch return false;
    var tmp_buf: [1032]u8 = undefined;
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

/// True if `<dir>/<stem>` is already cached under either extension we write.
fn isCached(io: Io, gpa: Allocator, dir: []const u8, stem: []const u8) bool {
    for ([_][]const u8{ ".jpg", ".png" }) |ext| {
        const p = std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, stem, ext }) catch return true;
        defer gpa.free(p);
        if (fileExists(io, p)) return true;
    }
    return false;
}

/// Only files this command downloaded are ever judged or deleted; anything
/// else in the directory is the user's own.
fn isFetched(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "bing_") or std.mem.startsWith(u8, name, "apod_");
}

const CacheEntry = struct {
    path: []const u8,
    mtime_ns: i128,
};

/// Deletes downloaded files that no longer fit the display (e.g. fetched
/// before the size check existed), then all but the newest `max_files`
/// entries in `dir` by mtime. Images of unknown format are kept.
fn pruneCache(io: Io, gpa: Allocator, dir: []const u8, fit: Fit) void {
    var entries: std.ArrayList(CacheEntry) = .empty;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    const head = gpa.alloc(u8, probe_bytes) catch return;
    defer gpa.free(head);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".tmp")) {
            // Leftover from a download killed mid-flight (suspend, timeout).
            if (d.statFile(io, entry.name, .{})) |st| {
                const age_s = @divFloor(Io.Timestamp.now(io, .real).nanoseconds - st.mtime.nanoseconds, std.time.ns_per_s);
                if (age_s > 3600) d.deleteFile(io, entry.name) catch {};
            } else |_| {}
            continue;
        }
        if (isFetched(entry.name)) {
            const bytes = d.readFile(io, entry.name, head) catch &[_]u8{};
            if (image_info.probe(bytes)) |info| {
                if (!fit.accepts(info)) {
                    d.deleteFile(io, entry.name) catch {};
                    continue;
                }
            }
        }
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

/// Display size from sway (built-in panel preferred) and the crop limit from
/// WALLPAPER_MAX_CROP; falls back to the gram16 panel size if sway can't be
/// reached.
fn displayFit(io: Io, gpa: Allocator, environ: *std.process.Environ.Map) Fit {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const size = if (sway.getOutputs(io, gpa, arena.allocator())) |outs| sway.target(outs) else sway.fallback;
    const max_crop = if (environ.get("WALLPAPER_MAX_CROP")) |v|
        std.fmt.parseFloat(f64, v) catch default_max_crop
    else
        default_max_crop;
    return .{ .size = size, .max_crop = max_crop };
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

    const fit = displayFit(io, gpa, environ);

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    // The stamp is only written if at least one index request worked, so an
    // offline run (e.g. just after a resume, before Wi-Fi is back) retries at
    // the next trigger instead of waiting out the 20 h rate limit.
    var index_ok = false;

    // --- Bing daily images (last 8 days) ---
    if (fetchBody(&client, gpa, "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-US")) |bing_json| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (std.json.parseFromSliceLeaky(BingResponse, arena.allocator(), bing_json, .{ .ignore_unknown_fields = true })) |bing| {
            index_ok = true;
            for (bing.images) |img| {
                if (img.urlbase.len == 0) continue;
                const id = sanitizeBingId(gpa, img.urlbase) catch continue;
                const stem = std.fmt.allocPrint(gpa, "bing_{s}", .{id}) catch continue;
                if (isCached(io, gpa, dir, stem)) continue;
                const url = std.fmt.allocPrint(gpa, "https://www.bing.com{s}_UHD.jpg", .{img.urlbase}) catch continue;
                _ = downloadImage(&client, io, gpa, url, dir, stem, fit);
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
                index_ok = true;
                if (std.mem.eql(u8, apod.media_type, "image")) {
                    const img_url = if (apod.hdurl.len > 0) apod.hdurl else apod.url;
                    const stem = std.fmt.allocPrint(gpa, "apod_{s}", .{apod.date}) catch "";
                    if (img_url.len > 0 and stem.len > 0 and !isCached(io, gpa, dir, stem)) {
                        _ = downloadImage(&client, io, gpa, img_url, dir, stem, fit);
                    }
                }
            } else |_| {}
        }
    }

    pruneCache(io, gpa, dir, fit);

    if (!index_ok) return 0;
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

test "isFetched only claims files this command downloads" {
    try testing.expect(isFetched("bing_OHR.Foo_EN-US1.jpg"));
    try testing.expect(isFetched("apod_2026-10-30.png"));
    try testing.expect(!isFetched("my-photo.jpg"));
    try testing.expect(!isFetched("Beach-1.tif"));
}

test "Fit rejects a tiny image and a portrait, accepts 4K 16:9, on a 2560x1600 panel" {
    const fit: Fit = .{ .size = .{ .width = 2560, .height = 1600 }, .max_crop = default_max_crop };
    try testing.expect(!fit.accepts(.{ .kind = .png, .width = 121, .height = 102 }));
    try testing.expect(!fit.accepts(.{ .kind = .jpeg, .width = 3000, .height = 4500 }));
    try testing.expect(fit.accepts(.{ .kind = .jpeg, .width = 3840, .height = 2160 }));
}
