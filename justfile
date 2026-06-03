RAYLIB := './vendor/raylib/src'
BUILD_FOLDER := './build'
LEAN_IR := '.lake/build/ir/TrackGeometry'

build:
	lake build
	make -C vendor/raylib/src USE_EXTERNAL_GLFW=TRUE GLFW_LINUX_ENABLE_X11=FALSE GLFW_LINUX_ENABLE_WAYLAND=TRUE
	mkdir -p build
	# Compile the computable Lean modules (Mathlib-free) to objects.
	leanc -c {{LEAN_IR}}/Lib.c -o {{BUILD_FOLDER}}/Lib.o
	leanc -c {{LEAN_IR}}/FFI.c -o {{BUILD_FOLDER}}/FFI.o
	# Link the Raylib host against the engine.
	leanc main.c {{BUILD_FOLDER}}/Lib.o {{BUILD_FOLDER}}/FFI.o -lm -lraylib $(pkg-config --libs --cflags glfw3) -I{{RAYLIB}} -L{{RAYLIB}} -o {{BUILD_FOLDER}}/main

run: build
	{{BUILD_FOLDER}}/main

clean:
	rm -rf {{BUILD_FOLDER}}
	make -C vendor/raylib/src clean
