package scene

import (
	"math"
	"math/rand/v2"
)

type petal struct {
	x, y, depth, vy, phase, flip, flipRate, age float64
}

// fallingPetals drift on the wind, mostly shed from the blossoms. Virtual
// coordinates.
type fallingPetals struct {
	spots  []point
	rng    *rand.Rand
	petals []petal
}

func newFallingPetals(spots []point, n int) *fallingPetals {
	f := &fallingPetals{spots: spots, rng: rand.New(rand.NewPCG(petalSeed, petalSeed*7919))}
	f.petals = make([]petal, n)
	for i := range f.petals {
		f.reset(&f.petals[i], true)
	}
	return f
}

func (f *fallingPetals) uniform(a, b float64) float64 { return a + (b-a)*f.rng.Float64() }

func (f *fallingPetals) reset(p *petal, initial bool) {
	p.depth = f.uniform(0.25, 1)
	switch {
	case initial: // scattered and already faded in
		p.x, p.y, p.age = f.uniform(-100, 1700), f.uniform(-40, 940), 99
	case len(f.spots) > 0 && f.rng.Float64() < 0.6: // shed from a blossom
		sp := f.spots[f.rng.IntN(len(f.spots))]
		p.x, p.y, p.age = sp.x+f.uniform(-10, 10), sp.y+f.uniform(-6, 10), 0
	default: // from above the screen
		p.x, p.y, p.age = f.uniform(-120, 1500), -40, 0
	}
	p.vy = 14 + p.depth*34 + f.uniform(0, 8)
	p.phase = f.uniform(0, tau)
	p.flip = f.uniform(0, tau)
	p.flipRate = f.uniform(0.8, 2.4)
}

func (f *fallingPetals) step(dt, t float64) {
	wind := 14 + 10*math.Sin(t*0.13) + 5*math.Sin(t*0.37)
	for i := range f.petals {
		p := &f.petals[i]
		p.x += (wind*(0.5+p.depth*0.7) + math.Sin(t*0.7+p.phase)*16) * dt
		p.y += (p.vy + math.Sin(t*1.1+p.phase*2)*6) * dt
		p.flip += p.flipRate * dt
		p.age += dt
		if p.y > 950 || p.x > 1750 {
			f.reset(p, false)
		}
	}
}

func (f *fallingPetals) draw(s *surface, sc *Scene) {
	for i := range f.petals {
		p := &f.petals[i]
		x, y := p.x*sc.s+sc.ox, p.y*sc.s+sc.oy
		fade := (0.35 + 0.65*p.depth) * math.Min(1, p.age/1.2)
		base := sc.pal[Pink]
		if fade > 0.75 {
			base = sc.pal[PinkHi]
		}
		k := 0.45 + 0.55*math.Min(1, fade*1.2)
		col := base
		for c := range col {
			col[c] = uint8(float64(base[c]) * k)
		}
		s.ink(col, false)
		ix, iy := int(math.Floor(x)), int(math.Floor(y))
		s.set(ix, iy)
		if p.depth > 0.6 && math.Abs(math.Cos(p.flip)) > 0.5 { // near petals are 1-2 px wide as they flip
			s.set(ix+1, iy)
		}
	}
}
