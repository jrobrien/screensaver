//! Terminal plumbing: raw-ish mode, size, signals, input wait.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const enter_seq = "\x1b[?1049h\x1b[?25l\x1b[?7l"; // alt screen, hide cursor, no autowrap
pub const leave_seq = "\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l";

const stdin_fd = posix.STDIN_FILENO;
const stdout_fd = posix.STDOUT_FILENO;

pub const Size = struct { cols: usize, rows: usize };

// Signal flags: the only mutable globals, written from handlers.
var quit_flag: std.atomic.Value(bool) = .init(false);
var winch_flag: std.atomic.Value(bool) = .init(true); // true so the first frame reads the size

fn onQuit(_: posix.SIG) callconv(.c) void {
    quit_flag.store(true, .monotonic);
}

fn onWinch(_: posix.SIG) callconv(.c) void {
    winch_flag.store(true, .monotonic);
}

pub fn quitRequested() bool {
    return quit_flag.load(.monotonic);
}

/// True once after each SIGWINCH (and once at start-up).
pub fn takeResized() bool {
    return winch_flag.swap(false, .monotonic);
}

/// Cbreak stdin (no ICANON, no ECHO) and route INT/TERM/HUP/WINCH to flags.
/// `restore` puts the original settings back.
pub const Raw = struct {
    saved: posix.termios,

    pub fn enable() !Raw {
        const saved = try posix.tcgetattr(stdin_fd);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(stdin_fd, .DRAIN, raw);
        installHandler(.INT, onQuit);
        installHandler(.TERM, onQuit);
        installHandler(.HUP, onQuit);
        installHandler(.WINCH, onWinch);
        return .{ .saved = saved };
    }

    pub fn restore(self: Raw) void {
        posix.tcsetattr(stdin_fd, .DRAIN, self.saved) catch {}; // nothing more can be done at exit
    }
};

fn installHandler(sig: posix.SIG, handler: posix.Sigaction.handler_fn) void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
}

/// Terminal size in cells; falls back to 80x24 when it cannot be read.
pub fn size() Size {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(stdout_fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Wait up to `ms` for a key press (or a signal). True if input is waiting.
pub fn inputWithin(ms: i32) !bool {
    var fds = [_]posix.pollfd{.{ .fd = stdin_fd, .events = posix.POLL.IN }};
    return (try posix.poll(&fds, ms)) > 0;
}
