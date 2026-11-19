# One entry point for every implementation. Linux only.
#
#   make            install toolchains (mise) and Python deps (uv), then build all
#   make setup      just the installs
#   make build      build C, Go, Zig, Odin; check the Python package imports
#   make test       run every test suite
#   make bench      same workload timed for each implementation (tools/bench.py)
#   make stats      code size / dependency table for the README (tools/stats.py)
#   make clean
#
# Needs on PATH: mise, a C compiler (cc) and make. mise provides Go, Zig, Odin
# and uv (versions in mise.toml); uv provides Python packages (python/pyproject.toml).

MISE := mise exec --
PY   := python/.venv/bin/python

.PHONY: all setup build test bench stats clean c go zig odin python

all: setup build

setup:
	mise trust --quiet $(CURDIR)/mise.toml
	mise install
	$(MISE) uv sync --project python --extra test --quiet

build: c go zig odin python

c:
	$(MAKE) -C c --no-print-directory
go:
	cd go && $(MISE) go build -o saver ./cmd/saver
zig:
	cd zig && $(MISE) zig build -Doptimize=ReleaseFast
odin:
	$(MAKE) -C odin --no-print-directory build
python:
	cd python && .venv/bin/python -c "import saver.main"

test:
	$(MAKE) -C c --no-print-directory test
	cd go && $(MISE) go vet ./... && $(MISE) go test ./...
	cd zig && $(MISE) zig build test --summary all
	$(MAKE) -C odin --no-print-directory test
	cd python && .venv/bin/python -m pytest -q

bench: build
	$(PY) tools/bench.py

stats:
	$(PY) tools/stats.py

clean:
	$(MAKE) -C c --no-print-directory clean
	$(MAKE) -C odin --no-print-directory clean
	rm -rf go/saver zig/zig-out zig/.zig-cache
	find python -name __pycache__ -type d -prune -exec rm -rf {} +
