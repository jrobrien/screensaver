package scene

import (
	"fmt"
	"strconv"

	"saver/internal/pix"
)

// Key names a colour slot in a Palette.
type Key int

// Colour keys. S1..S7 are the sun bands, top to bottom.
const (
	Culm Key = iota
	Node
	Bark
	LeafA
	LeafAHi
	LeafB
	LeafBHi
	Pink
	PinkHi
	PinkDk
	S1
	S2
	S3
	S4
	S5
	S6
	S7
	Line
	numKeys
)

// Palette maps colour keys to colours.
type Palette [numKeys]pix.RGB

// Names lists the palettes in rotation order.
var Names = []string{"ember", "moon", "dusk"}

type sunColours struct {
	bands [7]string
	line  string
}

var suns = map[string]sunColours{
	"ember": {[7]string{"#9e1b1b", "#bf3418", "#d4501a", "#e26a24", "#ea8640", "#ee9f66", "#eeb0a0"}, "#f3e9dd"},
	"moon":  {[7]string{"#e9f0f6", "#d3e0ec", "#bccfe1", "#a5bdd5", "#8da9c6", "#7694b5", "#5f7fa3"}, "#e6edf3"},
	"dusk":  {[7]string{"#3c0f22", "#4d152b", "#5e1b33", "#70223a", "#822a42", "#94344b", "#a63f55"}, "#d8c8cf"},
}

var common = map[Key]string{
	Culm: "#d9c35c", Node: "#9b8433", Bark: "#8a5a48",
	LeafA: "#2c7a3a", LeafAHi: "#7ed06c",
	LeafB: "#3f9142", LeafBHi: "#b0e17a",
	Pink: "#f4a9c4", PinkHi: "#fde6ee", PinkDk: "#c43a68",
}

func hex(s string) pix.RGB {
	var c pix.RGB
	for i := range c {
		v, err := strconv.ParseUint(s[1+2*i:3+2*i], 16, 8)
		if err != nil {
			panic("bad palette literal " + s) // compile-time constants only
		}
		c[i] = uint8(v)
	}
	return c
}

// NewPalette returns the named palette.
func NewPalette(name string) (Palette, error) {
	sun, ok := suns[name]
	if !ok {
		return Palette{}, fmt.Errorf("unknown palette %q", name)
	}
	var p Palette
	for k, v := range common {
		p[k] = hex(v)
	}
	for i, b := range sun.bands {
		p[S1+Key(i)] = hex(b)
	}
	p[Line] = hex(sun.line)
	return p, nil
}
