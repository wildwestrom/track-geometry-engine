import TrackGeometry.UI.State

/-! # Picking & snapping

Screen-space hit-testing for everything the cursor can grab: PIs, curve-end brackets,
and the translate gizmo's axis shafts. -/

open Raylib

/-- A reference to a single PI the cursor can grab to drag: which line, which index
    within that line, and its world position. -/
structure PointRef where
  lineIdx : Nat
  ptIdx   : Nat
  pos     : Vector3

/-- The PI nearest the cursor within `thresh` *screen pixels*, across every point of every
    line, paired with its squared pixel distance. Projects each PI to the screen and
    compares pixel distance, so snapping is uniform regardless of depth; PIs behind the
    camera are skipped. -/
def nearestPoint (lines : Array Line) (cam : Camera3D) (mouse : Vector2) (thresh : Float) :
    IO (Option (PointRef × Float)) := do
  let mut best : Option (PointRef × Float) := none
  let mut bestD := thresh * thresh
  for h : i in [0:lines.size] do
    let line := lines[i]
    for h : j in [0:line.size] do
      let p := line[j].pos
      if let some sp ← worldToScreenFront? p cam then
        let d := dist2 sp mouse
        if d ≤ bestD then
          bestD := d
          best := some ({ lineIdx := i, ptIdx := j, pos := p }, d)
  return best

/-! ## Curve-end control points (green brackets)

The cursor can snap onto the *ends* of a rounded corner — exactly where the smooth
curve begins (`entry`) and ends (`exit`), each `budget` back from the PI along its
leg. Dragging a bracket overrides that corner's tangent budget, widening or tightening
the curve. We mirror `buildPath`'s corner selection so brackets appear iff a curve is
actually drawn there. -/

/-- A curve endpoint the cursor can grab to resize a corner: which line, which interior
    PI, the two bracket anchor points, and the unit leg directions (into/out of the PI). -/
structure CurveEnd where
  lineIdx : Nat
  piIdx   : Nat
  entry   : Vector3
  exit    : Vector3
  uIn     : Vector3
  uOut    : Vector3

/-- Curve-end data for interior PI `i` of `line` (index `li`), or `none` when that
    corner is degenerate or near-straight — the same condition under which `solveCorner`
    returns `none`, so a bracket shows iff the curve rounds there. The anchors sit
    `budget` back from the PI along each leg (clamped like `buildPath`). -/
def cornerEnd (li : Nat) (line : Line) (i : Nat) : Option CurveEnd := Id.run do
  if ¬ (1 ≤ i ∧ i + 1 < line.size) then return none
  let a := line[i-1]!.pos
  let b := line[i]!.pos
  let c := line[i+1]!.pos
  match cornerLayout (toGeo a) (toGeo b) (toGeo c) designParams
      (line[i]!.budget.map rf) line[i]!.winding with
  | none => return none
  | some layout =>
      return some {
        lineIdx := li, piIdx := i,
        entry := ofGeo layout.entryPoint,
        exit  := ofGeo layout.exitPoint,
        uIn := ofGeo layout.uIn, uOut := ofGeo layout.uOut }

/-- Every curve endpoint across every line. -/
def curveEnds (lines : Array Line) : Array CurveEnd := Id.run do
  let mut out := #[]
  for li in [0:lines.size] do
    let line := lines[li]!
    for i in [1 : line.size - 1] do
      if let some ce := cornerEnd li line i then out := out.push ce
  return out

/-- The curve-end data for a specific corner, if it rounds. -/
def curveEndAt (lines : Array Line) (li pi : Nat) : Option CurveEnd :=
  if h : li < lines.size then cornerEnd li lines[li] pi else none

/-- The curve endpoint nearest the cursor within `thresh` *screen pixels*: `(lineIdx,
    piIdx, isEntry)` paired with its squared pixel distance. Used to highlight markers
    on hover and to grab one for resizing. Endpoints behind the camera are skipped. -/
def nearestCurveEnd (lines : Array Line) (cam : Camera3D) (mouse : Vector2) (thresh : Float) :
    IO (Option ((Nat × Nat × Bool) × Float)) := do
  let mut best : Option ((Nat × Nat × Bool) × Float) := none
  let mut bestD := thresh * thresh
  for ce in curveEnds lines do
    if let some sp ← worldToScreenFront? ce.entry cam then
      let dE := dist2 sp mouse
      if dE ≤ bestD then bestD := dE; best := some ((ce.lineIdx, ce.piIdx, true), dE)
    if let some sp ← worldToScreenFront? ce.exit cam then
      let dX := dist2 sp mouse
      if dX ≤ bestD then bestD := dX; best := some ((ce.lineIdx, ce.piIdx, false), dX)
  return best

/-- What the cursor is close enough to interact with. -/
inductive HitTarget where
  | point (ref : PointRef)
  | curveEnd (lineIdx piIdx : Nat) (isEntry : Bool)

/-- Snap to the nearest interactive target, preferring the closer of a PI and a
    curve-end marker (in screen pixels) when both are under the cursor. -/
def hitTargetAt (lines : Array Line) (cam : Camera3D) (mouse : Vector2) (thresh : Float) :
    IO (Option HitTarget) := do
  match ← nearestPoint lines cam mouse thresh, ← nearestCurveEnd lines cam mouse thresh with
  | some (pr, dP), some ((l, p, isEntry), dC) =>
      return some (if dC < dP then .curveEnd l p isEntry else .point pr)
  | some (pr, _), none => return some (.point pr)
  | none, some ((l, p, isEntry), _) => return some (.curveEnd l p isEntry)
  | none, none => return none

/-! ## Translate gizmo (X/Y/Z axis handles)

A Blender-style three-axis handle that appears on the PI under the cursor. Its shafts are
sized by camera distance to a roughly constant screen length; grabbing one constrains the
drag to that world axis, which is the only way to change a PI's elevation (Z) — plain point
drags slide along the ground plane. -/

/-- The gizmo axis nearest the cursor for the PI at `p`, with its screen-pixel distance:
    projects each shaft `[p, p + axis·len]` to the screen and measures cursor proximity. -/
def nearestAxis (p : Vector3) (dist : Float) (cam : Camera3D) (mouse : Vector2) :
    IO (Option (Nat × Float)) := do
  let sp ← getWorldToScreen p cam
  let len := dist * GIZMO_LEN_FACTOR
  let mut best : Option (Nat × Float) := none
  for a in [0:3] do
    let st ← getWorldToScreen (add3 p (scale3 len (axisDir a))) cam
    let d := distToSeg mouse sp st
    match best with
    | some (_, bd) => if d < bd then best := some (a, d)
    | none         => best := some (a, d)
  return best

/-- The PI under the cursor (within `GIZMO_PX`), paired with the gizmo axis its shaft is
    close enough to grab (within `AXIS_GRAB_PX`), if any. `none` when no PI is near. Shared
    by the hover highlight and the click-to-grab path so both arm the same axis. -/
def armedAxis (lines : Array Line) (cam : Camera3D) (mouse : Vector2) (dist : Float) :
    IO (Option (PointRef × Option Nat)) := do
  match ← nearestPoint lines cam mouse GIZMO_PX with
  | none    => return none
  | some (pr, _) =>
      match ← nearestAxis pr.pos dist cam mouse with
      | some (a, d) => return some (pr, if d ≤ AXIS_GRAB_PX then some a else none)
      | none        => return some (pr, none)

/-- New world position when dragging PI `p` along world `axis`: the point on the axis line
    through `p` closest to the cursor's pick ray. `none` when the axis is ~parallel to the
    view ray (the constraint is then ill-conditioned, so we skip the frame). -/
def axisDragPos (p : Vector3) (axis : Nat) (cam : Camera3D) (mouse : Vector2) :
    IO (Option Vector3) := do
  let ray ← getScreenToWorldRay mouse cam
  let u := axisDir axis
  let r := sub3 p ray.position
  let e := dot3 ray.direction ray.direction
  let b := dot3 u ray.direction
  let denom := e - b * b                 -- a = u·u = 1
  if denom < 1e-9 then return none
  let s := (b * dot3 ray.direction r - e * dot3 u r) / denom
  return some (add3 p (scale3 s u))
