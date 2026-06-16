import Lake
open Lake DSL

package «track_geometry_engine» where
  version := v!"0.1.0"

require mathlib from git
  "https://github.com/leanprover-community/mathlib4.git"

@[default_target]
lean_lib «TrackGeometry» where

/-- Compile the generated Raylib FFI shims (`ffi/raylib_shims.c`) to an object,
    pulling in both the Lean runtime headers and the vendored raylib headers. -/
target raylibShims pkg : System.FilePath := do
  let oFile := pkg.buildDir / "ffi" / "raylib_shims.o"
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "raylib_shims.c"
  let raylibInc := pkg.dir / "vendor" / "raylib" / "src"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString, "-I", raylibInc.toString]
  buildO oFile srcJob weakArgs #["-fPIC"] "cc" getLeanTrace

/-- Bundle the shim object into a static library so the executable links it.
    Declared *before* `libRaylib` so that on the link line the shims precede
    raylib — the shims reference raylib symbols, so raylib must resolve after. -/
extern_lib libRaylibShims pkg := do
  let shimO ← fetch <| pkg.target ``raylibShims
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "raylib_shims") #[shimO]

/-- Build the vendored raylib static library via its own (already incremental)
    Makefile, then hand the resulting `libraylib.a` to Lake so it is linked into
    the executable automatically — and, crucially, *ordered* before the binary. -/
extern_lib libRaylib pkg := Job.async do
  let libDir := pkg.dir / "vendor" / "raylib" / "src"
  let libFile := libDir / "libraylib.a"
  proc (quiet := true) {
    cmd := "make"
    args := #["-C", libDir.toString, "USE_EXTERNAL_GLFW=TRUE",
              "GLFW_LINUX_ENABLE_X11=FALSE", "GLFW_LINUX_ENABLE_WAYLAND=TRUE",
              -- raylib bakes RL_CULL_DISTANCE_FAR into rcore.c's RLGL_IMPLEMENTATION, so the
              -- far plane must be defined when raylib itself compiles (not in the FFI shim).
              "CUSTOM_CFLAGS=-DRL_CULL_DISTANCE_FAR=10000.0"]
  }
  -- The artifact's content trace drives whether dependents relink.
  setTrace (← computeTrace libFile)
  return libFile

/-- Regenerate the Raylib bindings from `raylib.h` via the patched rlparser.
    Writes `TrackGeometry/Raylib.lean` and `ffi/raylib_shims.c`. This is *not*
    part of the default build: Lake resolves the Lean module graph from disk
    before custom targets run, so a generated `.lean` consumed by the same
    library can't be a build-graph dependency. Run it deliberately after bumping
    the vendored raylib:  `lake build raylibBindings`  -/
target raylibBindings pkg : System.FilePath := Job.async do
  let raylib := pkg.dir / "vendor" / "raylib"
  let parserBin := pkg.buildDir / "rlparser"
  let bindings := pkg.dir / "TrackGeometry" / "Raylib.lean"
  IO.FS.createDirAll pkg.buildDir
  IO.FS.createDirAll (pkg.dir / "ffi")
  proc (quiet := true) {
    cmd := "cc"
    args := #[(raylib / "tools" / "rlparser" / "rlparser.c").toString,
              "-o", parserBin.toString]
  }
  proc (quiet := true) {
    cmd := parserBin.toString
    args := #["--input", (raylib / "src" / "raylib.h").toString,
              "--output", bindings.toString, "--format", "CODE"]
  }
  setTrace (← computeTrace (TextFilePath.mk bindings))
  return bindings

@[default_target]
lean_exe track where
  root := `Main
  -- raylib + the FFI shim are linked via the `extern_lib`s above; these are the
  -- remaining system dependencies raylib needs.
  moreLinkArgs := #["-lglfw", "-lGL", "-lm", "-lpthread", "-ldl", "-lrt"]
