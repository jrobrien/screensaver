package saver

import "base:runtime"
import "core:math"

// Sakura & Bamboo, drawn into a low-resolution pixel buffer.
//
// The geometry lives in a 1600x900 "virtual" space. It is built once as a
// tree of sway nodes, each holding shapes; every frame the tree is evaluated
// into affine matrices, all points are mapped to pixels, and the shapes are
// rasterised (no antialiasing) into the colour image and the glyph mask.

VW :: 1600.0
VH :: 900.0
DEG :: math.PI / 180

BOOST :: 1.35 // leaves and blossoms drawn larger than the SVG's
BAMBOO_SWAY :: 1.6 // bamboo sways more than the blossom branch

SUN_C :: [2]f64{800, 450}
SUN_R :: 250.0
HALO_R0 :: 236.0
HALO_R1 :: 430.0

// Top virtual y of each sun band, matching SUN_BANDS_KEYS.
SUN_BAND_TOPS :: [7]f64{200, 350, 420, 480, 535, 585, 640}

RIDGES :: [3][]([2]f64) {
	{{330, 770}, {450, 700}, {525, 742}, {640, 610}, {744, 750}},
	{{580, 790}, {710, 700}, {780, 748}, {880, 655}, {1000, 770}, {1060, 742}, {1190, 800}},
	{{240, 810}, {370, 745}, {460, 800}, {560, 760}, {660, 815}},
}

BAYER4 :: [4][4]int{{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}}

PETAL :: [10][2]f64{{0, 0}, {-7, -4}, {-11, -12}, {-9, -20}, {-4, -23}, {0, -20}, {4, -23}, {9, -20}, {11, -12}, {7, -4}}
PETAL_TIP :: [6][2]f64{{-5, -16}, {0, -14}, {5, -16}, {3, -22}, {0, -20}, {-3, -22}}

SCENE_SEED :: 20261118

// A sway node rotates its subtree about `pivot` by amp*sin(pi*t/dur + phase).
Node :: struct {
	parent: int, // -1 for a root
	pivot:  [2]f64,
	amp:    f64, // radians
	dur:    f64,
	phase:  f64,
}

Shape_Kind :: enum u8 {
	Poly, // filled
	Stem, // polyline whose width tapers w0 -> w1
	Line, // 1 px polyline
	Dot,
}

Shape :: struct {
	kind:       Shape_Kind,
	start, end: int, // range in Scene.pts
	key:        Colour_Key,
	w0, w1:     f64,
}

// Affine map: x' = a*x + c*y + e, y' = b*x + d*y + f.
Mat :: struct {
	a, b, c, d, e, f: f64,
}

Petal :: struct {
	x, y, depth, vy, phase, flip, flip_rate, age: f64,
}

PETAL_COUNT :: 48

Falling_Petals :: struct {
	rng:    Rng,
	petals: [PETAL_COUNT]Petal,
}

Scene :: struct {
	// geometry, built once
	nodes:         [dynamic]Node,
	shapes:        [dynamic]Shape,
	pts:           [dynamic][2]f64,
	pt_node:       [dynamic]int,
	blossom_spots: [dynamic][2]f64,
	mats:          []Mat, // scratch: one per node
	world:         []([2]f64), // scratch: one per point
	petals:        Falling_Petals,

	// fit to the pixel size
	w, h:          int,
	s, ox, oy:     f64,

	pal:           Palette,
	base:          Canvas, // static backdrop
	base_ok:       bool,
	frame:         Canvas, // the output of render()

	// build state
	rng:           Rng,
	sway_k:        f64,
	leaf_body:     [12][2]f64,
	leaf_tip:      [8][2]f64,
}

// ---- small geometry helpers ----------------------------------------------

bez2 :: proc(p0, p1, p2: [2]f64, t: f64) -> [2]f64 {
	u := 1 - t
	return u * u * p0 + 2 * u * t * p1 + t * t * p2
}

bez3 :: proc(p0, p1, p2, p3: [2]f64, t: f64) -> [2]f64 {
	u := 1 - t
	return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
}

// Tangent direction of a sampled curve at index i.
angle_at :: proc(pts: [][2]f64, i: int) -> f64 {
	a := pts[max(0, i - 1)]
	b := pts[min(len(pts) - 1, i + 1)]
	return math.atan2(b.y - a.y, b.x - a.x)
}

// Rotate by `rot`, scale, then translate; writes into `buf` and returns the used part.
transform :: proc(buf: [][2]f64, pts: [][2]f64, rot, scale, tx, ty: f64) -> [][2]f64 {
	c, s := math.cos(rot) * scale, math.sin(rot) * scale
	for p, i in pts {
		buf[i] = {c * p.x - s * p.y + tx, s * p.x + c * p.y + ty}
	}
	return buf[:len(pts)]
}

round_int :: proc(v: f64) -> int {
	return int(math.round(v))
}

// Leaf (base at origin, tip at (74, 0)): a dark body and a light tip.
@(private = "file")
leaf_outline :: proc(body: ^[12][2]f64, tip: ^[8][2]f64) {
	edge :: proc(dst: [][2]f64, sign, t0, t1: f64) {
		n := len(dst) - 1
		for i in 0 ..= n {
			t := t0 + (t1 - t0) * f64(i) / f64(n)
			u := 1 - t
			dst[i] = {2 * u * t * 24 + t * t * 74, sign * 2 * u * t * 11}
		}
	}
	edge(body[0:6], -1, 0, 1)
	edge(body[6:12], 1, 1, 0)
	edge(tip[0:4], -1, 0.55, 1)
	edge(tip[4:8], 1, 1, 0.55)
}

// ---- building the tree -----------------------------------------------------

@(private = "file")
rr :: proc(s: ^Scene, a, b: f64) -> f64 {
	return rng_range(&s.rng, a, b)
}

@(private = "file")
add_node :: proc(s: ^Scene, parent: int, pivot: [2]f64, amp, dur: f64) -> int {
	phase := rng_float(&s.rng) * math.TAU
	append(&s.nodes, Node{parent, pivot, amp * s.sway_k * DEG, dur, phase})
	return len(s.nodes) - 1
}

@(private = "file")
add_shape :: proc(s: ^Scene, node: int, kind: Shape_Kind, pts: [][2]f64, key: Colour_Key, w0 := 0.0, w1 := 0.0) {
	start := len(s.pts)
	append(&s.pts, ..pts)
	for _ in pts {
		append(&s.pt_node, node)
	}
	append(&s.shapes, Shape{kind, start, len(s.pts), key, w0, w1})
}

@(private = "file")
add_leaf :: proc(s: ^Scene, parent: int, q: [2]f64, angle, size: f64) {
	ang := math.atan2(math.sin(angle) + 0.35, math.cos(angle)) // leaves droop a little
	amp := rr(s, 2.5, 5.5)
	dur := rr(s, 3.5, 6.5)
	n := add_node(s, parent, q, amp, dur)
	a_side := rng_float(&s.rng) < 0.5
	buf: [16][2]f64
	add_shape(s, n, .Poly, transform(buf[:], s.leaf_body[:], ang, size * BOOST, q.x, q.y), .Leaf_A if a_side else .Leaf_B)
	add_shape(s, n, .Poly, transform(buf[:], s.leaf_tip[:], ang, size * BOOST, q.x, q.y), .Leaf_A_Hi if a_side else .Leaf_B_Hi)
}

@(private = "file")
add_branch :: proc(s: ^Scene, parent: int, p: [2]f64, ang, length, size: f64) {
	end := p + {math.cos(ang), math.sin(ang)} * length
	ctrl := (p + end) / 2
	ctrl.y += length * 0.12 + rr(s, -6, 6)
	pts: [7][2]f64
	for i in 0 ..< 7 {
		pts[i] = bez2(p, ctrl, end, f64(i) / 6)
	}
	amp := rr(s, 1.4, 2.6)
	dur := rr(s, 8, 12)
	n := add_node(s, parent, p, amp, dur)
	add_shape(s, n, .Stem, pts[:], .Culm, 2.8 * size, 1.1 * size)
	Spot :: struct {
		u:    f64,
		side: f64,
	}
	for sp in ([3]Spot{{0.35, 1}, {0.6, -1}, {0.82, 1}}) {
		i := round_int(sp.u * 6)
		a := angle_at(pts[:], i) + sp.side * rr(s, 28, 50) * DEG
		add_leaf(s, n, pts[i], a, size * rr(s, 0.8, 1.15))
	}
	th := angle_at(pts[:], 6)
	for a in ([3]f64{-38, 0, 36}) {
		jitter := rr(s, -6, 6)
		add_leaf(s, n, end, th + (a + jitter) * DEG, size * rr(s, 0.9, 1.25))
	}
}

@(private = "file")
add_bamboo :: proc(s: ^Scene, p0, p1, p2: [2]f64, w0, w1, amp, dur, scale: f64) {
	N :: 48
	n := add_node(s, -1, p0, amp, dur)
	pts: [N + 1][2]f64
	for i in 0 ..= N {
		pts[i] = bez2(p0, p1, p2, f64(i) / N)
	}
	add_shape(s, n, .Stem, pts[:], .Culm, w0, w1)
	side, t := 1.0, 0.05
	for t < 0.97 { 	// nodes up the culm, branches above 30%
		i := round_int(t * N)
		p, th := pts[i], angle_at(pts[:], i)
		k := (w0 + (w1 - w0) * t) / 2 + 1.4
		nx, ny := -math.sin(th) * k, math.cos(th) * k
		band := [2][2]f64{{p.x + nx, p.y + ny}, {p.x - nx, p.y - ny}}
		add_shape(s, n, .Line, band[:], .Node)
		if t > 0.3 && rng_float(&s.rng) < 0.85 {
			a := th + side * rr(s, 40, 64) * DEG
			add_branch(s, n, p, a, rr(s, 70, 130) * scale * (1.15 - 0.6 * t), scale)
			side = -side
		}
		t += 0.075
	}
	th := angle_at(pts[:], N)
	for a in ([3]f64{-30, 0, 28}) {
		jitter := rr(s, -5, 5)
		add_leaf(s, n, pts[N], th + (a + jitter) * DEG, scale * rr(s, 1.0, 1.3))
	}
}

@(private = "file")
add_blossom :: proc(s: ^Scene, parent: int, x, y, size: f64) {
	amp := rr(s, 2, 5)
	dur := rr(s, 5, 8)
	n := add_node(s, parent, {x, y}, amp, dur)
	rot0 := rr(s, 0, 360)
	sz := size * BOOST * 1.1
	petal := PETAL
	tip := PETAL_TIP
	buf: [16][2]f64
	for k in 0 ..< 5 {
		add_shape(s, n, .Poly, transform(buf[:], petal[:], (rot0 + 72 * f64(k)) * DEG, sz, x, y), .Pink)
	}
	for k in 0 ..< 5 {
		add_shape(s, n, .Poly, transform(buf[:], tip[:], (rot0 + 72 * f64(k)) * DEG, sz, x, y), .Pink_Hi)
	}
	dot := [1][2]f64{{x, y}}
	add_shape(s, n, .Dot, dot[:], .Pink_Dk)
	append(&s.blossom_spots, [2]f64{x, y})
}

@(private = "file")
add_twig :: proc(s: ^Scene, parent: int, p0: [2]f64, ang, length, w: f64, level: int) {
	end := p0 + {math.cos(ang), math.sin(ang)} * length
	ctrl := (p0 + end) / 2
	ctrl.x += rr(s, -10, 10)
	ctrl.y += length * 0.18
	pts: [7][2]f64
	for i in 0 ..< 7 {
		pts[i] = bez2(p0, ctrl, end, f64(i) / 6)
	}
	amp := rr(s, 1.2, 2.4)
	dur := rr(s, 8, 12)
	n := add_node(s, parent, p0, amp, dur)
	add_shape(s, n, .Stem, pts[:], .Bark, w, w * 0.35)
	if level == 0 {
		count := 2 if rng_float(&s.rng) < 0.6 else 1
		for _ in 0 ..< count {
			i := round_int(rr(s, 0.35, 0.7) * 6)
			side := -1.0 if rng_float(&s.rng) < 0.5 else 1.0
			a := angle_at(pts[:], i) + side * rr(s, 30, 55) * DEG
			add_twig(s, n, pts[i], a, length * rr(s, 0.4, 0.6), w * 0.6, 1)
		}
	}
	for k in 0 ..< (3 if level == 0 else 2) { 	// first blossom at the tip, the rest along it
		i := 6 if k == 0 else round_int(rr(s, 0.55, 0.95) * 6)
		j := 0.3 if k == 0 else 1.0
		dx := rr(s, -8, 8) * j
		dy := rr(s, -8, 8) * j
		add_blossom(s, n, pts[i].x + dx, pts[i].y + dy, rr(s, 0.6, 1.0))
	}
}

@(private = "file")
add_cherry :: proc(s: ^Scene) {
	P0, P1, P2, P3 :: [2]f64{-80, 490}, [2]f64{110, 520}, [2]f64{250, 330}, [2]f64{620, 250}
	N :: 28
	pts: [N + 1][2]f64
	for i in 0 ..= N {
		pts[i] = bez3(P0, P1, P2, P3, f64(i) / N)
	}
	n := add_node(s, -1, P0, 0.6, 14)
	add_shape(s, n, .Stem, pts[:], .Bark, 15, 3.5)
	for t, i in ([7]f64{0.2, 0.32, 0.45, 0.58, 0.7, 0.8, 0.9}) {
		idx := round_int(t * N)
		side := -1.0 if i % 2 == 1 else 1.0
		a := angle_at(pts[:], idx) + side * rr(s, 35, 60) * DEG
		add_twig(s, n, pts[idx], a, rr(s, 80, 140) * (1.1 - t * 0.5), 4.4 - t * 1.6, 0)
	}
	add_twig(s, n, pts[N], angle_at(pts[:], N) + rr(s, -10, 10) * DEG, 70, 3, 0)
}

@(private = "file")
build :: proc(s: ^Scene) {
	s.sway_k = BAMBOO_SWAY
	add_bamboo(s, {1400, 980}, {1405, 620}, {1300, 230}, 6.5, 2.8, 1.1, 11, 0.85)
	add_bamboo(s, {1250, 980}, {1215, 520}, {1035, 95}, 9, 3.5, 0.9, 13, 1)
	s.sway_k = 1.0
	add_cherry(s)
}

// ---- lifecycle -----------------------------------------------------------------

// Build the scene for a width x height pixel image. Free with scene_destroy.
scene_new :: proc(width, height: int, allocator := context.allocator) -> (s: ^Scene, err: runtime.Allocator_Error) {
	s = new(Scene, allocator) or_return
	defer if err != nil {
		scene_destroy(s, allocator)
		s = nil
	}
	s.nodes.allocator = allocator
	s.shapes.allocator = allocator
	s.pts.allocator = allocator
	s.pt_node.allocator = allocator
	s.blossom_spots.allocator = allocator

	s.rng = rng_make(SCENE_SEED)
	leaf_outline(&s.leaf_body, &s.leaf_tip)
	build(s)
	s.mats = make([]Mat, len(s.nodes), allocator) or_return
	s.world = make([][2]f64, len(s.pts), allocator) or_return
	petals_init(&s.petals, s.blossom_spots[:])
	scene_resize(s, width, height, allocator) or_return
	scene_set_palette(s, .Ember)
	return
}

scene_destroy :: proc(s: ^Scene, allocator := context.allocator) {
	if s == nil {
		return
	}
	delete(s.nodes)
	delete(s.shapes)
	delete(s.pts)
	delete(s.pt_node)
	delete(s.blossom_spots)
	delete(s.mats, allocator)
	delete(s.world, allocator)
	canvas_destroy(&s.base, allocator)
	canvas_destroy(&s.frame, allocator)
	free(s, allocator)
}

// Fit the virtual space to width x height pixels, covering it.
scene_resize :: proc(s: ^Scene, width, height: int, allocator := context.allocator) -> runtime.Allocator_Error {
	canvas_destroy(&s.base, allocator)
	canvas_destroy(&s.frame, allocator)
	s.w, s.h = width, height
	s.s = max(f64(width) / VW, f64(height) / VH)
	s.ox = (f64(width) - VW * s.s) / 2
	s.oy = (f64(height) - VH * s.s) / 2
	s.base_ok = false
	s.base = canvas_make(width, height, allocator) or_return
	s.frame = canvas_make(width, height, allocator) or_return
	return nil
}

scene_set_palette :: proc(s: ^Scene, name: Palette_Name) {
	s.pal = palette_get(name)
	s.base_ok = false
}

// ---- backdrop ------------------------------------------------------------------

// Static backdrop: dithered halo, banded sun, ridges.
@(private = "file")
make_base :: proc(s: ^Scene) {
	bayer := BAYER4
	tops := SUN_BAND_TOPS
	keys := SUN_BANDS_KEYS
	for y in 0 ..< s.h {
		vy := (f64(y) + 0.5 - s.oy) / s.s
		for x in 0 ..< s.w {
			vx := (f64(x) + 0.5 - s.ox) / s.s
			r := math.sqrt((vx - SUN_C.x) * (vx - SUN_C.x) + (vy - SUN_C.y) * (vy - SUN_C.y))
			col := Rgb{}
			a := clamp(1 - (r - HALO_R0) / (HALO_R1 - HALO_R0), 0, 1)
			if r >= HALO_R0 && r < HALO_R1 && a > 0.15 && a > (f64(bayer[y % 4][x % 4]) + 0.5) / 16 {
				s3 := s.pal[.S3]
				col = {u8(f64(s3.r) * 0.30), u8(f64(s3.g) * 0.30), u8(f64(s3.b) * 0.30)}
			}
			if r < SUN_R {
				for k := len(tops) - 1; k >= 0; k -= 1 {
					if vy >= tops[k] {
						col = s.pal[keys[k]]
						break
					}
				}
			}
			s.base.pix[y * s.w + x] = col
		}
	}
	ridges := RIDGES
	for ridge in ridges {
		pts: [16][2]f64
		n := len(ridge)
		for p, i in ridge {
			pts[i] = {p.x * s.s + s.ox, p.y * s.s + s.oy}
		}
		pts[n] = {pts[n - 1].x, f64(s.h)}
		pts[n + 1] = {pts[0].x, f64(s.h)}
		fill_poly(&s.base, pts[:n + 2], {0, 0, 0}, false)
		for i in 1 ..< n {
			line_f(&s.base, pts[i - 1], pts[i], s.pal[.Line], false)
		}
	}
	s.base_ok = true
}

// ---- per frame -------------------------------------------------------------------

// All shape points in pixel coordinates at time t, into s.world.
@(private = "file")
eval_world :: proc(s: ^Scene, t: f64) {
	root := Mat{s.s, 0, 0, s.s, s.ox, s.oy}
	for n, i in s.nodes {
		th := n.amp * math.sin(math.PI * t / n.dur + n.phase)
		c, sn := math.cos(th), math.sin(th)
		px, py := n.pivot.x, n.pivot.y
		e := px - c * px + sn * py // rotation about the pivot
		f := py - sn * px - c * py
		P := s.mats[n.parent] if n.parent >= 0 else root
		s.mats[i] = Mat {
			a = P.a * c + P.c * sn,
			b = P.b * c + P.d * sn,
			c = -P.a * sn + P.c * c,
			d = -P.b * sn + P.d * c,
			e = P.a * e + P.c * f + P.e,
			f = P.b * e + P.d * f + P.f,
		}
	}
	for p, i in s.pts {
		m := s.mats[s.pt_node[i]]
		s.world[i] = {m.a * p.x + m.c * p.y + m.e, m.b * p.x + m.d * p.y + m.f}
	}
}

// The scene at time t. The returned canvas (image + glyph mask) is owned by
// the scene and valid until the next render or resize.
scene_render :: proc(s: ^Scene, t, dt: f64) -> ^Canvas {
	if !s.base_ok {
		make_base(s)
	}
	c := &s.frame
	copy(c.pix, s.base.pix)
	for &m in c.mask {
		m = false
	}
	eval_world(s, t)
	for sh in s.shapes {
		pts := s.world[sh.start:sh.end]
		col := s.pal[sh.key]
		glyph := sh.key in GLYPH_KEYS // non-glyph shapes erase the mask they cover
		switch sh.kind {
		case .Poly:
			fill_poly(c, pts, col, glyph)
		case .Stem:
			n := len(pts) - 1
			for i in 0 ..< n {
				w := max(1, round_int((sh.w0 + (sh.w1 - sh.w0) * f64(i) / f64(n)) * s.s))
				thick_line(c, pts[i], pts[i + 1], w, col, glyph)
			}
		case .Line:
			for i in 1 ..< len(pts) {
				line_f(c, pts[i - 1], pts[i], col, glyph)
			}
		case .Dot:
			put(c, int(math.floor(pts[0].x)), int(math.floor(pts[0].y)), col, glyph)
		}
	}
	petals_step(&s.petals, s.blossom_spots[:], dt, t)
	petals_draw(&s.petals, s)
	return c
}

// ---- falling petals ------------------------------------------------------------

@(private = "file")
petal_reset :: proc(fp: ^Falling_Petals, spots: [][2]f64, p: ^Petal, initial: bool) {
	r := &fp.rng
	p.depth = rng_range(r, 0.25, 1)
	if initial { 	// scattered and already faded in
		p.x, p.y, p.age = rng_range(r, -100, 1700), rng_range(r, -40, 940), 99
	} else if len(spots) > 0 && rng_float(r) < 0.6 { 	// shed from a blossom
		sp := spots[rng_int(r, 0, len(spots) - 1)]
		p.x, p.y, p.age = sp.x + rng_range(r, -10, 10), sp.y + rng_range(r, -6, 10), 0
	} else { 	// from above the screen
		p.x, p.y, p.age = rng_range(r, -120, 1500), -40, 0
	}
	p.vy = 14 + p.depth * 34 + rng_range(r, 0, 8)
	p.phase = rng_range(r, 0, math.TAU)
	p.flip = rng_range(r, 0, math.TAU)
	p.flip_rate = rng_range(r, 0.8, 2.4)
}

@(private = "file")
petals_init :: proc(fp: ^Falling_Petals, spots: [][2]f64) {
	fp.rng = rng_make(7)
	for &p in fp.petals {
		petal_reset(fp, spots, &p, true)
	}
}

@(private = "file")
petals_step :: proc(fp: ^Falling_Petals, spots: [][2]f64, dt, t: f64) {
	wind := 14 + 10 * math.sin(t * 0.13) + 5 * math.sin(t * 0.37)
	for &p in fp.petals {
		p.x += (wind * (0.5 + p.depth * 0.7) + math.sin(t * 0.7 + p.phase) * 16) * dt
		p.y += (p.vy + math.sin(t * 1.1 + p.phase * 2) * 6) * dt
		p.flip += p.flip_rate * dt
		p.age += dt
		if p.y > 950 || p.x > 1750 {
			petal_reset(fp, spots, &p, false)
		}
	}
}

// Petals go into the image only; the glyph mask is left alone.
@(private = "file")
petals_draw :: proc(fp: ^Falling_Petals, s: ^Scene) {
	c := &s.frame
	plot :: proc(c: ^Canvas, x, y: int, col: Rgb) {
		if x >= 0 && y >= 0 && x < c.w && y < c.h {
			c.pix[y * c.w + x] = col
		}
	}
	for p in fp.petals {
		x, y := p.x * s.s + s.ox, p.y * s.s + s.oy
		fade := (0.35 + 0.65 * p.depth) * min(1.0, p.age / 1.2)
		base := s.pal[.Pink_Hi] if fade > 0.75 else s.pal[.Pink]
		k := 0.45 + 0.55 * min(1.0, fade * 1.2)
		col := Rgb{u8(f64(base.r) * k), u8(f64(base.g) * k), u8(f64(base.b) * k)}
		ix, iy := int(math.floor(x)), int(math.floor(y))
		plot(c, ix, iy, col)
		if p.depth > 0.6 && abs(math.cos(p.flip)) > 0.5 { 	// near petals are 1-2 pixels wide as they flip
			plot(c, ix + 1, iy, col)
		}
	}
}
