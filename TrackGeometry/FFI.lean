import TrackGeometry.Lib

/-! ## C FFI for interactive alignment editing

This module exposes a tiny C-callable API so a host program (e.g. a Raylib UI) can
build a `RailwayAlignment` by placing points of intersection (PIs) with the mouse and
then query points along the resulting curve to render it.

The state — the list of placed PIs and the cached `AlignmentPath` built from them —
lives in two module-global `IO.Ref`s, set up by the `initialize` blocks when the
module is loaded. The exported functions all run in `IO` (not as nullary `def`s) so
that each call re-reads the current state instead of being memoised as a constant.

### Exported C symbols

```c
void   place(double x, double y);          // record a PI (mouse click); rebuilds the path
void   clearAlignment(void);               // forget all PIs
double alignmentLength(void);              // total arc-length of the current curve
// pointAt returns a `Float × Float` as a Lean object (see main.c for how to unpack it)
lean_object* pointAt(double s);            // point at arc-length s (clamped/empty -> origin)
```

Scalars use the computable `RFloat` (a `Float` newtype) instance of `TrackScalar`.
-/

namespace FFI

open Vec3

/-- Wrap a raw `Float` as the engine's scalar type. -/
@[inline] private def s (x : Float) : RFloat := ⟨x⟩

/-- An empty path is a sensible default (needed so `initialize` can build the ref). -/
instance : Inhabited (AlignmentPath RFloat) := ⟨⟨#[]⟩⟩

/-- The placed points of intersection (PIs), in click order. -/
initialize ptsRef : IO.Ref (Array (Vec3 RFloat)) ← IO.mkRef #[]

/-- The alignment path built from the current PIs, cached so queries are cheap.
    Rebuilt by `place` / `clearAlignment`. -/
initialize pathRef : IO.Ref (AlignmentPath RFloat) ← IO.mkRef ⟨#[]⟩

/-- Cumulative end arc-length of each segment in `pathRef`: `cum[i]` is the total
    length of segments `0..i`. Computed once per rebuild so that a query never has
    to re-sum (and re-evaluate the trig inside) every segment's length. The last
    entry is the whole alignment's length; an empty array means an empty path. -/
initialize cumRef : IO.Ref (Array Float) ← IO.mkRef #[]

/-- Auto-radius design parameters for the PI builder: each interior corner may consume
    30% of the shorter adjacent leg as tangent budget; corners flatter than this
    `straightThreshold` (on `|sin Δ|`) pass straight through. -/
def designParams : DesignParams RFloat :=
  { legBudget := ⟨0.3⟩, straightThreshold := ⟨0.001⟩ }

/-- Rebuild the cached path — and its cumulative-length table — from the current PIs. -/
private def rebuild : IO Unit := do
  let pts ← ptsRef.get
  let path := buildPath pts designParams
  pathRef.set path
  let mut cum : Array Float := #[]
  let mut acc : Float := 0.0
  for seg in path.segments do
    acc := acc + seg.length.val
    cum := cum.push acc
  cumRef.set cum

/-- Record a placed PI at `(x, y)` (z = 0) and rebuild the alignment. -/
@[export place]
def place (x y : Float) : IO Unit := do
  ptsRef.modify (·.push (Vec3.mk (s x) (s y) (s 0)))
  rebuild

/-- Forget all placed PIs and reset the alignment to empty. -/
@[export clearAlignment]
def clearAlignment : IO Unit := do
  ptsRef.set #[]
  pathRef.set ⟨#[]⟩
  cumRef.set #[]

/-- Total arc-length of the current alignment (0 with fewer than two PIs). -/
@[export alignmentLength]
def alignmentLength : IO Float := do
  let cum ← cumRef.get
  return if cum.isEmpty then 0.0 else cum[cum.size - 1]!

/-- Sample the alignment at arc-length `arc`, returning `(x, y)`.

    `arc` is clamped to `[0, length]` so callers can sample right up to the endpoint
    without floating-point round-off falling off the end. An empty alignment yields
    `(0, 0)`. -/
@[export pointAt]
def pointAt (arc : Float) : IO (Float × Float) := do
  let path ← pathRef.get
  let cum ← cumRef.get
  let n := cum.size
  if n == 0 then return (0.0, 0.0)
  let len := cum[n - 1]!
  -- Clamp into [0, hi] with `hi` a hair below `len`, so round-off in the
  -- segment lookup below can't fall off the end.
  let hi := len - (len + 1.0) * 1e-9
  let arc := if arc ≤ 0 then 0.0 else if arc ≥ hi then hi else arc
  -- Find the first segment whose cumulative end length reaches `arc`. The table is
  -- monotone, so this is a plain walk over precomputed floats — no length recompute.
  let mut i := 0
  while i + 1 < n && cum[i]! < arc do
    i := i + 1
  let segStart := if i == 0 then 0.0 else cum[i - 1]!
  match path.segments[i]? with
  | some seg =>
    let p := seg.pointAt (s (arc - segStart))
    return ((p 0).val, (p 1).val)
  | none => return (0.0, 0.0)

end FFI
