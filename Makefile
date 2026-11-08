VET_FLAGS := -vet -strict-style -vet-tabs -warnings-as-errors
TEST_THREAD_COUNT := 1

check:
	odin check src $(VET_FLAGS) 

build:
	odin build src/ -o:speed -out:prog $(VET_FLAGS)

build-release:
	odin build src/ -o:speed -out:release -disable-assert -vet -no-bounds-check -no-type-assert

clean:
	rm prog; rm release

test:
	odin test tests/unit/ -debug -define:ODIN_TEST_THREADS=$(TEST_THREAD_COUNT)

fzztest:
	odin test tests/fuzz/ -debug -define:ODIN_TEST_THREADS=$(TEST_THREAD_COUNT)


