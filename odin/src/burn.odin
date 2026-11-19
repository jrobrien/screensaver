package saver

import "base:runtime"
import "core:math"

// Burn-to-ash and its reverse, as per-pixel effects on the scene image.
//
// Burn: a fire front crawls out from a few ignition points. Each pixel goes
//   heat glow -> flame -> char -> grey ash -> black,
// while ash flakes and sparks lift off and drift upward.
// Grow: the scene flashes in, spreading out from the centre.

Vec3 :: [3]f32

FLAME :: [5]Vec3{{255, 244, 190}, {255, 204, 70}, {240, 120, 24}, {178, 48, 12}, {80, 18, 8}}
HEAT :: Vec3{255, 120, 30}
EMBER :: Vec3{190, 70, 16}
ASH :: Vec3{1.0, 0.97, 0.92} // tint applied to grey levels
FLASH :: Vec3{255, 235, 200}

HEAT_T :: 0.6 // seconds of glow before the front arrives
FLAME_T :: 0.75 // in flame
CHAR_T :: 1.1 // smouldering
ASH_T :: 1.6 // grey ash, then black
GROW_FLASH_T :: 0.8

to_vec :: #force_inline proc(c: Rgb) -> Vec3 {
	return {f32(c.r), f32(c.g), f32(c.b)}
}

to_rgb :: #force_inline proc(v: Vec3) -> Rgb {
	return {u8(clamp(v.r, 0, 255)), u8(clamp(v.g, 0, 255)), u8(clamp(v.b, 0, 255))}
}

// Smooth noise in [0, 1]: a random grid every `cell` pixels, bilinearly interpolated.
@(private = "file")
value_noise :: proc(rng: ^Rng, w, h, cell: int, allocator := context.allocator) -> (out: []f32, err: runtime.Allocator_Error) {
	gh, gw := h / cell + 2, w / cell + 2
	grid := make([]f32, gh * gw, allocator) or_return
	defer delete(grid, allocator)
	for &g in grid {
		g = f32(rng_float(rng))
	}
	out = make([]f32, w * h, allocator) or_return
	sy := f32(gh - 1) - 0.001
	sx := f32(gw - 1) - 0.001
	for y in 0 ..< h {
		ys := sy * f32(y) / f32(max(h - 1, 1))
		y0 := int(ys)
		fy := ys - f32(y0)
		for x in 0 ..< w {
			xs := sx * f32(x) / f32(max(w - 1, 1))
			x0 := int(xs)
			fx := xs - f32(x0)
			top := grid[y0 * gw + x0] * (1 - fx) + grid[y0 * gw + x0 + 1] * fx
			bot := grid[(y0 + 1) * gw + x0] * (1 - fx) + grid[(y0 + 1) * gw + x0 + 1] * fx
			out[y * w + x] = top * (1 - fy) + bot * fy
		}
	}
	return
}

// FLAME gradient at u in [0, 1].
@(private = "file")
flame :: proc(u: f32) -> Vec3 {
	stops := FLAME
	v := clamp(u, 0, 1) * f32(len(stops) - 1)
	i := min(int(v), len(stops) - 2)
	f := v - f32(i)
	return stops[i] * (1 - f) + stops[i + 1] * f
}

// ---- grow --------------------------------------------------------------------

// Flash-in reveal radiating from the centre.
Grow :: struct {
	reveal:    []f32,
	end:       f32,
	allocator: runtime.Allocator,
}

grow_init :: proc(w, h: int, rng: ^Rng, duration: f32 = 4.0, allocator := context.allocator) -> (g: Grow, err: runtime.Allocator_Error) {
	g.allocator = allocator
	g.reveal = make([]f32, w * h, allocator) or_return
	cx, cy := f32(w) / 2, f32(h) / 2
	dmax := math.sqrt(cx * cx + cy * cy)
	for y in 0 ..< h {
		for x in 0 ..< w {
			dx, dy := f32(x) - cx, f32(y) - cy
			d := math.sqrt(dx * dx + dy * dy)
			r := d / max(dmax, 1) * duration + f32(rng_float(rng)) * 0.9
			g.reveal[y * w + x] = r
			g.end = max(g.end, r)
		}
	}
	g.end += GROW_FLASH_T
	return
}

grow_destroy :: proc(g: ^Grow) {
	delete(g.reveal, g.allocator)
	g^ = {}
}

grow_apply :: proc(g: ^Grow, pix: []Rgb, t: f32) {
	for &p, i in pix {
		age := t - g.reveal[i]
		if age < 0 {
			p = {}
		} else if age < GROW_FLASH_T {
			k := (1 - age / GROW_FLASH_T) * (1 - age / GROW_FLASH_T)
			p = to_rgb(to_vec(p) * (1 - k) + FLASH * k)
		}
	}
}

// ---- burn ----------------------------------------------------------------------

Flake :: struct {
	x, y, vx, vy, age, life: f32,
	spark:                   bool,
}

Burn :: struct {
	w, h:      int,
	ignite:    []f32, // per pixel: when the front arrives
	grain:     []f32, // per pixel: fixed ash brightness variation
	flakes:    [dynamic]Flake,
	end:       f32,
	t_prev:    f32,
	allocator: runtime.Allocator,
}

burn_init :: proc(w, h: int, rng: ^Rng, duration: f32, allocator := context.allocator) -> (b: Burn, err: runtime.Allocator_Error) {
	b.w, b.h, b.allocator = w, h, allocator
	b.flakes.allocator = allocator
	b.ignite = make([]f32, w * h, allocator) or_return
	defer if err != nil {
		burn_destroy(&b)
	}
	b.grain = make([]f32, w * h, allocator) or_return

	// Ignition points in the lower half of the screen.
	Point :: [2]f32
	pts: [3]Point
	count := rng_int(rng, 2, 3)
	for i in 0 ..< count {
		pts[i] = {f32(rng_range(rng, 0.1, 0.9)) * f32(w), f32(rng_range(rng, 0.55, 1.0)) * f32(h)}
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			d := f32(math.INF_F32)
			for p in pts[:count] {
				dx, dy := f32(x) - p.x, f32(y) - p.y
				d = min(d, math.sqrt(dx * dx + dy * dy))
			}
			b.ignite[y * w + x] = d
		}
	}
	size := f32(max(w, h))
	coarse := value_noise(rng, w, h, 7, allocator) or_return // ragged front
	defer delete(coarse, allocator)
	fine := value_noise(rng, w, h, 2, allocator) or_return
	defer delete(fine, allocator)
	lo, hi := f32(math.INF_F32), f32(-math.INF_F32)
	for &d, i in b.ignite {
		d += (coarse[i] - 0.5) * 0.22 * size + (fine[i] - 0.5) * 0.04 * size
		lo = min(lo, d)
		hi = max(hi, d)
	}
	span := max(hi - lo, 1e-6)
	latest := f32(0)
	for &d in b.ignite {
		d = (d - lo) / span * duration + f32(rng_float(rng)) * 0.25
		latest = max(latest, d)
	}
	for &g in b.grain {
		g = f32(rng_float(rng))
	}
	b.end = latest + FLAME_T + CHAR_T + ASH_T + 3.0 // + time for flakes to clear
	return
}

burn_destroy :: proc(b: ^Burn) {
	delete(b.ignite, b.allocator)
	delete(b.grain, b.allocator)
	delete(b.flakes)
	b^ = {}
}

burn_done :: proc(b: ^Burn) -> bool {
	return b.t_prev > b.end
}

@(private = "file")
spawn :: proc(b: ^Burn, rng: ^Rng, p: f64, vx_mean, vx_sd, vy_lo, vy_hi, life_lo, life_hi: f64, spark: bool, x, y: int) {
	if rng_float(rng) >= p {
		return
	}
	append(
		&b.flakes,
		Flake {
			x = f32(x),
			y = f32(y),
			vx = f32(rng_normal(rng, vx_mean, vx_sd)),
			vy = -f32(rng_range(rng, vy_lo, vy_hi)),
			life = f32(rng_range(rng, life_lo, life_hi)),
			spark = spark,
		},
	)
}

@(private = "file")
move_and_draw_flakes :: proc(b: ^Burn, pix: []Rgb, dt: f32) {
	kept := 0
	for f in b.flakes {
		f := f
		f.age += dt
		f.x += (f.vx + math.sin(f.age * 3 + f.y) * 3) * dt
		f.y += f.vy * dt
		if f.age >= f.life || f.y < -2 {
			continue
		}
		b.flakes[kept] = f
		kept += 1
		x, y := int(f.x), int(f.y)
		if f.x < 0 || f.y < 0 || x >= b.w || y >= b.h {
			continue
		}
		life := 1 - f.age / f.life
		col: Vec3 = ASH * (150 * life)
		if f.spark {
			col = {255 * life, 140 * life * life, 30 * life * life * life}
		}
		under := &pix[y * b.w + x]
		u := to_vec(under^)
		if col.r + col.g + col.b > u.r + u.g + u.b {
			under^ = to_rgb(col)
		}
	}
	resize(&b.flakes, kept)
}

// The burn at t seconds after the start, applied to `pix`.
burn_apply :: proc(b: ^Burn, rng: ^Rng, pix: []Rgb, t: f32) {
	dt, t0 := t - b.t_prev, b.t_prev
	b.t_prev = t
	ash_start :: FLAME_T + CHAR_T
	for &p, i in pix {
		age := t - b.ignite[i]
		switch {
		case age <= -HEAT_T:
		case age < 0:
			k := (1 + age / HEAT_T) * 0.55
			p = to_rgb(to_vec(p) * (1 - k) + HEAT * k)
		case age < FLAME_T:
			u := age / FLAME_T * 0.9 + (f32(rng_float(rng)) - 0.5) * 0.5
			p = to_rgb(flame(u))
		case age < ash_start:
			c := (age - FLAME_T) / CHAR_T
			if f32(rng_float(rng)) < 0.10 * (1 - c) {
				p = to_rgb(EMBER * (1 - c))
			} else {
				p = to_rgb(to_vec(p) * 0.22 * (1 - c))
			}
		case age < ash_start + ASH_T:
			grey := 112 * (1 - (age - ash_start) / ASH_T) * (0.65 + 0.35 * b.grain[i])
			p = to_rgb(ASH * grey)
		case:
			p = {}
		}
	}
	// Flakes: ash where the char turns to ash, sparks as the front passes.
	for i in 0 ..< len(pix) {
		x, y := i % b.w, i / b.w
		ash_at := b.ignite[i] + ash_start
		if ash_at > t0 && ash_at <= t {
			spawn(b, rng, 0.45, 2.5, 3, 2, 9, 1.5, 4.0, false, x, y)
		}
		if b.ignite[i] > t0 && b.ignite[i] <= t {
			spawn(b, rng, 0.06, 2, 4, 6, 18, 0.6, 1.8, true, x, y)
		}
	}
	move_and_draw_flakes(b, pix, dt)
}
