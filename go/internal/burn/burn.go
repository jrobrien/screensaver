// Package burn holds the per-pixel effects drawn over the scene.
//
// Burn: a fire front crawls out from a few ignition points. Each pixel goes
// heat glow -> flame -> char -> grey ash -> black, while ash flakes and
// sparks lift off and drift upward.
// Grow: the scene flashes in, spreading out from the centre.
package burn

import (
	"math"
	"math/rand/v2"

	"saver/internal/pix"
)

type vec [3]float32

var (
	flame = [5]vec{{255, 244, 190}, {255, 204, 70}, {240, 120, 24}, {178, 48, 12}, {80, 18, 8}}
	heat  = vec{255, 120, 30}
	ember = vec{190, 70, 16}
	ash   = vec{1.0, 0.97, 0.92} // tint applied to grey levels
	flash = vec{255, 235, 200}
)

// Timings in seconds.
const (
	HeatT  = 0.6  // glow before the front arrives
	FlameT = 0.75 // in flame
	CharT  = 1.1  // smouldering
	AshT   = 1.6  // grey ash, then black

	flashT = 0.8
)

func mix(a, b vec, k float32) vec {
	return vec{a[0]*(1-k) + b[0]*k, a[1]*(1-k) + b[1]*k, a[2]*(1-k) + b[2]*k}
}

func scale(a vec, k float32) vec { return vec{a[0] * k, a[1] * k, a[2] * k} }

func store(img *pix.Image, i int, c vec) {
	for k := range c {
		img.Pix[3*i+k] = uint8(min(max(c[k], 0), 255))
	}
}

func load(img *pix.Image, i int) vec {
	return vec{float32(img.Pix[3*i]), float32(img.Pix[3*i+1]), float32(img.Pix[3*i+2])}
}

// flameAt is the flame gradient at u in [0, 1].
func flameAt(u float32) vec {
	u = min(max(u, 0), 1) * float32(len(flame)-1)
	i := min(int(u), len(flame)-2)
	return mix(flame[i], flame[i+1], u-float32(i))
}

// valueNoise returns smooth noise in [0, 1]: a random grid every cell
// pixels, bilinearly interpolated.
func valueNoise(rng *rand.Rand, w, h, cell int) []float32 {
	gh, gw := h/cell+2, w/cell+2
	g := make([]float32, gh*gw)
	for i := range g {
		g[i] = rng.Float32()
	}
	pos := func(i, n, g int) (int, float32) {
		p := 0.0
		if n > 1 {
			p = float64(g-1) - 0.001
			p = p * float64(i) / float64(n-1)
		}
		i0 := int(p)
		return i0, float32(p - float64(i0))
	}
	out := make([]float32, w*h)
	for y := 0; y < h; y++ {
		y0, fy := pos(y, h, gh)
		for x := 0; x < w; x++ {
			x0, fx := pos(x, w, gw)
			top := g[y0*gw+x0]*(1-fx) + g[y0*gw+x0+1]*fx
			bot := g[(y0+1)*gw+x0]*(1-fx) + g[(y0+1)*gw+x0+1]*fx
			out[y*w+x] = top*(1-fy) + bot*fy
		}
	}
	return out
}

type flake struct {
	x, y, vx, vy, age, life float32
	spark                   bool
}

// Burn is the burn-to-ash effect.
type Burn struct {
	w, h   int
	rng    *rand.Rand
	ignite []float32
	grain  []float32
	end    float64
	tPrev  float64
	flakes []flake
}

// NewBurn prepares a burn over a w x h image whose front takes duration
// seconds to cross.
func NewBurn(w, h int, rng *rand.Rand, duration float64) *Burn {
	b := &Burn{w: w, h: h, rng: rng}
	n := w * h
	dist := make([]float32, n)
	for i := range dist {
		dist[i] = float32(math.Inf(1))
	}
	for range 2 + rng.IntN(2) { // ignition points, lower half of the screen
		sx := (0.1 + 0.8*rng.Float64()) * float64(w)
		sy := (0.55 + 0.45*rng.Float64()) * float64(h)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				d := float32(math.Hypot(float64(x)-sx, float64(y)-sy))
				dist[y*w+x] = min(dist[y*w+x], d)
			}
		}
	}
	size := float32(max(w, h))
	n7, n2 := valueNoise(rng, w, h, 7), valueNoise(rng, w, h, 2) // ragged front
	lo, hi := float32(math.Inf(1)), float32(math.Inf(-1))
	for i := range dist {
		dist[i] += (n7[i]-.5)*0.22*size + (n2[i]-.5)*0.04*size
		lo, hi = min(lo, dist[i]), max(hi, dist[i])
	}
	span := max(hi-lo, 1e-6)
	b.ignite = make([]float32, n)
	b.grain = make([]float32, n)
	var last float32
	for i := range dist {
		b.ignite[i] = (dist[i]-lo)/span*float32(duration) + rng.Float32()*0.25
		last = max(last, b.ignite[i])
	}
	for i := range b.grain {
		b.grain[i] = rng.Float32()
	}
	b.end = float64(last) + FlameT + CharT + AshT + 3 // + time for flakes to clear
	return b
}

// End is the time after which the burn is over.
func (b *Burn) End() float64 { return b.end }

// Done reports whether the burn has finished.
func (b *Burn) Done() bool { return b.tPrev > b.end }

// Apply draws the burn, t seconds after it began, onto img in place.
func (b *Burn) Apply(img *pix.Image, t float64) {
	dt, t0 := float32(t-b.tPrev), float32(b.tPrev)
	b.tPrev = t
	tf := float32(t)
	const a1 = FlameT + CharT
	for i, ig := range b.ignite {
		age := tf - ig
		switch {
		case age < -HeatT:
		case age < 0:
			k := (1 + age/HeatT) * 0.55
			store(img, i, mix(load(img, i), heat, k))
		case age < FlameT:
			u := age/FlameT*0.9 + (b.rng.Float32()-0.5)*0.5
			store(img, i, flameAt(u))
		case age < a1:
			c := (age - FlameT) / CharT
			if b.rng.Float32() < 0.10*(1-c) {
				store(img, i, scale(ember, 1-c))
			} else {
				store(img, i, scale(load(img, i), 0.22*(1-c)))
			}
		case age < a1+AshT:
			g := 112 * (1 - (age-a1)/AshT) * (0.65 + 0.35*b.grain[i])
			store(img, i, scale(ash, g))
		default:
			store(img, i, vec{})
		}
		if ashAt := ig + a1; ashAt > t0 && ashAt <= tf && b.rng.Float32() < 0.45 {
			b.spawn(i, 3, 2.5, 2, 9, 1.5, 4.0, false)
		}
		if ig > t0 && ig <= tf && b.rng.Float32() < 0.06 {
			b.spawn(i, 4, 2, 6, 18, 0.6, 1.8, true)
		}
	}
	b.drawFlakes(img, dt)
}

func (b *Burn) spawn(i int, vxSD, vxMean, vyLo, vyHi, lifeLo, lifeHi float32, spark bool) {
	b.flakes = append(b.flakes, flake{
		x: float32(i % b.w), y: float32(i / b.w),
		vx:    vxMean + vxSD*float32(b.rng.NormFloat64()),
		vy:    -(vyLo + (vyHi-vyLo)*b.rng.Float32()),
		life:  lifeLo + (lifeHi-lifeLo)*b.rng.Float32(),
		spark: spark,
	})
}

func (b *Burn) drawFlakes(img *pix.Image, dt float32) {
	live := b.flakes[:0]
	for _, f := range b.flakes {
		f.age += dt
		f.x += (f.vx + 3*float32(math.Sin(float64(f.age*3+f.y)))) * dt
		f.y += f.vy * dt
		if f.age >= f.life || f.y <= -2 {
			continue
		}
		live = append(live, f)
		x, y := int(f.x), int(f.y)
		if f.x < 0 || f.y < 0 || x >= b.w || y >= b.h {
			continue
		}
		l := 1 - f.age/f.life
		c := scale(ash, 150*l)
		if f.spark {
			c = vec{255 * l, 140 * l * l, 30 * l * l * l}
		}
		i := y*b.w + x
		if under := load(img, i); c[0]+c[1]+c[2] > under[0]+under[1]+under[2] {
			store(img, i, c)
		}
	}
	b.flakes = live
}

// Grow is the flash-in reveal radiating from the centre.
type Grow struct {
	w, h   int
	reveal []float32
	end    float64
}

// NewGrow prepares a reveal over a w x h image taking about duration seconds.
func NewGrow(w, h int, rng *rand.Rand, duration float64) *Grow {
	g := &Grow{w: w, h: h, reveal: make([]float32, w*h)}
	dmax := 0.0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			d := math.Hypot(float64(x)-float64(w)/2, float64(y)-float64(h)/2)
			g.reveal[y*w+x] = float32(d)
			dmax = math.Max(dmax, d)
		}
	}
	if dmax == 0 {
		dmax = 1
	}
	var last float32
	for i, d := range g.reveal {
		g.reveal[i] = d/float32(dmax)*float32(duration) + rng.Float32()*0.9
		last = max(last, g.reveal[i])
	}
	g.end = float64(last) + flashT
	return g
}

// End is the time at which the reveal has finished.
func (g *Grow) End() float64 { return g.end }

// Apply draws the reveal at t seconds onto img in place.
func (g *Grow) Apply(img *pix.Image, t float64) {
	tf := float32(t)
	for i, r := range g.reveal {
		age := tf - r
		switch {
		case age < 0:
			store(img, i, vec{})
		case age < flashT:
			k := 1 - age/flashT
			store(img, i, mix(load(img, i), flash, k*k))
		}
	}
}
