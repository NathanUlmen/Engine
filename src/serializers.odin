package main
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

default_txt_serializer :: proc() -> ResourceMarshaller {
	return {{nil, context_destructor}, ".txt", txt_bake_to_disk, txt_read_from_disk, destroy_resource}
}

txt_extract :: proc(user_data: rawptr, file_path: string) -> (rawptr, Resource_Error) {
	file_bytes, err := os.read_entire_file_from_path(file_path, context.allocator)
	defer delete(file_bytes)
	if err != nil {
		return {}, .Extraction_Error
	}
	string_data, cpy_err := strings.clone_from_bytes(file_bytes)
	stored := new(string)
	stored^ = string_data
	return rawptr(stored), .None
}

txt_bake_to_disk :: proc(user_data: rawptr, file_path: string, allocator: mem.Allocator) -> ([]ResourceArtifact, bool) {
	file_bytes, _ := os.read_entire_file(file_path, allocator)
	str_data := string(file_bytes)
	defer {
		delete(file_bytes)
	}

	split, err := strings.split_lines(str_data)
	defer delete(split)
	artifacts := make([]ResourceArtifact, len(split))
	defer delete(artifacts)
	for line, i in split {
		file_path := fmt.aprintf("out%v.txtout", i)
		err := os.write_entire_file(file_path, line)
		artifacts[i] = {
			id              = uuid.generate_v7_basic(nil),
			dependencies    = nil,
			baked_file_path = file_path,
			name            = file_path,
			import_version  = 1,
		}
	}
	return artifacts, true
}

txt_read_from_disk :: proc(user_data: rawptr, file_data: []byte, rsrc_sys: ^ResourceSystem, allocator: mem.Allocator) -> Resource {
	str_data := string(file_data)
	ptr := new(string)
	ptr^ = str_data
	return {ptr, u64(len(file_data))}
}

destroy_resource :: proc(user_data: rawptr, to_free: rawptr, rsrc_sys: ^ResourceSystem) {
	free(to_free)
}

context_destructor :: proc(data: rawptr, allocator: mem.Allocator) {

}
