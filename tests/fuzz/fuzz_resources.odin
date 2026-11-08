package fuzz

import "../../src"
import rand "core:math/rand"

SCENARIO_DURATION_SEC :: 10
SEED :: 1

create_resource_store :: proc() -> ^src.ResourceSystem {
	rs: ^src.ResourceSystem
	src.rsrc_sys_init(rs, context.allocator)
	return rs
}

test :: proc() {
	rand.reset(SEED)
	rs := create_resource_store()
	defer src.rsrc_sys_destroy(rs)
	src.rsrc_sys_register_marshaller(rs, src.default_txt_serializer())

	release_acquire_seed := rand.int31()

	//loop until duration is over
	for {
		release_acquire(rs, release_acquire_seed)
	}


}

release_acquire :: proc(rs: ^src.ResourceSystem, seed: i32) {
	for key, value in rs.id_to_artifact {
		if rand.int31() % 2 == 0 {
			// handle, _ := src.load_resource(rs, key)
		} else {
		}

	}

}
