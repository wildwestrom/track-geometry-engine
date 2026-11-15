# Track Geometry Engine

A railway/road **track geometry engine** written in Lean 4. Build smooth alignments — straights, circular arcs, and clothoid transitions — from points of intersection.
The geometry core is generic over a scalar type, so the *same* code runs exactly over `ℝ` (for proofs, via Mathlib) and fast over `Float` (for computation and an interactive UI).

## Story

It all started in the summer of 2025. I was playing Transport Fever 2, but I was frustrated by the track building tools. I kept trying to find new ways to build the tracks so the curves would look nice and smooth, but I could never get them just right. It was from this frustration that I went down the rabbit hole of curves and track geometry.

## The idea

- **One scalar interface, two instances.** `TrackScalar α` (in `TrackGeometry/Lib.lean`) captures the arithmetic/trig/sqrt a track engine needs. `RFloat` (Float newtype) is the computable instance; `ℝ` is the exact, `noncomputable` proof instance (`TrackGeometry/Real.lean`). The core carries **no Mathlib dependency** so it stays compilable to C.
- **PI-based building.** You place *points of intersection* (PIs) — corners of a tangent polyline. `buildPath` runs straights along the legs and rounds each interior corner with a circular fillet. No radius is supplied: each corner gets a tangent *budget* (fraction of the shorter leg) and the radius is whatever fits (`R = T / tan(Δ/2)`). Near-straight corners pass through.
- **Type-indexed segments.** `Segment α cA cB` is indexed by start/end `Curvature`, so only valid curvature transitions can be expressed. The UI samples a flat `AlignmentPath` of `AnySegment` pieces (join continuity erased for heterogeneous arrays).
- **Design cant.** Rails bank from curvature and operating speed: applied cant `h = G · V² · κ / g` (balanced), rolling a gravity-aligned level frame about the tangent. RMF remains available for continuous frame sampling; it is not the rail bank.

## Layout

```
TrackGeometry.lean          Top-level module (imports core + UI deps)
TrackGeometry/
  Lib.lean                  Barrel re-export of the geometry core modules below
  Vec.lean                  TrackScalar, Vec3, scalar helpers
  Segment.lean              Segment, clothoid, Frame/RMF, closed-form sampling
  Cant.lean                 Design cant from curvature and speed
  Path.lean                 AnySegment, AlignmentPath, corner solve, buildPath
  RFloat.lean               Computable Float scalar instance
  Real.lean                 Exact ℝ instance of TrackScalar (Mathlib)
  Continuity.lean           G¹/G² proofs for the spiral corner
  History.lean              Generic undo/redo *tree* (used by the UI)
  Raylib.lean               Generated Raylib FFI bindings (do not edit)
  UI/
    Util.lean               Float helpers, Vector3 math, ray/screen geometry
    Config.lean             Theme, design params, speed/cant Float facades
    Camera.lean             Orbit camera
    State.lean              Editor state, curve sampling, resample tasks
    Pick.lean               Hit-testing (PIs, curve ends, gizmo)
    Input.lean              Mouse/keyboard edit handlers
    Draw.lean               3D scene + HUD
Main.lean                   Frame loop (exe `track`)
Fixtures.lean               buildPath fixtures for the TF3 mod port (exe `fixtures`)
ffi/raylib_shims.c          Generated C FFI shim (the only C in the project)
vendor/raylib/              Vendored raylib
  tools/rlparser/rlparser.c FFI generator. Edit this to add bindings; regenerate with
                            `lake build raylibBindings`. **Do not** hand-edit Raylib.lean
                            or raylib_shims.c
lakefile.lean, flake.nix    Build config
```

## Commands

Enter the dev shell first (Nix + direnv): `direnv allow`, or `nix develop`.

```shell
lake exe track             # build vendored raylib + Lean exe `track`, then launch the window
lake build track           # build the `track` executable only
lake build TrackGeometry   # build the Lean library only
lake build raylibBindings  # regenerate Raylib.lean + raylib_shims.c from raylib.h (rlparser)
lake build libRaylib       # build the vendored raylib static lib (via its Makefile)
lake build libRaylibShims  # build the FFI shim static lib
lake exe fixtures          # write buildPath fixtures for the TF3 mod's Teal port (mod/test/fixtures.lua)
lake clean                 # remove Lean build outputs
```

`lake exe track` orchestrates everything: raylib (via its own Makefile), the FFI
shim, and the Lean binary — all incrementally, so an unchanged rebuild does no
work. `raylibBindings` is deliberately *not* part of the default build (Lake
resolves the Lean module graph before custom targets run); regenerate the
bindings by hand only after bumping the vendored raylib.

UI controls: press **F1** in the app for all keybindings.

## Troubleshooting

**`EGL: Failed to get EGL display: Success` / window won't open.** glibc skew: each Lean
toolchain bakes in its own glibc, and Mesa ≥ 26 needs glibc ≥ 2.41 (`GLIBC_ABI_GNU2_TLS`).
Keep `lean-toolchain` at `v4.31.0` or newer (v4.30.0 ships glibc 2.40).

## Where to look

New to the code: start at `TrackGeometry/Lib.lean`, then `Path.lean` (`solveCorner`, `buildPath`) and `Segment.lean`.
