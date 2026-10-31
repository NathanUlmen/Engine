package main

import hm "core:container/handle_map"
import "core:encoding/uuid"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"

/*
TBD:
- How/should we make this thing thread safe without locking aton?
    * Most of the time we will be acquiring, resolving, and releasing from this thing so we should focus on making those fast.
    * Writing/loading to the disk is very expensive though, 

- How should we handle allocation and freeing of resources? How do we enforce everything use the same allocator?
    * I dont think we can enforce the usage of the same allocator but we can make it pretty obvious which one to use
    by passing one into the interface. - DONE/IMPLEMENTED
    * For freeing of resources I am conflicted on this... On one hand I dont want to add the complexity of writing destructors
    but it does give far more flexibility to the end user on what is possible. I think that we should provide a callback and 
    from there the user decide what should happen. By providing a callback to the user they can then implement things like caching
    themselves by attaching it to the serializer. I don't like this as I think that serializers should be stateless ideally but also 
    it gives the user lots of fine grained control over behavior and what happens. For example in regards to caching the user gets fine grained
    control over which types of resources are cached and which type of strategy is used to do so. On the other hand this makes the structure hard to 
    make thread safe as it then puts responsibility on the users to ensure that their code is thread safe as well. It also complicates the lifespan of
    objects as it means that the resource system would need to own the user_data of the serializers.
    
    A potential middle ground could be that as apart of the serializer the user can configure caching (enabled, max_size, policy) on a serializer by serializer basis. 
    They still wouldn't get as fine grained control but but they would get a vast majority of the benefits. 

    I think that in conclusion we should provide a callback to the user when a resource no longer has any references to it as its just to valuable/useful and I think the felxibility it provides is worth it.
    I think we could prevent 90% of the potential downsides by providing direct caching support. It would give the library ownership around that feature and prevents users from having to roll their own for each serializer.
    The ownership over that feature would also make it easier to make the structure thread safe. If the user needs a level of finite control over the caching that the configuration would provide I would argue that they should
    be hand rolling their own custom system or that it shouldnt be apart of this store. They could always take on the responsibility of it themselves too if they insisted on using this system/store too.

    This means that two procs would be added to the interface, a destructor proc which is specifically used to destroy resoruces created by the serializer and a on_references_zero() proc.

    I am almost tempted to remove the user_data field from the serializer interface entirely at this point after thinking about it for a bit as I cant think of any good uses for it that arent code smells or kinda jank setups.
    But maybe I am being too narrow minded in what I am thinking of. By attaching state to the serializers it leaves the door open for users to shoot themselves in the foot if we go about making this thing thread safe as it becomes
    this thing is thread safe with some caviates. On the other hand its super nice to have as it would be nice ot have as configuration for the serializer and stuff which. 

    Verdicts:
    * First class support for caching that is owned by our api.
        - Where should cache configuration be stored? 
            * If its stored in the serializer that makes it easy to separate everything out. The downside of this is that
            resources that are registered with the registry wont have cache support. I would argue that this is fine as 
            if you need caching for performance reasons you should be registering a serializer and that registering resource.
            without serializers should only really be done for prototyping purposes or in a scenario where performance isnt super critical.
    * user_data should stick around but we need to be very explicity about what it should and shouldnt be.
    * user provided destructors for resources attached to serializers
    * optional callback on references becoming zero

- Is there a way we can get rid of the when loading user data and have it be type safe? Or at least auto cast for the user before passing it into their code.

- How should we handle baked resource output/automate which path/dir its sent to?

- Should we auto load the dependencies for the user or should we leave it up to them to implement that into read_from_disk?
    Another question of user control, explicitness, and ergonomics. 

    Currently leaning more towards the system resolving it for the user. Then the user in their serialization code
    can acquire a handle to the required dependencies and they will already be loaded.

    VERDICT: handle automatically

- How do we provide other avenues for storing resources without requiring stuff to be baked?
    The current proposed solution is that users can copy data into the system or they can allocate their data using the system allocator and then
    pass that pointer into the system and it will register it.
    I think it should be performant as its nice for iteration and prototyping. At this point in time I dont think we should plan on this 
    being a "second class" path. It should still work well and all that but shouldn't come at the expense of first class features.

    VERDICT: Implement proposed solution as is

- Should we make loading of resources more explicit? Currently acquire has the potential to load a resource if its not present,
what if instead we had to make it an explicit process to get the resource by having the user do something like:

    if !resources.load_status() == .NOT_REQUESTED {
        resources.load_resource()
    }
    resources.acquire_handle()
    Pros: 
        The system is easier to reason about and you know what can happen where.
        Our functions become simpler and easier to reason about
        We can always provide a procedure that has the old behavior, just make it more explicit/clear
    Cons:
        non really....
       
    Verdict: Implement it
DONE/IMPLEMENTED

- How should we structure the system such that is fast/not pointer hopping but also not 
memory inefficient?

- Should we rename this to Resource Store?
*/

ResourceSystem :: struct {
	serializers:    map[string]ResourceMarshaller,
	id_to_artifact: map[RsrcId]ResourceArtifact,
	id_to_loaded:   map[RsrcId]RsrcHandle, //should we point this at the slot instead?
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
}

RsrcId :: uuid.Identifier

RsrcHandle :: hm.Handle64

Resource :: struct {
	data:            rawptr,
	data_size_bytes: u64,
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
	destroy_resource:         proc(user_data: rawptr, to_free: rawptr, rsrc_sys: ^ResourceSystem),
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
	rs.sys_allocator = allocator
	rs.serializers = make(map[string]ResourceMarshaller, rs.sys_allocator)
	rs.id_to_artifact = make(map[RsrcId]ResourceArtifact, rs.sys_allocator)
	rs.id_to_loaded = make(map[RsrcId]RsrcHandle, rs.sys_allocator)
	hm.dynamic_init(&rs.handle_map, rs.sys_allocator)
}

/*

*/
rsrc_sys_destroy :: proc(rs: ^ResourceSystem) {
	hm.dynamic_destroy(&rs.handle_map)
	//TODO: Revist this later. (Maybe add a delete proc to the Serializer ?)
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
		return ResourceFuture{.COMPLETED}
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
		rs.id_to_loaded[slot.id] = {}
		//TODO: implement the serializer destructor here instead of this free...
		defer free(slot.data, rs.sys_allocator)
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
	panic("TODO: resource_load_status Unimplemented")
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
		return add_new_slot(rs, id, resource)
	case:
		return handle, error
	}
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


//--------------------


/*
Cache implementation for the resource store.

Requirements:
- Thread safety that goes well with the resource sys
- dynamic/adjustable max size

*/

CacheConfig :: struct {
	max_size_bytes: u64,
	evic_strat:     Eviction_Strategy,
}

Eviction_Strategy :: enum {
	LRU,
}

CacheEntry :: struct {
	id:              RsrcId,
	data:            rawptr,
	data_size_bytes: u64,
	destructor:      proc(data: rawptr),
}

Cache :: struct {
	current_size_bytes: u64,
	max_capacity_bytes: u64,
	entries:            [dynamic]CacheEntry,
	strategy:           Eviction_Strategy,
}

add_entry :: proc(cache: ^Cache, to_add: CacheEntry) {
	new_total := cache.current_size_bytes + to_add.data_size_bytes
	if new_total > cache.max_capacity_bytes {
		current := new_total
		#reverse for entry, index in cache.entries {
			(current > cache.max_capacity_bytes) or_break
			current -= entry.data_size_bytes
			entry.destructor(entry.data)
			unordered_remove(&cache.entries, index)
		}
	}
	append(&cache.entries, to_add)
	cache.current_size_bytes += to_add.data_size_bytes
}

take_entry :: proc(cache: ^Cache, target_id: RsrcId) -> CacheEntry {
	found := -1
	target: CacheEntry
	for entry, index in cache.entries {
		if entry.id == target_id {
			found = index
			target = entry
			break
		}
	}
	assert(found != -1)
	ordered_remove(&cache.entries, found)
	return target
}

adjust_cache :: proc(cache: ^Cache) {

}

configure_cache :: proc(cache: ^Cache, config: CacheConfig) {

}
