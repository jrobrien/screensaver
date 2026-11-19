CC      ?= cc
WARN    := -Wall -Wextra -Wpedantic
CFLAGS  ?= -O2
CFLAGS  := -std=c11 $(WARN) -D_POSIX_C_SOURCE=200809L $(CFLAGS)
LDLIBS  := -lm

LIB_SRC := $(addprefix src/,rng.c palettes.c raster.c scene.c burn.c show.c render.c still.c)
HDR     := $(wildcard src/*.h)
SAN     := -fsanitize=address,undefined -fno-omit-frame-pointer -g -O1

all: saver

saver: $(LIB_SRC) src/main.c $(HDR)
	$(CC) $(CFLAGS) -Isrc -o $@ $(LIB_SRC) src/main.c $(LDLIBS)

build/test_show: $(LIB_SRC) tests/test_show.c $(HDR)
	@mkdir -p build
	$(CC) $(CFLAGS) -Isrc -o $@ $(LIB_SRC) tests/test_show.c $(LDLIBS)

build/bench: $(LIB_SRC) tests/bench.c $(HDR)
	@mkdir -p build
	$(CC) $(CFLAGS) -Isrc -o $@ $(LIB_SRC) tests/bench.c $(LDLIBS)

test: build/test_show
	./build/test_show

bench: build/bench
	./build/bench

asan:
	@mkdir -p build
	$(CC) -std=c11 $(WARN) -D_POSIX_C_SOURCE=200809L $(SAN) -Isrc -o build/test_show_asan $(LIB_SRC) tests/test_show.c $(LDLIBS)
	$(CC) -std=c11 $(WARN) -D_POSIX_C_SOURCE=200809L $(SAN) -Isrc -o build/saver_asan $(LIB_SRC) src/main.c $(LDLIBS)
	./build/test_show_asan
	./build/saver_asan --still build/asan.ppm --phase burn --at 3 --size 80x30

clean:
	rm -rf saver build

.PHONY: all test bench asan clean
