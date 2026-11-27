package main

import "core:log"
import "core:math"
import "core:mem"
import gl "vendor:OpenGL"

SPEED :: f32(1)

Game_Context :: struct {
	rs:            Resource_Store,
	accumulator:   f32,
	fps_logger:    f32,
	buffer_handle: Rs_Handle(u32),
	color:         [3]f32,
}

DEFAULT_CATEGORY :: 0

create_game :: proc(ctx: ^Game_Context) -> bool {
	resource_store_init(&ctx.rs, context.allocator, {{100 * mem.Megabyte, 20 * mem.Megabyte, DEFAULT_CATEGORY}})
	resource_store_register_marshaller(&ctx.rs, glb_default_marshaller())
	err := resource_store_import_file(&ctx.rs, "assets/BoomBox.glb")
	assert(err == .None)
	ctx.buffer_handle, err = resource_load(&ctx.rs, {}, u32)
	assert(err == .None)
	return true
}

update :: proc(app: ^Application, deltaT: f32, ctx: ^Game_Context) -> (ok: bool) {
	ctx.accumulator += SPEED * deltaT
	ctx.fps_logger += deltaT
	if ctx.fps_logger > 1 {
		log.info(app.graphics.fps)
		ctx.fps_logger = 0
	}

	gl.ClearColor(ctx.color.r, ctx.color.g, ctx.color.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)


	// buffer, err := handle_resolve(&ctx.rs, ctx.buffer_handle)
	// assert(err == nil)
	// gl.BindBuffer(gl.ARRAY_BUFFER, buffer^)

	if is_pressed(app, .Q) {
		ctx.color.r = math.lerp(f32(0), f32(1.0), (math.sin(ctx.accumulator) * .5) + .5)
	}

	if is_pressed(app, .W) {
		ctx.color.g = math.lerp(f32(0), f32(1.0), (math.sin(ctx.accumulator) * .5) + .5)
	}

	if is_pressed(app, .E) {
		ctx.color.b = math.lerp(f32(0), f32(1.0), (math.sin(ctx.accumulator) * .5) + .5)
	}


	return true
}
