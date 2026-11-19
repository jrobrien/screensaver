package saver

// Colour palettes, taken from the Sakura & Bamboo artifact. Each palette
// changes the sun's seven bands and the ridge line; every other colour is
// shared.

Rgb :: [3]u8

// Every colour a shape can use. `Palette` is an enum-indexed array of these.
Colour_Key :: enum u8 {
	Culm,
	Node,
	Bark,
	Leaf_A,
	Leaf_A_Hi,
	Leaf_B,
	Leaf_B_Hi,
	Pink,
	Pink_Hi,
	Pink_Dk,
	S1,
	S2,
	S3,
	S4,
	S5,
	S6,
	S7,
	Line,
}

Palette :: [Colour_Key]Rgb

Palette_Name :: enum u8 {
	Ember,
	Moon,
	Dusk,
}

// Keys whose pixels are drawn as glyphs (the bamboo).
GLYPH_KEYS :: bit_set[Colour_Key]{.Culm, .Node, .Leaf_A, .Leaf_B, .Leaf_A_Hi, .Leaf_B_Hi}

SUN_BANDS_KEYS :: [7]Colour_Key{.S1, .S2, .S3, .S4, .S5, .S6, .S7}

@(private = "file")
hex :: proc(v: u32) -> Rgb {
	return {u8(v >> 16), u8(v >> 8), u8(v)}
}

@(private = "file")
Sun :: struct {
	bands: [7]u32,
	line:  u32,
}

@(private = "file")
SUNS := [Palette_Name]Sun {
	.Ember = {{0x9e1b1b, 0xbf3418, 0xd4501a, 0xe26a24, 0xea8640, 0xee9f66, 0xeeb0a0}, 0xf3e9dd},
	.Moon  = {{0xe9f0f6, 0xd3e0ec, 0xbccfe1, 0xa5bdd5, 0x8da9c6, 0x7694b5, 0x5f7fa3}, 0xe6edf3},
	.Dusk  = {{0x3c0f22, 0x4d152b, 0x5e1b33, 0x70223a, 0x822a42, 0x94344b, 0xa63f55}, 0xd8c8cf},
}

// The palette `name`: shared colours plus that palette's sun bands and line.
palette_get :: proc(name: Palette_Name) -> (pal: Palette) {
	pal[.Culm] = hex(0xd9c35c)
	pal[.Node] = hex(0x9b8433)
	pal[.Bark] = hex(0x8a5a48)
	pal[.Leaf_A] = hex(0x2c7a3a)
	pal[.Leaf_A_Hi] = hex(0x7ed06c)
	pal[.Leaf_B] = hex(0x3f9142)
	pal[.Leaf_B_Hi] = hex(0xb0e17a)
	pal[.Pink] = hex(0xf4a9c4)
	pal[.Pink_Hi] = hex(0xfde6ee)
	pal[.Pink_Dk] = hex(0xc43a68)
	sun := SUNS[name]
	for key, i in SUN_BANDS_KEYS {
		pal[key] = hex(sun.bands[i])
	}
	pal[.Line] = hex(sun.line)
	return
}
