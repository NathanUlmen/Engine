package main

import hm "core:container/handle_map"
import list "core:container/intrusive/list"
import "core:encoding/uuid"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
_ :: fmt
import "core:log"
_ :: log
import bits "core:math/bits"
import "core:mem"
import "core:path/filepath"


Category_Id :: u32

/*
Used to configure a resource category.
    - category_budget_bytes: The budget in bytes that the given category is alloted. The Resource_Store asserts that this value is not exceeded.
    - cache_budget_bytes: The number of bytes that can be used to cache resources in this category. Resrouces are moved to the cache when they have zero references to them. They are evicted using an LRU strategy.
    - category_id: Denotes the category. It's recommended to use an enum for this.

*/
Category_Configuration :: struct {
	category_budget_bytes: u64,
	cache_budget_bytes:    u64,
	category_id:           Category_Id,
}


Resource_Store :: struct {
	marshallers:     map[string]Resource_Marshaller,
	id_to_artifact:  map[Rs_Id]Resource_Artifact,
	id_to_loaded:    map[Rs_Id]hm.Handle64,
	categories:      map[Category_Id]Resource_Category,
	sys_allocator:   mem.Allocator,
	handle_map:      hm.Dynamic_Handle_Map(Resource_Slot, hm.Handle64),
	pool:            ^thread.Pool,
	marshaller_lock: ^sync.RW_Mutex,
	artficat_lock:   ^sync.RW_Mutex,
}

Resource_Error :: enum u8 {
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
	Type_Missmatch,
	Category_Missmatch,
	Category_Bugdet_Exceeded,
	Missing_Category,
}

Rs_Id :: uuid.Identifier

Rs_Handle :: struct($T: typeid) {
	using handle: hm.Handle64,
}

Resource :: struct {
	type:            typeid,
	data:            rawptr,
	data_size_bytes: u64,
	//We pass in rs as current resources might have dependencies it needs to free.
	destructor:      proc(to_free: rawptr, rs: ^Resource_Store),
}

Resource_Slot :: struct {
	using resource: Resource,
	handle:         hm.Handle64,
	id:             Rs_Id,
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
Resource_Future :: struct {
	status: Load_Status,
}

Dispatcher :: struct {
	post: proc(to_run: Resource_Callback),
}

Resource_Callback :: struct {
	user_data: rawptr,
	cb:        proc(user_data: rawptr, handle: Rs_Handle(any)),
}

Marshaller_Context :: struct {
	user_data:                  rawptr,
	destroy_serializer_context: proc(user_data: rawptr, allocator: mem.Allocator),
}

/*
An "interface" used by the ResourceStore.
    Fields:
    - user_data: custom user data field 
    - extension: file extension that this serializer is capable of handling. Must include the '.' EX: ".txt"
    - import_resource: 
    - hydrate_resource: procedure that is responsible for transforming the file bytes of the artifact into useful data.
    - destroy_resource: destroy a resource created by this serializer.
*/
Resource_Marshaller :: struct {
	using serializer_context: Marshaller_Context,
	extension:                string,
	import_resource:          proc(user_data: rawptr, file_path: string, allocator: mem.Allocator) -> (a: []Resource_Artifact, ok: bool),
	create_resource:          proc(user_data: rawptr, file_path: string, rsrc_sys: ^Resource_Store, allocator: mem.Allocator) -> Resource,
}

/*
    Fields:
    - id: stable id that is associated with this resource.
    - dependencies: ResourceArtifacts of other resources that this resource depends on.
    - category_id: Category that this resource belongs to. By default will zero initialize to the default category defined above.
    - baked_file_path: the file path to the baked resource data
    - name: Name associated with artifact
    - progenitor_file_path: path to the file that this artifact was derived/produced from.
    - _extension: Used to select the serializer to resolve this artifact.
    - import_version: uhhh

*/
Resource_Artifact :: struct {
	stable_id:            Rs_Id, //maybe we can handle this for the user?
	dependencies:         []Rs_Id,
	baked_file_path:      string,
	name:                 string,
	progenitor_file_path: string, //we can handle
	_extension:           string, //we can handle
	category_id:          Category_Id,
	import_version:       u16,
}

/*
Initializes all the fields of the Resource_System. 

Inputs:
    - rs: 
    - allocator: The allocator that the Resource_Store will use for all allocations.
    - thread_count: The number of threads available to use for asynchronous loading.
*/
rs_store_init :: proc(rs: ^Resource_Store, allocator: mem.Allocator, categories: []Category_Configuration = nil, thread_count: int = 1) {
	//TODO: figure out how to assert random generation is enabled/init.
	rs.sys_allocator = allocator
	rs.marshallers = make(map[string]Resource_Marshaller, rs.sys_allocator)
	rs.id_to_artifact = make(map[Rs_Id]Resource_Artifact, rs.sys_allocator)
	rs.id_to_loaded = make(map[Rs_Id]hm.Handle64, rs.sys_allocator)
	rs.categories = make(map[Category_Id]Resource_Category, rs.sys_allocator)

	if categories != nil {
		for config in categories {
			init_categories(rs, config)
		}
	}

	hm.dynamic_init(&rs.handle_map, rs.sys_allocator)
	rs.pool = new(thread.Pool)
	thread.pool_init(rs.pool, rs.sys_allocator, thread_count)
	//TODO: default cache creation and init
}

/*
Frees all resources stored stored inside the Resource_Store. Shutsdown thread pool by joining.
Inputs:
    - rs: The system that will be freed. 
*/
rs_store_destroy :: proc(rs: ^Resource_Store) {
	thread.pool_join(rs.pool)
	thread.pool_destroy(rs.pool)
	free(rs.pool)

	iterator := hm.iterator_make(&rs.handle_map)
	for slot, _ in hm.iterate(&iterator) {
		slot.resource.destructor(slot.data, rs)
	}

	hm.dynamic_destroy(&rs.handle_map)

	for _, serializer in rs.marshallers {
		serializer.destroy_serializer_context(serializer.user_data, rs.sys_allocator)
	}

	delete(rs.id_to_loaded)
	delete(rs.categories)
	for _, &artifact in rs.id_to_artifact {
		artifact_destroy(rs, &artifact)
	}
	delete(rs.marshallers)
	delete(rs.id_to_artifact)
	//dont like this, shouldnt call this.
	// free_all(rs.sys_allocator)
}

artifact_destroy :: proc(rs: ^Resource_Store, artifact: ^Resource_Artifact) {
	delete(artifact.dependencies, rs.sys_allocator)
	delete(artifact.baked_file_path, rs.sys_allocator)
	delete(artifact.name, rs.sys_allocator)
	delete(artifact.progenitor_file_path, rs.sys_allocator)
	delete(artifact._extension, rs.sys_allocator)
}

/*
Adds a Resource_Marshaller to the resource system. Marshallers are used by the resource store to read resource data from files into memory.
They are also used to produce Resource_Artifacts which is a container that stores info about a Resource. Resource_Artifacts are used like a manifest.
Marshallers are invoked/used based on file extension.
    Inputs
    - rs:
    - serializer:
*/
rs_store_register_marshaller :: proc(rs: ^Resource_Store, serializer: Resource_Marshaller) {
	when ODIN_DEBUG {
		if _, contains := rs.marshallers[serializer.extension]; contains {
			log.warnf("Replaced existing serializer responsible for extension %v", serializer.extension)
		}
	}
	to_replace, contained := rs.marshallers[serializer.extension]
	if contained {
		to_replace.destroy_serializer_context(to_replace.user_data, rs.sys_allocator)
	}
	rs.marshallers[serializer.extension] = serializer
}

/*
The Resource_Store produces Resource_Artifact(s) by invoking a user registered Marshaller. The Marshaller to invoke
is determiend by the file extension of the file to be imported. The Resource_Artifact(s) produced by the Marshaller added to a 
manifest that the Resource_Store uses to handle loading and .. TODO.
    Inputs:
    - rs: The Resource_Store that will have the 
    - target_file: file to be imported.
    Returns:
    - err: A Missing_Serializer when a Marshaller is not present or a Serialization_Error when something goes wrong during the import
    process in the Marshallers import_resource procedure.
*/
rs_store_import_file :: proc(rs: ^Resource_Store, target_file: string) -> (err: Resource_Error) {
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
		artifact._extension = strings.clone(extension)
		if old, has := rs.id_to_artifact[artifact.stable_id]; has {
			artifact_destroy(rs, &old)
		}
		rs.id_to_artifact[artifact.stable_id] = artifact
	}

	return .None
}

/*
Acquires a handle to an already loaded resource. If the resource state is not LOADED it will return an error. This operations is 
relatively expensive compared to handle_duplicate.
    Inputs:
    - rs: The Resource_Store to 
    - id: The stable id to the resource you wish to read from memory.
    Returns:
    - ResourceHandle: A handle to the resource.
    - Resource_Error: 
*/
handle_acquire :: proc(rs: ^Resource_Store, id: Rs_Id, $T: typeid) -> (Rs_Handle(T), Resource_Error) {
	handle := rs.id_to_loaded[id]
	target_slot, contained := hm.get(&rs.handle_map, handle)
	if contained && target_slot.status == .LOADED {
		if target_slot.type != T {
			return {}, .Type_Missmatch
		}
		//our resource was in cache, we need to remove it now.
		if target_slot.ref_count == 0 {
			category_id := rs.id_to_artifact[id].category_id
			category := &rs.categories[category_id]
			cache_take_entry(rs, category, target_slot)
		}
		target_slot.ref_count += 1
		//should we check for overflow here?
		return Rs_Handle(T){handle = target_slot.handle}, .None
	}
	return {}, .Not_Loaded
}

/*
Copies a handle to a resource, incrementing the ref_count in the process. 
    Inuts:
    - rs:
    - handle:
    Returns:
    - a copied resource handle that is reference counted
*/
handle_duplicate :: proc(rs: ^Resource_Store, handle: Rs_Handle($T)) -> (Rs_Handle(T), Resource_Error) {
	result, ok := hm.get(&rs.handle_map, handle)
	if !ok {
		return Rs_Handle(T){}, .Handle_Error
	}
	result.ref_count += 1
	return handle, .None
}

/*
"Releases" the handle to the associated Resource, decreasing the ref_count by one.
    Inputs:
    - rs:
    - handle:
    Returns:
    - err:
*/
handle_release :: proc(rs: ^Resource_Store, handle: Rs_Handle($T)) -> Resource_Error {
	slot, ok := hm.get(&rs.handle_map, handle)
	if !ok {
		return .Handle_Error
	}

	slot.ref_count -= 1
	assert(slot.ref_count != bits.U32_MAX, "Invalid Frees have occurred!")

	//give ownership to the cache
	if slot.ref_count == 0 {
		artifact, contained := rs.id_to_artifact[slot.id]
		//this means a resource was registered and thus should not be cached.
		if !contained {
			return resource_remove(rs, slot)
		}

		category, category_contained := &rs.categories[artifact.category_id]
		if !category_contained {
			//TODO: might want to revist this later as error from resource_remove is not handled...
			resource_remove(rs, slot)
			return .Missing_Category
		}

		cache_add_entry(rs, &category.cache, slot)
	}
	return .None
}

/*
Resolves/dereferrences what ever the resource handle points to, this is used to get the raw data that is stored.
    Inputs:
    - rs:
    - handle:
    Returns:
    - rawptr: pointer to the actual data stored inside the store 
*/
handle_resolve :: proc(rs: ^Resource_Store, handle: Rs_Handle($T)) -> (^T, Resource_Error) {
	slot, ok := hm.get(&rs.handle_map, handle)
	if !ok {
		return nil, .Handle_Error
	}
	assert(slot.ref_count > 0, "You are resolving a handle that you already freed or improperly duplicated!!")

	if slot.type != T {
		return nil, .Type_Missmatch
	}

	return cast(^T)slot.data, .None
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
resource_load :: proc(rs: ^Resource_Store, id: Rs_Id, $T: typeid) -> (Rs_Handle(T), Resource_Error) {
	handle, error := handle_acquire(rs, id, T)
	#partial switch error {
	case .Not_Loaded:
		//check
		artifact, contains := rs.id_to_artifact[id]
		if !contains {
			return Rs_Handle(T){}, .Missing_Artifact
		}

		//retrieve serializer
		serializer, ok := rs.marshallers[artifact._extension]
		if !ok {
			return {}, .Missing_Serializer
		}

		resource := serializer.create_resource(serializer.user_data, artifact.baked_file_path, rs, rs.sys_allocator)
		assert(resource.data_size_bytes > 0, "Data should not have a size of 0!")
		category := &rs.categories[artifact.category_id]


		over_budget := category.current_size_bytes + resource.data_size_bytes > category.budget_bytes
		fmt.assertf(!over_budget, "Budget of %v bytes for Category with id %v exceeded.", category.budget_bytes, category.category_id)


		if T != resource.type {
			resource.destructor(resource.data, rs)
			return {}, .Type_Missmatch
		}

		return add_new_slot(rs, id, resource, T)
	case:
		return handle, error
	}
}

/*
Acquires a handle to a resource in an asynchronous manner. If the requested resource is not 
yet loaded it is loaded asynchronously. Once the resource is loaded into Memory the callback
is sent to the dispatcher where it can then be fired. If the requested resource is already in memory 
the callback is sent to the dispatcher immediately. The user must 
    Inputs:
    - rs: the ResourceStore to 
    - id: The stable id to the resource you wish to read from memory.
    - callback: the procedure to execute once the resource has been acquired.
    - dispatcher: responsible for routing/scheduling the execution of the callback.
*/
resource_load_async :: proc(rs: ^Resource_Store, id: Rs_Id, callback: Resource_Callback, cb_dispatcher: Dispatcher, $T: typeid) -> Resource_Future {
	handle := rs.id_to_loaded[id]
	slot, contained := hm.get(&rs.handle_map, handle)
	if contained {
		slot.ref_count += 1
		//TODO: post callback to dispatcher
		return Resource_Future{.LOADED}
	}

	//Case: Resrouce not loaded.
	//1. Reserve/check out a slot for our data.
	new_slot_handle, err := add_new_slot(rs, id, {}, T, .SCHEDULED)

	//TODO: handlde error better.
	assert(err == .None)

	reserved_slot := hm.get(&rs.handle_map, new_slot_handle)


	//2. Start loading of our resrouce
	artifact, cont := rs.id_to_artifact[id]
	if !cont {
		return {.ERROR}
	}

	marshaller, has := rs.marshallers[artifact._extension]
	if !has {
		return Resource_Future{.ERROR}
	}

	Bar :: struct {
		file_path:  string,
		marshaller: Resource_Marshaller,
		rs:         ^Resource_Store,
		slot:       ^Resource_Slot,
		cb:         Resource_Callback,
		dispatcher: Dispatcher,
	}

	bar := new(Bar)
	bar^ = {artifact.baked_file_path, marshaller, rs, reserved_slot, callback, cb_dispatcher}

	foo :: proc(task: thread.Task) {
		casted := cast(^Bar)task.data

		casted.slot.status = .IN_PROGRESS
		//TODO: update create_resource to have the ability to return an error
		resource := casted.marshaller.create_resource(casted.marshaller.user_data, casted.file_path, casted.rs, casted.rs.sys_allocator)
		assert(resource.data != nil)

		//insert resource into slot
		casted.slot.resource = resource
		casted.slot.status = .LOADED

		//TODO: Dispatcher callback
		// casted.dispatcher.post(casted.cb)
		casted.cb.cb(casted.cb.user_data, Rs_Handle(any){casted.slot.handle})
		free(casted)
	}

	thread.pool_add_task(rs.pool, rs.sys_allocator, foo, bar)
	thread.pool_start(rs.pool)
	return {.IN_PROGRESS}
}

/*

*/
batch_load_async :: proc(rs: ^Resource_Store) -> Resource_Future {
	panic("handle_batch_acquire_async Unimplemented")
}


/*
Creates a new entry in the Resource_Store and stores the 'to_register' resource inside of the store. This procedure assumes that the 
'to_register' resource was allocated using same allocator as 'rs.sys_allocator'. Resources registered this way are NOT cached, and will be unloaded/freed the
moment their ref_count hits 0.
    Inputs:
    - rs: The Resource_Store that will take ownership of 'to_register'
    - to_register:
    Returns:
    - The id to this resource. This Id is not a stable identifier.
    - Handle to the registered resource
    - Error status
*/
resource_register :: proc(rs: ^Resource_Store, to_register: Resource, $T: typeid) -> (Rs_Handle(T), Resource_Error) {
	id := uuid.generate_v7(nil)
	slot_handle, err := add_new_slot(rs, id, to_register, T)
	if err != .None {
		return {}, err
	}
	return slot_handle, .None
}

/*

*/
resource_load_status :: proc(rs: ^Resource_Store, id: Rs_Id) -> Load_Status {
	handle, contained := rs.id_to_loaded[id]
	if contained {
		return hm.get(&rs.handle_map, handle).status
	} else {
		return .NOT_LOADED
	}
}


@(private)
add_new_slot :: proc(rs: ^Resource_Store, id: Rs_Id, resource: Resource, $T: typeid, status: Load_Status = .LOADED) -> (Rs_Handle(T), Resource_Error) {
	slot: Resource_Slot = {
		resource  = resource,
		ref_count = 1,
		id        = id,
		status    = status,
	}
	handle, alloc_err := hm.add(&rs.handle_map, slot)
	assert(alloc_err == nil)

	added_slot, _ := hm.get(&rs.handle_map, handle)
	rs.id_to_loaded[id] = handle
	added_slot.handle = handle
	return Rs_Handle(T){handle}, .None
}


@(private)
init_categories :: proc(rs: ^Resource_Store, config: Category_Configuration) {
	category: Resource_Category = {
		category_id          = config.category_id,
		budget_bytes         = config.category_budget_bytes,
		cache_max_size_bytes = config.cache_budget_bytes,
	}
	rs.categories[config.category_id] = category
	cache_init(&rs.categories[config.category_id], config.cache_budget_bytes)
}

/*

//TODO better handling here.
*/
resource_remove :: proc(rs: ^Resource_Store, removed_slot: ^Resource_Slot) -> Resource_Error {
	removed_slot.destructor(removed_slot.data, rs)
	found, _ := hm.remove(&rs.handle_map, removed_slot.handle)
	delete_key(&rs.id_to_loaded, removed_slot.id)
	if !found {
		return .Handle_Error
	}
	return .None
}

/*

*/
id_from_handle :: proc(rs: ^Resource_Store, handle: Rs_Handle(any)) -> (Rs_Id, Resource_Error) {
	slot, contained := hm.get(&rs.handle_map, handle)
	if !contained {
		return {}, .Handle_Error
	}
	return slot.id, .None
}

/*

*/
artifacts_write_to_disk :: proc(rs: Resource_Store, output_path: string) -> Resource_Error {
	panic("TODO write_registry_to_disk Unimplemented")
}

/*

*/
artifacts_read_from_disk :: proc(rs: ^Resource_Store, file_path: string) -> Resource_Error {
	panic("TODO read_reg_from_disk Unimplemented")
}


/*

*/
cache_clean :: proc(rs: ^Resource_Store, target_category: Category_Id) {
	category, contained := &rs.categories[target_category]
	assert(contained)
	cache_ensure_limit(rs, &category.cache, 0)
}

/*

*/
cache_resize :: proc(rs: ^Resource_Store, target_category: Category_Id, new_size_bytes: u64) {
	category, contained := &rs.categories[target_category]
	assert(contained)
	category.cache_max_size_bytes = new_size_bytes
	cache_ensure_limit(rs, &category.cache)
}

//-------CACHE IMPLEMENTATION-------------


/*
Cache implementation for the resource store.

Requirements:
- Thread safety that goes well with the resource sys
- dynamic/adjustable max size

*/

Resource_Category :: struct {
	budget_bytes:       u64,
	current_size_bytes: u64,
	using cache:        CacheLRU,
	category_id:        Category_Id,
}


CacheLRU :: struct {
	cache_current_size_bytes: u64,
	cache_max_size_bytes:     u64,
	linked_list:              list.List,
}

cache_init :: proc(cache: ^CacheLRU, max_size_bytes: u64) {
	cache.cache_max_size_bytes = max_size_bytes
	cache.cache_current_size_bytes = 0
}

cache_add_entry :: proc(rs: ^Resource_Store, cache: ^CacheLRU, slot: ^Resource_Slot) {
	cache.cache_current_size_bytes += slot.data_size_bytes
	list.push_front(&cache.linked_list, &slot.node)
	cache_ensure_limit(rs, cache)
}

cache_take_entry :: proc(rs: ^Resource_Store, cache: ^CacheLRU, slot: ^Resource_Slot) {
	cache.cache_current_size_bytes -= slot.data_size_bytes
	list.remove(&cache.linked_list, &slot.node)
}

cache_ensure_limit :: proc {
	cache_ensure_limit_max_size,
	cache_ensure_limit_to_size,
}

cache_ensure_limit_to_size :: proc(rs: ^Resource_Store, cache: ^CacheLRU, target_size: u64) {
	for cache.cache_current_size_bytes > target_size {
		removed_node := list.pop_back(&cache.linked_list)
		assert(removed_node != nil)
		removed_slot := container_of(removed_node, Resource_Slot, "node")
		err := resource_remove(rs, removed_slot)
		assert(err == .None)
		cache.cache_current_size_bytes -= removed_slot.data_size_bytes
	}
}

cache_ensure_limit_max_size :: proc(rs: ^Resource_Store, cache: ^CacheLRU) {
	cache_ensure_limit_to_size(rs, cache, cache.cache_max_size_bytes)
}

cache_configure :: proc(rs: ^Resource_Store, cache_id: Category_Id, max_size_bytes: u64) {
	cache, _ := &rs.categories[cache_id]
	cache.cache_max_size_bytes = max_size_bytes
	cache_ensure_limit(rs, cache)
}
