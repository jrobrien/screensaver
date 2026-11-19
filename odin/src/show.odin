package saver

import "base:runtime"

// The show: grow -> live -> burn -> black, then again with the next palette.

Phase :: enum u8 {
	Grow,
	Live,
	Burn,
	Black,
}

BLACK_T :: 1.2

// Per-pixel state of the grow and burn phases.
Effect :: union {
	Grow,
	Burn,
}

Show :: struct {
	w, h:      int,
	live_t:    f64,
	burn_t:    f64,
	palette:   Maybe(Palette_Name), // fixed palette, or nil to rotate
	rng:       Rng,
	scene:     ^Scene,
	cycle:     int,
	clock:     f64, // scene clock: the scene keeps swaying through every phase
	phase:     Phase,
	t0:        f64, // clock value when the phase began
	fx:        Effect,
	allocator: runtime.Allocator,
}

show_new :: proc(
	w, h: int,
	live, burn: f64,
	palette: Maybe(Palette_Name),
	seed: u64,
	allocator := context.allocator,
) -> (
	s: ^Show,
	err: runtime.Allocator_Error,
) {
	s = new(Show, allocator) or_return
	defer if err != nil {
		show_destroy(s)
		s = nil
	}
	s.allocator = allocator
	s.w, s.h = w, h
	s.live_t, s.burn_t = live, burn
	s.palette = palette
	s.rng = rng_make(seed)
	s.scene = scene_new(w, h, allocator) or_return
	start_cycle(s) or_return
	return
}

show_destroy :: proc(s: ^Show) {
	if s == nil {
		return
	}
	clear_effect(s)
	scene_destroy(s.scene, s.allocator)
	free(s, s.allocator)
}

@(private = "file")
clear_effect :: proc(s: ^Show) {
	switch &fx in s.fx {
	case Grow:
		grow_destroy(&fx)
	case Burn:
		burn_destroy(&fx)
	}
	s.fx = nil
}

@(private = "file")
start_cycle :: proc(s: ^Show) -> runtime.Allocator_Error {
	name, fixed := s.palette.?
	if !fixed {
		name = Palette_Name(s.cycle % len(Palette_Name))
	}
	scene_set_palette(s.scene, name)
	s.cycle += 1
	return enter(s, .Grow)
}

@(private = "file")
enter :: proc(s: ^Show, phase: Phase) -> runtime.Allocator_Error {
	clear_effect(s)
	s.phase, s.t0 = phase, s.clock
	#partial switch phase {
	case .Grow:
		s.fx = grow_init(s.w, s.h, &s.rng, allocator = s.allocator) or_return
	case .Burn:
		s.fx = burn_init(s.w, s.h, &s.rng, f32(s.burn_t), s.allocator) or_return
	}
	return nil
}

show_resize :: proc(s: ^Show, w, h: int) -> runtime.Allocator_Error {
	s.w, s.h = w, h
	scene_resize(s.scene, w, h, s.allocator) or_return
	if s.phase == .Grow || s.phase == .Burn { 	// their per-pixel state is size-specific
		return enter(s, .Grow)
	}
	return nil
}

// Advance dt seconds. The returned canvas (image + glyph mask) belongs to the
// scene and is valid until the next step or resize.
show_step :: proc(s: ^Show, dt: f64) -> (c: ^Canvas, err: runtime.Allocator_Error) {
	s.clock += dt
	t := s.clock - s.t0
	c = scene_render(s.scene, s.clock, dt)
	switch s.phase {
	case .Grow:
		fx := &s.fx.(Grow)
		grow_apply(fx, c.pix, f32(t))
		if f64(t) > f64(fx.end) {
			enter(s, .Live) or_return
		}
	case .Live:
		if t > s.live_t {
			enter(s, .Burn) or_return
		}
	case .Burn:
		fx := &s.fx.(Burn)
		burn_apply(fx, &s.rng, c.pix, f32(t))
		if burn_done(fx) {
			enter(s, .Black) or_return
		}
	case .Black:
		for &p in c.pix {
			p = {}
		}
		for &m in c.mask {
			m = false
		}
		if t > BLACK_T {
			start_cycle(s) or_return
		}
	}
	return
}

// Run from the start until `at` seconds into `phase` (or a later phase is
// reached). For stills and tests.
show_seek :: proc(s: ^Show, phase: Phase, at: f64, fps := 20.0) -> (c: ^Canvas, err: runtime.Allocator_Error) {
	for {
		c = show_step(s, 1.0 / fps) or_return
		if s.phase > phase || (s.phase == phase && s.clock - s.t0 >= at) {
			return
		}
	}
}
