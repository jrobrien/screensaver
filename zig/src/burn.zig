//! Burn-to-ash and its reverse, as per-pixel effects on the scene image.
//!
//! Burn: a fire front crawls out from a few ignition points. Each pixel goes
//!   heat glow -> flame -> char -> grey ash -> black,
//! while ash flakes and sparks lift off and drift upward.
//! Grow: the scene flashes in, spreading out from the centre.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster.zig");
const rng = @import("rng.zig");

const Frame = raster.Frame;
const Vec3 = @Vector(3, f32);

const flame_stops = [5]Vec3{
    .{ 255, 244, 190 }, .{ 255, 204, 70 }, .{ 240, 120, 24 }, .{ 178, 48, 12 }, .{ 80, 18, 8 },
};
const heat: Vec3 = .{ 255, 120, 30 };
const ember: Vec3 = .{ 190, 70, 16 };
const ash_tint: Vec3 = .{ 1.0, 0.97, 0.92 }; // applied to grey levels
const flash: Vec3 = .{ 255, 235, 200 };

const heat_t = 0.6; // seconds of glow before the front arrives
pub const flame_t = 0.75; // in flame
pub const char_t = 1.1; // smouldering
pub const ash_t = 1.6; // grey ash, then black

fn splat(v: f32) Vec3 {
    return @splat(v);
}

fn load(p: []const u8) Vec3 {
    return .{ @floatFromInt(p[0]), @floatFromInt(p[1]), @floatFromInt(p[2]) };
}

fn store(p: []u8, v: Vec3) void {
    inline for (0..3) |i| p[i] = @intFromFloat(std.math.clamp(v[i], 0, 255));
}

/// FLAME gradient at u in [0, 1].
fn flameAt(u_in: f32) Vec3 {
    const u = std.math.clamp(u_in, 0, 1) * (flame_stops.len - 1);
    const i: usize = @min(@as(usize, @intFromFloat(u)), flame_stops.len - 2);
    const f = u - @as(f32, @floatFromInt(i));
    return flame_stops[i] * splat(1 - f) + flame_stops[i + 1] * splat(f);
}

/// Adds amp * (noise - 0.5) to every element of `field` (h x w), where noise
/// is smooth value noise in [0, 1]: a random grid every `cell` pixels,
/// bilinearly interpolated.
fn addValueNoise(gpa: Allocator, r: std.Random, field: []f32, w: usize, h: usize, cell: usize, amp: f32) Allocator.Error!void {
    const gh = h / cell + 2;
    const gw = w / cell + 2;
    const grid = try gpa.alloc(f32, gh * gw);
    defer gpa.free(grid);
    for (grid) |*g| g.* = rng.uni(r);
    const step_y: f32 = if (h > 1) (@as(f32, @floatFromInt(gh)) - 1.001) / @as(f32, @floatFromInt(h - 1)) else 0;
    const step_x: f32 = if (w > 1) (@as(f32, @floatFromInt(gw)) - 1.001) / @as(f32, @floatFromInt(w - 1)) else 0;
    for (0..h) |y| {
        const ys = @as(f32, @floatFromInt(y)) * step_y;
        const y0: usize = @intFromFloat(ys);
        const fy = ys - @as(f32, @floatFromInt(y0));
        for (0..w) |x| {
            const xs = @as(f32, @floatFromInt(x)) * step_x;
            const x0: usize = @intFromFloat(xs);
            const fx = xs - @as(f32, @floatFromInt(x0));
            const top = grid[y0 * gw + x0] * (1 - fx) + grid[y0 * gw + x0 + 1] * fx;
            const bot = grid[(y0 + 1) * gw + x0] * (1 - fx) + grid[(y0 + 1) * gw + x0 + 1] * fx;
            field[y * w + x] += (top * (1 - fy) + bot * fy - 0.5) * amp;
        }
    }
}

const Flake = struct { x: f32, y: f32, vx: f32, vy: f32, age: f32, life: f32, spark: bool };

pub const Burn = struct {
    gpa: Allocator,
    w: usize,
    h: usize,
    /// Per pixel: when the fire front arrives, and a fixed grain for the ash.
    ignite: []f32,
    grain: []f32,
    end: f32,
    t_prev: f32 = 0,
    flakes: std.ArrayList(Flake) = .empty,

    pub fn init(gpa: Allocator, w: usize, h: usize, r: std.Random, duration: f32) Allocator.Error!Burn {
        const ignite = try gpa.alloc(f32, w * h);
        errdefer gpa.free(ignite);
        const grain = try gpa.alloc(f32, w * h);
        errdefer gpa.free(grain);

        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        @memset(ignite, std.math.inf(f32));
        // 2 or 3 ignition points, lower half of the screen.
        const points = r.intRangeAtMost(usize, 2, 3);
        for (0..points) |_| {
            const sx = rng.range(r, 0.1, 0.9) * fw;
            const sy = rng.range(r, 0.55, 1.0) * fh;
            for (0..h) |y| {
                for (0..w) |x| {
                    const d = std.math.hypot(@as(f32, @floatFromInt(x)) - sx, @as(f32, @floatFromInt(y)) - sy);
                    ignite[y * w + x] = @min(ignite[y * w + x], d);
                }
            }
        }
        const size = @max(fw, fh);
        try addValueNoise(gpa, r, ignite, w, h, 7, 0.22 * size); // ragged front
        try addValueNoise(gpa, r, ignite, w, h, 2, 0.04 * size);
        const lo = std.mem.min(f32, ignite);
        for (ignite) |*v| v.* -= lo;
        const hi = @max(std.mem.max(f32, ignite), 1e-6);
        for (ignite) |*v| v.* = v.* / hi * duration + rng.uni(r) * 0.25;
        for (grain) |*g| g.* = rng.uni(r);

        return .{
            .gpa = gpa,
            .w = w,
            .h = h,
            .ignite = ignite,
            .grain = grain,
            // Flakes need time to clear after the last pixel has burnt.
            .end = std.mem.max(f32, ignite) + flame_t + char_t + ash_t + 3.0,
        };
    }

    pub fn deinit(self: *Burn) void {
        self.gpa.free(self.ignite);
        self.gpa.free(self.grain);
        self.flakes.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn done(self: *const Burn) bool {
        return self.t_prev > self.end;
    }

    fn drawFlakes(self: *Burn, f: *Frame, dt: f32) void {
        var kept: usize = 0;
        for (self.flakes.items) |fl_in| {
            var fl = fl_in;
            fl.age += dt;
            fl.x += (fl.vx + @sin(fl.age * 3 + fl.y) * 3) * dt;
            fl.y += fl.vy * dt;
            if (fl.age >= fl.life or fl.y < -2) continue;
            self.flakes.items[kept] = fl;
            kept += 1;
            const xi: i32 = @intFromFloat(fl.x);
            const yi: i32 = @intFromFloat(fl.y);
            if (xi < 0 or yi < 0 or xi >= self.w or yi >= self.h) continue;
            const life = 1 - fl.age / fl.life;
            const colour: Vec3 = if (fl.spark)
                .{ 255 * life, 140 * life * life, 30 * life * life * life }
            else
                splat(150 * life) * ash_tint;
            const px = f.pix[(@as(usize, @intCast(yi)) * self.w + @as(usize, @intCast(xi))) * 3 ..][0..3];
            if (@reduce(.Add, colour) > @reduce(.Add, load(px))) store(px, colour);
        }
        self.flakes.shrinkRetainingCapacity(kept);
    }

    /// The burn at t seconds after ignition begins, applied to `f`.
    pub fn apply(self: *Burn, f: *Frame, t: f32, r: std.Random) Allocator.Error!void {
        const t0 = self.t_prev;
        const dt = t - t0;
        self.t_prev = t;
        const char_end = flame_t + char_t;
        for (self.ignite, self.grain, 0..) |ig, grain, i| {
            const age = t - ig;
            const px = f.pix[i * 3 ..][0..3];
            if (age < 0) {
                if (age > -heat_t) {
                    const k = splat((1 + age / heat_t) * 0.55);
                    store(px, load(px) * (splat(1) - k) + heat * k);
                }
            } else if (age < flame_t) {
                store(px, flameAt(age / flame_t * 0.9 + (rng.uni(r) - 0.5) * 0.5));
            } else if (age < char_end) {
                const c = (age - flame_t) / char_t;
                if (rng.uni(r) < 0.10 * (1 - c)) {
                    store(px, ember * splat(1 - c));
                } else {
                    store(px, load(px) * splat(0.22 * (1 - c)));
                }
            } else if (age < char_end + ash_t) {
                const grey = 112 * (1 - (age - char_end) / ash_t) * (0.65 + 0.35 * grain);
                store(px, splat(grey) * ash_tint);
            } else {
                @memset(px, 0);
            }
            // Flakes: ash where the char ends, sparks as the front passes.
            const x: f32 = @floatFromInt(i % self.w);
            const y: f32 = @floatFromInt(i / self.w);
            const ash_at = ig + char_end;
            if (ash_at > t0 and ash_at <= t and rng.uni(r) < 0.45) {
                try self.flakes.append(self.gpa, .{
                    .x = x,
                    .y = y,
                    .vx = rng.normal(r, 2.5, 3),
                    .vy = -rng.range(r, 2, 9),
                    .age = 0,
                    .life = rng.range(r, 1.5, 4.0),
                    .spark = false,
                });
            }
            if (ig > t0 and ig <= t and rng.uni(r) < 0.06) {
                try self.flakes.append(self.gpa, .{
                    .x = x,
                    .y = y,
                    .vx = rng.normal(r, 2, 4),
                    .vy = -rng.range(r, 6, 18),
                    .age = 0,
                    .life = rng.range(r, 0.6, 1.8),
                    .spark = true,
                });
            }
        }
        self.drawFlakes(f, dt);
    }
};

/// Flash-in reveal radiating from the centre.
pub const Grow = struct {
    const flash_t = 0.8;

    gpa: Allocator,
    reveal: []f32,
    end: f32,

    pub fn init(gpa: Allocator, w: usize, h: usize, r: std.Random, duration: f32) Allocator.Error!Grow {
        const reveal = try gpa.alloc(f32, w * h);
        const cx = @as(f32, @floatFromInt(w)) / 2;
        const cy = @as(f32, @floatFromInt(h)) / 2;
        var dmax: f32 = 0;
        for (0..h) |y| {
            for (0..w) |x| {
                const d = std.math.hypot(@as(f32, @floatFromInt(x)) - cx, @as(f32, @floatFromInt(y)) - cy);
                reveal[y * w + x] = d;
                dmax = @max(dmax, d);
            }
        }
        for (reveal) |*v| v.* = v.* / @max(dmax, 1e-6) * duration + rng.uni(r) * 0.9;
        return .{ .gpa = gpa, .reveal = reveal, .end = std.mem.max(f32, reveal) + flash_t };
    }

    pub fn deinit(self: *Grow) void {
        self.gpa.free(self.reveal);
        self.* = undefined;
    }

    pub fn apply(self: *const Grow, f: *Frame, t: f32) void {
        for (self.reveal, 0..) |rv, i| {
            const age = t - rv;
            const px = f.pix[i * 3 ..][0..3];
            if (age < 0) {
                @memset(px, 0);
            } else if (age < flash_t) {
                const u = 1 - age / flash_t;
                const k = splat(u * u);
                store(px, load(px) * (splat(1) - k) + flash * k);
            }
        }
    }
};

fn litFrame(gpa: Allocator, w: usize, h: usize) !Frame {
    const f = try Frame.init(gpa, w, h);
    @memset(f.pix, 200);
    return f;
}

fn anyLit(f: Frame) bool {
    for (f.pix) |v| if (v != 0) return true;
    return false;
}

test "burn takes a lit frame through flame to black and clears its flakes" {
    const gpa = std.testing.allocator;
    var prng = rng.Prng.init(3);
    const r = prng.random();
    var b = try Burn.init(gpa, 40, 30, r, 1.0);
    defer b.deinit();
    var f = try litFrame(gpa, 40, 30);
    defer f.deinit(gpa);

    var t: f32 = 0;
    var saw_orange = false;
    while (!b.done()) : (t += 0.05) {
        @memset(f.pix, 200);
        try b.apply(&f, t, r);
        for (0..40 * 30) |i| {
            if (f.pix[i * 3] > 200 and f.pix[i * 3 + 2] < 100) saw_orange = true;
        }
        try std.testing.expect(t < 60);
    }
    try std.testing.expect(saw_orange);
    @memset(f.pix, 200);
    try b.apply(&f, t + 1, r);
    try std.testing.expect(!anyLit(f));
}

test "grow starts black and ends untouched" {
    const gpa = std.testing.allocator;
    var prng = rng.Prng.init(4);
    const r = prng.random();
    var g = try Grow.init(gpa, 30, 20, r, 4.0);
    defer g.deinit();
    var f = try litFrame(gpa, 30, 20);
    defer f.deinit(gpa);
    g.apply(&f, 0);
    try std.testing.expectEqual(@as(u8, 0), f.pix[0]); // corner not revealed yet
    @memset(f.pix, 200);
    g.apply(&f, g.end + 0.01);
    for (f.pix) |v| try std.testing.expectEqual(@as(u8, 200), v);
}

test "value noise is bounded around zero" {
    const gpa = std.testing.allocator;
    var prng = rng.Prng.init(5);
    const field = try gpa.alloc(f32, 50 * 33);
    defer gpa.free(field);
    @memset(field, 0);
    try addValueNoise(gpa, prng.random(), field, 50, 33, 7, 2.0);
    for (field) |v| try std.testing.expect(@abs(v) <= 1.0);
}
