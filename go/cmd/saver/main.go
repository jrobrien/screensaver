// Command saver is the Sakura & Bamboo terminal screensaver.
//
//	saver                          run full screen in this terminal; any key quits
//	saver --live 6 --burn 6        shorter cycle
//	saver --still out.png --phase burn --at 4
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"saver/internal/render"
	"saver/internal/scene"
	"saver/internal/show"
	"saver/internal/term"
)

type options struct {
	fps        int
	live, burn float64
	palette    string
	maxSeconds float64
	still      string
	phase      string
	at         float64
	size       string
}

func parseSize(s string) (cols, rows int, err error) {
	a, b, ok := strings.Cut(s, "x")
	if ok {
		cols, err = strconv.Atoi(a)
		if err == nil {
			rows, err = strconv.Atoi(b)
		}
	}
	if !ok || err != nil || cols < 1 || rows < 1 {
		return 0, 0, fmt.Errorf("bad --size %q, want COLSxROWS", s)
	}
	return cols, rows, nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "saver:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	var o options
	fs := flag.NewFlagSet("saver", flag.ContinueOnError)
	fs.IntVar(&o.fps, "fps", 24, "frames per second")
	fs.Float64Var(&o.live, "live", 24, "seconds of scene before the burn")
	fs.Float64Var(&o.burn, "burn", 9, "seconds for the fire front to cross")
	fs.StringVar(&o.palette, "palette", "", "fix the palette: "+strings.Join(scene.Names, "|")+" (default: rotate)")
	fs.Float64Var(&o.maxSeconds, "max-seconds", 0, "exit after this long (testing); 0 = forever")
	fs.StringVar(&o.still, "still", "", "write a still frame to this PNG file and exit (no terminal needed)")
	fs.StringVar(&o.phase, "phase", "live", "grow|live|burn, for --still")
	fs.Float64Var(&o.at, "at", 5, "seconds into --phase, for --still")
	fs.StringVar(&o.size, "size", "200x56", "COLSxROWS, for --still")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if o.fps < 1 {
		return fmt.Errorf("--fps must be positive")
	}
	if o.palette != "" {
		if _, err := scene.NewPalette(o.palette); err != nil {
			return err
		}
	}
	if o.still != "" {
		return runStill(o)
	}
	return runTerminal(o)
}

func runStill(o options) error {
	phase, ok := show.ParsePhase(o.phase)
	if !ok || phase == show.Black {
		return fmt.Errorf("bad --phase %q", o.phase)
	}
	cols, rows, err := parseSize(o.size)
	if err != nil {
		return err
	}
	s, err := show.New(cols, rows*2, show.Config{Live: o.live, Burn: o.burn, Palette: o.palette, Seed: 1})
	if err != nil {
		return err
	}
	img, mask := s.Seek(phase, o.at)
	f, err := os.Create(o.still)
	if err != nil {
		return err
	}
	if err := render.WritePNG(f, render.ToCells(img, mask, nil)); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// pixelSize is the show's pixel size for the terminal: cols x rows*2.
func pixelSize() (int, int) {
	cols, rows, err := term.Size(os.Stdout)
	if err != nil || cols < 1 || rows < 1 {
		return 80, 48
	}
	return cols, rows * 2
}

func runTerminal(o options) (err error) {
	t, err := term.Open(os.Stdin, os.Stdout)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := t.Close(); err == nil {
			err = cerr
		}
	}()

	sig := make(chan os.Signal, 4)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGWINCH)
	defer signal.Stop(sig)
	keys := make(chan struct{}, 1)
	go func() { // any input byte quits
		var b [64]byte
		if n, _ := os.Stdin.Read(b[:]); n > 0 {
			keys <- struct{}{}
		}
	}()

	w, h := pixelSize()
	s, err := show.New(w, h, show.Config{Live: o.live, Burn: o.burn, Palette: o.palette, Seed: uint64(time.Now().UnixNano())})
	if err != nil {
		return err
	}
	var (
		em      render.Emitter
		cells   *render.Cells
		resized bool
		frameT  = time.Second / time.Duration(o.fps)
		start   = time.Now()
		last    = start
	)
	for {
		if resized {
			resized = false
			w, h = pixelSize()
			s.Resize(w, h)
			em.Reset()
		}
		now := time.Now()
		dt := min(0.1, now.Sub(last).Seconds())
		last = now
		img, mask := s.Step(dt)
		cells = render.ToCells(img, mask, cells)
		if _, err := os.Stdout.Write(em.Frame(cells)); err != nil {
			return err
		}
		if o.maxSeconds > 0 && now.Sub(start).Seconds() > o.maxSeconds {
			return nil
		}
		timer := time.NewTimer(max(0, frameT-time.Since(now)))
	wait:
		for {
			select {
			case <-timer.C:
				break wait
			case <-keys:
				timer.Stop()
				return nil
			case sg := <-sig:
				if sg == syscall.SIGWINCH {
					resized = true
					continue
				}
				timer.Stop()
				return nil
			}
		}
	}
}
