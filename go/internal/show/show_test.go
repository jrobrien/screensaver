package show

import (
	"testing"

	"saver/internal/render"
)

func mustShow(t testing.TB, w, h int, cfg Config) *Show {
	t.Helper()
	s, err := New(w, h, cfg)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestCycleVisitsEveryPhaseAndRotatesPalette(t *testing.T) {
	s := mustShow(t, 80, 48, Config{Live: 0.5, Burn: 1})
	firstS1 := s.Scene().Palette()
	seen := map[Phase]bool{}
	for range 20 * 60 {
		img, mask := s.Step(1.0 / 20)
		if img.W != 80 || img.H != 48 || len(img.Pix) != 80*48*3 || len(mask) != 80*48 {
			t.Fatalf("bad frame shape %dx%d, %d mask", img.W, img.H, len(mask))
		}
		seen[s.Phase()] = true
		if s.Cycle() == 2 {
			break
		}
	}
	for p := Grow; p <= Black; p++ {
		if !seen[p] {
			t.Errorf("phase %v never visited", p)
		}
	}
	if s.Cycle() != 2 {
		t.Fatalf("cycle = %d, want 2", s.Cycle())
	}
	if s.Scene().Palette() == firstS1 {
		t.Error("palette did not rotate")
	}
}

func TestLiveFrameHasBlocksAndGlyphs(t *testing.T) {
	s := mustShow(t, 120, 70, Config{Live: 24, Burn: 9})
	img, mask := s.Seek(Live, 1)
	masked := 0
	for _, m := range mask {
		if m {
			masked++
		}
	}
	if masked == 0 || masked == len(mask) {
		t.Fatalf("mask has %d of %d pixels set", masked, len(mask))
	}
	c := render.ToCells(img, mask, nil)
	if c.Rows != 35 || c.Cols != 120 {
		t.Fatalf("cells %dx%d", c.Rows, c.Cols)
	}
	var half, glyph int
	for _, ch := range c.Ch {
		switch {
		case ch == render.Half:
			half++
		case ch != ' ':
			glyph++
		}
	}
	if half == 0 || glyph == 0 {
		t.Errorf("half-blocks %d, glyphs %d; want both", half, glyph)
	}
}

func TestBurnEndsBlack(t *testing.T) {
	s := mustShow(t, 60, 40, Config{Live: 0.1, Burn: 0.5})
	img, _ := s.Seek(Burn, 1e9) // runs until the phase after burn
	if s.Phase() != Black {
		t.Fatalf("phase = %v, want black", s.Phase())
	}
	for _, v := range img.Pix {
		if v != 0 {
			t.Fatal("image not black after burn")
		}
	}
}

func TestResizeDuringBurnRestartsGrow(t *testing.T) {
	s := mustShow(t, 60, 40, Config{Live: 0.1, Burn: 2})
	s.Seek(Burn, 0.2)
	s.Resize(30, 20)
	if s.Phase() != Grow {
		t.Fatalf("phase = %v, want grow", s.Phase())
	}
	img, mask := s.Step(0.05)
	if img.W != 30 || img.H != 20 || len(mask) != 600 {
		t.Errorf("frame %dx%d after resize", img.W, img.H)
	}
}

func TestTinySizesSurvive(t *testing.T) {
	for _, sz := range [][2]int{{1, 2}, {10, 8}, {3, 2}} {
		s := mustShow(t, sz[0], sz[1], Config{Live: 0.2, Burn: 0.5})
		var em render.Emitter
		var cells *render.Cells
		for range 400 {
			img, mask := s.Step(0.05)
			cells = render.ToCells(img, mask, cells)
			em.Frame(cells)
		}
		s.Resize(80, 40)
		s.Step(0.05)
	}
}

func BenchmarkFrame(b *testing.B) {
	for _, bc := range []struct {
		name  string
		phase Phase
		liveT float64
	}{{"live", Live, 1e9}, {"burn", Burn, 0.1}} {
		b.Run(bc.name, func(b *testing.B) {
			var (
				s     *Show
				em    render.Emitter
				cells *render.Cells
			)
			b.ReportAllocs()
			for range b.N {
				if s == nil || s.Phase() != bc.phase { // restart when the phase runs out
					b.StopTimer()
					s = mustShow(b, 240, 134, Config{Live: bc.liveT, Burn: 9, Seed: 1})
					s.Seek(bc.phase, 1)
					b.StartTimer()
				}
				img, mask := s.Step(1.0 / 24)
				cells = render.ToCells(img, mask, cells)
				em.Frame(cells)
			}
		})
	}
}
