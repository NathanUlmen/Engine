package tests
import "../../src"
import hm "core:container/handle_map"
import "core:crypto"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

create_test_rsrc_sys :: proc() -> ^src.ResourceSystem {
	rs := new(src.ResourceSystem)
	src.rsrc_sys_init(rs, context.allocator)
	return rs
}

init_rsrc_sys_with_txt_serializer :: proc() -> ^src.ResourceSystem {
	context.random_generator = crypto.random_generator()
	rs := create_test_rsrc_sys()
	src.rsrc_sys_register_marshaller(rs, src.default_txt_serializer())
	return rs
}

@(test)
test_acquire_handle_non_loaded :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rsrc_sys_with_txt_serializer()
	src.rsrc_sys_import_file(rs, "testData.txt")
	defer src.rsrc_sys_destroy(rs)
	file_bytes, _ := os.read_entire_file("testData.txt", context.allocator)
	defer delete(file_bytes)
	defer free(rs)


	string_data := strings.split_lines(string(file_bytes))
	for id in rs.id_to_artifact {
		//acqurie handle
		handle, error := src.load_resource(rs, id)
		testing.expect(t, error == .None)

		//resolve out handle and get the data.
		data, e := src.handle_resolve(rs, handle)
		testing.expect(t, e == .None)
		testing.expect(t, data != nil)

		//verify our data is correct
		found := false
		for s in string_data {
			if s == (cast(^string)data)^ {
				found = true
				break
			}
		}
		testing.expect(t, found)

		//release handle, should go into the cache now
		src.release_handle(rs, handle)

		//assert the resource is in the cache
		status := src.resource_load_status(rs, id)
		testing.expect(t, status == .LOADED)
	}

}

@(test)
test_invalid_free :: proc(t: ^testing.T) {
	rs := init_rsrc_sys_with_txt_serializer()
	src.rsrc_sys_destroy(rs)
	free(rs)
}

test_acquire_loaded_resource :: proc(t: ^testing.T) {
	rs := init_rsrc_sys_with_txt_serializer()
}

test_replace_serializer :: proc(t: ^testing.T) {
}

test_copy_resource :: proc(t: ^testing.T) {}

test_load_status :: proc(t: ^testing.T) {}

test_invalid_handle :: proc(t: ^testing.T) {}

test_invalid_id :: proc(t: ^testing.T) {}

test_missing_serializer :: proc(t: ^testing.T) {}

@(test)
test_cache_resize :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	rs := init_rsrc_sys_with_txt_serializer()
	defer src.rsrc_sys_destroy(rs)
	src.rsrc_sys_import_file(rs, "testData.txt")

	//iterate through and move everything to cache
	for id, _ in rs.id_to_artifact {
		rs_handle, err := src.load_resource(rs, id)
		testing.expect(t, err == .None)

		err = src.release_handle(rs, rs_handle)
		testing.expect(t, err == .None)
	}

	//assert that each item we loaded is now in cache
	testing.expect(t, len(rs.id_to_loaded) == len(rs.id_to_artifact))

	//assert that release worked an are no longer referenced
	iterator := hm.iterator_make(&rs.handle_map)
	for slot, handle in hm.iterate(&iterator) {
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
