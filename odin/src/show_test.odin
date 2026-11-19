package saver

import "core:strings"
import "core:testing"

// Smoke tests: the show runs through every phase and produces sane frames.
// The test runner tracks allocations and reports leaks for each test.

@(test)
test_cycle_visits_every_phase_and_rotates_palette :: proc(t: ^testing.T) {
	show, err := show_new(80, 48, 0.5, 1.0, nil, 0)
	testing.expect_value(t, err, nil)
	defer show_destroy(show)
	first := show.scene.pal[.S1]
	seen: bit_set[Phase]
	for _ in 0 ..< 20 * 60 {
		c, serr := show_step(show, 1.0 / 20)
		testing.expect_value(t, serr, nil)
		testing.expect(t, c.w == 80 && c.h == 48 && len(c.pix) == 80 * 48 && len(c.mask) == 80 * 48)
		seen += {show.phase}
		if show.cycle == 2 {
			break
		}
	}
	testing.expect_value(t, seen, bit_set[Phase]{.Grow, .Live, .Burn, .Black})
	testing.expect(t, show.scene.pal[.S1] != first, "palette should rotate")
}

@(test)
test_live_frame_has_sun_bamboo_glyphs_and_blocks :: proc(t: ^testing.T) {
	show, err := show_new(120, 70, 24, 9, nil, 0)
	testing.expect_value(t, err, nil)
	defer show_destroy(show)
	c, _ := show_seek(show, .Live, 1.0)
	lit, masked := 0, 0
	for p in c.pix {
		lit += 1 if p != {} else 0
	}
	for m in c.mask {
		masked += 1 if m else 0
	}
	testing.expect(t, lit > 0 && masked > 0 && masked < len(c.mask))
	cells, cerr := cells_make(120, 35)
	testing.expect_value(t, cerr, nil)
	defer cells_destroy(&cells)
	to_cells(c, &cells)
	blocks, glyphs := 0, 0
	for cell in cells.data {
		if cell.ch == HALF {
			blocks += 1
		} else if strings.contains_rune(RAMP[1:], cell.ch) {
			glyphs += 1
		}
	}
	testing.expect(t, blocks > 0, "no half-block cells")
	testing.expect(t, glyphs > 0, "no glyph cells")
}

@(test)
test_burn_ends_black :: proc(t: ^testing.T) {
	show, err := show_new(60, 40, 0.1, 0.5, nil, 0)
	testing.expect_value(t, err, nil)
	defer show_destroy(show)
	c, _ := show_seek(show, .Burn, 1e9) // runs until the phase after burn
	testing.expect_value(t, show.phase, Phase.Black)
	for p in c.pix {
		if p != {} {
			testing.fail_now(t, "image not black after burn")
		}
	}
}

@(test)
test_emitter_only_redraws_changes :: proc(t: ^testing.T) {
	em: Emitter
	defer emitter_destroy(&em)
	cells, err := cells_make(3, 2)
	testing.expect_value(t, err, nil)
	defer cells_destroy(&cells)
	for &c in cells.data {
		c.ch = HALF
	}
	out, _ := emitter_frame(&em, cells)
	testing.expect(t, strings.contains(string(out), "\x1b[2J"), "first frame clears the screen")
	out, _ = emitter_frame(&em, cells)
	testing.expect_value(t, string(out), "\x1b[?2026h\x1b[0m\x1b[?2026l")
	cells.data[1 * 3 + 2].fg = {255, 255, 255}
	out, _ = emitter_frame(&em, cells)
	text := string(out)
	testing.expect(t, strings.count(text, "H") == 1 && strings.contains(text, "\x1b[2;3H"), "one move to row 2, col 3")
	emitter_reset(&em)
	out, _ = emitter_frame(&em, cells)
	testing.expect(t, strings.contains(string(out), "\x1b[2J"), "reset forces a full redraw")
}

@(test)
test_resize_restarts_size_dependent_phase :: proc(t: ^testing.T) {
	show, err := show_new(60, 40, 0.1, 2, nil, 0)
	testing.expect_value(t, err, nil)
	defer show_destroy(show)
	_, _ = show_seek(show, .Burn, 0.2)
	testing.expect_value(t, show.phase, Phase.Burn)
	testing.expect_value(t, show_resize(show, 30, 20), nil)
	testing.expect_value(t, show.phase, Phase.Grow)
	c, _ := show_step(show, 0.05)
	testing.expect(t, c.w == 30 && c.h == 20)
}

@(test)
test_tiny_sizes_do_not_crash :: proc(t: ^testing.T) {
	show, err := show_new(10, 8, 0.1, 0.3, nil, 3)
	testing.expect_value(t, err, nil)
	defer show_destroy(show)
	sizes := [?][2]int{{1, 2}, {2, 2}, {10, 4}, {3, 8}, {200, 112}, {10, 8}}
	for sz in sizes {
		testing.expect_value(t, show_resize(show, sz.x, sz.y), nil)
		cells, cerr := cells_make(sz.x, sz.y / 2)
		testing.expect_value(t, cerr, nil)
		em: Emitter
		for _ in 0 ..< 40 {
			c, _ := show_step(show, 0.1)
			to_cells(c, &cells)
			_, _ = emitter_frame(&em, cells)
		}
		emitter_destroy(&em)
		cells_destroy(&cells)
	}
}

@(test)
test_still_ppm_size :: proc(t: ^testing.T) {
	cells, err := cells_make(4, 3)
	testing.expect_value(t, err, nil)
	defer cells_destroy(&cells)
	for &c in cells.data {
		c = Cell{HALF, {1, 2, 3}, {4, 5, 6}}
	}
	data, derr := cells_to_ppm(cells)
	testing.expect_value(t, derr, nil)
	defer delete(data)
	header := "P6\n32 48\n255\n"
	testing.expect(t, strings.has_prefix(string(data), header))
	testing.expect_value(t, len(data), len(header) + 32 * 48 * 3)
}
