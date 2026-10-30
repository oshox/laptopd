//! Header-only image dimension sniffing for JPEG and PNG, so wallpaper-fetch
//! can reject images that are too small or the wrong shape for the display
//! without decoding them. Anything else (webp, jxl, truncated data) probes
//! as null — callers treat that as "unknown", not "bad".

const std = @import("std");

pub const Kind = enum { jpeg, png };

pub const Info = struct {
    kind: Kind,
    width: u32,
    height: u32,

    pub fn ext(self: Info) []const u8 {
        return switch (self.kind) {
            .jpeg => ".jpg",
            .png => ".png",
        };
    }
};

const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

fn be16(b: []const u8) u32 {
    return std.mem.readInt(u16, b[0..2], .big);
}

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

/// Reads dimensions from the leading bytes of a JPEG or PNG file. For JPEG
/// the first SOFn marker can sit behind a large EXIF/ICC segment, so give it
/// a few hundred KB.
pub fn probe(bytes: []const u8) ?Info {
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], &png_sig)) {
        if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
        return .{ .kind = .png, .width = be32(bytes[16..20]), .height = be32(bytes[20..24]) };
    }
    if (bytes.len >= 4 and bytes[0] == 0xFF and bytes[1] == 0xD8) return probeJpeg(bytes);
    return null;
}

fn probeJpeg(b: []const u8) ?Info {
    var i: usize = 2;
    while (true) {
        // Marker: 0xFF, any number of 0xFF fill bytes, then the code.
        if (i + 2 > b.len or b[i] != 0xFF) return null;
        while (i + 1 < b.len and b[i + 1] == 0xFF) i += 1;
        if (i + 2 > b.len) return null;
        const marker = b[i + 1];
        i += 2;

        // Standalone markers carry no length.
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8)) continue;
        // EOI / SOS before any SOF: nothing to report.
        if (marker == 0xD9 or marker == 0xDA) return null;

        if (i + 2 > b.len) return null;
        const seg_len = be16(b[i..]);
        if (seg_len < 2) return null;

        const is_sof = marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (is_sof) {
            // length(2) precision(1) height(2) width(2)
            if (i + 7 > b.len) return null;
            return .{ .kind = .jpeg, .width = be16(b[i + 5 ..]), .height = be16(b[i + 3 ..]) };
        }
        i += seg_len;
    }
}

/// True when `info` can fill `width`×`height` without upscaling and without
/// cropping more than `max_crop` (0.20 = 20%) of the image to match the
/// display's aspect ratio. Sway's `fill` scales to cover, then crops the
/// overflow, so the crop fraction is `1 - min(ra, rt) / max(ra, rt)`.
pub fn fits(info: Info, width: u32, height: u32, max_crop: f64) bool {
    if (info.width == 0 or info.height == 0 or width == 0 or height == 0) return false;
    if (info.width < width or info.height < height) return false;
    const ra = @as(f64, @floatFromInt(info.width)) / @as(f64, @floatFromInt(info.height));
    const rt = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
    const crop = 1.0 - @min(ra, rt) / @max(ra, rt);
    return crop <= max_crop;
}

const testing = std.testing;

fn pngHeader(w: u32, h: u32) [24]u8 {
    var b: [24]u8 = undefined;
    @memcpy(b[0..8], &png_sig);
    std.mem.writeInt(u32, b[8..12], 13, .big);
    @memcpy(b[12..16], "IHDR");
    std.mem.writeInt(u32, b[16..20], w, .big);
    std.mem.writeInt(u32, b[20..24], h, .big);
    return b;
}

test "probe reads PNG dimensions from IHDR" {
    const b = pngHeader(121, 102);
    const info = probe(&b).?;
    try testing.expectEqual(Kind.png, info.kind);
    try testing.expectEqual(@as(u32, 121), info.width);
    try testing.expectEqual(@as(u32, 102), info.height);
    try testing.expectEqualStrings(".png", info.ext());
}

test "probe reads JPEG dimensions behind an APP1 segment and fill bytes" {
    const b = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, 0x00, 0x08, 'E', 'x', 'i', 'f', 0, 0, // APP1, len 8 (incl. length bytes)
        0xFF, 0xFF, 0xFF, 0xC0, // fill bytes, then SOF0
        0x00, 0x11, 0x08, // len, precision
        0x08, 0x70, // height 2160
        0x0F, 0x00, // width 3840
    };
    const info = probe(&b).?;
    try testing.expectEqual(Kind.jpeg, info.kind);
    try testing.expectEqual(@as(u32, 3840), info.width);
    try testing.expectEqual(@as(u32, 2160), info.height);
    try testing.expectEqualStrings(".jpg", info.ext());
}

test "probe skips DHT (C4) and reads the progressive SOF2" {
    const b = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xC4, 0x00, 0x04, 0x00, 0x00, // DHT: not a SOF
        0xFF, 0xC2, 0x00, 0x11, 0x08, 0x03, 0x20, 0x05, 0x00, // 800 tall, 1280 wide
    };
    const info = probe(&b).?;
    try testing.expectEqual(@as(u32, 1280), info.width);
    try testing.expectEqual(@as(u32, 800), info.height);
}

test "probe returns null for truncated, unknown and SOS-first data" {
    try testing.expectEqual(@as(?Info, null), probe(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE1, 0x10 }));
    try testing.expectEqual(@as(?Info, null), probe("RIFF....WEBPVP8 "));
    try testing.expectEqual(@as(?Info, null), probe(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02 }));
    try testing.expectEqual(@as(?Info, null), probe(""));
    var b = pngHeader(1, 1);
    b[12] = 'X'; // not IHDR
    try testing.expectEqual(@as(?Info, null), probe(&b));
}

test "fits accepts 16:9 4K on a 16:10 panel at the default crop limit" {
    const info: Info = .{ .kind = .jpeg, .width = 3840, .height = 2160 };
    try testing.expect(fits(info, 2560, 1600, 0.20));
}

test "fits rejects images smaller than the display, portrait and ultrawide" {
    try testing.expect(!fits(.{ .kind = .png, .width = 121, .height = 102 }, 2560, 1600, 0.20));
    try testing.expect(!fits(.{ .kind = .jpeg, .width = 2400, .height = 3600 }, 2560, 1600, 0.20)); // portrait
    try testing.expect(!fits(.{ .kind = .jpeg, .width = 5120, .height = 1600 }, 2560, 1600, 0.20)); // 32:10
    try testing.expect(!fits(.{ .kind = .jpeg, .width = 2560, .height = 1599 }, 2560, 1600, 0.20)); // 1px short
}

test "fits honors a tighter crop limit" {
    const info: Info = .{ .kind = .jpeg, .width = 3840, .height = 2160 }; // 10% crop on 16:10
    try testing.expect(!fits(info, 2560, 1600, 0.05));
    try testing.expect(fits(info, 2560, 1600, 0.10 + 1e-9));
}
