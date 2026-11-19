//! The show: grow -> live -> burn -> black, then again with the next palette.

const std = @import("std");
const Allocator = std.mem.Allocator;
const burn = @import("burn.zig");
const palettes = @import("palettes.zig");
const raster = @import("raster.zig");
const rng = @import("rng.zig");
const scene_mod = @import("scene.zig");

const Frame = raster.Frame;

pub const Phase = enum { grow, live, burn, black };
const black_t = 1.2;
const scene_seed = 20261118;

const Fx = union(enum) {
    none,
    grow: burn.Grow,
    burn: burn.Burn,

    fn deinit(self: *Fx) void {
        switch (self.*) {
            .none => {},
            inline else => |*fx| fx.deinit(),
        }
        self.* = .none;
    }
};

pub const Options = struct {
    live: f32 = 24,
    burn: f32 = 9,
    /// Index into `palettes.names`, or null to rotate.
    palette: ?usize = null,
    seed: u64 = 0,
};

pub const Show = struct {
    gpa: Allocator,
    w: usize,
    h: usize,
    opts: Options,
    prng: rng.Prng,
    scene: scene_mod.Scene,
    frame: Frame,
    cycle: usize = 0,
    /// Scene clock: the scene keeps swaying through every phase.
    time: f64 = 0,
    phase: Phase = .grow,
    t0: f64 = 0,
    fx: Fx = .none,

    pub fn init(gpa: Allocator, w: usize, h: usize, opts: Options) !Show {
        var scene = try scene_mod.Scene.init(gpa, w, h, scene_seed);
        errdefer scene.deinit();
        var frame = try Frame.init(gpa, w, h);
        errdefer frame.deinit(gpa);
        var self: Show = .{
            .gpa = gpa,
            .w = w,
            .h = h,
            .opts = opts,
            .prng = .init(opts.seed),
            .scene = scene,
            .frame = frame,
        };
        errdefer self.fx.deinit();
        try self.startCycle();
        return self;
    }

    pub fn deinit(self: *Show) void {
        self.fx.deinit();
        self.frame.deinit(self.gpa);
        self.scene.deinit();
        self.* = undefined;
    }

    fn startCycle(self: *Show) !void {
        self.scene.setPalette(self.opts.palette orelse self.cycle % palettes.names.len);
        self.cycle += 1;
        try self.enter(.grow);
    }

    fn enter(self: *Show, phase: Phase) !void {
        self.fx.deinit();
        self.phase = phase;
        self.t0 = self.time;
        const r = self.prng.random();
        self.fx = switch (phase) {
            .grow => .{ .grow = try .init(self.gpa, self.w, self.h, r, 4.0) },
            .burn => .{ .burn = try .init(self.gpa, self.w, self.h, r, self.opts.burn) },
            else => .none,
        };
    }

    /// Fit to a new pixel size. Grow and burn hold per-pixel state, so they restart as grow.
    pub fn resize(self: *Show, w: usize, h: usize) !void {
        const frame = try Frame.init(self.gpa, w, h);
        self.frame.deinit(self.gpa);
        self.frame = frame;
        self.w = w;
        self.h = h;
        try self.scene.resize(w, h);
        if (self.phase == .grow or self.phase == .burn) {
            try self.enter(.grow);
        } else {
            self.fx.deinit();
        }
    }

    /// Advance dt seconds; returns the image and glyph mask (valid until the next call).
    pub fn step(self: *Show, dt: f32) !*const Frame {
        self.time += dt;
        const t: f32 = @floatCast(self.time - self.t0);
        const r = self.prng.random();
        self.scene.render(self.time, dt, &self.frame);
        switch (self.phase) {
            .grow => {
                self.fx.grow.apply(&self.frame, t);
                if (t > self.fx.grow.end) try self.enter(.live);
            },
            .live => if (t > self.opts.live) try self.enter(.burn),
            .burn => {
                try self.fx.burn.apply(&self.frame, t, r);
                if (self.fx.burn.done()) try self.enter(.black);
            },
            .black => {
                self.frame.clear();
                if (t > black_t) try self.startCycle();
            },
        }
        return &self.frame;
    }

    /// Run from the start until `at` seconds into `phase` (for stills and tests).
    pub fn seek(self: *Show, phase: Phase, at: f32, fps: f32) !*const Frame {
        while (true) {
            const frame = try self.step(1.0 / fps);
            const here = @backingInt(self.phase);
            const target = @backingInt(phase);
            if (here > target or (here == target and self.time - self.t0 >= at)) return frame;
        }
    }
};

fn allZero(f: *const Frame) bool {
    return std.mem.allEqual(u8, f.pix, 0);
}

test "cycle visits every phase and the palette rotates" {
    var show = try Show.init(std.testing.allocator, 80, 48, .{ .live = 0.5, .burn = 1.0 });
    defer show.deinit();
    const first = show.scene.palette.get(.s1);
    var seen = std.EnumSet(Phase).empty;
    var steps: usize = 0;
    while (show.cycle < 2) : (steps += 1) {
        const f = try show.step(1.0 / 20.0);
        try std.testing.expectEqual(@as(usize, 80 * 48 * 3), f.pix.len);
        seen.insert(show.phase);
        try std.testing.expect(steps < 20 * 60);
    }
    try std.testing.expectEqual(@as(usize, 4), seen.count());
    try std.testing.expect(!std.mem.eql(u8, &first, &show.scene.palette.get(.s1)));
}

test "a live frame has sun, bamboo mask and picture" {
    var show = try Show.init(std.testing.allocator, 120, 70, .{});
    defer show.deinit();
    const f = try show.seek(.live, 1.0, 20);
    try std.testing.expect(!allZero(f));
    try std.testing.expect(std.mem.indexOfScalar(u8, f.mask, 1) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, f.mask, 0) != null);
}

test "burn ends black" {
    var show = try Show.init(std.testing.allocator, 60, 40, .{ .live = 0.1, .burn = 0.5 });
    defer show.deinit();
    const f = try show.seek(.burn, 1e9, 20); // runs until the phase after burn
    try std.testing.expectEqual(Phase.black, show.phase);
    try std.testing.expect(allZero(f));
}

test "resize during burn restarts grow" {
    var show = try Show.init(std.testing.allocator, 60, 40, .{ .live = 0.1, .burn = 2 });
    defer show.deinit();
    _ = try show.seek(.burn, 0.2, 20);
    try show.resize(30, 20);
    try std.testing.expectEqual(Phase.grow, show.phase);
    const f = try show.step(0.05);
    try std.testing.expectEqual(@as(usize, 30), f.w);
    try std.testing.expectEqual(@as(usize, 20), f.h);
}

test "resize to tiny and back keeps running" {
    var show = try Show.init(std.testing.allocator, 80, 48, .{});
    defer show.deinit();
    _ = try show.step(0.05);
    try show.resize(10, 8);
    _ = try show.step(0.05);
    try show.resize(1, 2);
    _ = try show.step(0.05);
    try show.resize(80, 48);
    _ = try show.step(0.05);
}
