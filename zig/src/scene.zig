//! Sakura & Bamboo, drawn into a low-resolution pixel buffer.
//!
//! The geometry lives in a 1600x900 "virtual" space. It is built once as a
//! tree of sway nodes, each holding shapes. Every frame the tree is evaluated
//! into affine matrices, all points are mapped to pixels, and the shapes are
//! drawn without antialiasing so the result stays crisp.
//!
//! Alongside the colour image the scene draws a glyph mask: pixels of bamboo
//! (culm, nodes, leaves) that the renderer turns into ASCII glyphs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const palettes = @import("palettes.zig");
const raster = @import("raster.zig");
const rng = @import("rng.zig");

const Key = palettes.Key;
const Pt = raster.Pt;
const Frame = raster.Frame;
const Brush = raster.Brush;

pub const VW = 1600;
pub const VH = 900;
const DEG: f32 = std.math.pi / 180.0;

const BOOST = 1.35; // leaves and blossoms drawn larger than the SVG's
const BAMBOO_SWAY = 1.6; // bamboo sways more than the blossom branch

const sun_c = Pt{ 800, 450 };
const sun_r = 250.0;
const sun_bands = [_]struct { top: f32, key: Key }{
    .{ .top = 200, .key = .s1 }, .{ .top = 350, .key = .s2 }, .{ .top = 420, .key = .s3 },
    .{ .top = 480, .key = .s4 }, .{ .top = 535, .key = .s5 }, .{ .top = 585, .key = .s6 },
    .{ .top = 640, .key = .s7 },
};
const halo_r0 = 236.0;
const halo_r1 = 430.0; // ordered-dither glow ring around the sun

const ridges = [_][]const Pt{
    &.{ .{ 330, 770 }, .{ 450, 700 }, .{ 525, 742 }, .{ 640, 610 }, .{ 744, 750 } },
    &.{ .{ 580, 790 }, .{ 710, 700 }, .{ 780, 748 }, .{ 880, 655 }, .{ 1000, 770 }, .{ 1060, 742 }, .{ 1190, 800 } },
    &.{ .{ 240, 810 }, .{ 370, 745 }, .{ 460, 800 }, .{ 560, 760 }, .{ 660, 815 } },
};

const bayer4 = [4][4]f32{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

const petal = [_]Pt{
    .{ 0, 0 },   .{ -7, -4 }, .{ -11, -12 }, .{ -9, -20 }, .{ -4, -23 },
    .{ 0, -20 }, .{ 4, -23 }, .{ 9, -20 },   .{ 11, -12 }, .{ 7, -4 },
};
const petal_tip = [_]Pt{ .{ -5, -16 }, .{ 0, -14 }, .{ 5, -16 }, .{ 3, -22 }, .{ 0, -20 }, .{ -3, -22 } };

/// Leaf (base at origin, tip at (74, 0)): a dark body and a light tip.
const Leaf = struct { body: [12]Pt, tip: [8]Pt };
const leaf_outline: Leaf = blk: {
    @setEvalBranchQuota(10_000);
    const Edge = struct {
        fn make(comptime n: usize, sign: f32, t0: f32, t1: f32) [n + 1]Pt {
            var pts: [n + 1]Pt = undefined;
            for (0..n + 1) |i| {
                const t = t0 + (t1 - t0) * @as(f32, @floatFromInt(i)) / n;
                const u = 1 - t;
                pts[i] = .{ 2 * u * t * 24 + t * t * 74, sign * 2 * u * t * 11 };
            }
            return pts;
        }
    };
    break :blk .{
        .body = Edge.make(5, -1, 0, 1) ++ Edge.make(5, 1, 1, 0),
        .tip = Edge.make(3, -1, 0.55, 1) ++ Edge.make(3, 1, 1, 0.55),
    };
};

/// A sway node rotates its subtree about `pivot` by amp*sin(pi*t/dur + phase).
const Node = struct { parent: ?u16, pivot: Pt, amp: f32, dur: f32, phase: f32 };

const Kind = enum { poly, stem, line, dot };

/// `stem` is a polyline whose width tapers w0 -> w1 (virtual units).
const Shape = struct { kind: Kind, start: u32, end: u32, colour: Key, w0: f32 = 0, w1: f32 = 0 };

fn isGlyph(k: Key) bool {
    return switch (k) {
        .culm, .node, .leaf_a, .leaf_b, .leaf_a_hi, .leaf_b_hi => true,
        else => false,
    };
}

fn bez2(p0: Pt, p1: Pt, p2: Pt, t: f32) Pt {
    const u = 1 - t;
    return .{
        u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
        u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
    };
}

fn bez3(p0: Pt, p1: Pt, p2: Pt, p3: Pt, t: f32) Pt {
    const u = 1 - t;
    const a = u * u * u;
    const b = 3 * u * u * t;
    const c = 3 * u * t * t;
    const d = t * t * t;
    return .{
        a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
        a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1],
    };
}

/// n+1 points of a quadratic Bezier over t in [0, 1].
fn sampleBez2(comptime n: usize, p0: Pt, p1: Pt, p2: Pt) [n + 1]Pt {
    var out: [n + 1]Pt = undefined;
    for (&out, 0..) |*p, i| p.* = bez2(p0, p1, p2, @as(f32, @floatFromInt(i)) / n);
    return out;
}

fn sampleBez3(comptime n: usize, p0: Pt, p1: Pt, p2: Pt, p3: Pt) [n + 1]Pt {
    var out: [n + 1]Pt = undefined;
    for (&out, 0..) |*p, i| p.* = bez3(p0, p1, p2, p3, @as(f32, @floatFromInt(i)) / n);
    return out;
}

/// Tangent direction of a sampled curve at index i.
fn angleAt(pts: []const Pt, i: usize) f32 {
    const a = pts[i -| 1];
    const b = pts[@min(pts.len - 1, i + 1)];
    return std.math.atan2(b[1] - a[1], b[0] - a[0]);
}

fn transform(comptime n: usize, pts: [n]Pt, rot: f32, scale: f32, tx: f32, ty: f32) [n]Pt {
    const c = @cos(rot) * scale;
    const s = @sin(rot) * scale;
    var out: [n]Pt = undefined;
    for (&out, pts) |*o, p| o.* = .{ c * p[0] - s * p[1] + tx, s * p[0] + c * p[1] + ty };
    return out;
}

fn roundIndex(v: f32) usize {
    return @intFromFloat(@round(v));
}

/// Builds the scene tree. Random draws happen in the same order as the
/// Python builders, one local per draw so evaluation order never matters.
const Builder = struct {
    gpa: Allocator,
    r: std.Random,
    sway_k: f32 = 1.0,
    nodes: std.ArrayList(Node) = .empty,
    shapes: std.ArrayList(Shape) = .empty,
    pts: std.ArrayList(Pt) = .empty,
    pt_node: std.ArrayList(u16) = .empty,
    spots: std.ArrayList(Pt) = .empty,

    fn deinit(self: *Builder) void {
        self.nodes.deinit(self.gpa);
        self.shapes.deinit(self.gpa);
        self.pts.deinit(self.gpa);
        self.pt_node.deinit(self.gpa);
        self.spots.deinit(self.gpa);
    }

    fn rr(self: *Builder, a: f32, b: f32) f32 {
        return rng.range(self.r, a, b);
    }

    fn node(self: *Builder, parent: ?u16, pivot: Pt, amp: f32, dur: f32) !u16 {
        const phase = rng.uni(self.r) * std.math.tau;
        try self.nodes.append(self.gpa, .{
            .parent = parent,
            .pivot = pivot,
            .amp = amp * self.sway_k * DEG,
            .dur = dur,
            .phase = phase,
        });
        return @intCast(self.nodes.items.len - 1);
    }

    fn shape(self: *Builder, n: u16, kind: Kind, pts: []const Pt, colour: Key, w0: f32, w1: f32) !void {
        const start: u32 = @intCast(self.pts.items.len);
        try self.pts.appendSlice(self.gpa, pts);
        try self.pt_node.appendNTimes(self.gpa, n, pts.len);
        try self.shapes.append(self.gpa, .{
            .kind = kind,
            .start = start,
            .end = @intCast(self.pts.items.len),
            .colour = colour,
            .w0 = w0,
            .w1 = w1,
        });
    }

    fn leaf(self: *Builder, parent: u16, q: Pt, ang_in: f32, s: f32) !void {
        const ang = std.math.atan2(@sin(ang_in) + 0.35, @cos(ang_in)); // leaves droop a little
        const amp = self.rr(2.5, 5.5);
        const dur = self.rr(3.5, 6.5);
        const n = try self.node(parent, q, amp, dur);
        const colour: Key = if (rng.uni(self.r) < 0.5) .leaf_a else .leaf_b;
        const body = transform(12, leaf_outline.body, ang, s * BOOST, q[0], q[1]);
        const tip = transform(8, leaf_outline.tip, ang, s * BOOST, q[0], q[1]);
        try self.shape(n, .poly, &body, colour, 0, 0);
        try self.shape(n, .poly, &tip, if (colour == .leaf_a) .leaf_a_hi else .leaf_b_hi, 0, 0);
    }

    fn branch(self: *Builder, parent: u16, p: Pt, ang: f32, length: f32, s: f32) !void {
        const end = Pt{ p[0] + @cos(ang) * length, p[1] + @sin(ang) * length };
        const jitter = self.rr(-6, 6);
        const ctrl = Pt{ (p[0] + end[0]) / 2, (p[1] + end[1]) / 2 + length * 0.12 + jitter };
        const pts = sampleBez2(6, p, ctrl, end);
        const amp = self.rr(1.4, 2.6);
        const dur = self.rr(8, 12);
        const n = try self.node(parent, p, amp, dur);
        try self.shape(n, .stem, &pts, .culm, 2.8 * s, 1.1 * s);
        const along = [_]struct { f32, f32 }{ .{ 0.35, 1 }, .{ 0.6, -1 }, .{ 0.82, 1 } };
        for (along) |a| {
            const i = roundIndex(a[0] * 6);
            const turn = a[1] * self.rr(28, 50) * DEG;
            const size = s * self.rr(0.8, 1.15);
            try self.leaf(n, pts[i], angleAt(&pts, i) + turn, size);
        }
        const th = angleAt(&pts, 6);
        for ([_]f32{ -38, 0, 36 }) |a| {
            const turn = (a + self.rr(-6, 6)) * DEG;
            const size = s * self.rr(0.9, 1.25);
            try self.leaf(n, end, th + turn, size);
        }
    }

    fn bamboo(self: *Builder, p0: Pt, p1: Pt, p2: Pt, w0: f32, w1: f32, amp: f32, dur: f32, scale: f32) !void {
        const N = 48;
        const n = try self.node(null, p0, amp, dur);
        const pts = sampleBez2(N, p0, p1, p2);
        try self.shape(n, .stem, &pts, .culm, w0, w1);
        var side: f32 = 1;
        var t: f32 = 0.05;
        while (t < 0.97) : (t += 0.075) { // nodes up the culm, branches above 30%
            const i = roundIndex(t * N);
            const p = pts[i];
            const th = angleAt(&pts, i);
            const k = (w0 + (w1 - w0) * t) / 2 + 1.4;
            const nx = -@sin(th) * k;
            const ny = @cos(th) * k;
            try self.shape(n, .line, &.{ .{ p[0] + nx, p[1] + ny }, .{ p[0] - nx, p[1] - ny } }, .node, 0, 0);
            if (t > 0.3 and rng.uni(self.r) < 0.85) {
                const turn = side * self.rr(40, 64) * DEG;
                const len = self.rr(70, 130) * scale * (1.15 - 0.6 * t);
                try self.branch(n, p, th + turn, len, scale);
                side = -side;
            }
        }
        const th = angleAt(&pts, N);
        for ([_]f32{ -30, 0, 28 }) |a| {
            const turn = (a + self.rr(-5, 5)) * DEG;
            const size = scale * self.rr(1.0, 1.3);
            try self.leaf(n, pts[N], th + turn, size);
        }
    }

    fn blossom(self: *Builder, parent: u16, x: f32, y: f32, size: f32) !void {
        const amp = self.rr(2, 5);
        const dur = self.rr(5, 8);
        const n = try self.node(parent, .{ x, y }, amp, dur);
        const rot0 = self.rr(0, 360);
        const s = size * BOOST * 1.1;
        for (0..5) |k| {
            const rot = (rot0 + 72 * @as(f32, @floatFromInt(k))) * DEG;
            try self.shape(n, .poly, &transform(petal.len, petal, rot, s, x, y), .pink, 0, 0);
        }
        for (0..5) |k| {
            const rot = (rot0 + 72 * @as(f32, @floatFromInt(k))) * DEG;
            try self.shape(n, .poly, &transform(petal_tip.len, petal_tip, rot, s, x, y), .pink_hi, 0, 0);
        }
        try self.shape(n, .dot, &.{.{ x, y }}, .pink_dk, 0, 0);
        try self.spots.append(self.gpa, .{ x, y });
    }

    fn twig(self: *Builder, parent: u16, p0: Pt, ang: f32, length: f32, w: f32, level: u2) !void {
        const end = Pt{ p0[0] + @cos(ang) * length, p0[1] + @sin(ang) * length };
        const jitter = self.rr(-10, 10);
        const ctrl = Pt{ (p0[0] + end[0]) / 2 + jitter, (p0[1] + end[1]) / 2 + length * 0.18 };
        const pts = sampleBez2(6, p0, ctrl, end);
        const amp = self.rr(1.2, 2.4);
        const dur = self.rr(8, 12);
        const n = try self.node(parent, p0, amp, dur);
        try self.shape(n, .stem, &pts, .bark, w, w * 0.35);
        if (level == 0) {
            const count: usize = if (rng.uni(self.r) < 0.6) 2 else 1;
            for (0..count) |_| {
                const i = roundIndex(self.rr(0.35, 0.7) * 6);
                const side: f32 = if (rng.uni(self.r) < 0.5) -1 else 1;
                const turn = side * self.rr(30, 55) * DEG;
                const len = length * self.rr(0.4, 0.6);
                try self.twig(n, pts[i], angleAt(&pts, i) + turn, len, w * 0.6, 1);
            }
        }
        const blossoms: usize = if (level == 0) 3 else 2;
        for (0..blossoms) |k| { // first blossom at the tip, the rest along it
            const i = roundIndex((if (k == 0) 1.0 else self.rr(0.55, 0.95)) * 6);
            const j: f32 = if (k == 0) 0.3 else 1;
            const dx = self.rr(-8, 8) * j;
            const dy = self.rr(-8, 8) * j;
            const size = self.rr(0.6, 1.0);
            try self.blossom(n, pts[i][0] + dx, pts[i][1] + dy, size);
        }
    }

    fn cherry(self: *Builder) !void {
        const p0 = Pt{ -80, 490 };
        const N = 28;
        const pts = sampleBez3(N, p0, .{ 110, 520 }, .{ 250, 330 }, .{ 620, 250 });
        const n = try self.node(null, p0, 0.6, 14);
        try self.shape(n, .stem, &pts, .bark, 15, 3.5);
        const ts = [_]f32{ 0.2, 0.32, 0.45, 0.58, 0.7, 0.8, 0.9 };
        for (ts, 0..) |t, i| {
            const idx = roundIndex(t * N);
            const side: f32 = if (i % 2 == 1) -1 else 1;
            const turn = side * self.rr(35, 60) * DEG;
            const len = self.rr(80, 140) * (1.1 - t * 0.5);
            try self.twig(n, pts[idx], angleAt(&pts, idx) + turn, len, 4.4 - t * 1.6, 0);
        }
        const turn = self.rr(-10, 10) * DEG;
        try self.twig(n, pts[N], angleAt(&pts, N) + turn, 70, 3, 0);
    }

    fn build(self: *Builder) !void {
        self.sway_k = BAMBOO_SWAY;
        try self.bamboo(.{ 1400, 980 }, .{ 1405, 620 }, .{ 1300, 230 }, 6.5, 2.8, 1.1, 11, 0.85);
        try self.bamboo(.{ 1250, 980 }, .{ 1215, 520 }, .{ 1035, 95 }, 9, 3.5, 0.9, 13, 1);
        self.sway_k = 1.0;
        try self.cherry();
    }
};

/// Affine (a, b, c, d, e, f): x' = a*x + c*y + e, y' = b*x + d*y + f.
const Mat = [6]f32;

const Petal = struct { x: f32, y: f32, depth: f32, vy: f32, phase: f32, flip: f32, flip_rate: f32, age: f32 };

/// Petals drifting on the wind, mostly shed from the blossoms. Virtual coords.
const FallingPetals = struct {
    const count = 48;

    prng: rng.Prng,
    petals: [count]Petal,

    fn init(spots: []const Pt, seed: u64) FallingPetals {
        var self: FallingPetals = .{ .prng = .init(seed), .petals = undefined };
        for (&self.petals) |*p| self.reset(p, spots, true);
        return self;
    }

    fn reset(self: *FallingPetals, p: *Petal, spots: []const Pt, initial: bool) void {
        const r = self.prng.random();
        p.depth = rng.range(r, 0.25, 1);
        if (initial) { // scattered and already faded in
            p.x = rng.range(r, -100, 1700);
            p.y = rng.range(r, -40, 940);
            p.age = 99;
        } else if (spots.len > 0 and rng.uni(r) < 0.6) { // shed from a blossom
            const spot = spots[r.uintLessThan(usize, spots.len)];
            p.x = spot[0] + rng.range(r, -10, 10);
            p.y = spot[1] + rng.range(r, -6, 10);
            p.age = 0;
        } else { // from above the screen
            p.x = rng.range(r, -120, 1500);
            p.y = -40;
            p.age = 0;
        }
        p.vy = 14 + p.depth * 34 + rng.range(r, 0, 8);
        p.phase = rng.range(r, 0, std.math.tau);
        p.flip = rng.range(r, 0, std.math.tau);
        p.flip_rate = rng.range(r, 0.8, 2.4);
    }

    fn step(self: *FallingPetals, spots: []const Pt, dt: f32, t: f32) void {
        const wind = 14 + 10 * @sin(t * 0.13) + 5 * @sin(t * 0.37);
        for (&self.petals) |*p| {
            p.x += (wind * (0.5 + p.depth * 0.7) + @sin(t * 0.7 + p.phase) * 16) * dt;
            p.y += (p.vy + @sin(t * 1.1 + p.phase * 2) * 6) * dt;
            p.flip += p.flip_rate * dt;
            p.age += dt;
            if (p.y > 950 or p.x > 1750) self.reset(p, spots, false);
        }
    }

    fn draw(self: *const FallingPetals, f: *Frame, palette: palettes.Palette, s: f32, ox: f32, oy: f32) void {
        for (self.petals) |p| {
            const x = p.x * s + ox;
            const y = p.y * s + oy;
            const fade = (0.35 + 0.65 * p.depth) * @min(1.0, p.age / 1.2);
            const base = palette.get(if (fade > 0.75) .pink_hi else .pink);
            const k = 0.45 + 0.55 * @min(1.0, fade * 1.2);
            var rgb: palettes.Rgb = undefined;
            for (&rgb, base) |*o, c| o.* = @intFromFloat(@as(f32, @floatFromInt(c)) * k);
            const brush: Brush = .{ .pix = f.pix, .w = f.w, .h = f.h, .rgb = rgb };
            const xi: i32 = @intFromFloat(@floor(x));
            const yi: i32 = @intFromFloat(@floor(y));
            brush.put(xi, yi);
            if (p.depth > 0.6 and @abs(@cos(p.flip)) > 0.5) brush.put(xi + 1, yi); // near petals are 1-2 px wide as they flip
        }
    }
};

pub const Scene = struct {
    gpa: Allocator,
    nodes: []Node,
    shapes: []Shape,
    /// Shape points in virtual coordinates, and the node each belongs to.
    pts: []Pt,
    pt_node: []u16,
    spots: []Pt,
    petals: FallingPetals,
    // Per-frame scratch.
    mats: []Mat,
    world: []Pt,
    // Size and palette dependent state.
    w: usize = 0,
    h: usize = 0,
    s: f32 = 1,
    ox: f32 = 0,
    oy: f32 = 0,
    palette: palettes.Palette,
    base: []u8 = &.{},
    base_ok: bool = false,

    pub fn init(gpa: Allocator, w: usize, h: usize, seed: u64) !Scene {
        var prng = rng.Prng.init(seed);
        var b: Builder = .{ .gpa = gpa, .r = prng.random() };
        defer b.deinit();
        try b.build();

        const nodes = try b.nodes.toOwnedSlice(gpa);
        errdefer gpa.free(nodes);
        const shapes = try b.shapes.toOwnedSlice(gpa);
        errdefer gpa.free(shapes);
        const pts = try b.pts.toOwnedSlice(gpa);
        errdefer gpa.free(pts);
        const pt_node = try b.pt_node.toOwnedSlice(gpa);
        errdefer gpa.free(pt_node);
        const spots = try b.spots.toOwnedSlice(gpa);
        errdefer gpa.free(spots);
        const mats = try gpa.alloc(Mat, nodes.len);
        errdefer gpa.free(mats);
        const world = try gpa.alloc(Pt, pts.len);
        errdefer gpa.free(world);

        var self: Scene = .{
            .gpa = gpa,
            .nodes = nodes,
            .shapes = shapes,
            .pts = pts,
            .pt_node = pt_node,
            .spots = spots,
            .petals = .init(spots, 7),
            .mats = mats,
            .world = world,
            .palette = palettes.get(0),
        };
        try self.resize(w, h);
        return self;
    }

    pub fn deinit(self: *Scene) void {
        const gpa = self.gpa;
        gpa.free(self.nodes);
        gpa.free(self.shapes);
        gpa.free(self.pts);
        gpa.free(self.pt_node);
        gpa.free(self.spots);
        gpa.free(self.mats);
        gpa.free(self.world);
        gpa.free(self.base);
        self.* = undefined;
    }

    /// Fit the virtual space to w x h pixels, covering it ("slice").
    pub fn resize(self: *Scene, w: usize, h: usize) Allocator.Error!void {
        const base = try self.gpa.alloc(u8, w * h * 3);
        self.gpa.free(self.base);
        self.base = base;
        self.w = w;
        self.h = h;
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        self.s = @max(fw / VW, fh / VH);
        self.ox = (fw - VW * self.s) / 2;
        self.oy = (fh - VH * self.s) / 2;
        self.base_ok = false;
    }

    pub fn setPalette(self: *Scene, index: usize) void {
        self.palette = palettes.get(index);
        self.base_ok = false;
    }

    /// Static backdrop: dithered halo, banded sun, ridges.
    fn makeBase(self: *Scene) void {
        const pal = self.palette;
        const halo_rgb = blk: {
            var c: palettes.Rgb = undefined;
            for (&c, pal.get(.s3)) |*o, v| o.* = @intFromFloat(@as(f32, @floatFromInt(v)) * 0.30);
            break :blk c;
        };
        @memset(self.base, 0);
        for (0..self.h) |iy| {
            const vy = (@as(f32, @floatFromInt(iy)) + 0.5 - self.oy) / self.s;
            for (0..self.w) |ix| {
                const vx = (@as(f32, @floatFromInt(ix)) + 0.5 - self.ox) / self.s;
                const r = std.math.hypot(vx - sun_c[0], vy - sun_c[1]);
                const out = self.base[(iy * self.w + ix) * 3 ..][0..3];
                const a = std.math.clamp(1 - (r - halo_r0) / (halo_r1 - halo_r0), 0, 1);
                const dither = (bayer4[iy % 4][ix % 4] + 0.5) / 16;
                if (r >= halo_r0 and r < halo_r1 and a > 0.15 and a > dither) out.* = halo_rgb;
                if (r < sun_r) {
                    for (sun_bands, 0..) |band, k| {
                        const bottom = if (k + 1 < sun_bands.len) sun_bands[k + 1].top else std.math.inf(f32);
                        if (vy >= band.top and vy < bottom) out.* = pal.get(band.key);
                    }
                }
            }
        }
        var buf: [16]Pt = undefined;
        for (ridges) |ridge| {
            for (ridge, buf[0..ridge.len]) |p, *o| o.* = .{ p[0] * self.s + self.ox, p[1] * self.s + self.oy };
            const pts = buf[0..ridge.len];
            const bottom: f32 = @floatFromInt(self.h);
            buf[ridge.len] = .{ pts[pts.len - 1][0], bottom };
            buf[ridge.len + 1] = .{ pts[0][0], bottom };
            const fill: Brush = .{ .pix = self.base, .w = self.w, .h = self.h, .rgb = .{ 0, 0, 0 } };
            raster.fillPoly(fill, buf[0 .. ridge.len + 2]);
            raster.polyline(.{ .pix = self.base, .w = self.w, .h = self.h, .rgb = pal.get(.line) }, pts);
        }
        self.base_ok = true;
    }

    /// All shape points in pixel coordinates at time t.
    fn evalWorld(self: *Scene, t: f64) void {
        const root: Mat = .{ self.s, 0, 0, self.s, self.ox, self.oy };
        for (self.nodes, self.mats) |n, *m| {
            const th: f32 = @floatCast(n.amp * @sin(std.math.pi * t / n.dur + n.phase));
            const c = @cos(th);
            const s = @sin(th);
            const px = n.pivot[0];
            const py = n.pivot[1];
            const e = px - c * px + s * py; // rotation about the pivot
            const f = py - s * px - c * py;
            const p = if (n.parent) |i| self.mats[i] else root;
            m.* = .{
                p[0] * c + p[2] * s,
                p[1] * c + p[3] * s,
                -p[0] * s + p[2] * c,
                -p[1] * s + p[3] * c,
                p[0] * e + p[2] * f + p[4],
                p[1] * e + p[3] * f + p[5],
            };
        }
        for (self.world, self.pts, self.pt_node) |*o, p, ni| {
            const m = self.mats[ni];
            o.* = .{ m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5] };
        }
    }

    /// The scene at time t, drawn into `f` (which must be w x h).
    pub fn render(self: *Scene, t: f64, dt: f32, f: *Frame) void {
        std.debug.assert(f.w == self.w and f.h == self.h);
        if (!self.base_ok) self.makeBase();
        @memcpy(f.pix, self.base);
        @memset(f.mask, 0);
        self.evalWorld(t);
        for (self.shapes) |sh| {
            const pts = self.world[sh.start..sh.end];
            // Non-glyph shapes write 0, erasing the mask they cover.
            const brush: Brush = .{
                .pix = f.pix,
                .mask = f.mask,
                .w = f.w,
                .h = f.h,
                .rgb = self.palette.get(sh.colour),
                .glyph = @intFromBool(isGlyph(sh.colour)),
            };
            switch (sh.kind) {
                .poly => raster.fillPoly(brush, pts),
                .stem => {
                    const n = pts.len - 1;
                    for (0..n) |i| {
                        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                        const w: i32 = @max(1, @as(i32, @intFromFloat(@round((sh.w0 + (sh.w1 - sh.w0) * frac) * self.s))));
                        raster.thickLine(brush, pts[i], pts[i + 1], w);
                    }
                },
                .line => raster.polyline(brush, pts),
                .dot => raster.polyline(brush, pts[0..1]),
            }
        }
        self.petals.step(self.spots, dt, @floatCast(t));
        self.petals.draw(f, self.palette, self.s, self.ox, self.oy);
    }
};

fn countMask(f: Frame) usize {
    var n: usize = 0;
    for (f.mask) |m| n += m;
    return n;
}

test "scene builds, renders a sun, bamboo mask and blossoms" {
    const gpa = std.testing.allocator;
    var sc = try Scene.init(gpa, 160, 90, 20261118);
    defer sc.deinit();
    var f = try Frame.init(gpa, 160, 90);
    defer f.deinit(gpa);
    sc.render(1.0, 0.04, &f);
    // Sun centre is banded sun colour, not black.
    const c = (45 * 160 + 80) * 3;
    try std.testing.expect(f.pix[c] != 0);
    try std.testing.expect(countMask(f) > 50);
    try std.testing.expect(countMask(f) < f.w * f.h / 2);
    try std.testing.expect(sc.spots.len > 10);
}

test "palette change repaints the sun and swaying moves the bamboo" {
    const gpa = std.testing.allocator;
    var sc = try Scene.init(gpa, 120, 68, 20261118);
    defer sc.deinit();
    var a = try Frame.init(gpa, 120, 68);
    defer a.deinit(gpa);
    var b = try Frame.init(gpa, 120, 68);
    defer b.deinit(gpa);
    sc.render(0, 0, &a);
    sc.render(4.0, 0, &b);
    try std.testing.expect(!std.mem.eql(u8, a.mask, b.mask));
    sc.setPalette(1);
    sc.render(0, 0, &b);
    try std.testing.expect(!std.mem.eql(u8, a.pix, b.pix));
}

test "tiny sizes and resizes do not crash or leak" {
    const gpa = std.testing.allocator;
    var sc = try Scene.init(gpa, 10, 8, 1);
    defer sc.deinit();
    var f = try Frame.init(gpa, 10, 8);
    defer f.deinit(gpa);
    sc.render(0.5, 0.04, &f);
    try sc.resize(3, 2);
    var g = try Frame.init(gpa, 3, 2);
    defer g.deinit(gpa);
    sc.render(0.5, 0.04, &g);
}
