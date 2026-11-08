package main
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

TEXT_CACHE_CATEGORY :: Cache_Id(0)

default_txt_serializer :: proc() -> Resource_Marshaller {
	return {{nil, context_destructor}, ".txt", txt_bake_to_disk, txt_read_from_disk}
}

txt_extract :: proc(user_data: rawptr, file_path: string) -> (rawptr, Resource_Error) {
	file_bytes, err := os.read_entire_file_from_path(file_path, context.allocator)
	defer delete(file_bytes)
	if err != nil {
		return {}, .Extraction_Error
	}
	string_data, cpy_err := strings.clone_from_bytes(file_bytes)
	assert(cpy_err == nil)
	stored := new(string)
	stored^ = string_data
	return rawptr(stored), .None
}

txt_bake_to_disk :: proc(user_data: rawptr, file_path: string, allocator: mem.Allocator) -> ([]Resource_Artifact, bool) {
	file_bytes, _ := os.read_entire_file(file_path, allocator)
	str_data := string(file_bytes)
	defer {
		delete(file_bytes)
	}

	split, err := strings.split_lines(str_data)
	assert(err == nil)
	defer delete(split)
	artifacts := make([]Resource_Artifact, len(split))
	defer delete(artifacts)
	for line, i in split {
		artifact_file_path := fmt.aprintf("out/out%v.txtout", i)
		err := os.write_entire_file(artifact_file_path, line)
		assert(err == nil)
		artifacts[i] = {
			id              = uuid.generate_v7_basic(nil),
			cache_category  = {1024, TEXT_CACHE_CATEGORY},
			dependencies    = nil,
			baked_file_path = artifact_file_path,
			name            = artifact_file_path,
			import_version  = 1,
		}
	}
	return artifacts, true
}

txt_read_from_disk :: proc(user_data: rawptr, file_path: string, rsrc_sys: ^Resource_Store, allocator: mem.Allocator) -> Resource {
	file_data, _ := os.read_entire_file(file_path, allocator)
	defer delete(file_data)

	str_data := string(file_data)
	ptr := new(string)
	ptr^ = str_data
	// log.info("str size", len(file_data))
	return {ptr, u64(len(file_data)), destroy_resource}
}

destroy_resource :: proc(to_free: rawptr, rsrc_sys: ^Resource_Store) {
	free(to_free)
}

context_destructor :: proc(data: rawptr, allocator: mem.Allocator) {
	free(data)
}
