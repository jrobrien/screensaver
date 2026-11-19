package saver

import "base:runtime"
import "core:fmt"
import "core:os"

// A still frame as a binary PPM (P6): each cell is 8x16 pixels.
//
// Half-block cells are exact: top 8x8 in fg, bottom 8x8 in bg. A glyph cell
// is bg plus a centred fg rectangle whose size is proportional to its RAMP
// index (0 -> none, 9 -> the full cell).

CELL_W :: 8
CELL_H :: 16

@(private = "file")
ramp_pos :: proc(ch: rune) -> int {
	for r, i in RAMP {
		if r == ch {
			return i
		}
	}
	return 0
}

// Render `cells` to PPM bytes.
cells_to_ppm :: proc(cells: Cells, allocator := context.allocator) -> (data: []byte, err: runtime.Allocator_Error) {
	w, h := cells.cols * CELL_W, cells.rows * CELL_H
	header := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	data = make([]byte, len(header) + w * h * 3, allocator) or_return
	copy(data, header)
	pix := data[len(header):]
	last := len(RAMP) - 1
	for r in 0 ..< cells.rows {
		for c in 0 ..< cells.cols {
			cell := cells.data[r * cells.cols + c]
			idx := ramp_pos(cell.ch)
			// Ink rectangle, centred in the cell.
			iw, ih := CELL_W * idx / last, CELL_H * idx / last
			x0, y0 := (CELL_W - iw) / 2, (CELL_H - ih) / 2
			for y in 0 ..< CELL_H {
				for x in 0 ..< CELL_W {
					col := cell.bg
					switch {
					case cell.ch == HALF:
						col = cell.fg if y < CELL_H / 2 else cell.bg
					case x >= x0 && x < x0 + iw && y >= y0 && y < y0 + ih:
						col = cell.fg
					}
					o := ((r * CELL_H + y) * w + c * CELL_W + x) * 3
					pix[o], pix[o + 1], pix[o + 2] = col.r, col.g, col.b
				}
			}
		}
	}
	return
}

write_still :: proc(path: string, cells: Cells) -> bool {
	data, err := cells_to_ppm(cells)
	if err != nil {
		return false
	}
	defer delete(data)
	return os.write_entire_file(path, data) == nil
}
