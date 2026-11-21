import TrackGeometry.UI.Config
import TrackGeometry.UI.Camera
import TrackGeometry.History

/-! # UI state

The lines under construction, the line-building finite state machine, the top-level
`UI` state (with its undo tree and cached curve samples), state-update helpers, and the
off-thread curve resampling. -/

open Raylib

/-- One point of intersection: its world position, an optional per-corner tangent
    budget override (absolute world units), and a signed turn winding. The budget
    resizes the curve rounding *this* corner.
    `none` means the automatic `legBudget`-derived size. The override travels with its
    corner across inserts, prepends, and undo (it's attached to the point, not an index). -/
structure PI where
  pos     : Vector3
  budget  : Option Float := none
  winding : Int := 0
  deriving Inhabited

/-- One alignment under construction: an ordered polyline of points of
    intersection (world coordinates). Each line is rounded into its own smooth
    alignment independently of the others. -/
abbrev Line := Array PI

/-- One sampled point on a rendered alignment. `segmentColor` is the segment-type
    colour used by view 1; `speed` feeds the speed ramp in view 2. `label`, set only on
    the sample at a straight's or arc's midpoint, is that section's speed restriction
    (m/s) drawn as a number in the speed view.

    `kappa` is unsigned curvature magnitude (1/m) from `Segment.curvatureAt`.
    `cant` is **design** applied cant height (m): signed `± G V² κ / g` (balanced), with
    sign choosing outer-rail-high from the corner plane binormal.
    `normal` / `binormal` are the **design-cant** axes: level frame rolled about `T` by
    `φ` with `sin φ = cant/G` (not RMF geometric bank). -/
structure CurveSample where
  pos          : Vector3
  segmentColor : Color
  speed        : Float
  normal       : Vector3 := ⟨0, 0, 0⟩
  binormal     : Vector3 := ⟨0, 0, 1⟩
  kappa        : Float := 0.0
  cant         : Float := 0.0
  label        : Option Float := none
  deriving Inhabited

/-- Which render colouring is active. Toggling is a recolour only — never a resample. -/
inductive RenderView where
  | segmentType
  | speed
  deriving Inhabited, BEq, Repr

/-- The line-building finite state machine.

    * `idle` — no line is active. A left-click on empty space starts a new line;
      a left-click snapped onto an existing point either resumes its line (if it is
      an endpoint) or, after a small drag, moves that point.
    * `building lineIdx atEnd provisional recorded` — left-clicks extend
      `lines[lineIdx]`, appending to its end when `atEnd`, otherwise prepending to
      its start. `recorded` means this placement session already owns the current
      history node, so further placements update it in place. When `provisional`,
      Escape / right-click discards the one-point draft as if it was never started;
      otherwise it just returns to `idle`.
    * `pressed lineIdx ptIdx press` — the mouse went down on point `ptIdx` of line
      `lineIdx` (snapped); `press` is the cursor's *screen* position at that moment. We
      don't yet know if this is a click or a drag. Releasing without moving is a click;
      moving past a threshold (in screen pixels) starts a drag.
    * `dragging lineIdx ptIdx grab` — point `ptIdx` of line `lineIdx` follows the cursor
      until the button is released. `grab` is the world offset between the point and the
      cursor's ground hit captured when the drag began, so the point tracks the *change* in
      cursor position rather than snapping under it.
    * `bracketPressed lineIdx piIdx isEntry press` — the mouse went down on a green
      curve-end bracket (the entry bracket when `isEntry`, else the exit) of the curve
      at interior PI `piIdx`; like `pressed`, a release without movement is a no-op and
      moving past the threshold begins a resize.
    * `resizing lineIdx piIdx isEntry` — dragging that bracket along its leg, growing or
      shrinking the curve by overriding PI `piIdx`'s tangent budget.
    * `axisPressed lineIdx ptIdx axis press` — the mouse went down on one of PI `ptIdx`'s
      translate-gizmo shafts (`axis` is 0=X, 1=Y, 2=Z); like `pressed`, a release without
      movement is a no-op and moving past the threshold begins an axis-constrained drag.
    * `axisDragging lineIdx ptIdx axis grab` — dragging PI `ptIdx` along world `axis` only,
      tracking the closest point between the mouse ray and the axis line through the PI.
      `grab` is the same change-tracking offset as `dragging` (here along the axis). -/
inductive Mode
  | idle
  | building (lineIdx : Nat) (atEnd provisional recorded : Bool)
  | pressed (lineIdx ptIdx : Nat) (press : Vector2)
  | dragging (lineIdx ptIdx : Nat) (grab : Vector3)
  | bracketPressed (lineIdx piIdx : Nat) (isEntry : Bool) (press : Vector2)
  | resizing (lineIdx piIdx : Nat) (isEntry : Bool)
  | axisPressed (lineIdx ptIdx axis : Nat) (press : Vector2)
  | axisDragging (lineIdx ptIdx axis : Nat) (grab : Vector3)

/-- The PI at `lineIdx`/`ptIdx`, or `none` if either index is out of range. The one place
    bounds are checked when reaching into the (line, point) grid. -/
@[inline] def getPI? (lines : Array Line) (lineIdx ptIdx : Nat) : Option PI :=
  if h : lineIdx < lines.size then lines[lineIdx][ptIdx]? else none

/-- Whether `lineIdx`/`ptIdx` references an existing PI. -/
@[inline] def validPt (lines : Array Line) (lineIdx ptIdx : Nat) : Bool :=
  (getPI? lines lineIdx ptIdx).isSome

/-- Drop back to `idle` if a referenced line/point no longer exists (e.g. after an
    undo removed the line). Indices are otherwise stable across history moves. -/
def Mode.revalidate : Mode → Array Line → Mode
  | .building idx e p r, lines    => if idx < lines.size then .building idx e p r else .idle
  | .pressed l p press, lines     => if validPt lines l p then .pressed l p press else .idle
  | .dragging l p g, lines        => if validPt lines l p then .dragging l p g else .idle
  | .bracketPressed l p e press, lines => if validPt lines l p then .bracketPressed l p e press else .idle
  | .resizing l p e, lines        => if validPt lines l p then .resizing l p e else .idle
  | .axisPressed l p ax press, lines   => if validPt lines l p then .axisPressed l p ax press else .idle
  | .axisDragging l p ax g, lines => if validPt lines l p then .axisDragging l p ax g else .idle
  | .idle, _ => .idle

/-- An in-flight background resample. Every expensive `sampleCurve` runs here, off the
    render thread, so no edit ever blocks the UI. Two shapes:
    - `line idx task`: resample a single line's curve (a drag, or the one exact resample
      on release). Low latency; at most one in flight, a new one spawned when it finishes.
    - `full task`: resample *all* lines into a fresh curves array. Used for structural
      changes (placing/finishing a point, undo/redo, winding) where the line count or
      several lines may change at once. Superseded by any newer change. -/
inductive PendingResample where
  | line (idx : Nat) (task : Task (Array CurveSample))
  | full (task : Task (Array (Array CurveSample)))

structure UI where
  camera : OrbitCam
  /-- Undo/redo *tree* of the placed lines (each a polyline of PIs in world
      coordinates). The current node's state is the live set of lines. -/
  hist : History.History (Array Line)
  /-- Cached smooth alignment per line, resampled only when the lines change. Each
      sample carries its point, segment-type colour (view 1), and operating speed
      (view 2) — so toggling views is a recolour, never a resample. -/
  curves : Array (Array CurveSample)
  /-- Which render colouring is active (segment type vs speed ramp). -/
  view : RenderView
  /-- Transient line-building state. Not part of the undo history. -/
  mode : Mode
  /-- Modal instructions overlay. While open, edit inputs are ignored. -/
  showInstructions : Bool
  /-- Optional Raylib FPS counter. Toggled separately from instructions. -/
  showFPS : Bool
  /-- Level-frame lateral ticks (F4 toggle); aligned with the rails. -/
  showTicks : Bool
  /-- Always-on point coordinate labels (F5 toggle). -/
  showCoords : Bool
  /-- An in-flight background resample (see `PendingResample`). The render loop polls it
      each frame and never blocks, so *every* edit — drag, release, point placement,
      undo/redo — stays at full framerate while the route math runs off-thread. At most
      one is in flight; structural changes and releases supersede it. -/
  pending : Option PendingResample

/-! ### State update helpers -/

/-- Commit a line snapshot either as a fresh undo node or by updating the current one. -/
@[inline] def commitLines (hist : History.History (Array Line)) (lines : Array Line)
    (recorded : Bool) : History.History (Array Line) :=
  if recorded then History.setCurrent hist lines else History.record hist lines

/-- Update one line in the line array. The caller must have validated `lineIdx`. -/
@[inline] def updateLine! (lines : Array Line) (lineIdx : Nat) (f : Line → Line) : Array Line :=
  lines.set! lineIdx (f lines[lineIdx]!)

/-- Add a PI at either end of an existing line. -/
@[inline] def addPIAtEnd! (lines : Array Line) (lineIdx : Nat) (atEnd : Bool)
    (pos : Vector3) : Array Line :=
  updateLine! lines lineIdx fun line =>
    if atEnd then line.push { pos := pos } else #[({ pos := pos } : PI)] ++ line

/-- Move one PI inside an existing line. The caller must have validated both indices. -/
@[inline] def setPIPos! (lines : Array Line) (lineIdx ptIdx : Nat) (pos : Vector3) :
    Array Line :=
  updateLine! lines lineIdx fun line =>
    line.set! ptIdx { line[ptIdx]! with pos := pos }

/-- Override one PI's corner budget. The caller must have validated both indices. -/
@[inline] def setPIBudget! (lines : Array Line) (lineIdx piIdx : Nat) (budget : Float) :
    Array Line :=
  updateLine! lines lineIdx fun line =>
    line.set! piIdx { line[piIdx]! with budget := some budget }

/-- Cycle one interior PI through short, left-loop, and right-loop turns. -/
@[inline] def cyclePIWinding! (lines : Array Line) (lineIdx piIdx : Nat) : Array Line :=
  updateLine! lines lineIdx fun line =>
    let cur := line[piIdx]!
    let next := if cur.winding = 0 then 1 else if cur.winding = 1 then -1 else 0
    line.set! piIdx { cur with winding := next }

/-! ### Curve sampling -/

/-- Sample one line's smooth alignment into a polyline for drawing (empty if the
    line has fewer than two PIs). Rails/ticks use design cant from `κ` and segment
    operating speed (level frame rolled about `T`), not RMF geometric bank. -/
def sampleCurve (line : Line) : Array CurveSample := Id.run do
  let mut out := #[]
  if line.size ≥ 2 then
    let pts := line.map fun q => toGeo q.pos
    let path := buildPath pts layoutPolicy speedModel straightThreshold
      (line.map fun q => q.budget.map rf) (line.map (·.winding))
    let total := path.length |>.val
    if total > 0.0 then
      for e in path.segments do
        let color := segColor e
        let speed := segSpeed e
        let segment_len := e.length.val
        let num_of_samples := max 2 (Float.ceil (Float.ofNat CURVE_SAMPLES * segment_len / total)).toUInt64.toNat
        -- Straights and arcs carry a speed-restriction label at their midpoint sample;
        -- transitions share their corner's arc speed, so we don't double-label them.
        let labeled := match e with
          | ⟨_, _, .straight .., _⟩ | ⟨_, _, .arc .., _⟩ => true
          | _                                            => false
        let midSample := num_of_samples / 2
        -- Plane binormal gives turn sense for signed design cant (outer rail high).
        let bp := e.seg.planeBinormal
        let bpX := (bp 0).val; let bpY := (bp 1).val; let bpZ := (bp 2).val
        let bpLen := Float.sqrt (bpX*bpX + bpY*bpY + bpZ*bpZ)
        let Bplane : Vector3 :=
          if bpLen > 0.0 then ⟨bpX / bpLen, bpY / bpLen, bpZ / bpLen⟩ else ⟨0.0, 0.0, 1.0⟩
        for j in [0:num_of_samples + 1] do
          let t := segment_len * Float.ofNat j / Float.ofNat num_of_samples
          let q := e.pointAt (rf t)
          let Tg := e.tangentAt (rf t)
          let T : Vector3 := norm3 ⟨(Tg 0).val, (Tg 1).val, (Tg 2).val⟩
          let κ := (e.curvatureAt (rf t)).val
          -- Design cant from curvature + operating speed (balanced: |h| = h_eq).
          let hMag := designCantF speed κ
          let h := cantTurnSign T Bplane * hMag
          let (Ncant, Bcant) := cantedNB TRACK_GAUGE T h
          let label := if labeled && j == midSample then some speed else none
          out := out.push { pos := ofGeo q, segmentColor := color, speed := speed,
                            normal := Ncant, binormal := Bcant,
                            kappa := κ, cant := h, label := label }
  return out

/-- Rebuild or incrementally update cached curve samples after edits. -/
def updateCurveCache (lines : Array Line) (curves : Array (Array CurveSample))
    (pending : Option PendingResample) (dirty : Bool)
    (dragIdx finalizeIdx : Option Nat) :
    IO (Array (Array CurveSample) × Option PendingResample) := do
  let mut curves := curves
  let mut pending := pending

  -- 1. Apply the in-flight resample if it has finished. `curves` may lag `lines` for a
  --    few frames; `drawWorldScene` draws the tangent polyline and PIs straight from
  --    `lines`, so the only visible effect is a curve catching up a frame or two late.
  match pending with
  | some (.line idx task) =>
      if (← IO.hasFinished task) then
        if idx < curves.size then curves := curves.set! idx task.get
        pending := none
  | some (.full task) =>
      if (← IO.hasFinished task) then
        curves := task.get
        pending := none
  | none => pure ()

  -- 2. Spawn a resample for whatever changed this frame — always off-thread.
  --    Structural changes and the drag-release finalize *supersede* any in-flight task
  --    (which is now stale); a plain drag only spawns when nothing is pending so frames
  --    never queue up behind each other.
  if dirty then
    -- Placement, undo/redo, winding, etc.: the line count or several lines may change, so
    -- rebuild the whole curves array in the background.
    pending := some (.full (Task.spawn (fun _ => lines.map sampleCurve)))
  else if let some idx := finalizeIdx then
    if idx < lines.size then
      pending := some (.line idx (Task.spawn (fun _ => sampleCurve lines[idx]!)))
  else if let some idx := dragIdx then
    if pending.isNone && idx < lines.size then
      pending := some (.line idx (Task.spawn (fun _ => sampleCurve lines[idx]!)))

  return (curves, pending)

/-! ### Per-frame input state -/

/-- Read-only per-frame context shared by the input handlers: the camera, the cursor
    position, the orbit distance (for screen-constant sizing), and whether Escape fired. -/
structure InputCtx where
  cam    : Camera3D
  mouse  : Vector2
  dist   : Float
  escape : Bool

/-- The editable state threaded through one frame's input handlers: the undo history, the
    line-building FSM, the render view, and the resample hints the curve cache consumes
    (`dirty` for structural changes, `dragIdx`/`finalizeIdx` for single-line drags). -/
structure Edit where
  hist        : History.History (Array Line)
  mode        : Mode
  view        : RenderView
  dirty       : Bool := false
  dragIdx     : Option Nat := none
  finalizeIdx : Option Nat := none
