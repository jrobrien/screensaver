"""Terminal screensaver.

    python -m saver                                  run full screen in this terminal; any key quits
    python -m saver --live 6 --burn 6                shorter cycle
    python -m saver --png out.png --phase burn --at 4   headless still frame
"""
import argparse
import os
import select
import signal
import sys
import termios
import time
import tty

from . import palettes, render
from .show import Show

ENTER = '\x1b[?1049h\x1b[?25l\x1b[?7l'     # alt screen, hide cursor, no autowrap
LEAVE = '\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l'


def run_terminal(args):
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    resized = True

    def on_winch(*_):
        nonlocal resized
        resized = True

    signal.signal(signal.SIGWINCH, on_winch)
    out = sys.stdout
    emitter = render.Emitter()
    show = None
    frame_t = 1.0 / args.fps
    try:
        tty.setcbreak(fd)
        out.write(ENTER)
        start = last = time.monotonic()
        while True:
            if resized:
                resized = False
                size = os.get_terminal_size()
                w, h = size.columns, size.lines * 2
                if show is None:
                    show = Show(w, h, args.live, args.burn, args.palette)
                else:
                    show.resize(w, h)
                emitter.reset()
            now = time.monotonic()
            dt, last = min(0.1, now - last), now
            img, mask = show.step(dt)
            out.write(emitter.frame(*render.to_cells(img, mask)))
            out.flush()
            if args.max_seconds and now - start > args.max_seconds:
                break
            ready, _, _ = select.select([fd], [], [], max(0.0, frame_t - (time.monotonic() - now)))
            if ready:                                # any key quits
                break
    finally:
        out.write(LEAVE)
        out.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def main(argv=None):
    ap = argparse.ArgumentParser(prog='saver', description='Sakura & Bamboo terminal screensaver')
    ap.add_argument('--fps', type=int, default=24)
    ap.add_argument('--live', type=float, default=24, help='seconds of scene before the burn')
    ap.add_argument('--burn', type=float, default=9, help='seconds for the fire front to cross')
    ap.add_argument('--palette', choices=palettes.NAMES, help='fix the palette (default: rotate)')
    ap.add_argument('--max-seconds', type=float, default=0, help='exit after this long (testing)')
    ap.add_argument('--png', help='write a still frame to this file and exit (no terminal needed)')
    ap.add_argument('--phase', choices=('grow', 'live', 'burn'), default='live', help='for --png')
    ap.add_argument('--at', type=float, default=5.0, help='seconds into --phase, for --png')
    ap.add_argument('--size', default='200x56', help='COLSxROWS, for --png')
    args = ap.parse_args(argv)

    if args.png:
        from .preview import cells_to_png
        cols, rows = (int(v) for v in args.size.split('x'))
        show = Show(cols, rows * 2, args.live, args.burn, args.palette, seed=1)
        cells_to_png(*render.to_cells(*show.seek(args.phase, args.at)), args.png)
    else:
        run_terminal(args)


if __name__ == '__main__':
    main()
