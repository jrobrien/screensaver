"""The implementations, for tools/bench.py and tools/stats.py."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# name: (binary or launcher, source dir, source extensions, test-file test)
IMPLS = {
    'python': (ROOT / 'bin/saver', ROOT / 'python/saver', ('.py',), None),
    'c': (ROOT / 'c/saver', ROOT / 'c/src', ('.c', '.h'), None),
    'go': (ROOT / 'go/saver', ROOT / 'go', ('.go',), lambda p: p.name.endswith('_test.go')),
    'zig': (ROOT / 'zig/zig-out/bin/saver', ROOT / 'zig/src', ('.zig',), None),
    'odin': (ROOT / 'odin/saver', ROOT / 'odin/src', ('.odin',), lambda p: p.name.endswith('_test.odin')),
}

# separate test trees
TEST_DIRS = {'python': ROOT / 'python/tests', 'c': ROOT / 'c/tests'}
