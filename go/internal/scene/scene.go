// Package scene draws Sakura & Bamboo into a low-resolution pixel buffer.
//
// The geometry lives in a 1600x900 virtual space, built once as a tree of
// sway nodes holding shapes. Every frame the tree is evaluated into affine
// matrices and the shapes are rasterised, without antialiasing. Alongside
// the colour image the scene draws a glyph mask: bamboo pixels that the
// renderer turns into ASCII glyphs.
package scene

import (
	"math"

	"saver/internal/pix"
)

const (
	vw, vh = 1600, 900

	sunX, sunY, sunR = 800.0, 450.0, 250.0
	haloR0, haloR1   = 236.0, 430.0
)

type sunBand struct {
	top float64
	key Key
}

var sunBands = []sunBand{{200, S1}, {350, S2}, {420, S3}, {480, S4}, {535, S5}, {585, S6}, {640, S7}}

var ridges = [][]point{
	{{330, 770}, {450, 700}, {525, 742}, {640, 610}, {744, 750}},
	{{580, 790}, {710, 700}, {780, 748}, {880, 655}, {1000, 770}, {1060, 742}, {1190, 800}},
	{{240, 810}, {370, 745}, {460, 800}, {560, 760}, {660, 815}},
}

var bayer4 = [4][4]float64{{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}}

// affine maps x' = a*x + c*y + e, y' = b*x + d*y + f.
type affine struct{ a, b, c, d, e, f float64 }

// Scene is the Sakura & Bamboo picture.
type Scene struct {
	nodes   []node
	shapes  []shape
	px, py  []float64
	pn      []int
	petals  *fallingPetals
	keyCol  []pix.RGB // per shape colour
	pal     Palette
	palName string

	w, h      int
	s, ox, oy float64
	base      *pix.Image
	baseValid bool
	img       *pix.Image
	mask      []bool
	mats      []affine
	wx, wy    []float64
}

// New builds the scene for a w x h pixel image, in the first palette.
func New(w, h int) *Scene {
	b := build()
	sc := &Scene{nodes: b.nodes, shapes: b.shapes, px: b.px, py: b.py, pn: b.pn}
	sc.petals = newFallingPetals(b.blossoms, 48)
	sc.mats = make([]affine, len(sc.nodes))
	sc.wx, sc.wy = make([]float64, len(sc.px)), make([]float64, len(sc.px))
	sc.Resize(w, h)
	if err := sc.SetPalette(Names[0]); err != nil {
		panic(err) // Names[0] is always valid
	}
	return sc
}

// Resize fits the virtual space to w x h pixels, covering it.
func (sc *Scene) Resize(w, h int) {
	sc.w, sc.h = w, h
	sc.s = math.Max(float64(w)/vw, float64(h)/vh)
	sc.ox = (float64(w) - vw*sc.s) / 2
	sc.oy = (float64(h) - vh*sc.s) / 2
	sc.base = pix.New(w, h)
	sc.img = pix.New(w, h)
	sc.mask = make([]bool, w*h)
	sc.baseValid = false
}

// SetPalette switches to the named palette.
func (sc *Scene) SetPalette(name string) error {
	pal, err := NewPalette(name)
	if err != nil {
		return err
	}
	sc.pal, sc.palName = pal, name
	sc.keyCol = make([]pix.RGB, len(sc.shapes))
	for i, sh := range sc.shapes {
		sc.keyCol[i] = pal[sh.key]
	}
	sc.baseValid = false
	return nil
}

// Palette returns the current palette.
func (sc *Scene) Palette() Palette { return sc.pal }

// PaletteName returns the current palette's name.
func (sc *Scene) PaletteName() string { return sc.palName }

// Size returns the pixel size.
func (sc *Scene) Size() (w, h int) { return sc.w, sc.h }

// makeBase draws the static backdrop: dithered halo, banded sun, ridges.
func (sc *Scene) makeBase() {
	img := sc.base
	img.Clear()
	halo := sc.pal[S3]
	for c := range halo {
		halo[c] = uint8(float64(halo[c]) * 0.30)
	}
	for y := 0; y < sc.h; y++ {
		vy := (float64(y) + 0.5 - sc.oy) / sc.s
		for x := 0; x < sc.w; x++ {
			vx := (float64(x) + 0.5 - sc.ox) / sc.s
			r := math.Hypot(vx-sunX, vy-sunY)
			if r >= haloR0 && r < haloR1 {
				a := math.Min(math.Max(1-(r-haloR0)/(haloR1-haloR0), 0), 1)
				if a > 0.15 && a > (bayer4[y%4][x%4]+0.5)/16 {
					img.Set(x, y, halo)
				}
			}
			if r < sunR {
				for k := len(sunBands) - 1; k >= 0; k-- {
					if vy >= sunBands[k].top {
						img.Set(x, y, sc.pal[sunBands[k].key])
						break
					}
				}
			}
		}
	}
	surf := newSurface(img, nil)
	for _, ridge := range ridges {
		xs, ys := make([]float64, 0, len(ridge)+2), make([]float64, 0, len(ridge)+2)
		for _, p := range ridge {
			xs, ys = append(xs, p.x*sc.s+sc.ox), append(ys, p.y*sc.s+sc.oy)
		}
		n := len(xs)
		surf.ink(pix.RGB{}, false)
		surf.polygon(append(append([]float64{}, xs...), xs[n-1], xs[0]),
			append(append([]float64{}, ys...), float64(sc.h), float64(sc.h)))
		surf.ink(sc.pal[Line], false)
		surf.polyline(xs, ys)
	}
	sc.baseValid = true
}

// world computes all shape points in pixel coordinates at time t.
func (sc *Scene) world(t float64) {
	root := affine{sc.s, 0, 0, sc.s, sc.ox, sc.oy}
	for i, n := range sc.nodes {
		th := n.amp * math.Sin(math.Pi*t/n.dur+n.phase)
		c, s := math.Cos(th), math.Sin(th)
		e := n.pivot.x - c*n.pivot.x + s*n.pivot.y // rotation about the pivot
		f := n.pivot.y - s*n.pivot.x - c*n.pivot.y
		P := root
		if n.parent >= 0 {
			P = sc.mats[n.parent]
		}
		sc.mats[i] = affine{
			P.a*c + P.c*s, P.b*c + P.d*s,
			-P.a*s + P.c*c, -P.b*s + P.d*c,
			P.a*e + P.c*f + P.e, P.b*e + P.d*f + P.f,
		}
	}
	for i, ni := range sc.pn {
		m := &sc.mats[ni]
		sc.wx[i] = m.a*sc.px[i] + m.c*sc.py[i] + m.e
		sc.wy[i] = m.b*sc.px[i] + m.d*sc.py[i] + m.f
	}
}

// Render draws the scene at time t, advancing the petals by dt. The returned
// image and mask are owned by the scene and valid until the next call.
func (sc *Scene) Render(t, dt float64) (*pix.Image, []bool) {
	if !sc.baseValid {
		sc.makeBase()
	}
	sc.img.CopyFrom(sc.base)
	clear(sc.mask)
	sc.world(t)
	surf := newSurface(sc.img, sc.mask)
	for i, sh := range sc.shapes {
		surf.ink(sc.keyCol[i], glyphKeys[sh.key]) // non-glyph shapes erase the mask they cover
		xs, ys := sc.wx[sh.start:sh.end], sc.wy[sh.start:sh.end]
		switch sh.kind {
		case kPoly:
			surf.polygon(xs, ys)
		case kStem:
			n := len(xs) - 1
			for j := 0; j < n; j++ {
				w := math.Max(1, math.RoundToEven((sh.w0+(sh.w1-sh.w0)*float64(j)/float64(n))*sc.s))
				if w <= 1 {
					surf.line(xs[j], ys[j], xs[j+1], ys[j+1])
				} else {
					surf.thickLine(xs[j], ys[j], xs[j+1], ys[j+1], w)
				}
			}
		case kLine:
			surf.polyline(xs, ys)
		case kDot:
			surf.set(int(math.Floor(xs[0])), int(math.Floor(ys[0])))
		}
	}
	sc.petals.step(dt, t)
	sc.petals.draw(newSurface(sc.img, nil), sc)
	return sc.img, sc.mask
}
