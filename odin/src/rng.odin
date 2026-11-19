package saver

import "core:math/rand"

// A seeded random stream. Owned by whoever creates it and passed by pointer,
// so no global generator is involved. Must not be copied after first use
// (the generator holds a pointer to `state`).
Rng :: struct {
	state: rand.Default_Random_State,
}

rng_make :: proc(seed: u64) -> Rng {
	return Rng{state = rand.create(seed)}
}

@(private = "file")
gen :: proc(r: ^Rng) -> rand.Generator {
	return rand.default_random_generator(&r.state)
}

// Uniform in [0, 1).
rng_float :: proc(r: ^Rng) -> f64 {
	return rand.float64(gen(r))
}

// Uniform in [lo, hi).
rng_range :: proc(r: ^Rng, lo, hi: f64) -> f64 {
	return lo + (hi - lo) * rng_float(r)
}

// Uniform integer in [lo, hi].
rng_int :: proc(r: ^Rng, lo, hi: int) -> int {
	return rand.int_range(lo, hi + 1, gen(r))
}

// Normal with the given mean and standard deviation.
rng_normal :: proc(r: ^Rng, mean, sd: f64) -> f64 {
	return rand.norm_float64(gen(r)) * sd + mean
}
