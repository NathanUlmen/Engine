package fuzz

import "../../src"
import rand "core:math/rand"
import "core:testing"

SEED :: 1
ITER_OPS :: 10

create_resource_store :: proc() -> ^src.Resource_Store {
	rs: ^src.Resource_Store
	src.rs_store_init(rs, context.allocator)
	return rs
}

@(test)
test :: proc(t: testing.T) {
	rand.reset(SEED)
	rs := create_resource_store()
	defer src.rsrc_sys_destroy(rs)
	src.rsrc_sys_register_marshaller(rs, src.default_txt_serializer())

	release_acquire_seed := rand.int31()

	for i in 0 ..< 1_000 {
		release_acquire(rs, release_acquire_seed)
	}


}

release_acquire :: proc(rs: ^src.Resource_Store, seed: i32) {
	history: [ITER_OPS]i32
	for key, value in rs.id_to_artifact {
		src.resource_load(rs, key, string)
		for i in 0 ..< ITER_OPS {
			history[i] = rand.int31()

			if rand.int31() % 2 == 0 {
				src.resource_load(rs, key, string)
			} else {
				src.handle_acquire(rs, key, string)
			}

		}
	}
}
