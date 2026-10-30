package main
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"


default_txt_serializer :: proc() -> ResourceSerializier {
	return {nil, ".txt", txt_extract, txt_bake_to_disk, txt_read_from_disk}
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

txt_bake_to_disk :: proc(user_data: rawptr, extracted_data: rawptr) -> []ResourceArtifact {
	str_data := cast(^string)extracted_data
	defer {
		delete(str_data^)
		free(extracted_data)
	}

	split, err := strings.split_lines(str_data^)
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
	return artifacts
}

txt_read_from_disk :: proc(user_data: rawptr, file_data: []byte, rsrc_sys: ^ResourceSystem) -> rawptr {
	str_data := string(file_data)
	ptr := new(string)
	ptr^ = str_data
	return ptr
}
