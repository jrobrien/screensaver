package scene

import (
	"math"
	"math/rand/v2"
)

const (
	boost      = 1.35 // leaves and blossoms drawn larger than the SVG's
	bambooSway = 1.6  // bamboo sways more than the blossom branch
	deg        = math.Pi / 180
	tau        = 2 * math.Pi
	buildSeed  = 20261118
	petalSeed  = 7
)

type point struct{ x, y float64 }

// node is a sway node: it rotates its subtree about pivot by
// amp*sin(pi*t/dur + phase).
type node struct {
	parent int // -1 for the root
	pivot  point
	amp    float64
	dur    float64
	phase  float64
}

type kind uint8

const (
	kPoly kind = iota // filled polygon
	kStem             // polyline tapering w0 -> w1
	kLine             // 1 px polyline
	kDot              // single pixel
)

type shape struct {
	kind       kind
	node       int
	start, end int // range in the builder's point arrays
	key        Key
	w0, w1     float64
}

var glyphKeys = map[Key]bool{Culm: true, Node: true, LeafA: true, LeafB: true, LeafAHi: true, LeafBHi: true}

var (
	petalOutline = []point{{0, 0}, {-7, -4}, {-11, -12}, {-9, -20}, {-4, -23}, {0, -20},
		{4, -23}, {9, -20}, {11, -12}, {7, -4}}
	petalTip = []point{{-5, -16}, {0, -14}, {5, -16}, {3, -22}, {0, -20}, {-3, -22}}
)

func bez2(p0, p1, p2 point, t float64) point {
	u := 1 - t
	return point{u*u*p0.x + 2*u*t*p1.x + t*t*p2.x, u*u*p0.y + 2*u*t*p1.y + t*t*p2.y}
}

func bez3(p0, p1, p2, p3 point, t float64) point {
	u := 1 - t
	a, b, c, d := u*u*u, 3*u*u*t, 3*u*t*t, t*t*t
	return point{a*p0.x + b*p1.x + c*p2.x + d*p3.x, a*p0.y + b*p1.y + c*p2.y + d*p3.y}
}

// sample returns n+1 points of fn over t in [0, 1].
func sample(fn func(t float64) point, n int) []point {
	pts := make([]point, n+1)
	for i := range pts {
		pts[i] = fn(float64(i) / float64(n))
	}
	return pts
}

// angleAt is the tangent direction of a sampled curve at index i.
func angleAt(pts []point, i int) float64 {
	a := pts[max(0, i-1)]
	b := pts[min(len(pts)-1, i+1)]
	return math.Atan2(b.y-a.y, b.x-a.x)
}

func transform(pts []point, rot, scale float64, tx, ty float64) []point {
	c, s := math.Cos(rot)*scale, math.Sin(rot)*scale
	out := make([]point, len(pts))
	for i, p := range pts {
		out[i] = point{c*p.x - s*p.y + tx, s*p.x + c*p.y + ty}
	}
	return out
}

// leafOutline returns the leaf (base at the origin, tip at (74, 0)): a dark
// body and a light tip.
func leafOutline() (body, tip []point) {
	edge := func(sign, t0, t1 float64, n int) []point {
		pts := make([]point, 0, n+1)
		for i := 0; i <= n; i++ {
			t := t0 + (t1-t0)*float64(i)/float64(n)
			u := 1 - t
			pts = append(pts, point{2*u*t*24 + t*t*74, sign * 2 * u * t * 11})
		}
		return pts
	}
	body = append(edge(-1, 0, 1, 5), edge(1, 1, 0, 5)...)
	tip = append(edge(-1, 0.55, 1, 3), edge(1, 1, 0.55, 3)...)
	return body, tip
}

// builder grows the scene tree. The order of random draws within each
// method follows the Python reference.
type builder struct {
	rng      *rand.Rand
	swayK    float64
	nodes    []node
	shapes   []shape
	px, py   []float64
	pn       []int
	blossoms []point
	leafBody []point
	leafTip  []point
}

func (b *builder) rr(lo, hi float64) float64 { return lo + (hi-lo)*b.rng.Float64() }

func (b *builder) newNode(parent int, pivot point, amp, dur float64) int {
	b.nodes = append(b.nodes, node{parent, pivot, amp * b.swayK * deg, dur, b.rng.Float64() * tau})
	return len(b.nodes) - 1
}

func (b *builder) addShape(n int, k kind, pts []point, key Key, w0, w1 float64) {
	start := len(b.px)
	for _, p := range pts {
		b.px, b.py = append(b.px, p.x), append(b.py, p.y)
		b.pn = append(b.pn, n)
	}
	b.shapes = append(b.shapes, shape{k, n, start, len(b.px), key, w0, w1})
}

func (b *builder) leaf(parent int, q point, ang, s float64) {
	ang = math.Atan2(math.Sin(ang)+0.35, math.Cos(ang)) // leaves droop a little
	amp, dur := b.rr(2.5, 5.5), b.rr(3.5, 6.5)
	n := b.newNode(parent, q, amp, dur)
	body, tip := LeafA, LeafAHi
	if b.rng.Float64() >= .5 {
		body, tip = LeafB, LeafBHi
	}
	b.addShape(n, kPoly, transform(b.leafBody, ang, s*boost, q.x, q.y), body, 0, 0)
	b.addShape(n, kPoly, transform(b.leafTip, ang, s*boost, q.x, q.y), tip, 0, 0)
}

func (b *builder) branch(parent int, p point, ang, length, s float64) {
	end := point{p.x + math.Cos(ang)*length, p.y + math.Sin(ang)*length}
	ctrl := point{(p.x + end.x) / 2, (p.y+end.y)/2 + length*0.12 + b.rr(-6, 6)}
	pts := sample(func(t float64) point { return bez2(p, ctrl, end, t) }, 6)
	amp, dur := b.rr(1.4, 2.6), b.rr(8, 12)
	n := b.newNode(parent, p, amp, dur)
	b.addShape(n, kStem, pts, Culm, 2.8*s, 1.1*s)
	for _, l := range []struct{ u, side float64 }{{0.35, 1}, {0.6, -1}, {0.82, 1}} {
		i := int(math.RoundToEven(l.u * 6))
		a := angleAt(pts, i) + l.side*b.rr(28, 50)*deg
		b.leaf(n, pts[i], a, s*b.rr(0.8, 1.15))
	}
	th := angleAt(pts, 6)
	for _, a := range []float64{-38, 0, 36} {
		b.leaf(n, end, th+(a+b.rr(-6, 6))*deg, s*b.rr(0.9, 1.25))
	}
}

func (b *builder) bamboo(p0, p1, p2 point, w0, w1, amp, dur, scale float64) {
	const N = 48
	n := b.newNode(-1, p0, amp, dur)
	pts := sample(func(t float64) point { return bez2(p0, p1, p2, t) }, N)
	b.addShape(n, kStem, pts, Culm, w0, w1)
	side, t := 1.0, 0.05
	for t < 0.97 { // nodes up the culm, branches above 30%
		i := int(math.RoundToEven(t * N))
		p, th := pts[i], angleAt(pts, i)
		k := (w0+(w1-w0)*t)/2 + 1.4
		nx, ny := -math.Sin(th)*k, math.Cos(th)*k
		b.addShape(n, kLine, []point{{p.x + nx, p.y + ny}, {p.x - nx, p.y - ny}}, Node, 0, 0)
		if t > 0.3 && b.rng.Float64() < 0.85 {
			a := th + side*b.rr(40, 64)*deg
			b.branch(n, p, a, b.rr(70, 130)*scale*(1.15-0.6*t), scale)
			side = -side
		}
		t += 0.075
	}
	th := angleAt(pts, N)
	for _, a := range []float64{-30, 0, 28} {
		b.leaf(n, pts[N], th+(a+b.rr(-5, 5))*deg, scale*b.rr(1.0, 1.3))
	}
}

func (b *builder) blossom(parent int, x, y, s float64) {
	amp, dur := b.rr(2, 5), b.rr(5, 8)
	n := b.newNode(parent, point{x, y}, amp, dur)
	rot0 := b.rr(0, 360)
	s *= boost * 1.1
	for _, o := range []struct {
		outline []point
		key     Key
	}{{petalOutline, Pink}, {petalTip, PinkHi}} {
		for k := range 5 {
			b.addShape(n, kPoly, transform(o.outline, (rot0+72*float64(k))*deg, s, x, y), o.key, 0, 0)
		}
	}
	b.addShape(n, kDot, []point{{x, y}}, PinkDk, 0, 0)
	b.blossoms = append(b.blossoms, point{x, y})
}

func (b *builder) twig(parent int, p0 point, ang, length, w float64, level int) {
	end := point{p0.x + math.Cos(ang)*length, p0.y + math.Sin(ang)*length}
	ctrl := point{(p0.x+end.x)/2 + b.rr(-10, 10), (p0.y+end.y)/2 + length*0.18}
	pts := sample(func(t float64) point { return bez2(p0, ctrl, end, t) }, 6)
	amp, dur := b.rr(1.2, 2.4), b.rr(8, 12)
	n := b.newNode(parent, p0, amp, dur)
	b.addShape(n, kStem, pts, Bark, w, w*0.35)
	if level == 0 {
		count := 1
		if b.rng.Float64() < 0.6 {
			count = 2
		}
		for range count {
			i := int(math.RoundToEven(b.rr(0.35, 0.7) * 6))
			side := 1.0
			if b.rng.Float64() < .5 {
				side = -1
			}
			a := angleAt(pts, i) + side*b.rr(30, 55)*deg
			b.twig(n, pts[i], a, length*b.rr(0.4, 0.6), w*0.6, 1)
		}
	}
	blossoms := 2
	if level == 0 {
		blossoms = 3
	}
	for k := range blossoms { // first blossom at the tip, the rest along it
		u, j := 1.0, 0.3
		if k > 0 {
			u, j = b.rr(0.55, 0.95), 1
		}
		i := int(math.RoundToEven(u * 6))
		x := pts[i].x + b.rr(-8, 8)*j
		y := pts[i].y + b.rr(-8, 8)*j
		b.blossom(n, x, y, b.rr(0.6, 1.0))
	}
}

func (b *builder) cherry() {
	p0, p1, p2, p3 := point{-80, 490}, point{110, 520}, point{250, 330}, point{620, 250}
	const N = 28
	pts := sample(func(t float64) point { return bez3(p0, p1, p2, p3, t) }, N)
	n := b.newNode(-1, p0, 0.6, 14)
	b.addShape(n, kStem, pts, Bark, 15, 3.5)
	for i, t := range []float64{0.2, 0.32, 0.45, 0.58, 0.7, 0.8, 0.9} {
		idx := int(math.RoundToEven(t * N))
		side := 1.0
		if i%2 == 1 {
			side = -1
		}
		a := angleAt(pts, idx) + side*b.rr(35, 60)*deg
		b.twig(n, pts[idx], a, b.rr(80, 140)*(1.1-t*0.5), 4.4-t*1.6, 0)
	}
	b.twig(n, pts[N], angleAt(pts, N)+b.rr(-10, 10)*deg, 70, 3, 0)
}

func build() *builder {
	b := &builder{rng: rand.New(rand.NewPCG(buildSeed, buildSeed^0x9e3779b97f4a7c15)), swayK: bambooSway}
	b.leafBody, b.leafTip = leafOutline()
	b.bamboo(point{1400, 980}, point{1405, 620}, point{1300, 230}, 6.5, 2.8, 1.1, 11, 0.85)
	b.bamboo(point{1250, 980}, point{1215, 520}, point{1035, 95}, 9, 3.5, 0.9, 13, 1)
	b.swayK = 1.0
	b.cherry()
	return b
}
