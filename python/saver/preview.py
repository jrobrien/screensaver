"""Rasterise a cell frame to PNG, for checking output without a terminal."""
import subprocess

from PIL import Image, ImageDraw, ImageFont

from .render import HALF


def cells_to_png(ch, fg, bg, path, cw=10, chh=20):
    font_path = subprocess.run(['fc-match', '-f', '%{file}', 'monospace'],
                               capture_output=True, text=True, check=True).stdout
    font = ImageFont.truetype(font_path, chh - 4)
    rows, cols = ch.shape
    im = Image.new('RGB', (cols * cw, rows * chh))
    d = ImageDraw.Draw(im)
    for r in range(rows):
        for c in range(cols):
            x, y = c * cw, r * chh
            code = int(ch[r, c])
            d.rectangle([x, y, x + cw - 1, y + chh - 1], fill=tuple(bg[r, c]))
            if code == HALF:                  # exact half block, not the font's
                d.rectangle([x, y, x + cw - 1, y + chh // 2 - 1], fill=tuple(fg[r, c]))
            elif code != ord(' '):
                d.text((x, y), chr(code), font=font, fill=tuple(fg[r, c]))
    im.save(path)
