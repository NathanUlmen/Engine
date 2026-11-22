package main

import "core:log"
import "core:math"
import gl "vendor:OpenGL"

SPEED :: f32(1)

Game_Context :: struct {
	rs:          Resource_Store,
	accumulator: f32,
	fps_logger:  f32,
	color:       [3]f32,
}

create_game :: proc(ctx: Game_Context) -> bool {
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
