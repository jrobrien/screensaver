//! Pixel buffer -> terminal cells -> ANSI.
//!
//! The buffer is rows*2 x cols pixels: two square-ish pixels per character
//! cell. A cell is a half-block (top pixel = fg, bottom pixel = bg) unless
//! either of its pixels is in the glyph mask; then it is an ASCII glyph chosen
//! by brightness and tinted with the masked pixels' colour.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster.zig");
const Rgb = @import("palettes.zig").Rgb;

const Frame = raster.Frame;

pub const ramp = " .:-=+*#%@";
pub const half: u21 = 0x2580; // upper half block

/// A frame of character cells.
pub const Cells = struct {
    cols: usize,
    rows: usize,
    ch: []u21,
    fg: []Rgb,
    bg: []Rgb,

    pub fn init(gpa: Allocator, cols: usize, rows: usize) Allocator.Error!Cells {
        const ch = try gpa.alloc(u21, cols * rows);
        errdefer gpa.free(ch);
        const fg = try gpa.alloc(Rgb, cols * rows);
        errdefer gpa.free(fg);
        const bg = try gpa.alloc(Rgb, cols * rows);
        return .{ .cols = cols, .rows = rows, .ch = ch, .fg = fg, .bg = bg };
    }

    pub fn deinit(self: *Cells, gpa: Allocator) void {
        gpa.free(self.ch);
        gpa.free(self.fg);
        gpa.free(self.bg);
        self.* = undefined;
    }

    fn copyFrom(self: *Cells, other: Cells) void {
        std.debug.assert(self.ch.len == other.ch.len);
        self.cols = other.cols;
        self.rows = other.rows;
        @memcpy(self.ch, other.ch);
        @memcpy(self.fg, other.fg);
        @memcpy(self.bg, other.bg);
    }
};

const Vec3 = @Vector(3, f32);

fn load(p: []const u8) Vec3 {
    return .{ @floatFromInt(p[0]), @floatFromInt(p[1]), @floatFromInt(p[2]) };
}

fn toRgb(v: Vec3) Rgb {
    var out: Rgb = undefined;
    inline for (0..3) |i| out[i] = @intFromFloat(std.math.clamp(v[i], 0, 255));
    return out;
}

/// Glyph cell: fg = mean colour of the masked pixel(s), bg = the other pixel dimmed.
fn glyphCell(top: Vec3, bot: Vec3, mt: bool, mb: bool, ch: *u21, fg_out: *Rgb, bg_out: *Rgb) void {
    const mtf: f32 = @floatFromInt(@intFromBool(mt));
    const mbf: f32 = @floatFromInt(@intFromBool(mb));
    var fg = (top * @as(Vec3, @splat(mtf)) + bot * @as(Vec3, @splat(mbf))) / @as(Vec3, @splat(@max(mtf + mbf, 1)));
    const bg: Vec3 = if (mt and mb) fg * @as(Vec3, @splat(0.18)) else (if (mt) bot else top) * @as(Vec3, @splat(0.45));
    const lum = (0.2126 * fg[0] + 0.7152 * fg[1] + 0.0722 * fg[2]) / 255.0;
    const top_idx: f32 = ramp.len - 1;
    const idx: usize = @intFromFloat(std.math.clamp(std.math.pow(f32, lum, 0.55) * top_idx + 0.5, 0, top_idx));
    const peak = @reduce(.Max, fg);
    ch.* = if (peak < 12) ' ' else ramp[idx];
    // Brighten the ink toward full value so thin foliage stays vivid.
    fg *= @splat(std.math.clamp(225 / @max(peak, 1), 1, 2.4));
    fg_out.* = toRgb(fg);
    bg_out.* = toRgb(bg);
}

/// Turn a frame into cells (`out` must be f.w columns by f.h/2 rows).
pub fn toCells(f: *const Frame, out: *Cells) void {
    std.debug.assert(out.cols == f.w and out.rows == f.h / 2);
    for (0..out.rows) |r| {
        for (0..out.cols) |c| {
            const ti = (2 * r) * f.w + c;
            const bi = ti + f.w;
            const i = r * out.cols + c;
            const mt = f.mask[ti] != 0;
            const mb = f.mask[bi] != 0;
            if (mt or mb) {
                glyphCell(load(f.pix[ti * 3 ..]), load(f.pix[bi * 3 ..]), mt, mb, &out.ch[i], &out.fg[i], &out.bg[i]);
            } else {
                out.ch[i] = half;
                out.fg[i] = f.pix[ti * 3 ..][0..3].*;
                out.bg[i] = f.pix[bi * 3 ..][0..3].*;
            }
        }
    }
}

/// Turns successive cell frames into minimal ANSI updates (truecolour, synchronized).
pub const Emitter = struct {
    gpa: Allocator,
    prev: ?Cells = null,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Emitter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Emitter) void {
        if (self.prev) |*p| p.deinit(self.gpa);
        self.buf.deinit(self.gpa);
    }

    /// Force the next frame to redraw everything.
    pub fn reset(self: *Emitter) void {
        if (self.prev) |*p| p.deinit(self.gpa);
        self.prev = null;
    }

    fn appendNum(self: *Emitter, n: usize) Allocator.Error!void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var v = n;
        while (true) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
            if (v == 0) break;
        }
        try self.buf.appendSlice(self.gpa, tmp[i..]);
    }

    fn appendColour(self: *Emitter, comptime sgr: []const u8, c: Rgb) Allocator.Error!void {
        try self.buf.appendSlice(self.gpa, sgr);
        try self.appendNum(c[0]);
        try self.buf.append(self.gpa, ';');
        try self.appendNum(c[1]);
        try self.buf.append(self.gpa, ';');
        try self.appendNum(c[2]);
        try self.buf.append(self.gpa, 'm');
    }

    /// The bytes that bring the terminal from the previous frame to `cells`.
    /// The slice is valid until the next call.
    pub fn frame(self: *Emitter, cells: Cells) Allocator.Error![]const u8 {
        const gpa = self.gpa;
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(gpa, "\x1b[?2026h");
        var full = true;
        if (self.prev) |p| full = p.cols != cells.cols or p.rows != cells.rows;
        if (full) {
            self.reset();
            try self.buf.appendSlice(gpa, "\x1b[2J");
        }
        var last_fg: ?Rgb = null;
        var last_bg: ?Rgb = null;
        for (0..cells.rows) |r| {
            const row = r * cells.cols;
            var first: usize = cells.cols;
            var last: usize = 0; // one past the last change
            for (0..cells.cols) |c| {
                const i = row + c;
                const changed = if (self.prev) |p|
                    p.ch[i] != cells.ch[i] or !std.mem.eql(u8, &p.fg[i], &cells.fg[i]) or !std.mem.eql(u8, &p.bg[i], &cells.bg[i])
                else
                    true;
                if (changed) {
                    first = @min(first, c);
                    last = c + 1;
                }
            }
            if (first >= last) continue;
            try self.buf.appendSlice(gpa, "\x1b[");
            try self.appendNum(r + 1);
            try self.buf.append(gpa, ';');
            try self.appendNum(first + 1);
            try self.buf.append(gpa, 'H');
            for (first..last) |c| { // one run per row: first to last change
                const i = row + c;
                if (last_fg == null or !std.mem.eql(u8, &last_fg.?, &cells.fg[i])) {
                    try self.appendColour("\x1b[38;2;", cells.fg[i]);
                    last_fg = cells.fg[i];
                }
                if (last_bg == null or !std.mem.eql(u8, &last_bg.?, &cells.bg[i])) {
                    try self.appendColour("\x1b[48;2;", cells.bg[i]);
                    last_bg = cells.bg[i];
                }
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cells.ch[i], &utf8) catch unreachable; // always a valid scalar
                try self.buf.appendSlice(gpa, utf8[0..n]);
            }
        }
        try self.buf.appendSlice(gpa, "\x1b[0m\x1b[?2026l");

        if (self.prev == null) self.prev = try .init(gpa, cells.cols, cells.rows);
        self.prev.?.copyFrom(cells);
        return self.buf.items;
    }
};

pub const cell_w = 8;
pub const cell_h = 16;

/// A cell frame as a binary PPM (P6), each cell 8x16 pixels. Half-block cells
/// are exact; a glyph cell is its bg with a centred fg square whose side grows
/// with the glyph's ramp index (0 = none, 9 = full cell).
pub fn toPpm(gpa: Allocator, cells: Cells) Allocator.Error![]u8 {
    const w = cells.cols * cell_w;
    const h = cells.rows * cell_h;
    var head_buf: [48]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "P6\n{d} {d}\n255\n", .{ w, h }) catch unreachable; // 48 bytes is plenty
    const out = try gpa.alloc(u8, head.len + w * h * 3);
    @memcpy(out[0..head.len], head);
    const pix = out[head.len..];
    for (0..cells.rows) |r| {
        for (0..cells.cols) |c| {
            const i = r * cells.cols + c;
            const code = cells.ch[i];
            const idx = std.mem.indexOfScalar(u8, ramp, @intCast(@min(code, 255))) orelse 0;
            const side = if (code == half) 0 else idx * cell_w / (ramp.len - 1);
            const x0 = (cell_w - side) / 2;
            const y0 = (cell_h - side) / 2;
            for (0..cell_h) |py| {
                for (0..cell_w) |px| {
                    const colour = if (code == half)
                        (if (py < cell_h / 2) cells.fg[i] else cells.bg[i])
                    else if (px >= x0 and px < x0 + side and py >= y0 and py < y0 + side)
                        cells.fg[i]
                    else
                        cells.bg[i];
                    @memcpy(pix[((r * cell_h + py) * w + c * cell_w + px) * 3 ..][0..3], &colour);
                }
            }
        }
    }
    return out;
}

fn testCells(gpa: Allocator, cols: usize, rows: usize) !Cells {
    const c = try Cells.init(gpa, cols, rows);
    @memset(c.ch, half);
    @memset(c.fg, .{ 0, 0, 0 });
    @memset(c.bg, .{ 0, 0, 0 });
    return c;
}

test "emitter only redraws changes" {
    const gpa = std.testing.allocator;
    var em = Emitter.init(gpa);
    defer em.deinit();
    var c = try testCells(gpa, 3, 2);
    defer c.deinit(gpa);

    const full = try em.frame(c);
    try std.testing.expect(std.mem.indexOf(u8, full, "\x1b[2J") != null);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[0m\x1b[?2026l", try em.frame(c));

    c.fg[1 * 3 + 2] = .{ 255, 255, 255 };
    const diff = try em.frame(c);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\x1b[2;3H") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, diff, "H"));
    try std.testing.expect(std.mem.indexOf(u8, diff, "\x1b[2J") == null);
}

test "emitter reset and size change force a full redraw" {
    const gpa = std.testing.allocator;
    var em = Emitter.init(gpa);
    defer em.deinit();
    var a = try testCells(gpa, 3, 2);
    defer a.deinit(gpa);
    var b = try testCells(gpa, 4, 2);
    defer b.deinit(gpa);
    _ = try em.frame(a);
    em.reset();
    try std.testing.expect(std.mem.indexOf(u8, try em.frame(a), "\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, try em.frame(b), "\x1b[2J") != null);
}

test "toCells makes half blocks and glyphs" {
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa, 2, 4);
    defer f.deinit(gpa);
    for (0..8) |i| f.pix[i * 3 ..][0..3].* = .{ 100, 120, 140 };
    f.pix[0..3].* = .{ 10, 20, 30 };
    f.mask[1] = 1; // pixel (row 0, col 1) -> cell (0, 1)
    f.mask[5] = 1; // pixel (row 2, col 1) -> cell (1, 1)
    var cells = try Cells.init(gpa, 2, 2);
    defer cells.deinit(gpa);
    toCells(&f, &cells);
    try std.testing.expectEqual(half, cells.ch[0]);
    try std.testing.expectEqual(@as(Rgb, .{ 10, 20, 30 }), cells.fg[0]);
    try std.testing.expectEqual(half, cells.ch[2]);
    for ([_]usize{ 1, 3 }) |i| {
        try std.testing.expect(cells.ch[i] != half);
        try std.testing.expect(std.mem.indexOfScalar(u8, ramp, @intCast(cells.ch[i])) != null);
    }
}

test "a dark masked pixel gives a space and ink is brightened" {
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa, 1, 2);
    defer f.deinit(gpa);
    f.mask[0] = 1;
    var cells = try Cells.init(gpa, 1, 1);
    defer cells.deinit(gpa);
    f.pix[0..3].* = .{ 5, 5, 5 };
    toCells(&f, &cells);
    try std.testing.expectEqual(@as(u21, ' '), cells.ch[0]);
    f.pix[0..3].* = .{ 100, 50, 25 };
    toCells(&f, &cells);
    try std.testing.expect(cells.fg[0][0] > 200);
}

test "ppm has the header and the right size" {
    const gpa = std.testing.allocator;
    var c = try testCells(gpa, 3, 2);
    defer c.deinit(gpa);
    c.fg[0] = .{ 9, 8, 7 };
    c.bg[0] = .{ 1, 2, 3 };
    const ppm = try toPpm(gpa, c);
    defer gpa.free(ppm);
    const head = "P6\n24 32\n255\n";
    try std.testing.expect(std.mem.startsWith(u8, ppm, head));
    try std.testing.expectEqual(head.len + 24 * 32 * 3, ppm.len);
    try std.testing.expectEqual(@as(u8, 9), ppm[head.len]); // top half is fg
    try std.testing.expectEqual(@as(u8, 3), ppm[head.len + (9 * 24) * 3 + 2]); // bottom half is bg
}
