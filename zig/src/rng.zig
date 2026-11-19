//! Small helpers over `std.Random` for the draws this program makes.
//!
//! `Random.float` is exact over the whole exponent range, which is slow for
//! per-pixel noise; a 24-bit uniform is all the effects need.

const std = @import("std");

pub const Prng = std.Random.DefaultPrng;

/// Uniform in [0, 1).
pub fn uni(r: std.Random) f32 {
    return @as(f32, @floatFromInt(r.int(u32) >> 8)) * (1.0 / 16777216.0);
}

/// Uniform in [a, b).
pub fn range(r: std.Random, a: f32, b: f32) f32 {
    return a + (b - a) * uni(r);
}

/// Normal with the given mean and standard deviation.
pub fn normal(r: std.Random, mean: f32, sd: f32) f32 {
    return mean + sd * r.floatNorm(f32);
}

test "uni stays in [0, 1) and range respects its bounds" {
    var prng = Prng.init(1);
    const r = prng.random();
    for (0..1000) |_| {
        const u = uni(r);
        try std.testing.expect(u >= 0 and u < 1);
        const v = range(r, -3, 5);
        try std.testing.expect(v >= -3 and v < 5);
    }
}
