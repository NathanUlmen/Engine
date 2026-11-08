package main

import "base:runtime"
import hm "core:container/handle_map"
import list "core:container/intrusive/list"
import "core:encoding/uuid"
import "core:log"
import bits "core:math/bits"
import "core:mem"
import "core:os"
import "core:path/filepath"

DEFAULT_CACHE_ID :: CacheId(bits.U32_MAX)

DEFAULT_CATEGORY :: CacheCategory{100 * mem.Megabyte, DEFAULT_CACHE_ID}

CacheId :: distinct u32

CacheCategory :: struct {
	max_size_bytes: u64,
	category_id:    CacheId,
}

ResourceSystem :: struct {
	marshallers:    map[string]ResourceMarshaller,
	id_to_artifact: map[RsrcId]ResourceArtifact,
	id_to_loaded:   map[RsrcId]RsrcHandle,
	cache_lookup:   map[CacheId]CacheLRU,
	sys_allocator:  mem.Allocator,
	handle_map:     hm.Dynamic_Handle_Map(ResourceSlot, hm.Handle64),
}

Resource_Error :: enum {
	None,
	Not_Loaded,
	Missing_Serializer,
	Invalid_File,
	Extraction_Error,
	Handle_Error,
	Allocator_Error,
	Missing_Artifact,
	Serialization_Error,
	Missing_File,
}

RsrcId :: uuid.Identifier

RsrcHandle :: hm.Handle64

Resource :: struct {
	data:            rawptr,
	data_size_bytes: u64,
	//We pass in rs as current resources might have dependencies it needs to free.
	destructor:      proc(to_free: rawptr, rs: ^ResourceSystem),
}

ResourceSlot :: struct {
	using resource: Resource,
	handle:         RsrcHandle,
	id:             RsrcId,
	ref_count:      u32,
	status:         Load_Status,

	//linked list pointers
	node:           list.Node,
}

/*
Describes the status of a resource.
    - NOT_REQUESTED: Resource is not loaded at all.
    - SCHEDULED: Request is in the queue and awaits processing
    - IN_PROGRESS: Resource is currently being loaded.
    - COMPLETED: Resource has been loaded and its callback has been dispatched.
    - CANCELED: Resource has been canceled and no longer being loaded
    - ERROR: Resource encountered an error while loading. Callback is dispatched but must handle/react to the error.
*/
Load_Status :: enum {
	NOT_LOADED,
	SCHEDULED,
	IN_PROGRESS,
	LOADED,
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

ResourceCallback :: struct {
	user_data: rawptr,
	cb:        proc(user_data: rawptr, handle: RsrcHandle),
}

MarshallerContext :: struct {
	user_data:                  rawptr,
	destroy_serializer_context: proc(user_data: rawptr, allocator: mem.Allocator),
}

/*
An "interface" used by the ResourceSystem.
    Fields:
    - user_data: custom user data field 
    - extension: file extension that this serializer is capable of handling. Must include the '.' EX: ".txt"
    - import_resource: 
    - hydrate_resource: procedure that is responsible for transforming the file bytes of the artifact into useful data.
    - destroy_resource: destroy a resource created by this serializer.
*/
ResourceMarshaller :: struct {
	using serializer_context: MarshallerContext,
	extension:                string,
	import_resource:          proc(user_data: rawptr, file_path: string, allocator: mem.Allocator) -> (a: []ResourceArtifact, ok: bool),
	create_resource:          proc(user_data: rawptr, file_path: string, rsrc_sys: ^ResourceSystem, allocator: mem.Allocator) -> Resource,
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
	id:                   RsrcId, //maybe we can handle this for the user?
	cache_category:       CacheCategory,
	dependencies:         []RsrcId,
	type:                 string,
	baked_file_path:      string,
	name:                 string,
	progenitor_file_path: string, //we can handle
	_extension:           string, //we can handle
	import_version:       u16,
}

/*

*/
rsrc_sys_init :: proc(rs: ^ResourceSystem, allocator: mem.Allocator) {
	//TODO: figure out how to assert random generation is enabled/init.
	rs.sys_allocator = allocator
	rs.marshallers = make(map[string]ResourceMarshaller, rs.sys_allocator)
	rs.id_to_artifact = make(map[RsrcId]ResourceArtifact, rs.sys_allocator)
	rs.id_to_loaded = make(map[RsrcId]RsrcHandle, rs.sys_allocator)
	rs.cache_lookup = make(map[CacheId]CacheLRU)
	hm.dynamic_init(&rs.handle_map, rs.sys_allocator)
	//TODO: default cache creation and init
}

/*

*/
rsrc_sys_destroy :: proc(rs: ^ResourceSystem) {
	context.allocator = rs.sys_allocator
	iterator := hm.iterator_make(&rs.handle_map)
	for slot, handle in hm.iterate(&iterator) {
		slot.resource.destructor(slot.data, rs)
	}

	hm.dynamic_destroy(&rs.handle_map)

	for _, serializer in rs.marshallers {
		serializer.destroy_serializer_context(serializer.user_data, rs.sys_allocator)
	}
	delete(rs.marshallers)
	delete(rs.id_to_loaded)
	delete(rs.cache_lookup)
	// for _, &artifact in rs.id_to_artifact {
	// 	artifact_destroy(&artifact)
	// }
	delete(rs.id_to_artifact)

	//dont like this, shouldnt call this.
	// free_all(rs.sys_allocator)
}

artifact_destroy :: proc(artifact: ^ResourceArtifact) {
}

/*
    Inputs:
    - rs:
    - serializer:
*/
rsrc_sys_register_marshaller :: proc(rs: ^ResourceSystem, serializer: ResourceMarshaller) {
	when ODIN_DEBUG {
		_, contains := rs.marshallers[serializer.extension]
		log.warnf("Replaced existing serializer responsible for extension %v", serializer.extension)
	}
	to_replace, contained := rs.marshallers[serializer.extension]
	if contained {
		to_replace.destroy_serializer_context(to_replace.user_data, rs.sys_allocator)
	}
	rs.marshallers[serializer.extension] = serializer
}

/*
Produces resrouce artifact(s) from a target_file
    Inputs:
    - rs:
    - target_file:
*/
rsrc_sys_import_file :: proc(rs: ^ResourceSystem, target_file: string) -> Resource_Error {
	//Retrieve serializer
	extension := filepath.ext(target_file)
	serializer, contains := rs.marshallers[extension]
	if !contains {
		return Resource_Error.Missing_Serializer
	}

	artifacts, ok := serializer.import_resource(serializer.user_data, target_file, rs.sys_allocator)
	if !ok {
		return .Serialization_Error
	}

	//update the extension
	for &artifact in artifacts {
		artifact._extension = extension
		rs.id_to_artifact[artifact.id] = artifact
	}
	return .None
}

/*
Acquires a handle to an already loaded resource. If the resource state is not LOADED it will return an error.
    Inputs:
    - rs: the ResourceSystem to 
    - id: The stable id to the resource you wish to read from memory.
    Returns:
    - ResourceHandle: A handle to the resource.
    - Resource_Error: 
*/
handle_acquire :: proc(rs: ^ResourceSystem, id: RsrcId) -> (RsrcHandle, Resource_Error) {
	handle := rs.id_to_loaded[id]
	target_slot, contained := hm.get(&rs.handle_map, handle)
	if contained && target_slot.status == .LOADED {
		//our resource was in cache, we need to remove it now.
		if target_slot.ref_count == 0 {
			category := rs.id_to_artifact[id].cache_category
			cache := &rs.cache_lookup[category.category_id]
			cache_take_entry(rs, cache, target_slot)
		}
		target_slot.ref_count += 1
		//should we check for overflow here?
		return target_slot.handle, .None
	}
	return {}, .Not_Loaded
}

@(private)
add_new_slot :: proc(rs: ^ResourceSystem, id: RsrcId, resource: Resource) -> (RsrcHandle, Resource_Error) {
	slot: ResourceSlot = {
		resource  = resource,
		ref_count = 1,
		id        = id,
	}
	handle, alloc_err := hm.add(&rs.handle_map, slot)
	assert(alloc_err == nil)

	added_slot, _ := hm.get(&rs.handle_map, handle)
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
handle_acquire_async :: proc(rs: ^ResourceSystem, id: RsrcId, callback: ResourceCallback, cb_dispatcher: Dispatcher) -> ResourceFuture {
	handle := rs.id_to_loaded[id]
	slot, contained := hm.get(&rs.handle_map, handle)
	if contained {
		slot.ref_count += 1
		//TODO: post callback to dispatcher
		return ResourceFuture{.LOADED}
	}

	panic("handle_acquire_async Unimplemented")
}

/*

*/
handle_batch_acquire_async :: proc(rs: ^ResourceSystem) -> ResourceFuture {
	panic("handle_batch_acquire_async Unimplemented")
}

/*


*/
release_handle :: proc(rs: ^ResourceSystem, handle: RsrcHandle) -> Resource_Error {
	slot, ok := hm.get(&rs.handle_map, handle)
	if !ok {
		return .Handle_Error
	}

	slot.ref_count -= 1
	assert(slot.ref_count != bits.U32_MAX, "Multiple Invalid Frees have occurred!")

	//give ownership to the cache
	if slot.ref_count == 0 {
		artifact, contains := rs.id_to_artifact[slot.id]
		cache, err := ensure_cache(rs, artifact)
		assert(err == .None)
		cache_add_entry(rs, cache, slot)
	}
	return .None
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
	result, ok := hm.get(&rs.handle_map, handle)
	if !ok {
		return nil, .Handle_Error
	}
	assert(result.ref_count > 0, "You are resolving a handle that you already freed or improperly duplicated!!")

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
	panic("TODO: resource_shallow_copy_on_id Unimplemented")
}

resource_shallow_copy_on_handle :: proc(rs: ^ResourceSystem, handle: RsrcHandle) -> (RsrcId, RsrcHandle) {
	panic("TODO: resource_shallow_copy_on_handle Unimplemented")
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
	result, ok := hm.get(&rs.handle_map, handle)
	if !ok {
		return {}, .Handle_Error
	}
	result.ref_count += 1
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
copy_resource_into_registry :: proc(rs: ^ResourceSystem, to_register: rawptr, cache_category: CacheCategory) -> (RsrcId, RsrcHandle, Resource_Error) {
	panic("TODO: copy_resource_into_registry is Unimplemented")
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
resource_register :: proc(rs: ^ResourceSystem, to_register: rawptr, cache_category: CacheCategory) -> (RsrcId, RsrcHandle, Resource_Error) {
	panic("TODO: resource_register is Unimplemented")
}

/*

*/
resource_load_status :: proc(rs: ^ResourceSystem, id: RsrcId) -> Load_Status {
	_, contained := rs.id_to_loaded[id]
	if contained {
		return .LOADED
	} else {
		panic("TODO: resource_load_status Unimplemented")
	}
}

/*
Loads a resource in a synchronous/blocking fashion and gives you a handle to it. If the resource is already 
loaded you will recieve a hanlde to it
    Inputs:
    - rs:
    - id:
    Returns:
    - RsrcHandle:
    - Resource_Error:
*/
load_resource :: proc(rs: ^ResourceSystem, id: RsrcId) -> (RsrcHandle, Resource_Error) {
	handle, error := handle_acquire(rs, id)
	#partial switch error {
	case .Not_Loaded:
		//check
		artifact, contains := rs.id_to_artifact[id]
		if !contains {
			return {}, .Missing_Artifact
		}

		//retrieve serializer
		serializer, ok := rs.marshallers[artifact._extension]
		if !ok {
			return {}, .Missing_Serializer
		}

		resource := serializer.create_resource(serializer.user_data, artifact.baked_file_path, rs, rs.sys_allocator)
		assert(resource.data_size_bytes > 0, "Data should not have a size of 0!")

		return add_new_slot(rs, id, resource)
	case:
		return handle, error
	}
}


ensure_cache :: proc {
	ensure_cache_artifact,
	ensure_cache_id,
}

@(private)
ensure_cache_artifact :: proc(rs: ^ResourceSystem, artifact: ResourceArtifact) -> (^CacheLRU, Resource_Error) {
	return ensure_cache_id(rs, artifact.cache_category.category_id, artifact.cache_category.max_size_bytes)
}

@(private)
ensure_cache_id :: proc(rs: ^ResourceSystem, category_id: CacheId, cache_max_size_bytes: u64) -> (^CacheLRU, Resource_Error) {
	cache, cache_contained := &rs.cache_lookup[category_id]
	if !cache_contained {
		c := CacheLRU{}
		cache_init(&c, cache_max_size_bytes)
		rs.cache_lookup[category_id] = c
		return &rs.cache_lookup[category_id], .None
	}
	return cache, .None
}

/*

*/
write_registry_to_disk :: proc(rs: ResourceSystem, output_path: string) -> Resource_Error {
	panic("TODO write_registry_to_disk Unimplemented")
}

/*

*/
read_registry_from_disk :: proc(rs: ^ResourceSystem, file_path: string) -> Resource_Error {
	panic("TODO read_reg_from_disk Unimplemented")
}

//-------CACHE-------------


/*
Cache implementation for the resource store.

Requirements:
- Thread safety that goes well with the resource sys
- dynamic/adjustable max size

*/
CacheLRU :: struct {
	current_size_bytes: u64,
	max_capacity_bytes: u64,
	linked_list:        list.List,
}

cache_init :: proc(cache: ^CacheLRU, max_size_bytes: u64) {
	cache.max_capacity_bytes = max_size_bytes
	cache.current_size_bytes = 0
}

cache_add_entry :: proc(rs: ^ResourceSystem, cache: ^CacheLRU, slot: ^ResourceSlot) {
	cache.current_size_bytes += slot.data_size_bytes
	list.push_front(&cache.linked_list, &slot.node)
	cache_ensure_limit(rs, cache)
}

cache_take_entry :: proc(rs: ^ResourceSystem, cache: ^CacheLRU, slot: ^ResourceSlot) {
	cache.current_size_bytes -= slot.data_size_bytes
	list.remove(&cache.linked_list, &slot.node)
}

cache_ensure_limit :: proc(rs: ^ResourceSystem, cache: ^CacheLRU) {
	for cache.current_size_bytes > cache.max_capacity_bytes {
		removed_node := list.pop_back(&cache.linked_list)
		assert(removed_node != nil)
		removed_slot := container_of(removed_node, ResourceSlot, "node")
		removed_slot.resource.destructor(removed_slot.data, rs)
		cache.current_size_bytes -= removed_slot.data_size_bytes
		hm.remove(&rs.handle_map, removed_slot.handle)
		delete_key(&rs.id_to_loaded, removed_slot.id)
	}
}

cache_configure :: proc(rs: ^ResourceSystem, cache_id: CacheId, max_size_bytes: u64) {
	cache, _ := &rs.cache_lookup[cache_id]
	cache.max_capacity_bytes = max_size_bytes
	cache_ensure_limit(rs, cache)
}
