"""Run every implementation the same way and measure it.

Each binary runs in a pseudo-terminal of 240x67 cells (240x134 pixels) with
--fps set absurdly high, so it renders flat out through grow, live and burn
for a fixed wall time. Frames are counted from the synchronized-update
markers in its output, so the figure covers the real path: step, to_cells,
ANSI emit and the write to the terminal. Peak memory comes from wait4.
"""
import fcntl
import os
import select
import struct
import subprocess
import sys
import termios
import time

from impls import IMPLS

COLS, ROWS = 240, 67
SECONDS = 10
ARGS = ['--fps', '100000', '--live', '2', '--burn', '2', '--max-seconds', str(SECONDS), '--palette', 'ember']
MARK = b'\x1b[?2026h'


def run(cmd):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    proc = subprocess.Popen([str(cmd)] + ARGS, stdin=slave, stdout=slave, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    os.close(slave)
    frames, nbytes, tail = 0, 0, b''
    start = time.monotonic()
    while True:
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                chunk = os.read(master, 1 << 16)
            except OSError:          # EIO: the child closed the pty
                break
            if not chunk:
                break
            data = tail + chunk
            frames += data.count(MARK)
            tail = data[-(len(MARK) - 1):]
            nbytes += len(chunk)
        elif proc.poll() is not None:
            break
        if time.monotonic() - start > SECONDS + 15:
            proc.kill()
            break
    _, status, usage = os.wait4(proc.pid, 0)
    os.close(master)
    wall = time.monotonic() - start
    return frames, wall, nbytes, usage.ru_maxrss, os.waitstatus_to_exitcode(status)


def main():
    print(f'{COLS}x{ROWS} cells, {SECONDS} s flat out (grow, live, burn)\n')
    print('| impl | frames/s | ms/frame | MB/s to tty | peak RSS MB | exit |')
    print('|---|---:|---:|---:|---:|---:|')
    for name, (binary, *_rest) in IMPLS.items():
        if not binary.exists():
            print(f'| {name} | not built | | | | |')
            continue
        frames, wall, nbytes, rss_kb, code = run(binary)
        if frames == 0:
            print(f'| {name} | no frames | | | {rss_kb / 1024:.0f} | {code} |')
            continue
        fps = frames / wall
        print(f'| {name} | {fps:,.0f} | {1000 / fps:.2f} | {nbytes / wall / 1e6:.1f} | {rss_kb / 1024:.0f} | {code} |')
        sys.stdout.flush()


if __name__ == '__main__':
    main()
