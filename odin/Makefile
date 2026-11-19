ODIN ?= mise exec -- odin
FLAGS = -vet -strict-style

.PHONY: build debug test clean

build:
	$(ODIN) build src -out:saver -o:speed $(FLAGS)

# Debug build: bounds checks, and main reports leaks from a tracking allocator.
debug:
	$(ODIN) build src -out:saver-debug -debug $(FLAGS)

test:
	$(ODIN) test src -out:saver-test $(FLAGS) -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

clean:
	rm -f saver saver-debug saver-test
