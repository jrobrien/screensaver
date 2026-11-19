// Package show runs the phase machine: grow -> live -> burn -> black, then
// again with the next palette.
package show

import (
	"math/rand/v2"

	"saver/internal/burn"
	"saver/internal/pix"
	"saver/internal/scene"
)

// Phase is a stage of the show.
type Phase int

// The phases, in order.
const (
	Grow Phase = iota
	Live
	Burn
	Black
)

var phaseNames = [...]string{"grow", "live", "burn", "black"}

func (p Phase) String() string { return phaseNames[p] }

// ParsePhase converts a name to a Phase.
func ParsePhase(s string) (Phase, bool) {
	for i, n := range phaseNames {
		if n == s {
			return Phase(i), true
		}
	}
	return 0, false
}

const (
	blackT       = 1.2
	growDuration = 4.0
)

// Config sets the show's timing and palette.
type Config struct {
	Live    float64 // seconds of scene before the burn
	Burn    float64 // seconds for the fire front to cross
	Palette string  // fixed palette, or "" to rotate
	Seed    uint64
}

// effect is the per-pixel state of the grow and burn phases.
type effect interface {
	Apply(img *pix.Image, t float64)
}

// Show is the whole animation.
type Show struct {
	cfg    Config
	w, h   int
	rng    *rand.Rand
	scene  *scene.Scene
	cycle  int
	clock  float64 // scene clock: the scene keeps swaying through every phase
	phase  Phase
	t0     float64
	grow   *burn.Grow
	burn   *burn.Burn
	effect effect
}

// New starts a show on a w x h pixel image.
func New(w, h int, cfg Config) (*Show, error) {
	s := &Show{cfg: cfg, w: w, h: h, scene: scene.New(w, h)}
	s.rng = rand.New(rand.NewPCG(cfg.Seed, cfg.Seed^0x2545f4914f6cdd1d))
	if err := s.startCycle(); err != nil {
		return nil, err
	}
	return s, nil
}

// Phase returns the current phase.
func (s *Show) Phase() Phase { return s.phase }

// Cycle counts the cycles started so far.
func (s *Show) Cycle() int { return s.cycle }

// Scene returns the underlying scene.
func (s *Show) Scene() *scene.Scene { return s.scene }

// Elapsed is the time spent in the current phase.
func (s *Show) Elapsed() float64 { return s.clock - s.t0 }

func (s *Show) startCycle() error {
	name := s.cfg.Palette
	if name == "" {
		name = scene.Names[s.cycle%len(scene.Names)]
	}
	if err := s.scene.SetPalette(name); err != nil {
		return err
	}
	s.cycle++
	s.enter(Grow)
	return nil
}

func (s *Show) enter(p Phase) {
	s.phase, s.t0, s.effect = p, s.clock, nil
	switch p {
	case Grow:
		s.grow = burn.NewGrow(s.w, s.h, s.rng, growDuration)
		s.effect = s.grow
	case Burn:
		s.burn = burn.NewBurn(s.w, s.h, s.rng, s.cfg.Burn)
		s.effect = s.burn
	}
}

// Resize changes the pixel size. Grow and burn restart as grow, since their
// per-pixel state is size-specific.
func (s *Show) Resize(w, h int) {
	s.w, s.h = w, h
	s.scene.Resize(w, h)
	if s.phase == Grow || s.phase == Burn {
		s.enter(Grow)
	}
}

// Step advances dt seconds and returns the frame: an image and a glyph mask.
// Both are owned by the show and valid until the next Step.
func (s *Show) Step(dt float64) (*pix.Image, []bool) {
	s.clock += dt
	t := s.Elapsed()
	img, mask := s.scene.Render(s.clock, dt)
	switch s.phase {
	case Grow:
		s.grow.Apply(img, t)
		if t > s.grow.End() {
			s.enter(Live)
		}
	case Live:
		if t > s.cfg.Live {
			s.enter(Burn)
		}
	case Burn:
		s.burn.Apply(img, t)
		if s.burn.Done() {
			s.enter(Black)
		}
	case Black:
		img.Clear()
		clear(mask)
		if t > blackT {
			// The palette name was validated by New, so this cannot fail.
			_ = s.startCycle()
		}
	}
	return img, mask
}

// Seek steps at 1/20 s from the start until at seconds into phase, or until
// a later phase is reached. It is for stills and tests.
func (s *Show) Seek(phase Phase, at float64) (*pix.Image, []bool) {
	const dt = 1.0 / 20
	for {
		img, mask := s.Step(dt)
		if s.phase > phase || (s.phase == phase && s.Elapsed() >= at) {
			return img, mask
		}
	}
}
