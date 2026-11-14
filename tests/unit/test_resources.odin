package tests
import "../../src"
import "core:c/libc/tests"
import hm "core:container/handle_map"
import "core:crypto"
import "core:encoding/uuid"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

create_test_rs_store :: proc() -> ^src.Resource_Store {
	rs := new(src.Resource_Store)
	src.rs_store_init(rs, context.allocator)
	return rs
}

init_rs_store_with_txt_serializer :: proc() -> ^src.Resource_Store {
	context.random_generator = crypto.random_generator()
	rs := create_test_rs_store()
	src.rs_store_register_marshaller(rs, src.default_txt_serializer())
	return rs
}


ref_count :: proc(rs: ^src.Resource_Store, id: src.Rs_Id) -> u32 {
	return hm.get(&rs.handle_map, rs.id_to_loaded[id]).ref_count
}

cleanup_rs_store :: proc(data: rawptr) {
	rs := cast(^src.Resource_Store)data
	src.rs_store_destroy(rs)
	free(rs)
}

@(test)
test_acquire_handle_non_loaded :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	src.rs_store_import_file(rs, "testData.txt")

	file_bytes, _ := os.read_entire_file("testData.txt", context.allocator)
	defer {
		src.rs_store_destroy(rs)
		delete(file_bytes)
		free(rs)
	}

	string_data := strings.split_lines(string(file_bytes))
	defer delete(string_data)
	for id in rs.id_to_artifact {
		//acqurie handle
		handle, error := src.resource_load(rs, id, string)
		testing.expect(t, error == .None)

		//resolve out handle and get the data.
		data, e := src.handle_resolve(rs, handle)

		testing.expect(t, e == .None)
		testing.expect(t, data != nil)

		//verify our data is correct
		found := false
		for s in string_data {
			if s == data^ {
				found = true
				break
			}
		}
		testing.expect(t, found)

		//release handle, should go into the cache now
		src.handle_release(rs, handle)

		//assert the resource is in the cache
		status := src.resource_load_status(rs, id)
		testing.expect(t, status == .LOADED)
	}

}

@(test)
test_invalid_free :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}
	err := src.rs_store_import_file(rs, "testData.txt")
	testing.expect(t, err == .None)

	testing.cleanup(t, cleanup_rs_store, rs)
	for id, _ in rs.id_to_artifact {
		err := src.handle_release(rs, src.Rs_Handle(string){})
		testing.expect(t, err == .Handle_Error)

		handle, _ := src.resource_load(rs, id, string)

		err = src.handle_release(rs, handle)
		testing.expect(t, err == .None)

		testing.expect_assert(t, "Invalid Frees have occurred!")
		src.handle_release(rs, handle)
	}

}

@(test)
test_acquire_loaded_resource :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}

	err := src.rs_store_import_file(rs, "testData.txt")
	testing.expect(t, err == .None)

	for id, _ in rs.id_to_artifact {
		_, err := src.handle_acquire(rs, id, string)
		testing.expect(t, err == .Not_Loaded)

		status := src.resource_load_status(rs, id)
		testing.expect(t, status == .NOT_LOADED)

		loaded, _ := src.resource_load(rs, id, string)
		testing.expect(t, src.resource_load_status(rs, id) == .LOADED)

		other, _ := src.handle_acquire(rs, id, string)
		testing.expect(t, ref_count(rs, id) == 2)

		src.handle_release(rs, loaded)
		src.handle_release(rs, other)

		testing.expect(t, ref_count(rs, id) == 0)
	}
}

@(test)
test_duplicate_handle :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}

	err := src.rs_store_import_file(rs, "testData.txt")
	testing.expect(t, err == .None)

	for id, _ in rs.id_to_artifact {
		_, err := src.handle_duplicate(rs, src.Rs_Handle(string){})
		testing.expect(t, err == .Handle_Error)
		og, _ := src.resource_load(rs, id, string)
		for i in 0 ..< 5 {
			tmp, _ := src.handle_duplicate(rs, og)
			testing.expect(t, ref_count(rs, id) == u32(i + 2))
			data, _ := src.handle_resolve(rs, tmp)
			testing.expect(t, data != nil)
		}
		testing.expect(t, ref_count(rs, id) == u32(6))
	}

}

@(test)
test_invalid_id :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}

	err := src.rs_store_import_file(rs, "testData.txt")
	testing.expect(t, err == .None)

	_, err = src.resource_load(rs, {}, bool)

	testing.expect(t, err == .Missing_Artifact)

}

@(test)
test_type_validation :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}

	err := src.rs_store_import_file(rs, "testData.txt")
	testing.expect(t, err == .None)


	for id, _ in rs.id_to_artifact {
		bad_handle, err := src.resource_load(rs, id, bool)
		testing.expect(t, err == .Type_Missmatch)
	}

}

@(test)
test_cache_resize :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}
	src.rs_store_import_file(rs, "testData.txt")

	//iterate through and move everything to cache
	for id, _ in rs.id_to_artifact {
		rs_handle, err := src.resource_load(rs, id, string)
		testing.expect(t, err == .None)

		err = src.handle_release(rs, rs_handle)
		testing.expect(t, err == .None)
	}

	//assert that each item we loaded is now in cache
	testing.expect(t, len(rs.id_to_loaded) == len(rs.id_to_artifact))

	//assert that release worked an are no longer referenced
	iterator := hm.iterator_make(&rs.handle_map)
	for slot, _ in hm.iterate(&iterator) {
		testing.expect(t, slot.ref_count == 0)
	}

	//test that cache_resize to larger size is non-destructive and that values are set
	old_size := rs.cache_lookup[src.TEXT_CACHE_CATEGORY].current_size_bytes
	old_loaded := len(rs.id_to_loaded)
	src.cache_configure(rs, 0, 2048)
	testing.expect(t, rs.cache_lookup[src.TEXT_CACHE_CATEGORY].current_size_bytes == old_size)
	testing.expect(t, rs.cache_lookup[src.TEXT_CACHE_CATEGORY].max_capacity_bytes == 2048)
	testing.expect(t, len(rs.id_to_loaded) == old_loaded)

	//assert that a cache-resize to zero evicts all entries
	src.cache_configure(rs, src.TEXT_CACHE_CATEGORY, 0)

	//assert that items were deleted.
	testing.expect(t, len(rs.id_to_loaded) == 0)
}

@(test)
test_async_loading :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	cb_data := new(int)
	defer {
		src.rs_store_destroy(rs)
		free(rs)
		free(cb_data)
	}

	src.rs_store_import_file(rs, "testData.txt")

	Data :: struct {
		count: ^int,
		t:     ^testing.T,
	}


	foo :: proc(data: rawptr, foo: src.Rs_Handle(any)) {
		v := cast(^Data)data
		sync.atomic_add(v.count, 1)
		testing.expect(v.t, foo != {})
	}


	runner :: proc(cb: src.Resource_Callback) {
		cb.cb(cb.user_data, {})
	}


	blah := new(Data)
	defer free(blah)
	blah^ = {cb_data, t}
	for id, _ in rs.id_to_artifact {
		src.resource_load_async(rs, id, {user_data = blah, cb = foo}, {runner}, string)
	}

	//loop till all are loaded
	for {
		b := false
		for id, _ in rs.id_to_artifact {
			status := src.resource_load_status(rs, id)
			if status == .LOADED {
				b = true
			} else {
				b = false
				break
			}
		}
		if b do break
	}

	log.info("async count: ", cb_data^)
	testing.expect(t, cb_data^ == len(rs.id_to_artifact))

	for id, _ in rs.id_to_artifact {
		src.resource_load_async(rs, id, {blah, foo}, {runner}, string)
		testing.expect(t, ref_count(rs, id) == 2)
	}
}

@(test)
test_resource_register :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.rs_store_destroy(rs)
		free(rs)
	}

	data := new(string, rs.sys_allocator)
	resource := src.Resource{string, data, 1, proc(data: rawptr, rs: ^src.Resource_Store) {
			free(data)
		}}
	registered_handle, err := src.resource_register(rs, resource, string)
	testing.expect(t, err == .None)

	duplicated, duplication_error := src.handle_duplicate(rs, registered_handle)
	testing.expect(t, duplication_error == .None)

	testing.expect(t, src.handle_release(rs, duplicated) == .None)


	for id, _ in rs.id_to_loaded {
		testing.expect(t, ref_count(rs, id) == 1)
	}

	testing.expect(t, src.handle_release(rs, registered_handle) == .None)

	testing.expect(t, len(rs.id_to_loaded) == 0)
}
