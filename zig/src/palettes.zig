//! Colour palettes, taken from the Sakura & Bamboo artifact.
//!
//! Each palette changes the sun's seven bands and the ridge line; every other
//! colour is shared.

const std = @import("std");

pub const Rgb = [3]u8;

/// Colour keys a shape can refer to. `s1`..`s7` are the sun bands.
pub const Key = enum {
    culm,
    node,
    bark,
    leaf_a,
    leaf_a_hi,
    leaf_b,
    leaf_b_hi,
    pink,
    pink_hi,
    pink_dk,
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    line,
};

pub const Palette = std.EnumArray(Key, Rgb);

const Sun = struct { name: []const u8, bands: [7][]const u8, line: []const u8 };

const suns = [_]Sun{
    .{ .name = "ember", .bands = .{ "#9e1b1b", "#bf3418", "#d4501a", "#e26a24", "#ea8640", "#ee9f66", "#eeb0a0" }, .line = "#f3e9dd" },
    .{ .name = "moon", .bands = .{ "#e9f0f6", "#d3e0ec", "#bccfe1", "#a5bdd5", "#8da9c6", "#7694b5", "#5f7fa3" }, .line = "#e6edf3" },
    .{ .name = "dusk", .bands = .{ "#3c0f22", "#4d152b", "#5e1b33", "#70223a", "#822a42", "#94344b", "#a63f55" }, .line = "#d8c8cf" },
};

pub const names: [suns.len][]const u8 = blk: {
    var n: [suns.len][]const u8 = undefined;
    for (suns, 0..) |s, i| n[i] = s.name;
    break :blk n;
};

fn rgb(comptime hex: []const u8) Rgb {
    const h = if (hex[0] == '#') hex[1..] else hex;
    return .{
        std.fmt.parseInt(u8, h[0..2], 16) catch unreachable,
        std.fmt.parseInt(u8, h[2..4], 16) catch unreachable,
        std.fmt.parseInt(u8, h[4..6], 16) catch unreachable,
    };
}

const common = [_]struct { Key, []const u8 }{
    .{ .culm, "#d9c35c" },      .{ .node, "#9b8433" },      .{ .bark, "#8a5a48" },
    .{ .leaf_a, "#2c7a3a" },    .{ .leaf_a_hi, "#7ed06c" }, .{ .leaf_b, "#3f9142" },
    .{ .leaf_b_hi, "#b0e17a" }, .{ .pink, "#f4a9c4" },      .{ .pink_hi, "#fde6ee" },
    .{ .pink_dk, "#c43a68" },
};

/// Palette number `index` (see `names`) as a key -> colour table.
pub fn get(index: usize) Palette {
    // Evaluated at comptime for all palettes, looked up at run time.
    const all = comptime blk: {
        @setEvalBranchQuota(20_000);
        var out: [suns.len]Palette = undefined;
        for (suns, 0..) |s, i| {
            var p = Palette.initUndefined();
            for (common) |c| p.set(c[0], rgb(c[1]));
            const bands = [_]Key{ .s1, .s2, .s3, .s4, .s5, .s6, .s7 };
            for (bands, s.bands) |k, hex| p.set(k, rgb(hex));
            p.set(.line, rgb(s.line));
            out[i] = p;
        }
        break :blk out;
    };
    return all[index];
}

/// Index of the palette called `name`, or null.
pub fn indexOf(name: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

test "every palette defines every key and they differ only in sun and line" {
    const a = get(0);
    const b = get(1);
    try std.testing.expectEqual(@as(Rgb, .{ 0x9e, 0x1b, 0x1b }), a.get(.s1));
    try std.testing.expectEqual(a.get(.pink), b.get(.pink));
    try std.testing.expect(!std.mem.eql(u8, &a.get(.s1), &b.get(.s1)));
    try std.testing.expectEqual(@as(?usize, 2), indexOf("dusk"));
    try std.testing.expectEqual(@as(?usize, null), indexOf("nope"));
}
