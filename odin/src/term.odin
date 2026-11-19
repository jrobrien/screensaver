package saver

import "base:intrinsics"
import "core:sys/linux"
import "core:sys/posix"

// Terminal setup and restore, window size, signals, and input wait.

ENTER :: "\x1b[?1049h\x1b[?25l\x1b[?7l" // alt screen, hide cursor, no autowrap
LEAVE :: "\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l"

// Flags set from signal handlers (the only mutable globals). Handlers run
// outside Odin's context, so they only do atomic stores.
@(private = "file")
quit_flag: i32
@(private = "file")
resize_flag: i32

@(private = "file")
on_quit :: proc "c" (_: posix.Signal) {
	intrinsics.atomic_store(&quit_flag, 1)
}

@(private = "file")
on_winch :: proc "c" (_: posix.Signal) {
	intrinsics.atomic_store(&resize_flag, 1)
}

Terminal :: struct {
	saved:  posix.termios,
	active: bool,
}

// True once SIGINT, SIGTERM or SIGHUP has arrived.
quit_requested :: proc() -> bool {
	return intrinsics.atomic_load(&quit_flag) != 0
}

// True (once) after a SIGWINCH; also true at first call.
take_resized :: proc() -> bool {
	return intrinsics.atomic_exchange(&resize_flag, 0) != 0
}

request_resize :: proc() {
	intrinsics.atomic_store(&resize_flag, 1)
}

@(private = "file")
install :: proc(sig: posix.Signal, handler: proc "c" (_: posix.Signal)) {
	act: posix.sigaction_t
	act.sa_handler = handler
	posix.sigemptyset(&act.sa_mask)
	// No SA_RESTART: a signal interrupts poll() so we notice it at once.
	posix.sigaction(sig, &act, nil)
}

write_all :: proc(data: []byte) {
	rest := data
	for len(rest) > 0 {
		n := posix.write(posix.STDOUT_FILENO, raw_data(rest), len(rest))
		if n < 0 {
			if posix.get_errno() == .EINTR {
				continue
			}
			return
		}
		rest = rest[n:]
	}
}

// Cbreak mode, alternate screen, signal handlers. Pair with terminal_leave.
terminal_enter :: proc(t: ^Terminal) -> bool {
	if posix.tcgetattr(posix.STDIN_FILENO, &t.saved) != .OK {
		return false
	}
	raw := t.saved
	raw.c_lflag -= {.ICANON, .ECHO}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw) != .OK {
		return false
	}
	t.active = true
	install(.SIGINT, on_quit)
	install(.SIGTERM, on_quit)
	install(.SIGHUP, on_quit)
	install(posix.Signal(posix.SIGWINCH), on_winch)
	write_all(transmute([]byte)string(ENTER))
	return true
}

terminal_leave :: proc(t: ^Terminal) {
	if !t.active {
		return
	}
	write_all(transmute([]byte)string(LEAVE))
	posix.tcsetattr(posix.STDIN_FILENO, .TCSADRAIN, &t.saved)
	t.active = false
}

Win_Size :: struct {
	rows, cols, xpixel, ypixel: u16,
}

// Terminal size in character cells.
terminal_size :: proc() -> (cols, rows: int, ok: bool) {
	ws: Win_Size
	for fd in ([]linux.Fd{1, 0, 2}) {
		if linux.ioctl(fd, linux.TIOCGWINSZ, uintptr(&ws)) == 0 && ws.cols > 0 && ws.rows > 0 {
			return int(ws.cols), int(ws.rows), true
		}
	}
	return 0, 0, false
}

// Wait up to `ms` milliseconds; true if a key was pressed (any input byte).
// Also returns early (false) when a signal interrupts the wait.
wait_for_key :: proc(ms: int) -> bool {
	fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
	if posix.poll(raw_data(fds[:]), 1, i32(max(ms, 0))) <= 0 {
		return false
	}
	if fds[0].revents == {} {
		return false
	}
	b: [64]byte
	posix.read(posix.STDIN_FILENO, raw_data(b[:]), len(b))
	return true
}
