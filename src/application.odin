package main

import "core:log"
import sdl "vendor:sdl3"

/*
Application is a global container

*/
Application :: struct {
	input: Input_State,
}

application_init :: proc(app: ^Application) {
	flags := sdl.WindowFlags{.OPENGL, .FULLSCREEN}
	sdl.CreateWindow("PLACE_HOLDER", 960, 960, flags)
}

application_destroy :: proc() {}

loop :: proc(app: ^Application) {
	for {
		//poll events
		input_state_update(&app.input)
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .KEY_DOWN:
				{

				}
			case .KEY_UP:
				{

				}

			case .QUIT:
				panic("R")
			}
		}
		//user code update

	}
}

Input_State :: struct {}

input_state_update :: proc(input: ^Input_State) {
}

is_pressed :: proc() -> bool {
	return false
}

is_just_pressed :: proc() -> bool {
	return false
}

mouse_position :: proc() -> [2]f32 {
	return {0, 0}
}
