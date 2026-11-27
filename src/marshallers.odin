package main
import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import gltf "vendor:cgltf"

TEXT_CATEGORY :: Rs_Category_Id(0)

txt_default_marshaller :: proc() -> Resource_Marshaller {
	return {{nil, context_destructor}, ".txt", txt_bake_to_disk, txt_read_from_disk}
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
			stable_id       = uuid.generate_v7_basic(nil),
			category_id     = TEXT_CATEGORY,
			dependencies    = nil,
			baked_file_path = artifact_file_path,
			name            = strings.clone(artifact_file_path),
			import_version  = 1,
		}
	}
	return artifacts, true
}

txt_read_from_disk :: proc(user_data: rawptr, file_path: string, rsrc_sys: ^Resource_Store, allocator: mem.Allocator) -> (Resource, bool) {
	file_data, _ := os.read_entire_file(file_path, allocator)
	defer delete(file_data)

	str_data := string(file_data)
	ptr := new(string)
	ptr^ = str_data
	return {string, ptr, u64(len(file_data)), destroy_resource}, true
}

destroy_resource :: proc(to_free: rawptr, rsrc_sys: ^Resource_Store) {
	free(to_free)
}

context_destructor :: proc(data: rawptr, allocator: mem.Allocator) {
	free(data)
}

//---------GTLF/GLB------

glb_default_marshaller :: proc() -> Resource_Marshaller {
	return {{}, ".glb", glb_read_from_disk, glb_create_resource}
}

glb_read_from_disk :: proc(_: rawptr, file_path: string, allocator: mem.Allocator) -> ([]Resource_Artifact, bool) {
	context.allocator = allocator
	cloned_c_string := strings.clone_to_cstring(file_path)

	data, parse_result := gltf.parse_file(gltf.options{}, cloned_c_string)
	assert(parse_result == .success)
	buffer_result := gltf.load_buffers(gltf.options{}, data, cloned_c_string)
	assert(buffer_result == .success)

	defer {
		delete(cloned_c_string)
		gltf.free(data)
	}

	//mesh in gltf represents a model, not raw verticies
	for mesh in data.meshes {
		attributes := make(map[gltf.attribute_type][][]f32)
		for primitive in mesh.primitives {
			for attribute in primitive.attributes {
				accessor := attribute.data

				log.info(accessor.type)

				attribute_data := make([][]f32, accessor.count)

				@(static, rodata)
				counts := [gltf.type]uint {
					.invalid = 0,
					.scalar  = 1,
					.vec2    = 2,
					.vec3    = 3,
					.vec4    = 4,
					.mat2    = 4,
					.mat3    = 9,
					.mat4    = 16,
				}

				float_count := counts[accessor.type]

				data := make([]f32, accessor.count * float_count)

				for &position, i in attribute_data {
					offset := i * int(float_count)
					position = data[offset:(offset + int(float_count))]
				}

				for i in 0 ..< int(accessor.count) {
					ok := gltf.accessor_read_float(accessor, uint(i), raw_data(attribute_data[i][:]), float_count)
					assert(bool(ok))
				}
				attributes[attribute.type] = attribute_data

			}
		}

		for key, _ in attributes {
			log.info(key)
		}

		/*
        TODO: take attribute data and interleave it into a single 
        buffer that the renderer supports and can consume. We need to determine that...
        */
	}

	return nil, true
}

glb_create_resource :: proc(_: rawptr, file_path: string, rs: ^Resource_Store, allocator: mem.Allocator) -> (Resource, bool) {

	return {}, true
}
