//! A pixel buffer and the few rasterising primitives the scene needs.
//!
//! No antialiasing: scanline polygon fill (even-odd, pixel centres), Bresenham
//! lines, and quads for thick lines. Everything is clipped to the buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rgb = @import("palettes.zig").Rgb;

pub const Pt = [2]f32;

/// An RGB image plus the glyph mask drawn alongside it.
pub const Frame = struct {
    w: usize,
    h: usize,
    /// h*w*3 bytes, row-major RGB.
    pix: []u8,
    /// h*w bytes: non-zero where the renderer should use an ASCII glyph.
    mask: []u8,

    pub fn init(gpa: Allocator, w: usize, h: usize) Allocator.Error!Frame {
        const pix = try gpa.alloc(u8, w * h * 3);
        errdefer gpa.free(pix);
        const mask = try gpa.alloc(u8, w * h);
        @memset(pix, 0);
        @memset(mask, 0);
        return .{ .w = w, .h = h, .pix = pix, .mask = mask };
    }

    pub fn deinit(self: *Frame, gpa: Allocator) void {
        gpa.free(self.pix);
        gpa.free(self.mask);
        self.* = undefined;
    }

    pub fn clear(self: *Frame) void {
        @memset(self.pix, 0);
        @memset(self.mask, 0);
    }
};

/// Where a primitive puts its pixels: a colour, and optionally a mask value.
pub const Brush = struct {
    pix: []u8,
    mask: ?[]u8 = null,
    w: usize,
    h: usize,
    rgb: Rgb,
    glyph: u8 = 0,

    pub fn put(self: Brush, x: i32, y: i32) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i = @as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x));
        @memcpy(self.pix[i * 3 ..][0..3], &self.rgb);
        if (self.mask) |m| m[i] = self.glyph;
    }
};

inline fn round(v: f32) i32 {
    return @intFromFloat(@round(v));
}

/// 1-pixel line between the rounded endpoints.
pub fn line(b: Brush, p0: Pt, p1: Pt) void {
    var x = round(p0[0]);
    var y = round(p0[1]);
    const x1 = round(p1[0]);
    const y1 = round(p1[1]);
    const dx: i32 = @intCast(@abs(x1 - x));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y)));
    const sx: i32 = if (x < x1) 1 else -1;
    const sy: i32 = if (y < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        b.put(x, y);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// Polyline of 1-pixel lines.
pub fn polyline(b: Brush, pts: []const Pt) void {
    if (pts.len == 1) return b.put(round(pts[0][0]), round(pts[0][1]));
    for (pts[0..pts.len -| 1], pts[1..]) |p, q| line(b, p, q);
}

const max_edges = 64;

/// Even-odd scanline fill of pixels whose centre is inside, plus the outline,
/// so tiny polygons never vanish.
pub fn fillPoly(b: Brush, pts: []const Pt) void {
    std.debug.assert(pts.len <= max_edges);
    if (pts.len == 0) return;
    var ymin = pts[0][1];
    var ymax = pts[0][1];
    for (pts) |p| {
        ymin = @min(ymin, p[1]);
        ymax = @max(ymax, p[1]);
    }
    const y_first: i32 = @max(0, @as(i32, @intFromFloat(@ceil(ymin - 0.5))));
    const y_last: i32 = @min(@as(i32, @intCast(b.h)) - 1, @as(i32, @intFromFloat(@ceil(ymax - 0.5))) - 1);
    var y = y_first;
    while (y <= y_last) : (y += 1) {
        const yc = @as(f32, @floatFromInt(y)) + 0.5;
        var xs: [max_edges]f32 = undefined;
        var n: usize = 0;
        var prev = pts[pts.len - 1];
        for (pts) |cur| {
            const lo = if (prev[1] <= cur[1]) prev else cur;
            const hi = if (prev[1] <= cur[1]) cur else prev;
            if (lo[1] <= yc and yc < hi[1]) {
                const x = lo[0] + (yc - lo[1]) / (hi[1] - lo[1]) * (hi[0] - lo[0]);
                var i = n; // insertion sort
                while (i > 0 and xs[i - 1] > x) : (i -= 1) xs[i] = xs[i - 1];
                xs[i] = x;
                n += 1;
            }
            prev = cur;
        }
        var k: usize = 0;
        while (k + 1 < n) : (k += 2) {
            const x0: i32 = @intFromFloat(@ceil(xs[k] - 0.5));
            const x1: i32 = @intFromFloat(@ceil(xs[k + 1] - 0.5));
            var x = @max(0, x0);
            const end = @min(@as(i32, @intCast(b.w)), x1);
            while (x < end) : (x += 1) b.put(x, y);
        }
    }
    var prev = pts[pts.len - 1];
    for (pts) |cur| {
        line(b, prev, cur);
        prev = cur;
    }
}

/// Line of the given pixel width: a 1-pixel line, or a filled quad.
pub fn thickLine(b: Brush, p0: Pt, p1: Pt, width: i32) void {
    if (width <= 1) return line(b, p0, p1);
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return b.put(round(p0[0]), round(p0[1]));
    const h = @as(f32, @floatFromInt(width)) / 2;
    const nx = -dy / len * h;
    const ny = dx / len * h;
    fillPoly(b, &.{
        .{ p0[0] + nx, p0[1] + ny }, .{ p1[0] + nx, p1[1] + ny },
        .{ p1[0] - nx, p1[1] - ny }, .{ p0[0] - nx, p0[1] - ny },
    });
}

fn testBrush(f: *Frame, v: u8, glyph: ?u8) Brush {
    return .{
        .pix = f.pix,
        .mask = if (glyph != null) f.mask else null,
        .w = f.w,
        .h = f.h,
        .rgb = .{ v, v, v },
        .glyph = glyph orelse 0,
    };
}

fn countLit(f: Frame) usize {
    var n: usize = 0;
    for (0..f.w * f.h) |i| {
        if (f.pix[i * 3] != 0) n += 1;
    }
    return n;
}

test "fillPoly fills a square and clips to the frame" {
    var f = try Frame.init(std.testing.allocator, 20, 20);
    defer f.deinit(std.testing.allocator);
    fillPoly(testBrush(&f, 200, 1), &.{ .{ 4, 4 }, .{ 12, 4 }, .{ 12, 12 }, .{ 4, 12 } });
    try std.testing.expectEqual(@as(u8, 200), f.pix[(8 * 20 + 8) * 3]);
    try std.testing.expectEqual(@as(u8, 1), f.mask[8 * 20 + 8]);
    try std.testing.expectEqual(@as(u8, 0), f.pix[(2 * 20 + 2) * 3]);
    f.clear();
    fillPoly(testBrush(&f, 9, null), &.{ .{ -50, -50 }, .{ 500, -50 }, .{ 500, 500 }, .{ -50, 500 } });
    try std.testing.expectEqual(@as(usize, 400), countLit(f));
}

test "a polygon smaller than a pixel still draws" {
    var f = try Frame.init(std.testing.allocator, 8, 8);
    defer f.deinit(std.testing.allocator);
    fillPoly(testBrush(&f, 255, null), &.{ .{ 3.2, 3.2 }, .{ 3.4, 3.2 }, .{ 3.3, 3.4 } });
    try std.testing.expect(countLit(f) >= 1);
}

test "line hits both endpoints and thickLine is wider" {
    var f = try Frame.init(std.testing.allocator, 30, 30);
    defer f.deinit(std.testing.allocator);
    line(testBrush(&f, 255, null), .{ 2, 3 }, .{ 20, 9 });
    try std.testing.expectEqual(@as(u8, 255), f.pix[(3 * 30 + 2) * 3]);
    try std.testing.expectEqual(@as(u8, 255), f.pix[(9 * 30 + 20) * 3]);
    const thin = countLit(f);
    f.clear();
    thickLine(testBrush(&f, 255, null), .{ 2, 3 }, .{ 20, 9 }, 4);
    try std.testing.expect(countLit(f) > 2 * thin);
}
