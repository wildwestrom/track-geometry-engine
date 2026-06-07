# Track Geometry Engine

A railway/road **track geometry engine** written in Lean 4. Build smooth alignments — straights, circular arcs, and clothoid transitions — from points of intersection.
The geometry core is generic over a scalar type, so the *same* code runs exactly over `ℝ` (for proofs, via Mathlib) and fast over `Float` (for computation and an interactive UI).

## Story

It all started in the summer of 2025. I was playing Transport Fever 2, but I was frustrated by the track building tools. I kept trying to find new ways to build the tracks so the curves would look nice and smooth, but I could never get them just right. It was from this frustration that I went down the rabbit hole of curves and track geometry.

## The idea

- **One scalar interface, two instances.** `TrackScalar α` (in `TrackGeometry/Lib.lean`) captures the arithmetic/trig/sqrt a track engine needs. `RFloat` (Float newtype) is the computable instance; `ℝ` is the exact, `noncomputable` proof instance (`TrackGeometry/Real.lean`). The core carries **no Mathlib dependency** so it stays compilable to C.
- **PI-based building.** You place *points of intersection* (PIs) — corners of a tangent polyline. `buildPath` runs straights along the legs and rounds each interior corner with a circular fillet. No radius is supplied: each corner gets a tangent *budget* (fraction of the shorter leg) and the radius is whatever fits (`R = T / tan(Δ/2)`). Near-straight corners pass through.
- **Type-indexed segments.** `Segment α cA cB` is indexed by start/end `Curvature`, so only valid curvature transitions can be expressed; `RailwayAlignment` chains them with matching joins.

## Layout

```
TrackGeometry.lean        Top-level module (imports everything below)
TrackGeometry/
  Lib.lean        ← START HERE. Core: TrackScalar, Vec3, Segment, clothoid, PI builder (buildPath), RFloat instance.
  Real.lean         The exact ℝ instance of TrackScalar (Mathlib).
  GnuPlot.lean      Sample alignments → CSV + gnuplot script generation.
  History.lean      Generic undo/redo *tree* (used by the UI).
  Raylib.lean       Generated Raylib FFI bindings (do not edit; see `lake build raylibBindings`).
Main.lean           Interactive raylib UI (exe `track`), written in Lean.
scripts/dump_csv.lean   Headless demo: writes example CSVs + plot.gnuplot.
ffi/raylib_shims.c      Generated C FFI shim (the only C in the project).
vendor/raylib/          Vendored raylib.
	tools/rlparser/rlparser.c    FFI shim generator. Edit this file if you need new bindings from raylib not yet present. **Do not** hand-edit the auto generated `raylib_shims.c` or `Raylib.lean`
lakefile.lean, flake.nix   Build config.
```

## Commands

Enter the dev shell first (Nix + direnv): `direnv allow`, or `nix develop`.

### Headless: generate plots

```shell
lake env lean --run scripts/dump_csv.lean   # writes scripts/example*.csv + plot.gnuplot
gnuplot --persist scripts/plot.gnuplot      # view the alignments
```

### Interactive UI

```shell
lake exe track             # build vendored raylib + Lean exe `track`, then launch the window
lake build track           # build the `track` executable only
lake build TrackGeometry   # build the Lean library only
lake build raylibBindings  # regenerate Raylib.lean + raylib_shims.c from raylib.h (rlparser)
lake build libRaylib       # build the vendored raylib static lib (via its Makefile)
lake build libRaylibShims  # build the FFI shim static lib
lake clean                 # remove Lean build outputs
```

`lake exe track` orchestrates everything: raylib (via its own Makefile), the FFI
shim, and the Lean binary — all incrementally, so an unchanged rebuild does no
work. `raylibBindings` is deliberately *not* part of the default build (Lake
resolves the Lean module graph before custom targets run); regenerate the
bindings by hand only after bumping the vendored raylib.

UI controls:
- **left-click** place PI
- **right-click / C** clear
- **scroll** zoom
- **middle-drag** pan
- **Ctrl+Z** undo
- **Ctrl+Shift+Z** redo
- **[ ]** switch redo branch. The history tree is drawn top-right.

## Where to look

- New to the project → `TrackGeometry/Lib.lean` (the whole engine).
- How a curve is sampled → `clothoidPoint`, `Segment.pointAt`, `AlignmentPath.pointAt`.
- How corners become arcs → `solveCorner`, `buildPath`.
- How the UI uses it → `Main.lean` (`step` calls `buildPath` + `pointAt`).
- Worked examples → `scripts/dump_csv.lean`.
- 
