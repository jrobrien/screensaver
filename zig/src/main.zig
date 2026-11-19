//! Sakura & Bamboo terminal screensaver.
//!
//!     saver                         full screen in this terminal; any key quits
//!     saver --live 6 --burn 6       shorter cycle
//!     saver --still out.ppm --phase burn --at 4     headless still frame (PPM)
//!     saver --bench 600 --size 240x67               time the frame pipeline

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const palettes = @import("palettes.zig");
const render = @import("render.zig");
const show_mod = @import("show.zig");
const term = @import("term.zig");

comptime {
    _ = @import("raster.zig");
    _ = @import("rng.zig");
    _ = @import("scene.zig");
    _ = @import("burn.zig");
}

const usage =
    \\usage: saver [options]
    \\  --fps N            frames per second (24)
    \\  --live S           seconds of scene before the burn (24)
    \\  --burn S           seconds for the fire front to cross (9)
    \\  --palette NAME     ember|moon|dusk (default: rotate)
    \\  --max-seconds S    exit after this long (0 = forever)
    \\  --still FILE       write one frame as a PPM and exit (no terminal needed)
    \\  --phase P          grow|live|burn, for --still (live)
    \\  --at S             seconds into --phase, for --still (5)
    \\  --size COLSxROWS   for --still and --bench (200x56)
    \\  --bench N          time N frames of step + to_cells + emit and exit
    \\
;

const Args = struct {
    fps: f32 = 24,
    live: f32 = 24,
    burn: f32 = 9,
    palette: ?usize = null,
    max_seconds: f32 = 0,
    still: ?[]const u8 = null,
    phase: show_mod.Phase = .live,
    at: f32 = 5,
    cols: usize = 200,
    rows: usize = 56,
    bench: usize = 0,
};

const ParseError = error{ BadFlag, BadValue, MissingValue };

fn number(comptime T: type, s: []const u8) ParseError!T {
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, s) catch error.BadValue,
        else => std.fmt.parseInt(T, s, 10) catch error.BadValue,
    };
}

/// Parse command-line arguments (without the program name).
fn parseArgs(argv: []const []const u8) ParseError!Args {
    var a: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const flag = argv[i];
        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const v = argv[i];
        if (std.mem.eql(u8, flag, "--fps")) {
            a.fps = try number(f32, v);
            if (!(a.fps > 0)) return error.BadValue;
        } else if (std.mem.eql(u8, flag, "--live")) {
            a.live = try number(f32, v);
        } else if (std.mem.eql(u8, flag, "--burn")) {
            a.burn = try number(f32, v);
        } else if (std.mem.eql(u8, flag, "--palette")) {
            a.palette = palettes.indexOf(v) orelse return error.BadValue;
        } else if (std.mem.eql(u8, flag, "--max-seconds")) {
            a.max_seconds = try number(f32, v);
        } else if (std.mem.eql(u8, flag, "--still")) {
            a.still = v;
        } else if (std.mem.eql(u8, flag, "--phase")) {
            a.phase = std.meta.stringToEnum(show_mod.Phase, v) orelse return error.BadValue;
            if (a.phase == .black) return error.BadValue;
        } else if (std.mem.eql(u8, flag, "--at")) {
            a.at = try number(f32, v);
        } else if (std.mem.eql(u8, flag, "--size")) {
            const x = std.mem.indexOfScalar(u8, v, 'x') orelse return error.BadValue;
            a.cols = try number(usize, v[0..x]);
            a.rows = try number(usize, v[x + 1 ..]);
            if (a.cols == 0 or a.rows == 0) return error.BadValue;
        } else if (std.mem.eql(u8, flag, "--bench")) {
            a.bench = try number(usize, v);
        } else {
            return error.BadFlag;
        }
    }
    return a;
}

fn writeAll(io: Io, file: Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}

fn nowSeconds(io: Io) f64 {
    const ns = Io.Clock.awake.now(io).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn showOptions(a: Args, seed: u64) show_mod.Options {
    return .{ .live = a.live, .burn = a.burn, .palette = a.palette, .seed = seed };
}

fn runStill(gpa: Allocator, io: Io, a: Args, path: []const u8) !void {
    var show = try show_mod.Show.init(gpa, a.cols, a.rows * 2, showOptions(a, 1));
    defer show.deinit();
    const frame = try show.seek(a.phase, a.at, 20);
    var cells = try render.Cells.init(gpa, a.cols, a.rows);
    defer cells.deinit(gpa);
    render.toCells(frame, &cells);
    const ppm = try render.toPpm(gpa, cells);
    defer gpa.free(ppm);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ppm });
}

fn runBench(gpa: Allocator, io: Io, a: Args) !void {
    const w = a.cols;
    const h = a.rows * 2;
    var show = try show_mod.Show.init(gpa, w, h, showOptions(a, 1));
    defer show.deinit();
    var cells = try render.Cells.init(gpa, w, h / 2);
    defer cells.deinit(gpa);
    var em = render.Emitter.init(gpa);
    defer em.deinit();

    const phases = std.enums.values(show_mod.Phase).len;
    var step_s = @as([phases]f64, @splat(0));
    var cells_s = @as([phases]f64, @splat(0));
    var emit_s = @as([phases]f64, @splat(0));
    var count = @as([phases]usize, @splat(0));
    var bytes: usize = 0;
    var worst: f64 = 0;
    const dt: f32 = 1.0 / a.fps;
    for (0..a.bench) |_| {
        const t0 = nowSeconds(io);
        const frame = try show.step(dt);
        const ph = @backingInt(show.phase);
        const t1 = nowSeconds(io);
        render.toCells(frame, &cells);
        const t2 = nowSeconds(io);
        bytes += (try em.frame(cells)).len;
        const t3 = nowSeconds(io);
        step_s[ph] += t1 - t0;
        cells_s[ph] += t2 - t1;
        emit_s[ph] += t3 - t2;
        count[ph] += 1;
        worst = @max(worst, t3 - t0);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.print(gpa, "{d} frames at {d}x{d} px ({d}x{d} cells), {d:.1} KiB/frame emitted\n", .{ a.bench, w, h, w, h / 2, @as(f64, @floatFromInt(bytes)) / 1024 / @as(f64, @floatFromInt(@max(a.bench, 1))) });
    var tot_n: usize = 0;
    var tot_s: f64 = 0;
    for (0..phases) |p| {
        if (count[p] == 0) continue;
        const n: f64 = @floatFromInt(count[p]);
        const sum = step_s[p] + cells_s[p] + emit_s[p];
        try out.print(gpa, "{s:>5}: {d:6.3} ms/frame (step {d:.3}, to_cells {d:.3}, emit {d:.3}) over {d} frames\n", .{
            @tagName(@as(show_mod.Phase, @fromBackingInt(@intCast(p)))),
            sum / n * 1000,
            step_s[p] / n * 1000,
            cells_s[p] / n * 1000,
            emit_s[p] / n * 1000,
            count[p],
        });
        tot_n += count[p];
        tot_s += sum;
    }
    try out.print(gpa, "  all: {d:6.3} ms/frame mean, {d:.3} ms worst\n", .{ tot_s / @as(f64, @floatFromInt(@max(tot_n, 1))) * 1000, worst * 1000 });
    try writeAll(io, Io.File.stdout(), out.items);
}

fn runTerminal(gpa: Allocator, io: Io, a: Args) !void {
    const stdout = Io.File.stdout();
    var raw = try term.Raw.enable();
    defer raw.restore();
    try writeAll(io, stdout, term.enter_seq);
    defer writeAll(io, stdout, term.leave_seq) catch {}; // terminal is going away anyway

    var show: ?show_mod.Show = null;
    defer if (show) |*s| s.deinit();
    var cells: ?render.Cells = null;
    defer if (cells) |*c| c.deinit(gpa);
    var em = render.Emitter.init(gpa);
    defer em.deinit();

    const frame_s: f64 = 1.0 / a.fps;
    const start = nowSeconds(io);
    var last = start;
    const seed: u64 = @truncate(@as(u96, @bitCast(Io.Clock.real.now(io).nanoseconds)));
    while (!term.quitRequested()) {
        if (term.takeResized()) {
            const sz = term.size();
            if (show) |*s| try s.resize(sz.cols, sz.rows * 2) else show = try .init(gpa, sz.cols, sz.rows * 2, showOptions(a, seed));
            if (cells) |*c| c.deinit(gpa);
            cells = null; // so a failed init below cannot double free
            cells = try .init(gpa, sz.cols, sz.rows);
            em.reset();
        }
        const now = nowSeconds(io);
        const dt: f32 = @floatCast(@min(0.1, now - last));
        last = now;
        const frame = try show.?.step(dt);
        render.toCells(frame, &cells.?);
        try writeAll(io, stdout, try em.frame(cells.?));
        if (a.max_seconds > 0 and now - start > a.max_seconds) break;
        const wait_ms: i32 = @intFromFloat(@ceil(@max(0, frame_s - (nowSeconds(io) - now)) * 1000));
        if (try term.inputWithin(wait_ms)) { // any key quits
            var scratch: [64]u8 = undefined;
            _ = std.posix.read(std.posix.STDIN_FILENO, &scratch) catch 0; // swallow it
            break;
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    var da: std.heap.DebugAllocator(.{}) = .init;
    const gpa = da.allocator();
    defer if (da.deinit() == .leak) std.log.err("memory leaked", .{});
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = parseArgs(argv[@min(1, argv.len)..]) catch |err| {
        const stderr = Io.File.stderr();
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "saver: {t}\n", .{err}) catch "saver: bad arguments\n";
        try writeAll(io, stderr, msg);
        try writeAll(io, stderr, usage);
        return 2;
    };

    if (args.bench > 0) {
        try runBench(gpa, io, args);
    } else if (args.still) |path| {
        try runStill(gpa, io, args, path);
    } else {
        runTerminal(gpa, io, args) catch |err| switch (err) {
            error.NotATerminal => {
                try writeAll(io, Io.File.stderr(), "saver: stdin is not a terminal (use --still FILE for a headless frame)\n");
                return 1;
            },
            else => return err,
        };
    }
    return 0;
}

test "parseArgs reads every flag" {
    const a = try parseArgs(&.{ "--fps", "30", "--live", "6", "--burn", "5", "--palette", "moon", "--phase", "burn", "--at", "2.5", "--size", "10x4", "--still", "x.ppm" });
    try std.testing.expectEqual(@as(f32, 30), a.fps);
    try std.testing.expectEqual(@as(?usize, 1), a.palette);
    try std.testing.expectEqual(show_mod.Phase.burn, a.phase);
    try std.testing.expectEqual(@as(usize, 10), a.cols);
    try std.testing.expectEqual(@as(usize, 4), a.rows);
    try std.testing.expectEqualStrings("x.ppm", a.still.?);
}

test "parseArgs rejects bad input" {
    try std.testing.expectError(error.BadFlag, parseArgs(&.{ "--nope", "1" }));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{"--fps"}));
    try std.testing.expectError(error.BadValue, parseArgs(&.{ "--palette", "neon" }));
    try std.testing.expectError(error.BadValue, parseArgs(&.{ "--size", "0x5" }));
    try std.testing.expectError(error.BadValue, parseArgs(&.{ "--fps", "0" }));
}
