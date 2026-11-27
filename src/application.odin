package main

import "core:log"
import "core:os"
import "core:time"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

/*
*/
Application :: struct {
	#subtype input: Input_State,
	graphics: Graphics,
}

Graphics :: struct {
	fps:        f32,
	deltaT:     f32, //in seconds
	window:     ^sdl.Window,
	gl_context: sdl.GLContext,
}

Game :: struct($T: typeid) {
	game_context: T,
	game_create:  proc(game_context: T) -> bool,
	game_destroy: proc(game_context: T),
	update:       proc(app: ^Application, deltaT: f32, game_context: ^T) -> (ok: bool),
	game_exit:    proc(game_context: T),
}

application_init :: proc(app: ^Application) {
	if !sdl.Init({.VIDEO}) {
		log.error("Failed to init video using sdl. ", sdl.GetError())
	}

	flags := sdl.WindowFlags{.OPENGL}
	app.graphics.window = sdl.CreateWindow("PLACE HOLDER", 960, 960, flags)
	if app.graphics.window == nil {
		log.error("Failed to create Window", sdl.GetError())
	}

	app.graphics.gl_context = sdl.GL_CreateContext(app.graphics.window)

	gl.load_up_to(4, 3, sdl.gl_set_proc_address)

}

application_destroy :: proc() {}

loop :: proc(app: ^Application, game: ^Game($T)) {
	fps_accumulator: f32 = 0.0
	frame_counter := 0
	current := time.tick_now()
	for {
		//calculate our delta time
		now := time.tick_now()
		duration := time.tick_diff(current, now)
		current = now
		app.graphics.deltaT = f32(time.duration_seconds(duration))

		//update fps - this approach is gremlin but is good enough for now
		fps_accumulator += app.graphics.deltaT
		frame_counter += 1
		if fps_accumulator >= 1.0 {
			app.graphics.fps = f32(frame_counter)
			frame_counter = 0
			fps_accumulator = 0
		}

		//update state of our just pressed keys to held.
		input_state_update(&app.input)

		//update mouse position
		_ = sdl.GetMouseState(&app.input.mouse_pos[0], &app.input.mouse_pos[1])

		//poll events
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .KEY_DOWN:
				{
					if !event.key.repeat {
						app.input.keys[Input_Code(event.key.scancode)] = .JUST_PRESSED
					}
				}
			case .KEY_UP:
				{
					app.input.keys[Input_Code(event.key.scancode)] = .NONE
				}
			case .MOUSE_BUTTON_DOWN:
				app.input.keys[Input_Code(-i32(event.button.button))] = .JUST_PRESSED
			case .MOUSE_BUTTON_UP:
				app.input.keys[Input_Code(-i32(event.button.button))] = .NONE
			case .WINDOW_HIDDEN:
				{
					//TODO: post event to user code.
				}
			case .WINDOW_RESIZED:
				{
					//TODO: post event to user code.
				}

			case .QUIT:
				os.exit(0)
			//post to engine to shutdown.
			}
		}

		//user code update, exit if error
		if !game.update(app, app.graphics.deltaT, &game.game_context) do return

		sdl.GL_SwapWindow(app.graphics.window)

	}
}

Input_Status :: enum {
	NONE,
	JUST_PRESSED,
	HELD,
}

//This is not optimal but oh well
Input_State :: struct {
	keys:      #sparse[Input_Code]Input_Status,
	mouse_pos: [2]f32,
}

input_state_update :: proc(input: ^Input_State) {
	for &state in input.keys {
		if state == .JUST_PRESSED {
			state = .HELD
		}
	}
}

is_pressed :: proc(input: Input_State, key: Input_Code) -> bool {
	return input.keys[key] == .HELD
}

is_just_pressed :: proc(input: Input_State, key: Input_Code) -> bool {
	return input.keys[key] == .JUST_PRESSED
}


// Keyboard codes use same values as sdl. We flip the sign of mouse codes to keep them unique.
Input_Code :: enum i32 {
	MOUSE_LEFT           = -sdl.BUTTON_LEFT,
	MOUSE_MIDDLE         = -sdl.BUTTON_MIDDLE,
	MOUSE_RIGHT          = -sdl.BUTTON_RIGHT,
	MOUSE_X1             = -sdl.BUTTON_X1,
	MOUSE_X2             = -sdl.BUTTON_X2,
	UNKNOWN              = i32(sdl.Scancode.UNKNOWN),
	A                    = i32(sdl.Scancode.A),
	B                    = i32(sdl.Scancode.B),
	C                    = i32(sdl.Scancode.C),
	D                    = i32(sdl.Scancode.D),
	E                    = i32(sdl.Scancode.E),
	F                    = i32(sdl.Scancode.F),
	G                    = i32(sdl.Scancode.G),
	H                    = i32(sdl.Scancode.H),
	I                    = i32(sdl.Scancode.I),
	J                    = i32(sdl.Scancode.J),
	K                    = i32(sdl.Scancode.K),
	L                    = i32(sdl.Scancode.L),
	M                    = i32(sdl.Scancode.M),
	N                    = i32(sdl.Scancode.N),
	O                    = i32(sdl.Scancode.O),
	P                    = i32(sdl.Scancode.P),
	Q                    = i32(sdl.Scancode.Q),
	R                    = i32(sdl.Scancode.R),
	S                    = i32(sdl.Scancode.S),
	T                    = i32(sdl.Scancode.T),
	U                    = i32(sdl.Scancode.U),
	V                    = i32(sdl.Scancode.V),
	W                    = i32(sdl.Scancode.W),
	X                    = i32(sdl.Scancode.X),
	Y                    = i32(sdl.Scancode.Y),
	Z                    = i32(sdl.Scancode.Z),
	_1                   = i32(sdl.Scancode._1),
	_2                   = i32(sdl.Scancode._2),
	_3                   = i32(sdl.Scancode._3),
	_4                   = i32(sdl.Scancode._4),
	_5                   = i32(sdl.Scancode._5),
	_6                   = i32(sdl.Scancode._6),
	_7                   = i32(sdl.Scancode._7),
	_8                   = i32(sdl.Scancode._8),
	_9                   = i32(sdl.Scancode._9),
	_0                   = i32(sdl.Scancode._0),
	RETURN               = i32(sdl.Scancode.RETURN),
	ESCAPE               = i32(sdl.Scancode.ESCAPE),
	BACKSPACE            = i32(sdl.Scancode.BACKSPACE),
	TAB                  = i32(sdl.Scancode.TAB),
	SPACE                = i32(sdl.Scancode.SPACE),
	MINUS                = i32(sdl.Scancode.MINUS),
	EQUALS               = i32(sdl.Scancode.EQUALS),
	LEFTBRACKET          = i32(sdl.Scancode.LEFTBRACKET),
	RIGHTBRACKET         = i32(sdl.Scancode.RIGHTBRACKET),
	BACKSLASH            = i32(sdl.Scancode.BACKSLASH),
	NONUSHASH            = i32(sdl.Scancode.NONUSHASH),
	SEMICOLON            = i32(sdl.Scancode.SEMICOLON),
	APOSTROPHE           = i32(sdl.Scancode.APOSTROPHE),
	GRAVE                = i32(sdl.Scancode.GRAVE),
	COMMA                = i32(sdl.Scancode.COMMA),
	PERIOD               = i32(sdl.Scancode.PERIOD),
	SLASH                = i32(sdl.Scancode.SLASH),
	CAPSLOCK             = i32(sdl.Scancode.CAPSLOCK),
	F1                   = i32(sdl.Scancode.F1),
	F2                   = i32(sdl.Scancode.F2),
	F3                   = i32(sdl.Scancode.F3),
	F4                   = i32(sdl.Scancode.F4),
	F5                   = i32(sdl.Scancode.F5),
	F6                   = i32(sdl.Scancode.F6),
	F7                   = i32(sdl.Scancode.F7),
	F8                   = i32(sdl.Scancode.F8),
	F9                   = i32(sdl.Scancode.F9),
	F10                  = i32(sdl.Scancode.F10),
	F11                  = i32(sdl.Scancode.F11),
	F12                  = i32(sdl.Scancode.F12),
	PRINTSCREEN          = i32(sdl.Scancode.PRINTSCREEN),
	SCROLLLOCK           = i32(sdl.Scancode.SCROLLLOCK),
	PAUSE                = i32(sdl.Scancode.PAUSE),
	INSERT               = i32(sdl.Scancode.INSERT),
	HOME                 = i32(sdl.Scancode.HOME),
	PAGEUP               = i32(sdl.Scancode.PAGEUP),
	DELETE               = i32(sdl.Scancode.DELETE),
	END                  = i32(sdl.Scancode.END),
	PAGEDOWN             = i32(sdl.Scancode.PAGEDOWN),
	RIGHT                = i32(sdl.Scancode.RIGHT),
	LEFT                 = i32(sdl.Scancode.LEFT),
	DOWN                 = i32(sdl.Scancode.DOWN),
	UP                   = i32(sdl.Scancode.UP),
	NUMLOCKCLEAR         = i32(sdl.Scancode.NUMLOCKCLEAR),
	KP_DIVIDE            = i32(sdl.Scancode.KP_DIVIDE),
	KP_MULTIPLY          = i32(sdl.Scancode.KP_MULTIPLY),
	KP_MINUS             = i32(sdl.Scancode.KP_MINUS),
	KP_PLUS              = i32(sdl.Scancode.KP_PLUS),
	KP_ENTER             = i32(sdl.Scancode.KP_ENTER),
	KP_1                 = i32(sdl.Scancode.KP_1),
	KP_2                 = i32(sdl.Scancode.KP_2),
	KP_3                 = i32(sdl.Scancode.KP_3),
	KP_4                 = i32(sdl.Scancode.KP_4),
	KP_5                 = i32(sdl.Scancode.KP_5),
	KP_6                 = i32(sdl.Scancode.KP_6),
	KP_7                 = i32(sdl.Scancode.KP_7),
	KP_8                 = i32(sdl.Scancode.KP_8),
	KP_9                 = i32(sdl.Scancode.KP_9),
	KP_0                 = i32(sdl.Scancode.KP_0),
	KP_PERIOD            = i32(sdl.Scancode.KP_PERIOD),
	NONUSBACKSLASH       = i32(sdl.Scancode.NONUSBACKSLASH),
	APPLICATION          = i32(sdl.Scancode.APPLICATION),
	POWER                = i32(sdl.Scancode.POWER),
	KP_EQUALS            = i32(sdl.Scancode.KP_EQUALS),
	F13                  = i32(sdl.Scancode.F13),
	F14                  = i32(sdl.Scancode.F14),
	F15                  = i32(sdl.Scancode.F15),
	F16                  = i32(sdl.Scancode.F16),
	F17                  = i32(sdl.Scancode.F17),
	F18                  = i32(sdl.Scancode.F18),
	F19                  = i32(sdl.Scancode.F19),
	F20                  = i32(sdl.Scancode.F20),
	F21                  = i32(sdl.Scancode.F21),
	F22                  = i32(sdl.Scancode.F22),
	F23                  = i32(sdl.Scancode.F23),
	F24                  = i32(sdl.Scancode.F24),
	EXECUTE              = i32(sdl.Scancode.EXECUTE),
	HELP                 = i32(sdl.Scancode.HELP),
	MENU                 = i32(sdl.Scancode.MENU),
	SELECT               = i32(sdl.Scancode.SELECT),
	STOP                 = i32(sdl.Scancode.STOP),
	AGAIN                = i32(sdl.Scancode.AGAIN),
	UNDO                 = i32(sdl.Scancode.UNDO),
	CUT                  = i32(sdl.Scancode.CUT),
	COPY                 = i32(sdl.Scancode.COPY),
	PASTE                = i32(sdl.Scancode.PASTE),
	FIND                 = i32(sdl.Scancode.FIND),
	MUTE                 = i32(sdl.Scancode.MUTE),
	VOLUMEUP             = i32(sdl.Scancode.VOLUMEUP),
	VOLUMEDOWN           = i32(sdl.Scancode.VOLUMEDOWN),
	KP_COMMA             = i32(sdl.Scancode.KP_COMMA),
	KP_EQUALSAS400       = i32(sdl.Scancode.KP_EQUALSAS400),
	INTERNATIONAL1       = i32(sdl.Scancode.INTERNATIONAL1),
	INTERNATIONAL2       = i32(sdl.Scancode.INTERNATIONAL2),
	INTERNATIONAL3       = i32(sdl.Scancode.INTERNATIONAL3),
	INTERNATIONAL4       = i32(sdl.Scancode.INTERNATIONAL4),
	INTERNATIONAL5       = i32(sdl.Scancode.INTERNATIONAL5),
	INTERNATIONAL6       = i32(sdl.Scancode.INTERNATIONAL6),
	INTERNATIONAL7       = i32(sdl.Scancode.INTERNATIONAL7),
	INTERNATIONAL8       = i32(sdl.Scancode.INTERNATIONAL8),
	INTERNATIONAL9       = i32(sdl.Scancode.INTERNATIONAL9),
	LANG1                = i32(sdl.Scancode.LANG1),
	LANG2                = i32(sdl.Scancode.LANG2),
	LANG3                = i32(sdl.Scancode.LANG3),
	LANG4                = i32(sdl.Scancode.LANG4),
	LANG5                = i32(sdl.Scancode.LANG5),
	LANG6                = i32(sdl.Scancode.LANG6),
	LANG7                = i32(sdl.Scancode.LANG7),
	LANG8                = i32(sdl.Scancode.LANG8),
	LANG9                = i32(sdl.Scancode.LANG9),
	ALTERASE             = i32(sdl.Scancode.ALTERASE),
	SYSREQ               = i32(sdl.Scancode.SYSREQ),
	CANCEL               = i32(sdl.Scancode.CANCEL),
	CLEAR                = i32(sdl.Scancode.CLEAR),
	PRIOR                = i32(sdl.Scancode.PRIOR),
	RETURN2              = i32(sdl.Scancode.RETURN2),
	SEPARATOR            = i32(sdl.Scancode.SEPARATOR),
	OUT                  = i32(sdl.Scancode.OUT),
	OPER                 = i32(sdl.Scancode.OPER),
	CLEARAGAIN           = i32(sdl.Scancode.CLEARAGAIN),
	CRSEL                = i32(sdl.Scancode.CRSEL),
	EXSEL                = i32(sdl.Scancode.EXSEL),
	FRONT                = i32(sdl.Scancode.FRONT),
	KP_00                = i32(sdl.Scancode.KP_00),
	KP_000               = i32(sdl.Scancode.KP_000),
	THOUSANDSSEPARATOR   = i32(sdl.Scancode.THOUSANDSSEPARATOR),
	DECIMALSEPARATOR     = i32(sdl.Scancode.DECIMALSEPARATOR),
	CURRENCYUNIT         = i32(sdl.Scancode.CURRENCYUNIT),
	CURRENCYSUBUNIT      = i32(sdl.Scancode.CURRENCYSUBUNIT),
	KP_LEFTPAREN         = i32(sdl.Scancode.KP_LEFTPAREN),
	KP_RIGHTPAREN        = i32(sdl.Scancode.KP_RIGHTPAREN),
	KP_LEFTBRACE         = i32(sdl.Scancode.KP_LEFTBRACE),
	KP_RIGHTBRACE        = i32(sdl.Scancode.KP_RIGHTBRACE),
	KP_TAB               = i32(sdl.Scancode.KP_TAB),
	KP_BACKSPACE         = i32(sdl.Scancode.KP_BACKSPACE),
	KP_A                 = i32(sdl.Scancode.KP_A),
	KP_B                 = i32(sdl.Scancode.KP_B),
	KP_C                 = i32(sdl.Scancode.KP_C),
	KP_D                 = i32(sdl.Scancode.KP_D),
	KP_E                 = i32(sdl.Scancode.KP_E),
	KP_F                 = i32(sdl.Scancode.KP_F),
	KP_XOR               = i32(sdl.Scancode.KP_XOR),
	KP_POWER             = i32(sdl.Scancode.KP_POWER),
	KP_PERCENT           = i32(sdl.Scancode.KP_PERCENT),
	KP_LESS              = i32(sdl.Scancode.KP_LESS),
	KP_GREATER           = i32(sdl.Scancode.KP_GREATER),
	KP_AMPERSAND         = i32(sdl.Scancode.KP_AMPERSAND),
	KP_DBLAMPERSAND      = i32(sdl.Scancode.KP_DBLAMPERSAND),
	KP_VERTICALBAR       = i32(sdl.Scancode.KP_VERTICALBAR),
	KP_DBLVERTICALBAR    = i32(sdl.Scancode.KP_DBLVERTICALBAR),
	KP_COLON             = i32(sdl.Scancode.KP_COLON),
	KP_HASH              = i32(sdl.Scancode.KP_HASH),
	KP_SPACE             = i32(sdl.Scancode.KP_SPACE),
	KP_AT                = i32(sdl.Scancode.KP_AT),
	KP_EXCLAM            = i32(sdl.Scancode.KP_EXCLAM),
	KP_MEMSTORE          = i32(sdl.Scancode.KP_MEMSTORE),
	KP_MEMRECALL         = i32(sdl.Scancode.KP_MEMRECALL),
	KP_MEMCLEAR          = i32(sdl.Scancode.KP_MEMCLEAR),
	KP_MEMADD            = i32(sdl.Scancode.KP_MEMADD),
	KP_MEMSUBTRACT       = i32(sdl.Scancode.KP_MEMSUBTRACT),
	KP_MEMMULTIPLY       = i32(sdl.Scancode.KP_MEMMULTIPLY),
	KP_MEMDIVIDE         = i32(sdl.Scancode.KP_MEMDIVIDE),
	KP_PLUSMINUS         = i32(sdl.Scancode.KP_PLUSMINUS),
	KP_CLEAR             = i32(sdl.Scancode.KP_CLEAR),
	KP_CLEARENTRY        = i32(sdl.Scancode.KP_CLEARENTRY),
	KP_BINARY            = i32(sdl.Scancode.KP_BINARY),
	KP_OCTAL             = i32(sdl.Scancode.KP_OCTAL),
	KP_DECIMAL           = i32(sdl.Scancode.KP_DECIMAL),
	KP_HEXADECIMAL       = i32(sdl.Scancode.KP_HEXADECIMAL),
	LCTRL                = i32(sdl.Scancode.LCTRL),
	LSHIFT               = i32(sdl.Scancode.LSHIFT),
	LALT                 = i32(sdl.Scancode.LALT),
	LGUI                 = i32(sdl.Scancode.LGUI),
	RCTRL                = i32(sdl.Scancode.RCTRL),
	RSHIFT               = i32(sdl.Scancode.RSHIFT),
	RALT                 = i32(sdl.Scancode.RALT),
	RGUI                 = i32(sdl.Scancode.RGUI),
	MODE                 = i32(sdl.Scancode.MODE),
	SLEEP                = i32(sdl.Scancode.SLEEP),
	WAKE                 = i32(sdl.Scancode.WAKE),
	CHANNEL_INCREMENT    = i32(sdl.Scancode.CHANNEL_INCREMENT),
	CHANNEL_DECREMENT    = i32(sdl.Scancode.CHANNEL_DECREMENT),
	MEDIA_PLAY           = i32(sdl.Scancode.MEDIA_PLAY),
	MEDIA_PAUSE          = i32(sdl.Scancode.MEDIA_PAUSE),
	MEDIA_RECORD         = i32(sdl.Scancode.MEDIA_RECORD),
	MEDIA_FAST_FORWARD   = i32(sdl.Scancode.MEDIA_FAST_FORWARD),
	MEDIA_REWIND         = i32(sdl.Scancode.MEDIA_REWIND),
	MEDIA_NEXT_TRACK     = i32(sdl.Scancode.MEDIA_NEXT_TRACK),
	MEDIA_PREVIOUS_TRACK = i32(sdl.Scancode.MEDIA_PREVIOUS_TRACK),
	MEDIA_STOP           = i32(sdl.Scancode.MEDIA_STOP),
	MEDIA_EJECT          = i32(sdl.Scancode.MEDIA_EJECT),
	MEDIA_PLAY_PAUSE     = i32(sdl.Scancode.MEDIA_PLAY_PAUSE),
	MEDIA_SELECT         = i32(sdl.Scancode.MEDIA_SELECT),
	AC_NEW               = i32(sdl.Scancode.AC_NEW),
	AC_OPEN              = i32(sdl.Scancode.AC_OPEN),
	AC_CLOSE             = i32(sdl.Scancode.AC_CLOSE),
	AC_EXIT              = i32(sdl.Scancode.AC_EXIT),
	AC_SAVE              = i32(sdl.Scancode.AC_SAVE),
	AC_PRINT             = i32(sdl.Scancode.AC_PRINT),
	AC_PROPERTIES        = i32(sdl.Scancode.AC_PROPERTIES),
	AC_SEARCH            = i32(sdl.Scancode.AC_SEARCH),
	AC_HOME              = i32(sdl.Scancode.AC_HOME),
	AC_BACK              = i32(sdl.Scancode.AC_BACK),
	AC_FORWARD           = i32(sdl.Scancode.AC_FORWARD),
	AC_STOP              = i32(sdl.Scancode.AC_STOP),
	AC_REFRESH           = i32(sdl.Scancode.AC_REFRESH),
	AC_BOOKMARKS         = i32(sdl.Scancode.AC_BOOKMARKS),
	SOFTLEFT             = i32(sdl.Scancode.SOFTLEFT),
	SOFTRIGHT            = i32(sdl.Scancode.SOFTRIGHT),
	CALL                 = i32(sdl.Scancode.CALL),
	ENDCALL              = i32(sdl.Scancode.ENDCALL),
	RESERVED             = i32(sdl.Scancode.RESERVED),
}
