package main

import b3d "vendor:box3d"

SUB_STEPS :: 4

Physics_World :: struct {
	world_id: b3d.WorldId,
}

box3d_init :: proc(config: b3d.WorldDef) -> Physics_World {
	id := b3d.CreateWorld(config)
	return {world_id = id}
}

physics_step :: proc(world_id: b3d.WorldId, $T: f32) {
	b3d.World_Step(world_id, T, SUB_STEPS)
}
