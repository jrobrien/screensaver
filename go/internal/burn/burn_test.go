package burn

import (
	"math/rand/v2"
	"testing"

	"saver/internal/pix"
)

func filled(w, h int) *pix.Image {
	img := pix.New(w, h)
	for i := range img.Pix {
		img.Pix[i] = 200
	}
	return img
}

func TestBurnLifecycle(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	b := NewBurn(40, 30, rng, 2)
	tests := []struct {
		t        float64
		wantDark bool
	}{{0, false}, {b.End() + 0.1, true}}
	for _, tc := range tests {
		img := filled(40, 30)
		b.Apply(img, tc.t)
		dark := true
		for _, v := range img.Pix {
			if v != 0 {
				dark = false
			}
		}
		if dark != tc.wantDark {
			t.Errorf("t=%.1f all black = %v, want %v", tc.t, dark, tc.wantDark)
		}
	}
	if !b.Done() {
		t.Error("burn not done after End")
	}
}

func TestGrowRevealsFromCentre(t *testing.T) {
	g := NewGrow(41, 21, rand.New(rand.NewPCG(1, 2)), 4)
	img := filled(41, 21)
	g.Apply(img, 0.5)
	if img.At(0, 0) != (pix.RGB{}) {
		t.Error("corner should still be black")
	}
	img = filled(41, 21)
	g.Apply(img, g.End()+1)
	if img.At(0, 0) != (pix.RGB{200, 200, 200}) {
		t.Error("corner should be revealed at the end")
	}
}
