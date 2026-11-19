// Package term handles raw terminal setup, size queries and restoration,
// using only the standard library (syscall, Linux).
package term

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// Escape sequences for entering and leaving the screensaver screen.
const (
	Enter = "\x1b[?1049h\x1b[?25l\x1b[?7l" // alt screen, hide cursor, no autowrap
	Leave = "\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l"
)

func ioctl(fd uintptr, req uintptr, arg unsafe.Pointer) error {
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(arg)); e != 0 {
		return e
	}
	return nil
}

// Terminal is a terminal in cbreak mode with the alternate screen active.
type Terminal struct {
	in    *os.File
	out   *os.File
	saved syscall.Termios
	live  bool
}

// Open puts in into cbreak mode (no ICANON, no ECHO) and writes Enter to out.
func Open(in, out *os.File) (*Terminal, error) {
	t := &Terminal{in: in, out: out}
	if err := ioctl(in.Fd(), syscall.TCGETS, unsafe.Pointer(&t.saved)); err != nil {
		return nil, fmt.Errorf("stdin is not a terminal: %w", err)
	}
	raw := t.saved
	raw.Lflag &^= syscall.ICANON | syscall.ECHO
	raw.Cc[syscall.VMIN], raw.Cc[syscall.VTIME] = 1, 0
	if err := ioctl(in.Fd(), syscall.TCSETS, unsafe.Pointer(&raw)); err != nil {
		return nil, fmt.Errorf("set cbreak: %w", err)
	}
	t.live = true
	if _, err := out.WriteString(Enter); err != nil {
		_ = t.Close()
		return nil, err
	}
	return t, nil
}

// Close restores the screen and the terminal modes. It is safe to call twice.
func (t *Terminal) Close() error {
	if !t.live {
		return nil
	}
	t.live = false
	_, werr := t.out.WriteString(Leave)
	if err := ioctl(t.in.Fd(), syscall.TCSETS, unsafe.Pointer(&t.saved)); err != nil {
		return err
	}
	return werr
}

// Size returns the terminal's columns and rows.
func Size(f *os.File) (cols, rows int, err error) {
	var ws struct{ Row, Col, X, Y uint16 }
	if err := ioctl(f.Fd(), syscall.TIOCGWINSZ, unsafe.Pointer(&ws)); err != nil {
		return 0, 0, err
	}
	return int(ws.Col), int(ws.Row), nil
}
