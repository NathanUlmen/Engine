package main

import "core:container/queue"
import "core:thread"

Dispatcher :: struct {
	callbacks: queue.Queue(thread.Task),
	post:      proc(self: Dispatcher, task: thread.Task),
}

post :: proc(dis: ^Dispatcher, callback: thread.Task) {

}
