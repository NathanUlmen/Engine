package main

import "base:runtime"
import hm "core:container/handle_map"
import list "core:container/intrusive/list"
import "core:encoding/uuid"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"

ResourceSystem :: struct {
	serializers:    map[string]ResourceMarshaller,
	id_to_artifact: map[RsrcId]ResourceArtifact,
	id_to_loaded:   map[RsrcId]RsrcHandle,
	cache:          Cache,
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
	destructor:      proc(to_free: rawptr, rs: ^ResourceSystem),
}

ResourceData :: struct {
	data: rawptr,
}

ResourceSlot :: struct {
	using resource: Resource,
	handle:         RsrcHandle,
	id:             RsrcId,
	checked_out:    u32,
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
	create_resource:          proc(user_data: rawptr, file_data: []byte, rsrc_sys: ^ResourceSystem, allocator: mem.Allocator) -> Resource,
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
	rs.serializers = make(map[string]ResourceMarshaller, rs.sys_allocator)
	rs.id_to_artifact = make(map[RsrcId]ResourceArtifact, rs.sys_allocator)
	rs.id_to_loaded = make(map[RsrcId]RsrcHandle, rs.sys_allocator)
	cache_init(&rs.cache, rs.sys_allocator, {1024, .LRU})
	hm.dynamic_init(&rs.handle_map, rs.sys_allocator)
}

/*

*/
rsrc_sys_destroy :: proc(rs: ^ResourceSystem) {
	hm.dynamic_destroy(&rs.handle_map)

	//TODO: Revist this later. (Maybe add a delete proc to the Serializer ?)
	cache_destroy(rs, &rs.cache)
	for _, serializer in rs.serializers {
		serializer.destroy_serializer_context(serializer.user_data, rs.sys_allocator)
	}
	free_all(rs.sys_allocator)
}

/*
    Inputs:
    - rs:
    - serializer:
*/
rsrc_sys_register_serializer :: proc(rs: ^ResourceSystem, serializer: ResourceMarshaller) {
	when ODIN_DEBUG {
		_, contains := rs.serializers[serializer.extension]
		log.warnf("Replaced existing serializer responsible for extension %v", serializer.extension)
	}
	to_replace, contained := rs.serializers[serializer.extension]
	if contained {
		to_replace.destroy_serializer_context(to_replace.user_data, rs.sys_allocator)
	}
	rs.serializers[serializer.extension] = serializer
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
	serializer, contains := rs.serializers[extension]
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
Acquires a handle to an already loaded resource. If the resource state is not COMPLETED will return an error.
    Inputs:
    - rs: the ResourceSystem to 
    - id: The stable id to the resource you wish to read from memory.
    Returns:
    - ResourceHandle: A handle to the resource.
    - Resource_Error: 
*/
handle_acquire :: proc(rs: ^ResourceSystem, id: RsrcId) -> (RsrcHandle, Resource_Error) {
	target, loaded := rs.id_to_loaded[id]
	if loaded {
		slot, valid := hm.dynamic_get(&rs.handle_map, target)
		if !valid {
			return {}, .Handle_Error
		}
		return duplicate_handle(rs, slot.handle)
	}
	return {}, .Not_Loaded
}

@(private)
add_new_slot :: proc(rs: ^ResourceSystem, id: RsrcId, resource: Resource) -> (RsrcHandle, Resource_Error) {
	slot: ResourceSlot = {
		resource    = resource,
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
handle_acquire_async :: proc(rs: ^ResourceSystem, id: RsrcId, callback: ResourceCallback, cb_dispatcher: Dispatcher) -> ResourceFuture {
	result, contained := rs.id_to_loaded[id]
	if contained {
		slot, _ := hm.dynamic_get(&rs.handle_map, result)
		slot.checked_out += 1
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
	slot, ok := hm.dynamic_get(&rs.handle_map, handle)
	if !ok {
		return .Handle_Error
	}

	slot.checked_out -= 1
	if slot.checked_out == 0xFFFFFFFF {
		return .Handle_Error
	}

	if slot.checked_out == 0 {
		hm.dynamic_remove(&rs.handle_map, handle)
		cache_add_entry(rs, &rs.cache, {slot.id, slot^})
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
resource_register :: proc(rs: ^ResourceSystem, to_register: rawptr) -> (RsrcId, RsrcHandle, Resource_Error) {
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
		//check out cache here first...
		result, cache_hit := cache_take_entry(rs, &rs.cache, id)
		if cache_hit {
			return add_new_slot(rs, id, result.resource)
		}

		artifact, contained := rs.id_to_artifact[id]
		if !contained {
			//Might want to change the name of this error later on...
			return {}, .Missing_Artifact
		}
		//retrieve serializer
		serializer, ok := rs.serializers[artifact._extension]
		if !ok {
			return {}, .Missing_Serializer
		}

		bytes, err := os.read_entire_file(artifact.baked_file_path, rs.sys_allocator)
		if err != nil {
			//TODO: return an error that matches read file error
		}

		resource := serializer.create_resource(serializer.user_data, bytes, rs, rs.sys_allocator)
		assert(resource.data_size_bytes > 0)
		return add_new_slot(rs, id, resource)
	case:
		return handle, error
	}
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

CacheConfig :: struct {
	max_size_bytes: u64,
	evict_strat:    Eviction_Strategy,
}

Eviction_Strategy :: enum {
	LRU,
}

CacheNode :: struct {
	using link: list.Node,
	entry:      CacheEntry,
}

CacheEntry :: struct {
	id:       RsrcId,
	resource: ResourceSlot,
}

Cache :: struct {
	entry_lookup:       map[RsrcId]^CacheNode,
	current_size_bytes: u64,
	max_capacity_bytes: u64,
	strategy:           Eviction_Strategy,
	linked_list:        list.List,
}

cache_init :: proc(c: ^Cache, allocator: mem.Allocator, config: CacheConfig) {
	c.entry_lookup = make(map[RsrcId]^CacheNode, allocator)
	c.max_capacity_bytes = config.max_size_bytes
	c.strategy = config.evict_strat
}

cache_destroy :: proc(rs: ^ResourceSystem, c: ^Cache) {
	for !list.is_empty(&c.linked_list) {
		link := list.pop_back(&c.linked_list)
		node := container_of(link, CacheNode, "link")
		node.entry.resource.destructor(node.entry.resource.data, rs)
		free(node)
	}
	delete(c.entry_lookup)
	c.current_size_bytes = 0
}

cache_add_entry :: proc(rs: ^ResourceSystem, cache: ^Cache, to_add: CacheEntry) {
	new_node := new(CacheNode)
	new_node.entry = to_add
	cache.entry_lookup[to_add.id] = new_node
	cache.current_size_bytes += to_add.resource.data_size_bytes
	list.push_front(&cache.linked_list, new_node)
	cache_ensure_limit(rs, cache)
}

cache_take_entry :: proc(rs: ^ResourceSystem, cache: ^Cache, target_id: RsrcId) -> (target: CacheEntry, contained: bool) {
	to_remove, has := cache.entry_lookup[target_id]
	if !has {
		return {}, false
	}
	delete_key(&cache.entry_lookup, target_id)
	list.remove(&cache.linked_list, &to_remove.link)
	defer free(to_remove)
	return to_remove.entry, true
}

cache_ensure_limit :: proc(rs: ^ResourceSystem, cache: ^Cache) {
	log.info("Current Size", cache.current_size_bytes)
	log.info("Max Capacity", cache.max_capacity_bytes)
	for cache.current_size_bytes > cache.max_capacity_bytes && !list.is_empty(&cache.linked_list) {
		last := cache.linked_list.tail
		node := container_of(last, CacheNode, "link")
		removed, _ := cache_take_entry(rs, cache, node.entry.id)
		handle, _ := rs.id_to_loaded[removed.id]
		delete_key(&rs.id_to_loaded, removed.id)
		cache.current_size_bytes -= removed.resource.data_size_bytes
		removed.resource.destructor(removed.resource.data, rs)
	}
}

cache_configure :: proc(rs: ^ResourceSystem, cache: ^Cache, config: CacheConfig) {
	cache.max_capacity_bytes = config.max_size_bytes
	cache.strategy = config.evict_strat
	cache_ensure_limit(rs, cache)
}
