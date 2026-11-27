package tests
import "../../src"
import "base:runtime"
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
import "core:thread"

DEFAULT_CATEGORY :: src.Rs_Category_Id(0)

create_test_rs_store :: proc() -> ^src.Resource_Store {
	rs := new(src.Resource_Store)
	categories := []src.Category_Configuration{{100 * mem.Megabyte, 20 * mem.Megabyte, DEFAULT_CATEGORY}}
	src.resource_store_init(rs, context.allocator, categories)
	return rs
}

init_rs_store_with_txt_serializer :: proc() -> ^src.Resource_Store {
	rs := create_test_rs_store()
	src.resource_store_register_marshaller(rs, src.txt_default_marshaller())
	return rs
}

init_rs_store_with_data :: proc() -> ^src.Resource_Store {
	rs := init_rs_store_with_txt_serializer()
	err := src.resource_store_import_file(rs, "testData.txt")
	assert(err == .None)
	return rs
}

ref_count :: proc(rs: ^src.Resource_Store, id: src.Rs_Id) -> u32 {
	return hm.get(&rs.handle_map, rs.id_to_loaded[id]).ref_count
}

cleanup_rs_store :: proc(data: rawptr) {
	rs := cast(^src.Resource_Store)data
	src.resource_store_destroy(rs)
	free(rs)
}

@(test)
test_acquire_handle_non_loaded :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()

	file_bytes, _ := os.read_entire_file("testData.txt", context.allocator)
	defer {
		delete(file_bytes)
		cleanup_rs_store(rs)
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
		src.handle_release(rs, &handle)

		//assert the resource is in the cache
		status := src.resource_load_status(rs, id)
		testing.expect(t, status == .LOADED)
	}

}

@(test)
test_invalid_free :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}

	for id, _ in rs.id_to_artifact {
		err := src.handle_release(rs, &src.Rs_Handle(string){})
		testing.expect(t, err == .Handle_Error)

		handle, _ := src.resource_load(rs, id, string)

		err = src.handle_release(rs, &handle)
		testing.expect(t, err == .None)

		// testing.expect_assert(t, "Invalid Frees have occurred!")
		err = src.handle_release(rs, &handle)
		testing.expect(t, err == .Handle_Error)
	}

}

@(test)
test_acquire_loaded_resource :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}
	for id, _ in rs.id_to_artifact {
		_, err := src.handle_acquire(rs, id, string)
		testing.expect(t, err == .Not_Loaded)

		status := src.resource_load_status(rs, id)
		testing.expect(t, status == .NOT_LOADED)

		loaded, _ := src.resource_load(rs, id, string)
		testing.expect(t, src.resource_load_status(rs, id) == .LOADED)

		other, _ := src.handle_acquire(rs, id, string)
		testing.expect(t, ref_count(rs, id) == 2)

		src.handle_release(rs, &loaded)
		src.handle_release(rs, &other)

		testing.expect(t, ref_count(rs, id) == 0)
	}
}

@(test)
test_duplicate_handle :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}

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
		src.resource_store_destroy(rs)
		free(rs)
	}

	err := src.resource_store_import_file(rs, "testData.txt")
	testing.expect(t, err == .None)

	_, err = src.resource_load(rs, {}, bool)

	testing.expect(t, err == .Missing_Artifact)

}

@(test)
test_type_validation :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}

	for id, _ in rs.id_to_artifact {
		bad_handle, err := src.resource_load(rs, id, bool)
		testing.expect(t, err == .Type_Missmatch)
	}

}

@(test)
test_cache_resize :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}

	//iterate through and move everything to cache
	for id, _ in rs.id_to_artifact {
		rs_handle, err := src.resource_load(rs, id, string)
		testing.expect(t, err == .None)

		err = src.handle_release(rs, &rs_handle)
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
	old_size := rs.categories[src.TEXT_CATEGORY].cache_current_size_bytes
	old_loaded := len(rs.id_to_loaded)
	src.cache_configure(rs, 0, 2048)
	testing.expect(t, rs.categories[src.TEXT_CATEGORY].cache_current_size_bytes == old_size)
	testing.expect(t, rs.categories[src.TEXT_CATEGORY].cache_max_size_bytes == 2048)
	testing.expect(t, len(rs.id_to_loaded) == old_loaded)

	//assert that a cache-resize to zero evicts all entries
	src.cache_configure(rs, src.TEXT_CATEGORY, 0)

	//assert that items were deleted.
	testing.expect(t, len(rs.id_to_loaded) == 0)
}

@(test)
test_async_loading :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	cb_data := new(int)
	cb_data^ = 0
	defer {
		cleanup_rs_store(rs)
		free(cb_data)
	}

	Data :: struct {
		count: ^int,
		t:     ^testing.T,
	}

	initial_cb :: proc(data: ^src.Resource_Callback(string)) {
		v := cast(^Data)data.user_data
		context.logger = log.create_console_logger()
		defer log.destroy_console_logger(context.logger)
		testing.expectf(v.t, data.handle.handle != hm.Handle64{}, "Expected handle to not equal %v", hm.Handle64{})
		sync.atomic_add(v.count, 1)
	}

	/*
    for testing purposes we just run it immediately. In real usage you would probably
    defer it to run somewhere else later on in the program.
    */
	runner :: proc(_: src.Dispatcher, cb: thread.Task) {
		cb.procedure(cb)
	}

	callback_data := new(Data)
	defer free(callback_data)
	callback_data^ = {cb_data, t}
	for id, _ in rs.id_to_artifact {
		callback := src.Resource_Callback(string) {
			user_data = callback_data,
			cb        = initial_cb,
		}
		src.resource_load_async(rs, id, &callback, {{}, runner})
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
	testing.expectf(t, cb_data^ == len(rs.id_to_artifact), "Expected callback count to be %v, recieved %v", len(rs.id_to_artifact), cb_data^)

	for id, _ in rs.id_to_artifact {
		callback := src.Resource_Callback(string) {
			user_data = callback_data,
			cb        = initial_cb,
		}
		src.resource_load_async(rs, id, &callback, {{}, runner})
		testing.expect(t, ref_count(rs, id) == 2)
	}
	category, has := rs.categories[DEFAULT_CATEGORY]
	testing.expect(t, has)
	testing.expectf(t, category.current_size_bytes == u64(len(rs.id_to_loaded)), "Expected %v bytes, got %v", len(rs.id_to_loaded), category.current_size_bytes)
}

@(test)
test_resource_register :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		src.resource_store_destroy(rs)
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

	testing.expect(t, src.handle_release(rs, &duplicated) == .None)


	for id, _ in rs.id_to_loaded {
		testing.expect(t, ref_count(rs, id) == 1)
	}

	testing.expect(t, src.handle_release(rs, &registered_handle) == .None)

	testing.expect(t, len(rs.id_to_loaded) == 0)
}

@(test)
test_fails_when_category_budget_exceeded :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}

	for id, _ in rs.id_to_artifact {
		src.resource_load(rs, id, string)
	}

	testing.expect_assert(t, "Budget size exceeded after resize.")
	testing.cleanup(t, cleanup_rs_store, rs)
	src.category_resize(rs, DEFAULT_CATEGORY, 1)
}

@(test)
test_cache_clean :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}

	handles := make([]src.Rs_Handle(string), len(rs.id_to_artifact))
	defer delete(handles)
	i := 0
	for id, _ in rs.id_to_artifact {
		handle, _ := src.resource_load(rs, id, string)
		handles[i] = handle
		i += 1
	}


	for &handle in handles {
		src.handle_release(rs, &handle)
	}
	loaded := len(rs.id_to_loaded)
	testing.expect(t, loaded == len(rs.id_to_artifact))
	src.cache_clean(rs, DEFAULT_CATEGORY)
	testing.expect(t, len(rs.id_to_loaded) == 0)
	testing.expect(t, rs.categories[DEFAULT_CATEGORY].cache_current_size_bytes == 0)
}

@(test)
test_category_resize :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer cleanup_rs_store(rs)

	src.category_resize(rs, DEFAULT_CATEGORY, 2000)
	testing.expect(t, rs.categories[DEFAULT_CATEGORY].budget_bytes == 2000)
}

@(test)
test_error_on_missing_file :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_txt_serializer()
	defer {
		cleanup_rs_store(rs)
	}

	err := src.resource_store_import_file(rs, "foobar.txt")
	testing.expect(t, err == .Missing_File)
}

test_fails_when_resource_size_zero :: proc(t: ^testing.T) {}

@(test)
test_category_byte_counts_accurate :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer cleanup_rs_store(rs)

	i: u64 = 0 //our resources are all 1 byte in size. Also use this as our index
	handles := make([]src.Rs_Handle(string), len(rs.id_to_artifact))
	defer delete(handles)
	for id, _ in rs.id_to_artifact {
		handle, _ := src.resource_load(rs, id, string)
		testing.expect(t, rs.categories[DEFAULT_CATEGORY].current_size_bytes == i + 1)
		handles[i] = handle
		i += 1
	}
	starting_size := rs.categories[DEFAULT_CATEGORY].current_size_bytes
	i = 1
	for &handle in handles {
		src.handle_release(rs, &handle)
		testing.expect(t, rs.categories[DEFAULT_CATEGORY].current_size_bytes == starting_size - i)
		testing.expect(t, rs.categories[DEFAULT_CATEGORY].cache_current_size_bytes == i)
		i += 1
	}

}

@(test)
test_id_from_handle :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rs_store_with_data()
	defer {
		cleanup_rs_store(rs)
	}

	for id, _ in rs.id_to_artifact {
		handle, err := src.resource_load(rs, id, string)
		testing.expect(t, err == .None)
		id_from_handle, handle_err := src.id_from_handle(rs, handle)
		testing.expect(t, handle_err == .None)
		testing.expect(t, id == id_from_handle)
	}
}

@(test)
test_init_no_category :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs: src.Resource_Store

	ok := src.resource_store_init(&rs, context.allocator, {})
	testing.expect(t, !ok)
}

@(test)
test_init_bad_threads :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs: src.Resource_Store

	ok := src.resource_store_init(&rs, context.allocator, {{1 * mem.Megabyte, 50 * mem.Kilobyte, DEFAULT_CATEGORY}}, 0)
	testing.expect(t, !ok)
}

@(test)
test_load_with_non_present_category_errors :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs: src.Resource_Store
	made_up_category: u32 = 1
	ok := src.resource_store_init(&rs, context.allocator, {{100, 100, made_up_category}}, 1)
	testing.expect(t, ok)
	defer {
		src.resource_store_destroy(&rs)
	}

	src.resource_store_register_marshaller(&rs, src.txt_default_marshaller())

	err := src.resource_store_import_file(&rs, "testData.txt")
	testing.expect(t, err == .Missing_Category)

	//no artifacts should have been loaded.
	testing.expect(t, len(rs.id_to_artifact) == 0)
}
