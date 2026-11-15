package fuzz

import "../../src"
import "core:crypto"
import "core:encoding/uuid"
import "core:fmt"
import rand "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

SEED :: 1
ARTIFACT_COUNT :: 5000
DATA_FP :: "data.txt"
ITERATIONS :: 1
OP_COUNT :: 1


/*
Things we can verify:
ref_count
callback_counts

*/

Handle_Counter :: struct {
	handle:      src.Rs_Handle(string),
	checked_out: int,
}

Test_Context :: struct {
	using rs:      ^src.Resource_Store,
	handles:       map[src.Rs_Id]Handle_Counter,
	ids:           []src.Rs_Id,
	pending_async: int,
}


create_resource_store :: proc() -> ^src.Resource_Store {
	rs := new(src.Resource_Store)
	src.rs_store_init(rs, context.allocator)
	return rs
}

@(test)
fuzz :: proc(t: ^testing.T) {
	rand.reset(SEED)
	context.random_generator = crypto.random_generator()
	rs := create_resource_store()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}
	src.rs_store_register_marshaller(rs, src.default_txt_serializer())
	produce_data()
	defer os.remove(DATA_FP)

	src.rs_store_import_file(rs, DATA_FP)

	c := Test_Context {
		rs      = rs,
		handles = make(map[src.Rs_Id]Handle_Counter),
		ids     = make([]src.Rs_Id, len(rs.id_to_artifact)),
	}
	defer {
		delete(c.handles)
		delete(c.ids)
	}

	index := 0
	for id, _ in rs.id_to_artifact {
		c.ids[index] = id
		c.handles[id] = {}
		index += 1
	}

	testing.expect(t, len(c.ids) == len(c.id_to_artifact))

	for i in 0 ..< ITERATIONS {
		for j in 0 ..< OP_COUNT {
			random_operation(&c)
		}
		thread.pool_join(c.pool)
		//verify count
	}


}

/*
Write a huge file to disk

*/
produce_data :: proc() {
	context.allocator = context.temp_allocator
	lines := make([]string, ARTIFACT_COUNT)
	for &l in lines {
		l = fmt.tprintln(rand.int31())
	}
	result, alloc_err := strings.join(lines, "")

	assert(alloc_err == nil)
	write_error := os.write_entire_file(DATA_FP, result)
	assert(write_error == nil)
	free_all(context.allocator)
}

random_operation :: proc(c: ^Test_Context) {
	if len(c.ids) <= 0 || rand.float32_range(0, 1) < .55 {
		release_random_handle(c)
	} else {
		acquire_random_handle(c)
	}

}

release_random_handle :: proc(c: ^Test_Context) {

}

acquire_random_handle :: proc(c: ^Test_Context) {
	if len(c.ids) <= 0 {
		return
	}
	val := rand.int_range(0, len(c.ids))
	target_id := c.ids[val]
	if src.resource_load_status(c.rs, target_id) == .LOADED {
		entry := &c.handles[target_id]
		entry.checked_out += 1
		e: src.Resource_Error
		entry.handle, e = src.handle_acquire(c.rs, target_id, string)
		assert(e == .None)
	} else {

		Load_Callback_Data :: struct {
			test_context: ^Test_Context,
			id:           src.Rs_Id,
		}

		loaded :: proc(user_data: rawptr, handle: src.Rs_Handle(any)) {
		}

		dispatch :: proc(callback: src.Resource_Callback) {
		}

		callback_data := new(Load_Callback_Data, c.rs.sys_allocator)
		callback_data^ = {c, target_id}
		sync.atomic_add(&c.pending_async, 1)
		future := src.resource_load_async(c.rs, target_id, {user_data = callback_data, cb = loaded}, {post = dispatch}, string)
	}
}
