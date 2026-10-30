package main

import "core:log"
import "core:mem"
import "core:os"


main :: proc() {
	args := os.args[1:]
	//setup our logging.
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	when ODIN_DEBUG {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		context.allocator = mem.tracking_allocator(&tracker)

		defer {
			log_and_destroy(&tracker, "Primary Allocator")
		}

		log_and_destroy :: proc(tracker: ^mem.Tracking_Allocator, name: string) {
			if len(tracker.allocation_map) > 0 {
				log.error("===", name, len(tracker.allocation_map), "allocations not freed: ===")
				for _, entry in tracker.allocation_map {
					log.error("Failed to free", entry.size, "at", entry.location)
				}
			}

			if len(tracker.bad_free_array) > 0 {
				log.warn("===", name, len(tracker.bad_free_array), "incorrect frees: ===")
				for entry in tracker.bad_free_array {
					log.error("-", entry.memory, "at", entry.location)
				}
			}
			mem.tracking_allocator_destroy(tracker)
		}
	}


}
