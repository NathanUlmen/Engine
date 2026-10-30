package tests
import "core:crypto"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "src"

create_test_rsrc_sys :: proc() -> ^src.ResourceSystem {
	rs := new(src.ResourceSystem)
	src.rsrc_sys_init(rs, context.allocator)
	return rs
}

init_rsrc_sys_with_txt_serializer :: proc() -> ^src.ResourceSystem {
	context.random_generator = crypto.random_generator()
	rs := create_test_rsrc_sys()
	src.rsrc_sys_register_serializer(rs, src.default_txt_serializer())
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
	

	string_data := strings.split_lines(string(file_bytes))
	for id in rs.id_to_artifact {
		//acqurie handle
		handle, error := src.handle_acquire(rs, id)
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

		src.release_handle(rs, handle)

		//assert that the removal was successful
		data, e = src.handle_resolve(rs, handle)
		testing.expect(t, e == .Handle_Error)
		testing.expect(t, data == nil)
	}

}

@(test)
test_invalid_free :: proc(t: ^testing.T) {
    rs := init_rsrc_sys_with_txt_serializer()
	src.rsrc_sys_destroy(rs)
}
