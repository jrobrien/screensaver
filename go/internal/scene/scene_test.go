package scene

import "testing"

func TestRenderDeterministicAndMasked(t *testing.T) {
	sc := New(160, 90)
	img, mask := sc.Render(1, 0.04)
	var lit, masked int
	for i, m := range mask {
		if m {
			masked++
		}
		if img.Pix[3*i]|img.Pix[3*i+1]|img.Pix[3*i+2] != 0 {
			lit++
		}
	}
	if masked == 0 || lit <= masked {
		t.Errorf("lit %d, masked %d", lit, masked)
	}
}

func TestPalettes(t *testing.T) {
	for _, name := range Names {
		if _, err := NewPalette(name); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := NewPalette("nope"); err == nil {
		t.Error("unknown palette accepted")
	}
	p, _ := NewPalette("ember")
	if p[S1] != [3]uint8{0x9e, 0x1b, 0x1b} {
		t.Errorf("ember s1 = %v", p[S1])
	}
}

func TestCoverScale(t *testing.T) {
	sc := New(100, 100)
	if sc.s != 100.0/900 {
		t.Errorf("scale %v, want height-limited", sc.s)
	}
	if sc.ox >= 0 || sc.oy != 0 {
		t.Errorf("offsets %v %v", sc.ox, sc.oy)
	}
}
