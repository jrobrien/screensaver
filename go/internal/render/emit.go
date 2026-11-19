package render

import (
	"strconv"
	"unicode/utf8"

	"saver/internal/pix"
)

const (
	syncOn  = "\x1b[?2026h"
	syncOff = "\x1b[0m\x1b[?2026l"
)

// Emitter turns successive cell frames into minimal ANSI updates
// (truecolour, synchronized).
type Emitter struct {
	prev *Cells
	buf  []byte
}

// Reset forces the next frame to redraw everything.
func (e *Emitter) Reset() { e.prev = nil }

func (e *Emitter) color(sgr string, c pix.RGB) {
	e.buf = append(e.buf, "\x1b["...)
	e.buf = append(e.buf, sgr...)
	for _, v := range c {
		e.buf = append(e.buf, ';')
		e.buf = strconv.AppendUint(e.buf, uint64(v), 10)
	}
	e.buf = append(e.buf, 'm')
}

// Frame returns the bytes that bring the screen to c. The slice is reused by
// the next call.
func (e *Emitter) Frame(c *Cells) []byte {
	e.buf = append(e.buf[:0], syncOn...)
	full := e.prev == nil || e.prev.Rows != c.Rows || e.prev.Cols != c.Cols
	if full {
		e.buf = append(e.buf, "\x1b[2J"...)
	}
	var lastFg, lastBg pix.RGB
	haveFg, haveBg := false, false
	for r := 0; r < c.Rows; r++ {
		a, b := 0, c.Cols // one run per row: first to last change
		if !full {
			a, b = -1, 0
			for col := 0; col < c.Cols; col++ {
				i := r*c.Cols + col
				if c.Ch[i] != e.prev.Ch[i] || c.Fg[i] != e.prev.Fg[i] || c.Bg[i] != e.prev.Bg[i] {
					if a < 0 {
						a = col
					}
					b = col + 1
				}
			}
			if a < 0 {
				continue
			}
		}
		e.buf = append(e.buf, "\x1b["...)
		e.buf = strconv.AppendInt(e.buf, int64(r+1), 10)
		e.buf = append(e.buf, ';')
		e.buf = strconv.AppendInt(e.buf, int64(a+1), 10)
		e.buf = append(e.buf, 'H')
		for col := a; col < b; col++ {
			i := r*c.Cols + col
			if !haveFg || c.Fg[i] != lastFg {
				e.color("38;2", c.Fg[i])
				lastFg, haveFg = c.Fg[i], true
			}
			if !haveBg || c.Bg[i] != lastBg {
				e.color("48;2", c.Bg[i])
				lastBg, haveBg = c.Bg[i], true
			}
			e.buf = utf8.AppendRune(e.buf, c.Ch[i])
		}
	}
	e.buf = append(e.buf, syncOff...)
	if e.prev == nil || e.prev.Rows != c.Rows || e.prev.Cols != c.Cols {
		e.prev = c.clone()
	} else {
		copy(e.prev.Ch, c.Ch)
		copy(e.prev.Fg, c.Fg)
		copy(e.prev.Bg, c.Bg)
	}
	return e.buf
}
