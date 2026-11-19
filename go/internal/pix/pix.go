// Package pix holds the pixel buffer shared by the scene, the effects and
// the renderer.
package pix

// RGB is one pixel.
type RGB [3]uint8

// Image is a W x H buffer of packed RGB bytes, row-major.
type Image struct {
	W, H int
	Pix  []uint8
}

// New returns a black image.
func New(w, h int) *Image {
	return &Image{W: w, H: h, Pix: make([]uint8, w*h*3)}
}

// At returns the pixel at (x, y).
func (m *Image) At(x, y int) RGB {
	i := (y*m.W + x) * 3
	return RGB{m.Pix[i], m.Pix[i+1], m.Pix[i+2]}
}

// Set stores a pixel at (x, y).
func (m *Image) Set(x, y int, c RGB) {
	i := (y*m.W + x) * 3
	m.Pix[i], m.Pix[i+1], m.Pix[i+2] = c[0], c[1], c[2]
}

// CopyFrom copies src, which must have the same size.
func (m *Image) CopyFrom(src *Image) { copy(m.Pix, src.Pix) }

// Clear sets every pixel to black.
func (m *Image) Clear() { clear(m.Pix) }
