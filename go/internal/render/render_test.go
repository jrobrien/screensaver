package render

import (
	"bytes"
	"image/png"
	"strings"
	"testing"

	"saver/internal/pix"
)

func halfCells(rows, cols int) *Cells {
	c := NewCells(rows, cols)
	for i := range c.Ch {
		c.Ch[i] = Half
	}
	return c
}

func TestEmitterOnlyRedrawsChanges(t *testing.T) {
	var em Emitter
	c := halfCells(2, 3)
	if full := string(em.Frame(c)); !strings.Contains(full, "\x1b[2J") {
		t.Error("first frame lacks a clear")
	}
	if got, want := string(em.Frame(c)), "\x1b[?2026h\x1b[0m\x1b[?2026l"; got != want {
		t.Errorf("identical frame = %q, want %q", got, want)
	}
	c.Fg[1*3+2] = pix.RGB{255, 255, 255}
	got := string(em.Frame(c))
	if n := strings.Count(got, "H"); n != 1 || !strings.Contains(got, "\x1b[2;3H") {
		t.Errorf("changed cell frame = %q", got)
	}
	em.Reset()
	if !strings.Contains(string(em.Frame(c)), "\x1b[2J") {
		t.Error("Reset did not force a full redraw")
	}
}

func TestGlyphCells(t *testing.T) {
	white, black := pix.RGB{255, 255, 255}, pix.RGB{}
	tests := []struct {
		name     string
		top, bot pix.RGB
		mt, mb   bool
		ch       rune
	}{
		{"bright", white, white, true, true, '@'},
		{"dark ink is blank", pix.RGB{5, 5, 5}, black, true, false, ' '},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if ch, _, _ := glyphCell(tc.top, tc.bot, tc.mt, tc.mb); ch != tc.ch {
				t.Errorf("glyph %q, want %q", ch, tc.ch)
			}
		})
	}
	_, fg, bg := glyphCell(pix.RGB{100, 100, 100}, pix.RGB{200, 0, 0}, true, false)
	if fg != (pix.RGB{225, 225, 225}) || bg != (pix.RGB{90, 0, 0}) {
		t.Errorf("fg %v bg %v", fg, bg)
	}
}

func TestToCellsHalfBlock(t *testing.T) {
	img := pix.New(1, 2)
	img.Set(0, 0, pix.RGB{1, 2, 3})
	img.Set(0, 1, pix.RGB{4, 5, 6})
	c := ToCells(img, make([]bool, 2), nil)
	if c.Ch[0] != Half || c.Fg[0] != (pix.RGB{1, 2, 3}) || c.Bg[0] != (pix.RGB{4, 5, 6}) {
		t.Errorf("cell = %q %v %v", c.Ch[0], c.Fg[0], c.Bg[0])
	}
}

func TestWritePNG(t *testing.T) {
	var buf bytes.Buffer
	if err := WritePNG(&buf, halfCells(2, 3)); err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if b := img.Bounds(); b.Dx() != 24 || b.Dy() != 32 {
		t.Errorf("size %v, want 24x32", b)
	}
}
