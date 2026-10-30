package main

import hm "core:container/handle_map"
import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"

/*
TBD:
How/should we make this thing thread safe?
*/

ResourceSystem :: struct {
	serializers:    map[string]ResourceSerializier,
	id_to_artifact: map[RsrcId]ResourceArtifact,
	id_to_loaded:   map[RsrcId]RsrcHandle, //should we point this at the slot instead?
	allocator:      mem.Allocator,
	handle_map:     hm.Dynamic_Handle_Map(ResourceSlot, hm.Handle64),
}

Resource_Error :: enum {
	None,
	Missing_Serializer,
	Invalid_File,
	Extraction_Error,
	Handle_Error,
	Allocator_Error,
	Missing_Artifact,
}

RsrcId :: uuid.Identifier

RsrcHandle :: hm.Handle64

ResourceData :: struct {
	data: rawptr,
}

ResourceSlot :: struct {
	handle:      RsrcHandle,
	id:          RsrcId,
	data:        rawptr,
	checked_out: u32,
}

/*
Describes the status of a asynchronously loaded resource.
    - SCHEDULED: Request is in the queue and awaits processing
    - IN_PROGRESS: Resource is currently being loaded.
    - COMPLETED: Resource has been loaded and its callback has been dispatched.
    - CANCELED: Resource has been canceled and no longer being loaded
    - ERROR: Resource encountered an error while loading. Callback is dispatched but must handle/react to the error.
*/
Load_Status :: enum {
	NOT_REQUESTED,
	SCHEDULED,
	IN_PROGRESS,
	COMPLETED,
	CANCELED,
	ERROR,
}

/*
A future to a resource that is being acquired asynchronously.

*/
ResourceFuture :: struct {
	status: Load_Status,
}

Dispatcher :: struct {
	post: proc(runnable: proc()),
}

ResourceCallback :: proc(user_data: rawptr, handle: RsrcHandle)

/*
An "interface" used by the ResourceSystem.
    Fields:
    - user_data: custom user data field 
    - extension: file extension that this serializer is capable of handling. Must include the '.' EX: ".txt"
    - extract: procedure that is responsible for opening and reading out the file contents into data that bake_to_disk can consume.
    - bake_to_disk: procedure that is responsible for consuming the results of extract and producing artifacts that are written to disk.
    - read_from_disk: procedure that is responsible for consuming/constructing runtime data from artifacts produced by bake_to_disk.
*/
ResourceSerializier :: struct {
	user_data:      rawptr,
	extension:      string,
	extract:        proc(user_data: rawptr, file_path: string) -> (rawptr, Resource_Error),
	bake_to_disk:   proc(user_data: rawptr, extracted_data: rawptr) -> []ResourceArtifact,
	read_from_disk: proc(user_data: rawptr, file_data: []byte, rsrc_sys: ^ResourceSystem) -> rawptr,
}

/*
    Fields:
    - id: stable id that is associated with this resource.
    - dependencies: ResourceArtifacts of other resources that this resource depends on.
    - baked_file_path: the file path to the baked resource data
    - name: Name associated with artifact
    - progenitor_file_path: path to the file that this artifact was derived/produced from.
    - _extension: Used to select the serializer to resolve this artifact.
    - import_version: uhhh

*/
ResourceArtifact :: struct {
	id:                   RsrcId, //maybe we can handle?
	dependencies:         []RsrcId,
	baked_file_path:      string,
	name:                 string,
	progenitor_file_path: string, //we can handle
	_extension:           string, //we can handle
	import_version:       u16,
}

/*

*/
rsrc_sys_init :: proc(rs: ^ResourceSystem, allocator: mem.Allocator) {
	rs.allocator = allocator
	rs.serializers = make(map[string]ResourceSerializier, rs.allocator)
	rs.id_to_artifact = make(map[RsrcId]ResourceArtifact, rs.allocator)
	rs.id_to_loaded = make(map[RsrcId]RsrcHandle, rs.allocator)
	hm.dynamic_init(&rs.handle_map, rs.allocator)
}

/*

*/
rsrc_sys_destroy :: proc(rs: ^ResourceSystem) {
	hm.dynamic_destroy(&rs.handle_map)
	free_all(rs.allocator) // this also wont work in long run but yolo
	//TODO: Revist this later. (Maybe add a delete proc to the Serializer ?)
	for _, serializer in rs.serializers {
		free(serializer.user_data)
	}

}

/*
    Inputs:
    - rs:
    - serializer:
*/
rsrc_sys_register_serializer :: proc(rs: ^ResourceSystem, serializer: ResourceSerializier) {
	when ODIN_DEBUG {
		_, contains := rs.serializers[serializer.extension]
		log.warnf("Replaced existing serializer responsible for extension %v", serializer.extension)
	}
	to_replace, contained := rs.serializers[serializer.extension]
	if contained {
		free(to_replace.user_data, rs.allocator)
	}
	rs.serializers[serializer.extension] = serializer
}

/*
Produces asset artifact(s) from a target_file
    Inputs:
    - rs:
    - target_file:
*/
rsrc_sys_import_file :: proc(rs: ^ResourceSystem, target_file: string) -> Resource_Error {
	context.allocator = rs.allocator
	extension := filepath.ext(target_file)
	serializer, contains := rs.serializers[extension]
	if !contains {
		return Resource_Error.Missing_Serializer
	}
	data, err := serializer.extract(serializer.user_data, target_file)
	if err != nil {
		return err
	}
	//TODO: make bake to disk return an error
	artifacts := serializer.bake_to_disk(serializer.user_data, data)
	for &artifact in artifacts {
		artifact._extension = extension
		rs.id_to_artifact[artifact.id] = artifact
	}
	return .None
}

/*
Acquires a handle to a resource in a synchronous/blocking manner.
    Inputs:
    - rs: the ResourceSystem to 
    - id: The stable id to the resource you wish to read from memory.

    Returns:
    - ResourceHandle: A handle to the resource.
*/
handle_acquire :: proc(rs: ^ResourceSystem, id: RsrcId) -> (RsrcHandle, Resource_Error) {
	target, loaded := rs.id_to_loaded[id]
	if loaded {
		slot, valid := hm.dynamic_get(&rs.handle_map, target)
		if !valid {
			return {}, .Handle_Error
		}
		return duplicate_handle(rs, slot.handle)
	} else {
		artifact, contained := rs.id_to_artifact[id]
		if !contained {
			//Might want to change the name of this error later on...
			return {}, .Missing_Artifact
		}
		serializer, ok := rs.serializers[artifact._extension]
		if !ok {
			return {}, .Missing_Serializer
		}
		bytes, err := os.read_entire_file(artifact.baked_file_path, rs.allocator)
		if err != nil {
			//TODO
		}
		context.allocator = rs.allocator
		raw_data := serializer.read_from_disk(serializer.user_data, bytes, rs)
		return add_new_slot(rs, id, raw_data)
	}
}

@(private)
add_new_slot :: proc(rs: ^ResourceSystem, id: RsrcId, raw_data: rawptr) -> (RsrcHandle, Resource_Error) {
	slot: ResourceSlot = {
		data        = raw_data,
		checked_out = 1,
		id          = id,
	}
	ptr := &slot
	handle, alloc_err := hm.dynamic_add(&rs.handle_map, slot)
	if alloc_err != nil {
		return {}, .Allocator_Error
	}
	added_slot, _ := hm.dynamic_get(&rs.handle_map, handle)
	rs.id_to_loaded[id] = handle
	added_slot.handle = handle
	return handle, .None
}

/*
Acquires a handle to a resource in an asynchronous manner. If the requested resource is not 
yet loaded it is loaded asynchronously. Once the resource is loaded into Memory the callback
is sent to the dispatcher where it can then be fired. If the requested resource is already in memory 
the callback is sent to the dispatcher immediately.

    Inputs:
    - rs: the ResourceSystem to 
    - id: The stable id to the resource you wish to read from memory.
    - callback: the procedure to execute once the resource has been acquired.
    - dispatcher: responsible for routing/scheduling the execution of the callback.
*/
handle_acquire_async :: proc(rsrc_sys: ^ResourceSystem, id: RsrcId, callback: ResourceCallback, cb_dispatcher: Dispatcher) -> ResourceFuture {
	panic("handle_acquire_async Unimplemented")
}

/*

*/
handle_batch_acquire_async :: proc(rs: ^ResourceSystem) -> ResourceFuture {
	panic("handle_batch_acquire_async Unimplemented")
}

/*

*/
release_handle :: proc(rs: ^ResourceSystem, handle: RsrcHandle) {
	slot, ok := hm.dynamic_get(&rs.handle_map, handle)
	if !ok {
		panic("TODO: release_handle")
	}

	slot.checked_out -= 1
	if slot.checked_out == 0xFFFFFFFF {
		panic("Invalid Frees have occured!")
	}

	if slot.checked_out == 0 {
		hm.dynamic_remove(&rs.handle_map, handle)
		rs.id_to_loaded[slot.id] = {}
		//TODO: Look into adding another callback instead of just blindly freeing here
		defer free(slot.data, rs.allocator)
	}
}

/*
Resolves/dereferrences what ever the resource handle points to, this is used to get the raw data that is stored.

    Inputs:
    - rs:
    - handle:

    Returns:
    - rawptr: pointer to the actual data stored inside the system
*/
handle_resolve :: proc(rs: ^ResourceSystem, handle: RsrcHandle) -> (rawptr, Resource_Error) {
	hanlde := hm.Handle64{}
	result, ok := hm.dynamic_get(&rs.handle_map, handle)
	if !ok {
		return nil, .Handle_Error
	}
	return result.data, .None
}

/*
Performs a shallow copy of a resource. If the resoruce is part of the registry it will be loaded
from disk.

    Inputs:
    - rs:
    - id:

    Returns:
    - new_id: 
    - handle: 
*/
resource_shallow_copy :: proc {
	resource_shallow_copy_on_handle,
	resource_shallow_copy_on_id,
}

resource_shallow_copy_on_id :: proc(rs: ^ResourceSystem, id: RsrcId) -> (RsrcId, RsrcHandle) {
	return {}, {}
}

resource_shallow_copy_on_handle :: proc(rs: ^ResourceSystem, handle: RsrcHandle) -> (RsrcId, RsrcHandle) {
	return {}, {}
}

/*
Copies a handle to a given resource and preserves reference counting
    Inuts:
    - rsrc_sys:
    - handle:

    Returns:
    - a copied resource handle that is reference counted
*/
duplicate_handle :: proc(rs: ^ResourceSystem, handle: RsrcHandle) -> (RsrcHandle, Resource_Error) {
	result, ok := hm.dynamic_get(&rs.handle_map, handle)
	if !ok {
		return {}, .Handle_Error
	}
	result.checked_out += 1
	return handle, .None
}

/*
Used to register a non imported resource to the resource store. Copies the data to_register points to into the registry, taking ownership of it.
It's probably a good idea to free the original after calling this procedure.
    Inputs:
    - rs: 
    - to_register: pointer to the data that will be tracked
    Returns:
    - the id to this handle
*/
copy_resource_into_registry :: proc(rs: ^ResourceSystem, to_register: rawptr) -> (RsrcId, RsrcHandle, Resource_Error) {
	return {}, {}, .None
}

/*
Assumes that the resource to be registered was allocated with the same allocator that rs uses.
    Inputs:
    - rs: 
    - to_register: pointer to the data that will be tracked
    Returns:
    - The id to this resource
    - Handle to the registered resource
    - Error status
*/
resource_register :: proc(rs: ^ResourceSystem, to_register: rawptr) -> (RsrcId, RsrcHandle, Resource_Error) {
	new_id := uuid.generate_v7()
	return new_id, add_new_slot(rs, new_id, to_register)
}

/*

*/
resource_load_status :: proc(rs: ^ResourceSystem, id: RsrcId) -> Load_Status {
	panic("TODO: resource_load_status Unimplemented")
}

/*

*/
write_registry_to_disk :: proc(rs: ResourceSystem, output_path: string) -> Resource_Error {
	return .None
}

/*

*/
read_registry_from_disk :: proc(rs: ^ResourceSystem, file_path: string) -> Resource_Error {
	return .None
}
