package saver

import "base:runtime"
import "core:fmt"
import "core:math"
@(require)
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Terminal screensaver.
//
//   saver                                 run full screen in this terminal; any key quits
//   saver --live 6 --burn 6               shorter cycle
//   saver --still out.ppm --phase burn --at 4    headless still frame (PPM)
//   saver --bench 300                     time 300 frames at 240x134 pixels

USAGE :: `usage: saver [options]
  --fps N            frames per second (24)
  --live S           seconds of scene before the burn (24)
  --burn S           seconds for the fire front to cross (9)
  --palette NAME     ember, moon or dusk (default: rotate)
  --max-seconds S    exit after this long (0 = forever)
  --still FILE       write one frame as a PPM and exit (no terminal needed)
  --phase NAME       grow, live or burn, for --still (live)
  --at S             seconds into --phase, for --still (5)
  --size COLSxROWS   for --still (200x56)
  --bench N          time N frames at 240x134 pixels and exit
`

Options :: struct {
	fps:         int,
	live, burn:  f64,
	palette:     Maybe(Palette_Name),
	max_seconds: f64,
	still:       string,
	phase:       Phase,
	at:          f64,
	cols, rows:  int,
	bench:       int,
}

// Parse command-line arguments. On failure `msg` says why.
parse_args :: proc(args: []string) -> (o: Options, msg: string, ok: bool) {
	o = Options {
		fps  = 24,
		live = 24,
		burn = 9,
		phase = .Live,
		at   = 5,
		cols = 200,
		rows = 56,
	}
	i := 0
	for i < len(args) {
		flag := args[i]
		i += 1
		if flag == "-h" || flag == "--help" {
			return o, USAGE, false
		}
		if i >= len(args) {
			return o, fmt.tprintf("%s needs a value", flag), false
		}
		val := args[i]
		i += 1
		good := true
		switch flag {
		case "--fps":
			o.fps, good = strconv.parse_int(val)
			good &&= o.fps > 0
		case "--live":
			o.live, good = strconv.parse_f64(val)
		case "--burn":
			o.burn, good = strconv.parse_f64(val)
		case "--max-seconds":
			o.max_seconds, good = strconv.parse_f64(val)
		case "--at":
			o.at, good = strconv.parse_f64(val)
		case "--bench":
			o.bench, good = strconv.parse_int(val)
		case "--still":
			o.still = val
		case "--palette":
			switch val {
			case "ember":
				o.palette = .Ember
			case "moon":
				o.palette = .Moon
			case "dusk":
				o.palette = .Dusk
			case:
				good = false
			}
		case "--phase":
			switch val {
			case "grow":
				o.phase = .Grow
			case "live":
				o.phase = .Live
			case "burn":
				o.phase = .Burn
			case:
				good = false
			}
		case "--size":
			parts := strings.split(val, "x", context.temp_allocator)
			good = len(parts) == 2
			if good {
				cols, rows: int
				cols, good = strconv.parse_int(parts[0])
				if good {
					rows, good = strconv.parse_int(parts[1])
				}
				good &&= cols > 0 && rows > 0
				o.cols, o.rows = cols, rows
			}
		case:
			return o, fmt.tprintf("unknown option %s", flag), false
		}
		if !good {
			return o, fmt.tprintf("bad value '%s' for %s", val, flag), false
		}
	}
	return o, "", true
}

seconds_since :: proc(start: time.Tick) -> f64 {
	return time.duration_seconds(time.tick_since(start))
}

// Headless: one frame to a PPM file.
run_still :: proc(o: Options) -> int {
	show, err := show_new(o.cols, o.rows * 2, o.live, o.burn, o.palette, 1)
	if err != nil {
		fmt.eprintln("out of memory")
		return 1
	}
	defer show_destroy(show)
	canvas, serr := show_seek(show, o.phase, o.at)
	cells, cerr := cells_make(o.cols, o.rows)
	if serr != nil || cerr != nil {
		fmt.eprintln("out of memory")
		return 1
	}
	defer cells_destroy(&cells)
	to_cells(canvas, &cells)
	if !write_still(o.still, cells) {
		fmt.eprintfln("cannot write %s", o.still)
		return 1
	}
	return 0
}

// Time step + to_cells + emit at 240x134 pixels, without a terminal.
run_bench :: proc(o: Options) -> int {
	W, H :: 240, 134
	show, err := show_new(W, H, 1e9, o.burn, o.palette, 1)
	if err != nil {
		return 1
	}
	defer show_destroy(show)
	cells, cerr := cells_make(W, H / 2)
	if cerr != nil {
		return 1
	}
	defer cells_destroy(&cells)
	em: Emitter
	defer emitter_destroy(&em)
	bytes_out := 0
	frame :: proc(show: ^Show, cells: ^Cells, em: ^Emitter, n: ^int) {
		canvas, _ := show_step(show, 1.0 / 24)
		to_cells(canvas, cells)
		out, _ := emitter_frame(em, cells^)
		n^ += len(out)
	}
	for _ in 0 ..< 200 { 	// get past grow
		frame(show, &cells, &em, &bytes_out)
	}
	bytes_out = 0
	start := time.tick_now()
	for _ in 0 ..< o.bench {
		frame(show, &cells, &em, &bytes_out)
	}
	ms := seconds_since(start) * 1000 / f64(o.bench)
	fmt.printfln("%dx%d px, %d frames (live phase): %.3f ms/frame, %d bytes/frame", W, H, o.bench, ms, bytes_out / o.bench)
	return 0
}

run_terminal :: proc(o: Options) -> int {
	term: Terminal
	if !terminal_enter(&term) {
		fmt.eprintln("saver: stdin is not a terminal")
		return 1
	}
	defer terminal_leave(&term)

	show: ^Show
	defer show_destroy(show)
	cells: Cells
	defer cells_destroy(&cells)
	em: Emitter
	defer emitter_destroy(&em)

	seed := u64(time.to_unix_nanoseconds(time.now()))
	frame_t := 1.0 / f64(o.fps)
	request_resize()
	start := time.tick_now()
	last := start
	for !quit_requested() {
		if take_resized() {
			cols, rows, _ := terminal_size()
			if cols < 1 || rows < 1 {
				cols, rows = 80, 24
			}
			err: runtime.Allocator_Error
			if show == nil {
				show, err = show_new(cols, rows * 2, o.live, o.burn, o.palette, seed)
			} else {
				err = show_resize(show, cols, rows * 2)
			}
			cells_destroy(&cells)
			cells, _ = cells_make(cols, rows)
			emitter_reset(&em)
			if err != nil || show == nil || len(cells.data) != cols * rows {
				return 1
			}
		}
		now := time.tick_now()
		dt := min(0.1, time.duration_seconds(time.tick_diff(last, now)))
		last = now
		canvas, err := show_step(show, dt)
		if err != nil {
			return 1
		}
		to_cells(canvas, &cells)
		out: []byte
		out, err = emitter_frame(&em, cells)
		if err != nil {
			return 1
		}
		write_all(out)
		if o.max_seconds > 0 && time.duration_seconds(time.tick_diff(start, now)) > o.max_seconds {
			break
		}
		wait := frame_t - seconds_since(now)
		if wait_for_key(int(math.ceil(max(wait, 0) * 1000))) { 	// any key quits
			break
		}
	}
	return 0
}

run :: proc() -> int {
	o, msg, ok := parse_args(os.args[1:])
	if !ok {
		if msg == USAGE {
			fmt.print(USAGE)
			return 0
		}
		fmt.eprintln(msg)
		fmt.eprint(USAGE)
		return 2
	}
	switch {
	case o.bench > 0:
		return run_bench(o)
	case o.still != "":
		return run_still(o)
	}
	return run_terminal(o)
}

main :: proc() {
	code: int
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		code = run()
		leaked := len(track.allocation_map) + len(track.bad_free_array)
		for _, leak in track.allocation_map {
			fmt.eprintfln("leak: %v bytes at %v", leak.size, leak.location)
		}
		for bad in track.bad_free_array {
			fmt.eprintfln("bad free at %v", bad.location)
		}
		mem.tracking_allocator_destroy(&track)
		if leaked > 0 {
			code = 3
		}
	} else {
		code = run()
	}
	os.exit(code)
}
