import TrackGeometry.Lib
import TrackGeometry.Raylib
import TrackGeometry.History

/-! # Track Geometry — interactive UI (in Lean)

The whole UI loop lives here: camera (zoom/pan), mouse & keyboard input, drawing the
tangent polyline, the smooth alignment, the PI markers, and the screen-space HUD. It calls
the geometry engine (`TrackGeometry.Lib`) directly and the generated Raylib bindings
(`TrackGeometry.Raylib`). The only C left in the project is the generated FFI shim. -/

open Raylib

/-! ## Small numeric / formatting helpers -/

/-- Wrap a raw `Float` as the engine's scalar type. -/
@[inline] def rf (x : Float) : RFloat := ⟨x⟩

def clampF (lo hi x : Float) : Float := max lo (min hi x)

def pow10 : Nat → Float
  | 0 => 1.0
  | n + 1 => 10.0 * pow10 n

/-- Format `x` with `prec` fixed decimal places (à la C's `%.Nf`). -/
def fmtFixed (x : Float) (prec : Nat) : String := Id.run do
  let neg := x < 0.0
  let x := if neg then -x else x
  let scaled := (x * pow10 prec + 0.5).toUInt64.toNat
  let mut digits := toString scaled
  if digits.length < prec + 1 then
    digits := String.ofList (List.replicate (prec + 1 - digits.length) '0') ++ digits
  let cut := digits.length - prec
  let intPart := digits.take cut
  let fracPart := digits.drop cut
  return (if neg then "-" else "") ++ intPart ++ (if prec == 0 then "" else "." ++ fracPart)

/-- A `%g`-ish formatter: drop the fraction for whole numbers, else 3 places. -/
def fmtG (x : Float) : String :=
  if x == x.floor then toString x.floor.toUInt64.toNat else fmtFixed x 3

/-- Float → screen coordinate (raylib `int`, mapped to `UInt32` by the binding). -/
@[inline] def f2u (x : Float) : UInt32 := x.toUInt32

/-! ## Constants -/

def FONT : UInt32 := 8
def MAX_PI : Nat := 512
def CURVE_SAMPLES : Nat := 400
/-- Snap radius, in screen pixels, for grabbing a line endpoint. Converted to
    world units per frame (`SNAP_PX / zoom`) so it's zoom-independent. -/
def SNAP_PX : Float := 20.0
/-- How far (screen pixels) the cursor must move after pressing on a point before it
    counts as a drag rather than a click. Below this, a press+release is a click. -/
def DRAG_PX : Float := 4.0

def BG : Color := BLACK
def FG : Color := WHITE
def SECONDARY : Color := GRAY
def POINT_COLOR : Color := RED
/-- Highlight for the branch `redo` will follow next. -/
def REDO_COLOR : Color := GREEN

/-! ### Per-segment-type colors for the smooth alignment. -/
def STRAIGHT_COLOR   : Color := Color.mk 102 191 255 255
def ARC_COLOR        : Color := Color.mk 255 161   0 255
def TRANSITION_COLOR : Color := Color.mk 230 110 200 255

/-- Color for a path piece, by segment type. -/
def segColor (e : AnySegment RFloat) : Color :=
  match e with
  | ⟨_, _, .straight ..⟩      => STRAIGHT_COLOR
  | ⟨_, _, .arc ..⟩           => ARC_COLOR
  | ⟨_, _, .transitionIn ..⟩  => TRANSITION_COLOR
  | ⟨_, _, .transitionOut ..⟩ => TRANSITION_COLOR

/-- Auto-radius design parameters for the PI builder. `minRadius` is a hard floor (1
    scene unit = 1 m): ~100 m is roughly an AREMA-style absolute minimum for sharp
    standard-gauge yard/industrial track (mainline minimums run far larger). -/
def designParams : DesignParams RFloat :=
  { legBudget := rf 0.3, minRadius := rf 100.0, straightThreshold := rf 0.001,
    -- comfort limits (1 scene unit = 1 m): V = √(a_max·R) per corner, clothoid sized
    -- to the larger of the jerk- and yaw-acceleration-limited lengths.
    maxLateralAccel := rf 1.2, maxLateralJerk := rf 0.5, maxYawAccel := rf 0.2,
    maxDesignSpeed := rf 83.3333 }  -- 300 km/h

/-! ### Speed view: per-segment operating speed and a green→red colour ramp. -/

def MPS_TO_KMH : Float := 3.6
/-- Design-speed ceiling, as a raw `Float`. -/
def designSpeedF : Float := designParams.maxDesignSpeed.val
def aMaxF : Float := designParams.maxLateralAccel.val

/-- Speed-view colour-ramp endpoints (m/s), an absolute scale independent of the
    route. Anything at or below `SPEED_RAMP_MIN` is red; at or above `SPEED_RAMP_MAX`
    is green. Constants for now; can be made configurable later. -/
def SPEED_RAMP_MIN : Float := 30.0  / MPS_TO_KMH   -- 30 km/h
def SPEED_RAMP_MAX : Float := 300.0 / MPS_TO_KMH   -- 300 km/h

/-- Operating speed (scene-units/s) a piece is designed for: `min(designSpeed,
    √(a_max·|R|))` for curved pieces (radius read straight off the segment), and the
    design speed for unrestricted straights. Mirrors `solveCorner`'s `opSpeed`. -/
def segSpeed (e : AnySegment RFloat) : Float :=
  let curveSpeed := fun (r : RFloat) =>
    let absR := if r.val < 0.0 then -r.val else r.val
    min designSpeedF (Float.sqrt (aMaxF * absR))
  match e with
  | ⟨_, _, .straight ..⟩        => designSpeedF
  | ⟨_, _, .arc r ..⟩           => curveSpeed r
  | ⟨_, _, .transitionIn r ..⟩  => curveSpeed r
  | ⟨_, _, .transitionOut r ..⟩ => curveSpeed r

/-- Clamp a float to a `[0,255]` colour channel. -/
@[inline] def chan (x : Float) : UInt8 := (clampF 0.0 255.0 x).toUInt32.toUInt8

/-- Map a speed to a colour on a red→yellow→green ramp: `s = minS` is red (slow),
    `s = maxS` is green (fast). Passing through yellow keeps the mid-range legible. -/
def speedColor (minS maxS s : Float) : Color :=
  let t := if maxS - minS < 1e-9 then 1.0 else clampF 0.0 1.0 ((s - minS) / (maxS - minS))
  let (r, g, b) :=
    if t < 0.5 then
      let u := t / 0.5                       -- red(220,40,40) → yellow(230,200,40)
      (220.0 + 10.0 * u, 40.0 + 160.0 * u, 40.0)
    else
      let u := (t - 0.5) / 0.5               -- yellow(230,200,40) → green(40,200,40)
      (230.0 - 190.0 * u, 200.0, 40.0)
  Color.mk (chan r) (chan g) (chan b) 255

/-! ## 3D math, vectors, and the orbit camera -/

def CAM_FOVY : Float := 60.0
def MIN_DIST : Float := 5.0
/-- Max orbit distance, kept under raylib's far-clip (`RL_CULL_DISTANCE_FAR`) so the
    target plane never falls outside the view frustum when zoomed all the way out. -/
def MAX_DIST : Float := 9000.0

/-! ### Small 3D vector helpers (raylib `Vector3`, world space). -/
@[inline] def sub3 (a b : Vector3) : Vector3 := ⟨a.x - b.x, a.y - b.y, a.z - b.z⟩
@[inline] def add3 (a b : Vector3) : Vector3 := ⟨a.x + b.x, a.y + b.y, a.z + b.z⟩
@[inline] def scale3 (s : Float) (v : Vector3) : Vector3 := ⟨s * v.x, s * v.y, s * v.z⟩
@[inline] def dot3 (a b : Vector3) : Float := a.x * b.x + a.y * b.y + a.z * b.z
@[inline] def cross3 (a b : Vector3) : Vector3 :=
  ⟨a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x⟩
@[inline] def len3 (v : Vector3) : Float := Float.sqrt (dot3 v v)
@[inline] def norm3 (v : Vector3) : Vector3 :=
  let l := len3 v; if l < 1e-12 then v else scale3 (1.0 / l) v

/-- raylib `Vector3` → geometry `Vec3 RFloat`. -/
@[inline] def toGeo (p : Vector3) : Vec3 RFloat := Vec3.mk (rf p.x) (rf p.y) (rf p.z)
/-- geometry `Vec3 RFloat` → raylib `Vector3`. -/
@[inline] def ofGeo (p : Vec3 RFloat) : Vector3 := ⟨(p 0).val, (p 1).val, (p 2).val⟩

/-- Orbit camera state: a target point with a spherical eye offset. World-up is +z
    (elevation), so `yaw` swings the eye around the vertical and `pitch` raises/lowers it. -/
structure OrbitCam where
  target   : Vector3
  distance : Float
  yaw      : Float
  pitch    : Float
  deriving Inhabited

/-- Unit eye-from-target direction for the current yaw/pitch. -/
@[inline] def OrbitCam.dir (o : OrbitCam) : Vector3 :=
  let cp := Float.cos o.pitch
  ⟨cp * Float.cos o.yaw, cp * Float.sin o.yaw, Float.sin o.pitch⟩

/-- The per-frame raylib `Camera3D` (perspective, world-up = +z). -/
def OrbitCam.toCamera3D (o : OrbitCam) : Camera3D :=
  { position := add3 o.target (scale3 o.distance o.dir),
    target := o.target, up := ⟨0.0, 0.0, 1.0⟩,
    fovy := CAM_FOVY, projection := CAMERA_PERSPECTIVE }

/-- Intersect a ray with the horizontal plane `z = planeZ`; `none` if parallel to it or
    the hit lies behind the ray origin. -/
def rayPlaneZ (ray : Ray) (planeZ : Float) : Option Vector3 :=
  let dz := ray.direction.z
  if dz == 0.0 then none
  else
    let t := (planeZ - ray.position.z) / dz
    if t < 0.0 then none
    else some ⟨ray.position.x + t * ray.direction.x, ray.position.y + t * ray.direction.y, planeZ⟩

/-- World point under the cursor on the horizontal plane `z = planeZ` (the ground by
    default). `none` when the cursor ray misses the plane. -/
def screenToGround (mouse : Vector2) (cam : Camera3D) (planeZ : Float := 0.0) :
    IO (Option Vector3) := do
  return rayPlaneZ (← getScreenToWorldRay mouse cam) planeZ

/-! ## UI state -/

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
    (m/s) drawn as a number in the speed view. -/
structure CurveSample where
  pos          : Vector3
  segmentColor : Color
  speed        : Float
  label        : Option Float := none
  deriving Inhabited

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
  /-- Which render view is active: `1` = segment type, `2` = speed. -/
  view : Nat
  /-- Transient line-building state. Not part of the undo history. -/
  mode : Mode
  /-- Modal instructions overlay. While open, edit inputs are ignored. -/
  showInstructions : Bool
  /-- Optional Raylib FPS counter. Toggled separately from instructions. -/
  showFPS : Bool
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

/-! ## HUD helpers (screen space) -/

/-- Crosshair at the cursor plus the ground-plane coordinate under it. The cursor is
    already in logical screen space, the same space 2D drawing uses, so no scaling. -/
def drawMouse (cam : Camera3D) (mouse : Vector2) (showCoords : Bool := true) : IO Unit := do
  let sp := mouse
  let size := 6.0
  drawLine (f2u (sp.x - size)) (f2u sp.y) (f2u (sp.x + size - 1.0)) (f2u sp.y) FG
  drawLine (f2u sp.x) (f2u (sp.y - size)) (f2u sp.x) (f2u (sp.y + size - 1.0)) FG
  if showCoords then
    match ← screenToGround mouse cam with
    | some g => drawText s!"({fmtFixed g.x 1},{fmtFixed g.y 1})" (f2u (sp.x + 1.0)) (f2u (sp.y + 1.0)) FONT FG
    | none   => pure ()

/-- Modal help screen for all interactive controls. -/
def drawInstructions (showFPS : Bool) (view : Nat) : IO Unit := do
  let sw := Float.ofNat (← getScreenWidth).toNat
  let sh := Float.ofNat (← getScreenHeight).toNat
  let panelW := min (sw - 48.0) 560.0
  let panelH := min (sh - 48.0) 330.0
  let x := max 12.0 ((sw - panelW) / 2.0)
  let y := max 12.0 ((sh - panelH) / 2.0)
  let bg := Color.mk 0 0 0 232
  drawRectangle (f2u x) (f2u y) (f2u panelW) (f2u panelH) bg
  drawText "Instructions" (f2u (x + 16.0)) (f2u (y + 14.0)) 20 FG
  drawText "Press F1 or Esc to return." (f2u (x + 16.0)) (f2u (y + 42.0)) FONT SECONDARY
  let rows := #[
    ("F1", "toggle instructions"),
    ("F3", s!"toggle FPS ({if showFPS then "shown" else "hidden"})"),
    ("Left click", "place a PI, continue a line, or grab a point"),
    ("Endpoint click", "resume building from that end"),
    ("Drag point", "move a PI on the ground plane"),
    ("Drag X/Y/Z handle", "move a PI along one axis (Z = elevation)"),
    ("Drag curve end", "resize that corner"),
    ("L", "cycle selected corner winding"),
    ("Right click / Esc", "finish or cancel the active line"),
    ("Mouse wheel", "dolly (zoom) the camera"),
    ("Middle drag", "orbit the camera"),
    ("Shift + Middle drag", "pan the camera"),
    ("Ctrl+Z", "undo"),
    ("Ctrl+Shift+Z", "redo"),
    ("[ / ]", "switch redo branch"),
    ("1 / 2", s!"view: {if view == 1 then "[type]" else "type"} / {if view == 2 then "[speed]" else "speed"}")
  ]
  for h : i in [0:rows.size] do
    let row := rows[i]
    let yy := y + 64.0 + Float.ofNat i * 17.0
    drawText row.1 (f2u (x + 20.0)) (f2u yy) FONT FG
    drawText row.2 (f2u (x + 140.0)) (f2u yy) FONT SECONDARY

/-! ## Undo-tree HUD -/

/-- Assign each node a `(column, depth)` coordinate by a tidy depth-first layout:
    leaves take successive columns, and each internal node is centered over the span
    of its children. Writes into `acc` (indexed by node) and threads the running leaf
    column. -/
partial def layoutTree (nodes : Array (History.Node (Array Line)))
    (i : Nat) (depth col : Float) (acc : Array (Float × Float)) :
    Array (Float × Float) × Float :=
  let children := nodes[i]!.children
  if children.size = 0 then
    (acc.set! i (col, depth), col + 1.0)
  else Id.run do
    let mut acc := acc
    let mut col := col
    let mut firstX := 0.0
    let mut lastX := 0.0
    for k in [0:children.size] do
      let c := children[k]!
      let (acc', col') := layoutTree nodes c (depth + 1.0) col acc
      acc := acc'
      col := col'
      let cx := (acc[c]!).1
      if k = 0 then firstX := cx
      lastX := cx
    acc := acc.set! i ((firstX + lastX) / 2.0, depth)
    return (acc, col)

/-- How many depth levels of history to show above (older than) the current node.
    Older states scroll off the top so the tree always fits the panel. -/
def HIST_ROWS_BACK : Float := 14.0
/-- How many levels below (newer than) the current node to show (redo branches). -/
def HIST_ROWS_FWD : Float := 4.0
/-- Pixel spacing between tree rows / columns. -/
def HIST_STEP : Float := 12.0

/-- Draw the undo/redo tree in the top-right corner: edges to children, a dot per
    state, the current node highlighted, and a one-line caption. Only a window of
    depth levels around the current node is shown so a long history stays on screen. -/
def drawHistory (h : History.History (Array Line)) : IO Unit := do
  let nodes := h.nodes
  let n := nodes.size
  let pos := (layoutTree nodes 0 0.0 0.0 (Array.replicate n (0.0, 0.0))).1
  let maxCol := pos.foldl (fun m p => max m p.1) 0.0
  -- visible depth window, anchored on the current node
  let curDepth := (pos[h.current]!).2
  let minD := curDepth - HIST_ROWS_BACK
  let maxD := curDepth + HIST_ROWS_FWD
  let visible := fun (i : Nat) => let d := (pos[i]!).2; minD ≤ d && d ≤ maxD
  let sw := Float.ofNat (← getScreenWidth).toNat
  let right := sw - 12.0
  let top := 64.0
  -- right-align the rightmost column at `right`; clamp so far-left branches don't
  -- wrap to huge coordinates via `f2u`.
  let px := fun (c : Float) => max 2.0 (right - (maxCol - c) * HIST_STEP)
  let py := fun (d : Float) => top + (d - minD) * HIST_STEP
  -- caption, right-aligned using the measured text width
  let label := s!"history: {n} states  ·  {History.branchCount h} branch(es)"
  let tw := Float.ofNat (← measureText label FONT).toNat
  drawText label (f2u (max 2.0 (right - tw))) (f2u (top - 12.0)) FONT SECONDARY
  -- the node `redo` would move to: the current node's active child, if any
  let cur := nodes[h.current]!
  let redoTarget := cur.children[cur.active]?
  -- edges (parent → child), only when both ends are within the window. The edge to
  -- the redo target is drawn in the highlight color so it's clear which branch is next.
  for i in [0:n] do
    if visible i then
      let (cx, cd) := pos[i]!
      for c in nodes[i]!.children do
        if visible c then
          let (kx, kd) := pos[c]!
          let isRedo := i = h.current && redoTarget == some c
          let color := if isRedo then REDO_COLOR else SECONDARY
          drawLine (f2u (px cx)) (f2u (py cd)) (f2u (px kx)) (f2u (py kd)) color
  -- nodes
  for i in [0:n] do
    if visible i then
      let (cx, cd) := pos[i]!
      let center : Vector2 := ⟨px cx, py cd⟩
      if i = h.current then
        drawCircleV center 3.5 POINT_COLOR
      else if redoTarget == some i then
        drawCircleV center 2.5 REDO_COLOR
      else
        drawCircleV center 2.0 FG

/-! ## Snapping & curve sampling -/

/-- Squared distance between two screen points (avoids a `sqrt`). -/
@[inline] def dist2 (a b : Vector2) : Float :=
  let dx := a.x - b.x; let dy := a.y - b.y; dx * dx + dy * dy

/-- A reference to a single PI the cursor can grab to drag: which line, which index
    within that line, and its world position. -/
structure PointRef where
  lineIdx : Nat
  ptIdx   : Nat
  pos     : Vector3

/-- The PI nearest the cursor within `thresh` *screen pixels*, across every point of every
    line. Projects each PI to the screen and compares pixel distance, so snapping is
    uniform regardless of depth; PIs behind the camera are skipped. -/
def nearestPoint (lines : Array Line) (cam : Camera3D) (mouse : Vector2) (thresh : Float) :
    IO (Option PointRef) := do
  let mut best : Option PointRef := none
  let mut bestD := thresh * thresh
  let fwd := sub3 cam.target cam.position
  for h : i in [0:lines.size] do
    let line := lines[i]
    for h : j in [0:line.size] do
      let p := line[j].pos
      if dot3 (sub3 p cam.position) fwd > 0.0 then
        let sp ← getWorldToScreen p cam
        let d := dist2 sp mouse
        if d ≤ bestD then
          bestD := d
          best := some { lineIdx := i, ptIdx := j, pos := p }
  return best

/-- Sample one line's smooth alignment into a polyline for drawing (empty if the
    line has fewer than two PIs). -/
def sampleCurve (line : Line) : Array CurveSample := Id.run do
  let mut out := #[]
  if line.size ≥ 2 then
    let pts := line.map fun q => toGeo q.pos
    let path := buildPath pts designParams (line.map fun q => q.budget.map rf) (line.map (·.winding))
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
          | ⟨_, _, .straight ..⟩ | ⟨_, _, .arc ..⟩ => true
          | _                                      => false
        let midSample := num_of_samples / 2
        for j in [0:num_of_samples + 1] do
          let t := segment_len * Float.ofNat j / Float.ofNat num_of_samples
          let q := e.pointAt (rf t)
          let label := if labeled && j == midSample then some speed else none
          out := out.push { pos := ofGeo q, segmentColor := color, speed := speed, label := label }
  return out

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
    piIdx, isEntry, pos)`. Used to highlight markers on hover and to grab one for
    resizing. Endpoints behind the camera are skipped. -/
def nearestCurveEnd (lines : Array Line) (cam : Camera3D) (mouse : Vector2) (thresh : Float) :
    IO (Option (Nat × Nat × Bool × Vector3)) := do
  let mut best : Option (Nat × Nat × Bool × Vector3) := none
  let mut bestD := thresh * thresh
  let fwd := sub3 cam.target cam.position
  for ce in curveEnds lines do
    if dot3 (sub3 ce.entry cam.position) fwd > 0.0 then
      let sp ← getWorldToScreen ce.entry cam
      let dE := dist2 sp mouse
      if dE ≤ bestD then bestD := dE; best := some (ce.lineIdx, ce.piIdx, true, ce.entry)
    if dot3 (sub3 ce.exit cam.position) fwd > 0.0 then
      let sp ← getWorldToScreen ce.exit cam
      let dX := dist2 sp mouse
      if dX ≤ bestD then bestD := dX; best := some (ce.lineIdx, ce.piIdx, false, ce.exit)
  return best

/-- What the cursor is close enough to interact with. -/
inductive HitTarget where
  | point (ref : PointRef)
  | curveEnd (lineIdx piIdx : Nat) (isEntry : Bool)

/-- Snap to the nearest interactive target, preferring the closer of a PI and a
    curve-end marker (in screen pixels) when both are under the cursor. -/
def hitTargetAt (lines : Array Line) (cam : Camera3D) (mouse : Vector2) (thresh : Float) :
    IO (Option HitTarget) := do
  let pPI ← nearestPoint lines cam mouse thresh
  let pCE ← nearestCurveEnd lines cam mouse thresh
  let useCE ← match pPI, pCE with
    | some pr, some (_, _, _, cePos) => do
        let spP ← getWorldToScreen pr.pos cam
        let spC ← getWorldToScreen cePos cam
        pure (decide (dist2 spC mouse < dist2 spP mouse))
    | none, some _ => pure true
    | _, _ => pure false
  match (if useCE then none else pPI), (if useCE then pCE else none) with
  | some pr, _ => return some (.point pr)
  | _, some (l, p, isEntry, _) => return some (.curveEnd l p isEntry)
  | none, none => return none

/-- Bright lime for the curve-end markers. -/
def BRACKET_COLOR : Color := GREEN

/-- Draw both grab markers of a corner (entry and exit) as small spheres, sized relative
    to the camera distance so they stay roughly constant on screen. -/
def drawCurveBrackets (ce : CurveEnd) (dist : Float) : IO Unit := do
  let r := dist * 0.004
  drawSphere ce.entry r BRACKET_COLOR
  drawSphere ce.exit  r BRACKET_COLOR

/-- Adaptive reference grid on the ground plane (`z = 0`), drawn with 3D lines (raylib's
    `drawGrid` lies in the XZ plane). It follows the camera target in XY and sizes its
    cells to the camera distance — rounded to a "nice" 1/2/5×10ⁿ world spacing — so a
    constant number of lines always fills the view at any zoom. Lines snap to multiples of
    the spacing so they don't swim while panning. -/
def drawGroundGrid (center : Vector3) (dist : Float) (col : Color) : IO Unit := do
  -- nice cell size: aim for ~`dist/6` world units per cell, rounded to 1/2/5×10ⁿ
  let raw := dist / 6.0
  let p10 := Float.exp (Float.floor (Float.log raw / Float.log 10.0) * Float.log 10.0)
  let f := raw / p10
  let step := (if f < 1.5 then 1.0 else if f < 3.5 then 2.0 else if f < 7.5 then 5.0 else 10.0) * p10
  let n := 20                                  -- 2n+1 lines each way → fixed line budget
  let half := step * Float.ofNat n
  let cx := Float.floor (center.x / step) * step   -- snap origin to the grid
  let cy := Float.floor (center.y / step) * step
  for i in [0:2 * n + 1] do
    let off := Float.ofNat i * step - half
    drawLine3D ⟨cx + off, cy - half, 0.0⟩ ⟨cx + off, cy + half, 0.0⟩ col   -- ∥ Y
    drawLine3D ⟨cx - half, cy + off, 0.0⟩ ⟨cx + half, cy + off, 0.0⟩ col   -- ∥ X

/-- A horizontal ring (in the plane `z = center.z`) as a closed 3D polyline. Used to
    mark a PI whose corner winds the long way around. -/
def drawRing3D (center : Vector3) (radius : Float) (col : Color) : IO Unit := do
  let n := 24
  for i in [0:n] do
    let a0 := 2.0 * Raylib.PI * Float.ofNat i / Float.ofNat n
    let a1 := 2.0 * Raylib.PI * Float.ofNat (i + 1) / Float.ofNat n
    drawLine3D ⟨center.x + radius * Float.cos a0, center.y + radius * Float.sin a0, center.z⟩
               ⟨center.x + radius * Float.cos a1, center.y + radius * Float.sin a1, center.z⟩ col

/-! ## Translate gizmo (X/Y/Z axis handles)

A Blender-style three-axis handle that appears on the PI under the cursor. Its shafts are
sized by camera distance to a roughly constant screen length; grabbing one constrains the
drag to that world axis, which is the only way to change a PI's elevation (Z) — plain point
drags slide along the ground plane. -/

/-- World-space shaft length as a fraction of the camera distance (≈ constant on screen). -/
def GIZMO_LEN_FACTOR : Float := 0.07
/-- Screen-pixel tolerance for grabbing an axis shaft. -/
def AXIS_GRAB_PX : Float := 9.0
/-- Screen-pixel radius around a PI within which its gizmo is shown / armed. Larger than the
    shaft length so the whole gizmo stays interactive once the cursor is near the PI. -/
def GIZMO_PX : Float := 80.0

/-- The three world axes, indexed 0=X, 1=Y, 2=Z. -/
def axisDir : Nat → Vector3
  | 0 => ⟨1.0, 0.0, 0.0⟩
  | 1 => ⟨0.0, 1.0, 0.0⟩
  | _ => ⟨0.0, 0.0, 1.0⟩
/-- Per-axis colour (X red, Y green, Z blue). -/
def axisColor : Nat → Color
  | 0 => RED
  | 1 => GREEN
  | _ => SKYBLUE
/-- Highlight tint for the armed/hovered axis. -/
def AXIS_HL : Color := Color.mk 255 255 140 255

/-- Distance from point `p` to segment `[a,b]`, all in 2D screen space. -/
def distToSeg (p a b : Vector2) : Float :=
  let abx := b.x - a.x; let aby := b.y - a.y
  let len2 := abx * abx + aby * aby
  let t := if len2 < 1e-9 then 0.0
           else clampF 0.0 1.0 (((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)
  let dx := p.x - (a.x + t * abx); let dy := p.y - (a.y + t * aby)
  Float.sqrt (dx * dx + dy * dy)

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
  | some pr =>
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

/-- Draw the three-axis translate gizmo at `p`, sized to the camera distance. `active`
    (if any) is highlighted; the rest use their axis colours. Each axis is a thin cylinder
    shaft capped with a cone arrowhead. -/
def drawGizmo (p : Vector3) (dist : Float) (active : Option Nat) : IO Unit := do
  let len := dist * GIZMO_LEN_FACTOR
  let r := dist * 0.0012
  for a in [0:3] do
    let u := axisDir a
    let col := if active == some a then AXIS_HL else axisColor a
    let neck := add3 p (scale3 (len * 0.8) u)
    drawCylinderEx p neck r r 8 col
    drawCylinderEx neck (add3 p (scale3 len u)) (r * 2.8) 0.0 10 col

/-! ## Per-frame helpers -/

/-- True if either key is currently held (e.g. left or right Shift). -/
@[inline] def isKeyDownEither (a b : UInt32) : IO Bool :=
  (· || ·) <$> isKeyDown a <*> isKeyDown b

/-- Apply camera-only inputs: wheel dollies (zooms), middle-drag orbits, and
    Shift+middle-drag pans the target across the view plane. -/
def updateCameraFromInput (o : OrbitCam) (enabled : Bool) : IO OrbitCam := do
  let mut o := o
  let wheel ← getMouseWheelMove
  if enabled && wheel != 0.0 then
    o := { o with distance := clampF MIN_DIST MAX_DIST (o.distance * Float.exp (-0.2 * wheel)) }

  if enabled && (← isMouseButtonDown MOUSE_BUTTON_MIDDLE) then
    let d ← getMouseDelta
    let shift ← isKeyDownEither KEY_LEFT_SHIFT KEY_RIGHT_SHIFT
    if shift then
      -- pan: slide the target along the camera's screen-right and screen-up axes,
      -- scaled by distance so the grab tracks the cursor at any zoom.
      let fwd := scale3 (-1.0) o.dir
      let right := norm3 (cross3 fwd ⟨0.0, 0.0, 1.0⟩)
      let camUp := norm3 (cross3 right fwd)
      let k := o.distance * 0.001
      o := { o with target := add3 o.target (add3 (scale3 (-d.x * k) right) (scale3 (d.y * k) camUp)) }
    else
      -- orbit: yaw with horizontal motion, pitch with vertical, clamped off the poles
      -- so world-up never aligns with the view direction.
      o := { o with yaw := o.yaw - d.x * 0.005,
                    pitch := clampF (-1.4) 1.4 (o.pitch + d.y * 0.005) }

  return o

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

/-- Speed-view legend: a vertical red→yellow→green bar on the absolute speed ramp
    (`SPEED_RAMP_MIN`…`SPEED_RAMP_MAX`). -/
def drawSpeedLegend : IO Unit := do
  let green  := Color.mk 40 200 40 255
  let yellow := Color.mk 230 200 40 255
  let red    := Color.mk 220 40 40 255
  let lx := 12.0; let ly := 92.0; let lw := 14.0; let lh := 130.0; let half := lh / 2.0
  drawRectangleGradientV (f2u lx) (f2u ly)          (f2u lw) (f2u half) green yellow
  drawRectangleGradientV (f2u lx) (f2u (ly + half)) (f2u lw) (f2u half) yellow red
  let tx := f2u (lx + lw + 4.0)
  drawText "speed" (f2u lx) (f2u (ly - 12.0)) FONT SECONDARY
  drawText s!"{fmtFixed (SPEED_RAMP_MAX * MPS_TO_KMH) 0} km/h" tx (f2u ly) FONT FG
  drawText s!"{fmtFixed (SPEED_RAMP_MIN * MPS_TO_KMH) 0} km/h" tx (f2u (ly + lh - 7.0)) FONT FG

/-- Speed-view section labels: the operating-speed restriction (e.g. `"100 km/h"`) drawn
    at each straight's and arc's midpoint sample. A 2D overlay, so it runs after the 3D
    pass; midpoints behind the camera are skipped, and text is centred over its point. -/
def drawSpeedLabels (cam : Camera3D) (curves : Array (Array CurveSample)) : IO Unit := do
  let fwd := sub3 cam.target cam.position
  for curve in curves do
    for cs in curve do
      if let some spd := cs.label then
        if dot3 (sub3 cs.pos cam.position) fwd > 0.0 then
          let sp ← getWorldToScreen cs.pos cam
          let txt := s!"{fmtFixed (spd * MPS_TO_KMH) 0} km/h"
          let w := (← measureText txt FONT).toNat.toFloat
          let x := sp.x - w / 2.0
          let y := sp.y - 4.0
          -- a 1px dark shadow keeps the number legible over any track colour
          drawText txt (f2u (x + 1.0)) (f2u (y + 1.0)) FONT BG
          drawText txt (f2u x) (f2u y) FONT FG

/-- Everything one frame needs to draw: the orbit camera and its distance (for screen-
    constant sizing), the lines and their cached curves, the active render `view` and FSM
    `mode`, the cursor, the two HUD toggles, and the history for the undo-tree overlay. -/
structure Scene where
  cam              : Camera3D
  dist             : Float
  lines            : Array Line
  curves           : Array (Array CurveSample)
  view             : Nat
  mode             : Mode
  mouse            : Vector2
  showInstructions : Bool
  showFPS          : Bool
  hist             : History.History (Array Line)

/-- Draw world-space route geometry and active edit feedback inside a 3D pass. `s.dist` is
    the camera distance, used to keep point/marker sizes roughly constant on screen. -/
def drawWorldScene (s : Scene) : IO Unit := do
  beginMode3D s.cam
  drawGroundGrid s.cam.target s.dist (Color.mk 45 45 45 255)
  let ptR := s.dist * 0.005
  -- tangent polylines (the raw PIs)
  for line in s.lines do
    if line.size ≥ 2 then
      for i in [1:line.size] do
        drawLine3D line[i-1]!.pos line[i]!.pos SECONDARY

  for curve in s.curves do
    for i in [1:curve.size] do
      let cs := curve[i]!
      let prev := curve[i-1]!
      let col := if s.view == 1 then cs.segmentColor else speedColor SPEED_RAMP_MIN SPEED_RAMP_MAX cs.speed
      drawLine3D prev.pos cs.pos col

  for line in s.lines do
    for q in line do
      if q.winding != 0 then
        let col := if q.winding > 0 then ARC_COLOR else TRANSITION_COLOR
        drawRing3D q.pos (ptR * 2.5) col
      drawSphere q.pos ptR POINT_COLOR

  -- feedback: snap highlight (PI sphere or curve-end markers) when idle, rubber-band to
  -- the ground point when building, markers on the active corner while resizing.
  match s.mode with
  | .idle =>
      let hit ← hitTargetAt s.lines s.cam s.mouse SNAP_PX
      -- gizmo on the PI under the cursor (broad radius). Don't arm an axis while the cursor
      -- is snapped to a hub (a PI ball or curve-end) — that grab takes precedence.
      match ← armedAxis s.lines s.cam s.mouse s.dist with
      | some (pr, ax) => drawGizmo pr.pos s.dist (if hit.isSome then none else ax)
      | none          => pure ()
      match hit with
      | some (.curveEnd l p _) =>
          match curveEndAt s.lines l p with
          | some ce => drawCurveBrackets ce s.dist
          | none    => pure ()
      | some (.point pr) => drawSphere pr.pos (ptR * 1.6) REDO_COLOR
      | none => pure ()
  | .building idx atEnd _ _ =>
      let line := s.lines[idx]!
      if line.size ≥ 1 then
        match ← screenToGround s.mouse s.cam with
        | some g => drawLine3D (if atEnd then line[line.size - 1]!.pos else line[0]!.pos) g SECONDARY
        | none   => pure ()
  | .pressed lineIdx ptIdx _ | .dragging lineIdx ptIdx _ =>
      if let some q := getPI? s.lines lineIdx ptIdx then
        drawSphere q.pos (ptR * 1.6) REDO_COLOR
  | .bracketPressed lineIdx piIdx _ _ | .resizing lineIdx piIdx _ =>
      match curveEndAt s.lines lineIdx piIdx with
      | some ce => drawCurveBrackets ce s.dist
      | none    => pure ()
  | .axisPressed lineIdx ptIdx axis _ | .axisDragging lineIdx ptIdx axis _ =>
      if let some q := getPI? s.lines lineIdx ptIdx then
        drawGizmo q.pos s.dist (some axis)
        drawSphere q.pos (ptR * 1.6) REDO_COLOR
  endMode3D

/-! ## Per-frame input handling -/

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
  view        : Nat
  dirty       : Bool := false
  dragIdx     : Option Nat := none
  finalizeIdx : Option Nat := none

/-- Left-button press: extend the active line, grab a snapped PI (defer click-vs-drag),
    grab a curve-end bracket or a gizmo axis, or start a fresh line on empty ground. -/
def handleLeftPress (fr : InputCtx) (lines : Array Line) (e : Edit) : IO Edit := do
  unless (← isMouseButtonPressed MOUSE_BUTTON_LEFT) do return e
  let mut e := e
  let totalPts := lines.foldl (fun a l => a + l.size) 0
  let ground? ← screenToGround fr.mouse fr.cam     -- where the cursor meets z = 0
  match e.mode with
  | .building idx atEnd _ recorded =>
      match ground? with
      | some m =>
        if totalPts < MAX_PI then
          let liveLines := History.current e.hist
          e := { e with hist := commitLines e.hist (addPIAtEnd! liveLines idx atEnd m) recorded,
                        mode := .building idx atEnd false true, dirty := true }
      | none => pure ()
  | .idle =>
      -- snap onto whichever is closer: an existing PI (grab to drag) or a curve-end marker
      -- (grab to resize). The press position is stored in *screen* space for click-vs-drag.
      match ← hitTargetAt lines fr.cam fr.mouse SNAP_PX with
      | some (.point pr)             => e := { e with mode := .pressed pr.lineIdx pr.ptIdx fr.mouse }
      | some (.curveEnd l p isEntry) => e := { e with mode := .bracketPressed l p isEntry fr.mouse }
      | none =>
          -- not on a PI hub or curve-end: try grabbing one of the hovered PI's gizmo axis
          -- shafts (the only way to change elevation); otherwise start a new line.
          match ← armedAxis lines fr.cam fr.mouse fr.dist with
          | some (pr, some a) => e := { e with mode := .axisPressed pr.lineIdx pr.ptIdx a fr.mouse }
          | _ =>
            match ground? with
            | some m =>
              if totalPts < MAX_PI then
                e := { e with hist := History.record e.hist (lines.push #[{ pos := m }]),
                              mode := .building lines.size true true true }  -- new line is now last
                e := { e with dirty := true }
            | none => pure ()
  | _ => pure ()  -- pressed/dragging/resizing: edge already consumed below
  return e

/-- Shared press→click/drag skeleton for `.pressed`/`.bracketPressed`/`.axisPressed`: a
    release without movement yields `released`; moving past `DRAG_PX` runs `beginDrag` (which
    snapshots history and enters the drag mode); holding still leaves `e` unchanged. -/
@[inline] def onPressResolve (fr : InputCtx) (e : Edit) (press : Vector2)
    (released : Edit) (beginDrag : IO Edit) : IO Edit := do
  if !(← isMouseButtonDown MOUSE_BUTTON_LEFT) then return released
  else if dist2 fr.mouse press > DRAG_PX * DRAG_PX then beginDrag
  else return e

/-- Shared drag→release skeleton for `.dragging`/`.resizing`/`.axisDragging`: releasing the
    button drops to `idle` and flags one exact resample of `lineIdx`; otherwise runs `held`
    (the live per-frame update, which leaves the drag mode in place). -/
@[inline] def onDragResolve (e : Edit) (lineIdx : Nat) (held : IO Edit) : IO Edit := do
  if !(← isMouseButtonDown MOUSE_BUTTON_LEFT) then
    return { e with mode := .idle, finalizeIdx := some lineIdx }       -- one exact resample
  else held

/-- Resolve an in-progress grab: turn a press into a click (resume a line from an endpoint)
    or a drag once it moves past `DRAG_PX`, and apply live drags (point move, corner resize,
    axis-constrained move). Each drag updates the current history node in place so the whole
    gesture is a single undo step; releasing flags one exact resample. -/
def handleActiveMode (fr : InputCtx) (lines : Array Line) (e : Edit) : IO Edit :=
  match e.mode with
  | .pressed lineIdx ptIdx press =>
      let line := lines[lineIdx]!
      let released := { e with mode := if ptIdx = 0 || ptIdx = line.size - 1
                                       then .building lineIdx (ptIdx = line.size - 1) false false  -- resume
                                       else .idle }
      onPressResolve fr e press released do
        let pos0 := (lines[lineIdx]!)[ptIdx]!.pos
        match ← screenToGround fr.mouse fr.cam pos0.z with
        | some mw =>
            -- capture the grab offset and begin dragging *without* moving the point yet, so it
            -- tracks cursor motion from here rather than snapping under the cursor.
            return { e with hist := History.record e.hist lines,         -- snapshot original once
                            mode := .dragging lineIdx ptIdx (sub3 pos0 mw) }
        | none => return e
  | .dragging lineIdx ptIdx grab =>
      onDragResolve e lineIdx do
        match ← screenToGround fr.mouse fr.cam (lines[lineIdx]!)[ptIdx]!.pos.z with
        | some mw => return { e with hist := History.setCurrent e.hist (setPIPos! lines lineIdx ptIdx (add3 mw grab)),
                                     dragIdx := some lineIdx }
        | none    => return e
  | .bracketPressed lineIdx piIdx isEntry press =>
      onPressResolve fr e press { e with mode := .idle } do
        return { e with hist := History.record e.hist lines, mode := .resizing lineIdx piIdx isEntry }
  | .resizing lineIdx piIdx isEntry =>
      onDragResolve e lineIdx do
        match ← screenToGround fr.mouse fr.cam with
        | none => return e
        | some mw =>
          if h : lineIdx < lines.size then
            let line := lines[lineIdx]
            if 1 ≤ piIdx ∧ piIdx + 1 < line.size then
              let a := line[piIdx-1]!.pos
              let b := line[piIdx]!.pos
              let c := line[piIdx+1]!.pos
              match cornerGeometry (toGeo a) (toGeo b) (toGeo c) designParams line[piIdx]!.winding with
              | none => return e
              | some geom =>
                -- new budget = distance from the PI to the cursor projected onto the grabbed
                -- leg, clamped to [min-radius floor, ½·shorter leg] so it can't cross the PI nor
                -- make the arc tighter than `minRadius`. The budget is the unsigned distance
                -- along the leg line, so we take the magnitude of the projection: a reverse-
                -- winding loop's handles sit on the *extension* rays, flipping the raw sign.
                let uIn := ofGeo geom.uIn
                let uOut := ofGeo geom.uOut
                let hi := geom.maxBudget.val
                let lo := max 0.001 geom.minBudget.val
                let dRaw := if isEntry then dot3 (sub3 mw b) uIn else dot3 (sub3 mw b) uOut
                let d := if dRaw < 0.0 then -dRaw else dRaw
                let d' := max lo (min hi d)
                return { e with hist := History.setCurrent e.hist (setPIBudget! lines lineIdx piIdx d'),
                                dragIdx := some lineIdx }
            else return e
          else return e
  | .axisPressed lineIdx ptIdx axis press =>
      onPressResolve fr e press { e with mode := .idle } do
        -- capture the grab offset along the axis so the point tracks cursor motion from here,
        -- rather than jumping to the cursor's projection onto the axis line.
        let pos0 := (lines[lineIdx]!)[ptIdx]!.pos
        let grab := match ← axisDragPos pos0 axis fr.cam fr.mouse with
                    | some q0 => sub3 pos0 q0
                    | none    => (⟨0.0, 0.0, 0.0⟩ : Vector3)
        return { e with hist := History.record e.hist lines,
                        mode := .axisDragging lineIdx ptIdx axis grab }
  | .axisDragging lineIdx ptIdx axis grab =>
      onDragResolve e lineIdx do
        match ← axisDragPos (lines[lineIdx]!)[ptIdx]!.pos axis fr.cam fr.mouse with
        | some q => return { e with hist := History.setCurrent e.hist (setPIPos! lines lineIdx ptIdx (add3 q grab)),
                                    dragIdx := some lineIdx }
        | none   => return e
  | _ => return e

/-- Keyboard & right-click edits: finish/cancel the active line (a one-point draft is
    discarded), undo/redo, switch redo branch, cycle a corner's winding, switch render view. -/
def handleKeys (fr : InputCtx) (lines : Array Line) (e : Edit) : IO Edit := do
  let mut e := e
  -- Escape / right-click finishes the current line; a brand-new one-point draft is discarded
  -- so cancel behaves as if the alignment was never started.
  if (← isMouseButtonPressed MOUSE_BUTTON_RIGHT) || fr.escape then
    match e.mode with
    | .building idx _ true _ =>
        let liveLines := History.current e.hist
        if h : idx < liveLines.size then
          if liveLines[idx].size = 1 then
            e := { e with hist := History.discardCurrentLeaf e.hist, dirty := true }
    | _ => pure ()
    e := { e with mode := .idle }

  -- Ctrl+Z undo / Ctrl+Shift+Z redo
  let ctrl  ← isKeyDownEither KEY_LEFT_CONTROL KEY_RIGHT_CONTROL
  let shift ← isKeyDownEither KEY_LEFT_SHIFT KEY_RIGHT_SHIFT
  if ctrl && (← isKeyPressed KEY_Z) then
    e := { e with hist := if shift then History.redo e.hist else History.undo e.hist,
                  mode := .idle, dirty := true }

  -- [ / ] cycle which branch redo will follow at a fork (no state change)
  if (← isKeyPressed KEY_LEFT_BRACKET)  then e := { e with hist := History.cycleBranch e.hist (-1) }
  if (← isKeyPressed KEY_RIGHT_BRACKET) then e := { e with hist := History.cycleBranch e.hist 1 }

  -- L cycles an interior corner through short, left-loop, and right-loop winding.
  if (← isKeyPressed KEY_L) then
    match e.mode with
    | .idle =>
        match ← hitTargetAt lines fr.cam fr.mouse SNAP_PX with
        | some (.curveEnd l p _) =>
            e := { e with hist := History.record e.hist (cyclePIWinding! lines l p), dirty := true }
        | some (.point pr) =>
            if h : pr.lineIdx < lines.size then
              let line := lines[pr.lineIdx]
              if 1 ≤ pr.ptIdx ∧ pr.ptIdx + 1 < line.size then
                e := { e with hist := History.record e.hist (cyclePIWinding! lines pr.lineIdx pr.ptIdx),
                              dirty := true }
        | none => pure ()
    | _ => pure ()

  -- 1 / 2 switch render view (segment type / speed). Recolour only — no resample.
  if (← isKeyPressed KEY_ONE) then e := { e with view := 1 }
  if (← isKeyPressed KEY_TWO) then e := { e with view := 2 }
  return e

/-- The full-screen draw for one frame: the 3D scene, HUD overlays, and either the
    instructions modal or the cursor crosshair (hidden behind a position readout while a
    marker is being dragged). -/
def render (s : Scene) : IO Unit := do
  beginDrawing
  clearBackground BG
  drawWorldScene s
  if s.showFPS then drawFPS 0 0
  if s.view == 2 then
    drawSpeedLegend
    drawSpeedLabels s.cam s.curves
  drawHistory s.hist
  -- hide the crosshair while dragging a marker so it doesn't fight the green handles
  if s.showInstructions then
    drawInstructions s.showFPS s.view
  else
    match s.mode with
    | .resizing .. => pure ()
    | .dragging lineIdx ptIdx _ | .axisDragging lineIdx ptIdx _ _ =>
        if let some q := getPI? s.lines lineIdx ptIdx then
          drawText s!"({fmtFixed q.pos.x 1}, {fmtFixed q.pos.y 1}, {fmtFixed q.pos.z 1})"
            (f2u (s.mouse.x + 8.0)) (f2u (s.mouse.y - 14.0)) FONT FG
        drawMouse s.cam s.mouse (showCoords := false)
    | _            => drawMouse s.cam s.mouse
  endDrawing

/-! ## Per-frame step -/

def step (st : UI) : IO UI := do
  -- F1/F3/Esc toggles stay live even while the instructions overlay is up.
  let mut showInstructions := st.showInstructions
  let mut showFPS := st.showFPS
  let escapePressed ← isKeyPressed KEY_ESCAPE
  if (← isKeyPressed KEY_F1) then showInstructions := !showInstructions
  if (← isKeyPressed KEY_F3) then showFPS := !showFPS
  if showInstructions && escapePressed then showInstructions := false

  let orbit ← updateCameraFromInput st.camera (!showInstructions)
  let cam := orbit.toCamera3D                 /- the raylib Camera3D for this frame
  -- raylib keeps the cursor, `getScreenToWorldRay`, `getWorldToScreen`, and 2D drawing all
  -- in *logical* screen space (HighDPI upscaling is handled by raylib's `screenScale`), so
  -- the cursor feeds the ray directly and snap thresholds are plain logical pixels.
  -/
  let mouse ← getMousePosition
  let lines := History.current st.hist        -- frame-start snapshot, shared by all handlers
  let fr : InputCtx := { cam, mouse, dist := orbit.distance, escape := escapePressed }

  -- All map-editing input is dead while the instructions overlay is up. The handlers thread
  -- one `Edit` accumulator: each may update the history, the FSM mode, and the resample hints.
  let mut e : Edit := { hist := st.hist, mode := st.mode, view := st.view }
  unless showInstructions do
    e ← handleLeftPress fr lines e
    e ← handleActiveMode fr lines e
    e ← handleKeys fr lines e

  -- the current lines after any edits above; drop a stale active-line index
  let lines := History.current e.hist
  let mode := e.mode.revalidate lines

  let (curves, pending) ←
    updateCurveCache lines st.curves st.pending e.dirty e.dragIdx e.finalizeIdx

  render {
    cam, dist := orbit.distance, lines, curves, view := e.view, mode, mouse,
    showInstructions, showFPS, hist := e.hist }

  return {
    camera := orbit, hist := e.hist, curves := curves, view := e.view, mode := mode,
    showInstructions := showInstructions, showFPS := showFPS, pending := pending }

partial def loop (st : UI) : IO Unit := do
  if (← windowShouldClose) then
    closeWindow
  else
    loop (← step st)

def main : IO Unit := do
  setConfigFlags (FLAG_VSYNC_HINT ||| FLAG_WINDOW_HIGHDPI ||| FLAG_MSAA_4X_HINT)
  initWindow 1280 720 "Track Geometry"
  setExitKey 0  -- KEY_NULL: don't let Escape close the window
  hideCursor
  setTraceLogLevel LOG_DEBUG
  let cam : OrbitCam := { target := ⟨0.0, 0.0, 0.0⟩, distance := 4000.0, yaw := -1.0, pitch := 0.9 }
  loop {
    camera := cam, hist := History.init #[], curves := #[], view := 1, mode := .idle,
    showInstructions := false, showFPS := false, pending := none }
