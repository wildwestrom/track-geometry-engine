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
def MIN_ZOOM : Float := 0.015625
def MAX_ZOOM : Float := 64.0
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
/-- Design-speed ceiling, as a raw `Float` (the green end of the speed ramp). -/
def designSpeedF : Float := designParams.maxDesignSpeed.val
def aMaxF : Float := designParams.maxLateralAccel.val

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

/-! ## UI state -/

/-- One point of intersection: its world position, an optional per-corner tangent
    budget override (absolute world units), and a signed turn winding. The budget
    resizes the curve rounding *this* corner.
    `none` means the automatic `legBudget`-derived size. The override travels with its
    corner across inserts, prepends, and undo (it's attached to the point, not an index). -/
structure PI where
  pos     : Vector2
  budget  : Option Float := none
  winding : Int := 0
  deriving Inhabited

/-- One alignment under construction: an ordered polyline of points of
    intersection (world coordinates). Each line is rounded into its own smooth
    alignment independently of the others. -/
abbrev Line := Array PI

/-- One sampled point on a rendered alignment. `segmentColor` is the segment-type
    colour used by view 1; `speed` feeds the speed ramp in view 2. -/
structure CurveSample where
  pos          : Vector2
  segmentColor : Color
  speed        : Float
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
      `lineIdx` (snapped) at world position `press`; we don't yet know if this is a
      click or a drag. Releasing without moving is a click; moving past a threshold
      starts a drag.
    * `dragging lineIdx ptIdx` — point `ptIdx` of line `lineIdx` follows the cursor
      until the button is released.
    * `bracketPressed lineIdx piIdx isEntry press` — the mouse went down on a green
      curve-end bracket (the entry bracket when `isEntry`, else the exit) of the curve
      at interior PI `piIdx`; like `pressed`, a release without movement is a no-op and
      moving past the threshold begins a resize.
    * `resizing lineIdx piIdx isEntry` — dragging that bracket along its leg, growing or
      shrinking the curve by overriding PI `piIdx`'s tangent budget. -/
inductive Mode
  | idle
  | building (lineIdx : Nat) (atEnd provisional recorded : Bool)
  | pressed (lineIdx ptIdx : Nat) (press : Vector2)
  | dragging (lineIdx ptIdx : Nat)
  | bracketPressed (lineIdx piIdx : Nat) (isEntry : Bool) (press : Vector2)
  | resizing (lineIdx piIdx : Nat) (isEntry : Bool)

/-- Drop back to `idle` if a referenced line/point no longer exists (e.g. after an
    undo removed the line). Indices are otherwise stable across history moves. -/
def Mode.revalidate : Mode → Array Line → Mode
  | .building idx e p r, lines => if idx < lines.size then .building idx e p r else .idle
  | .pressed l p press, lines =>
      if h : l < lines.size then (if p < lines[l].size then .pressed l p press else .idle) else .idle
  | .dragging l p, lines =>
      if h : l < lines.size then (if p < lines[l].size then .dragging l p else .idle) else .idle
  | .bracketPressed l p e press, lines =>
      if h : l < lines.size then (if p < lines[l].size then .bracketPressed l p e press else .idle) else .idle
  | .resizing l p e, lines =>
      if h : l < lines.size then (if p < lines[l].size then .resizing l p e else .idle) else .idle
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
  camera : Camera2D
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
    (pos : Vector2) : Array Line :=
  updateLine! lines lineIdx fun line =>
    if atEnd then line.push { pos := pos } else #[({ pos := pos } : PI)] ++ line

/-- Move one PI inside an existing line. The caller must have validated both indices. -/
@[inline] def setPIPos! (lines : Array Line) (lineIdx ptIdx : Nat) (pos : Vector2) :
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

/-- Crosshair at the cursor plus a world-coordinate readout. -/
def drawMouse (camera : Camera2D) : IO Unit := do
  let mp ← getMousePosition
  let wp ← getScreenToWorld2D mp camera
  let dpi ← getWindowScaleDPI
  let sp : Vector2 := ⟨mp.x / dpi.x, mp.y / dpi.y⟩
  let size := 6.0
  drawLine (f2u (sp.x - size)) (f2u sp.y) (f2u (sp.x + size - 1.0)) (f2u sp.y) FG
  drawLine (f2u sp.x) (f2u (sp.y - size)) (f2u sp.x) (f2u (sp.y + size - 1.0)) FG
  drawText s!"({fmtFixed wp.x 1},{fmtFixed wp.y 1})" (f2u (sp.x + 1.0)) (f2u (sp.y + 1.0)) FONT FG

/-- Screen-space scale bar (bottom-right): a "nice" 1/2/5×10ⁿ world distance. -/
def drawScaleBar (camera : Camera2D) (dpi : Vector2) : IO Unit := do
  let targetPx := 96.0
  let pxPerWorld := camera.zoom / dpi.x
  let rawWorld := targetPx / pxPerWorld
  let e := Float.floor (Float.log rawWorld / Float.log 10.0)
  let p10 := Float.exp (e * Float.log 10.0)
  let f := rawWorld / p10
  let nf := if f < 1.5 then 1.0 else if f < 3.5 then 2.0 else if f < 7.5 then 5.0 else 10.0
  let niceWorld := nf * p10
  let barPx := niceWorld * pxPerWorld
  let label := s!"{fmtG niceWorld} u"
  let tw := Float.ofNat (← measureText label FONT).toNat
  let sw := Float.ofNat (← getScreenWidth).toNat
  let sh := Float.ofNat (← getScreenHeight).toNat
  let x1 := sw - 8.0
  let x0 := x1 - barPx
  let y := sh - 12.0
  let tick := 4.0
  drawText label (f2u (x0 - tw - 6.0)) (f2u (y - Float.ofNat FONT.toNat / 2.0)) FONT FG
  drawLine (f2u x0) (f2u y) (f2u x1) (f2u y) FG
  drawLine (f2u x0) (f2u (y - tick)) (f2u x0) (f2u y) FG
  drawLine (f2u x1) (f2u (y - tick)) (f2u x1) (f2u y) FG

/-- Modal help screen for all interactive controls. -/
def drawInstructions (showFPS : Bool) (view : Nat) : IO Unit := do
  let sw := Float.ofNat (← getScreenWidth).toNat
  let sh := Float.ofNat (← getScreenHeight).toNat
  let panelW := min (sw - 48.0) 560.0
  let panelH := min (sh - 48.0) 310.0
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
    ("Drag point", "move a PI"),
    ("Drag curve end", "resize that corner"),
    ("L", "cycle selected corner winding"),
    ("Right click / Esc", "finish or cancel the active line"),
    ("Mouse wheel", "zoom toward the cursor"),
    ("Middle drag", "pan"),
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

/-- Squared world distance between two points (avoids a `sqrt`). -/
@[inline] def dist2 (a b : Vector2) : Float :=
  let dx := a.x - b.x; let dy := a.y - b.y; dx * dx + dy * dy

/-! ### Small 2D vector helpers (world space). -/
@[inline] def sub2 (a b : Vector2) : Vector2 := ⟨a.x - b.x, a.y - b.y⟩
@[inline] def add2 (a b : Vector2) : Vector2 := ⟨a.x + b.x, a.y + b.y⟩
@[inline] def scale2 (s : Float) (v : Vector2) : Vector2 := ⟨s * v.x, s * v.y⟩
@[inline] def dot2 (a b : Vector2) : Float := a.x * b.x + a.y * b.y
/-- Rotate 90° counterclockwise. -/
@[inline] def perp2 (v : Vector2) : Vector2 := ⟨-v.y, v.x⟩
@[inline] def v2ToV3 (p : Vector2) : Vec3 RFloat := Vec3.mk (rf p.x) (rf p.y) (rf 0.0)
@[inline] def v3ToV2 (p : Vec3 RFloat) : Vector2 := ⟨(p 0).val, (p 1).val⟩

/-- A reference to a single PI the cursor can grab to drag: which line, which index
    within that line, and its world position. -/
structure PointRef where
  lineIdx : Nat
  ptIdx   : Nat
  pos     : Vector2

/-- The PI nearest `target` within `thresh` world units, across every point of every
    line, if any. Used to grab a point for dragging. -/
def nearestPoint (lines : Array Line) (target : Vector2) (thresh : Float) : Option PointRef := Id.run do
  let mut best : Option PointRef := none
  let mut bestD := thresh * thresh
  for h : i in [0:lines.size] do
    let line := lines[i]
    for h : j in [0:line.size] do
      let p := line[j].pos
      let d := dist2 p target
      if d ≤ bestD then
        bestD := d
        best := some { lineIdx := i, ptIdx := j, pos := p }
  return best

/-- Sample one line's smooth alignment into a polyline for drawing (empty if the
    line has fewer than two PIs). -/
def sampleCurve (line : Line) : Array CurveSample := Id.run do
  let mut out := #[]
  if line.size ≥ 2 then
    let pts := line.map fun q => Vec3.mk (rf q.pos.x) (rf q.pos.y) (rf 0.0)
    let path := buildPath pts designParams (line.map fun q => q.budget.map rf) (line.map (·.winding))
    let total := path.length |>.val
    if total > 0.0 then
      -- Sample each piece on its own so points carry their segment's colour and
      -- operating speed; a piece gets samples proportional to its share of the total.
      for e in path.segments do
        let col := segColor e
        let spd := segSpeed e
        let segLen := e.length.val
        let nsamp := max 2 (Float.ceil (Float.ofNat CURVE_SAMPLES * segLen / total)).toUInt64.toNat
        for j in [0:nsamp + 1] do
          let t := segLen * Float.ofNat j / Float.ofNat nsamp
          let q := e.pointAt (rf t)
          out := out.push { pos := ⟨(q 0).val, (q 1).val⟩, segmentColor := col, speed := spd }
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
  entry   : Vector2
  exit    : Vector2
  uIn     : Vector2
  uOut    : Vector2

/-- Curve-end data for interior PI `i` of `line` (index `li`), or `none` when that
    corner is degenerate or near-straight — the same condition under which `solveCorner`
    returns `none`, so a bracket shows iff the curve rounds there. The anchors sit
    `budget` back from the PI along each leg (clamped like `buildPath`). -/
def cornerEnd (li : Nat) (line : Line) (i : Nat) : Option CurveEnd := Id.run do
  if ¬ (1 ≤ i ∧ i + 1 < line.size) then return none
  let a := line[i-1]!.pos
  let b := line[i]!.pos
  let c := line[i+1]!.pos
  match cornerLayout (v2ToV3 a) (v2ToV3 b) (v2ToV3 c) designParams
      (line[i]!.budget.map rf) line[i]!.winding with
  | none => return none
  | some layout =>
      return some {
        lineIdx := li, piIdx := i,
        entry := v3ToV2 layout.entryPoint,
        exit  := v3ToV2 layout.exitPoint,
        uIn := v3ToV2 layout.uIn, uOut := v3ToV2 layout.uOut }

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

/-- The curve endpoint nearest `target` within `thresh` world units: `(lineIdx, piIdx,
    isEntry, pos)`. Used to highlight brackets on hover and to grab one for resizing. -/
def nearestCurveEnd (lines : Array Line) (target : Vector2) (thresh : Float) :
    Option (Nat × Nat × Bool × Vector2) := Id.run do
  let mut best : Option (Nat × Nat × Bool × Vector2) := none
  let mut bestD := thresh * thresh
  for ce in curveEnds lines do
    let dE := dist2 ce.entry target
    if dE ≤ bestD then bestD := dE; best := some (ce.lineIdx, ce.piIdx, true, ce.entry)
    let dX := dist2 ce.exit target
    if dX ≤ bestD then bestD := dX; best := some (ce.lineIdx, ce.piIdx, false, ce.exit)
  return best

/-- What the cursor is close enough to interact with. -/
inductive HitTarget where
  | point (ref : PointRef)
  | curveEnd (lineIdx piIdx : Nat) (isEntry : Bool)

/-- Snap to the nearest interactive target, preferring the closer of a PI and a
    curve-end bracket when both are under the cursor. -/
def hitTargetAt (lines : Array Line) (target : Vector2) (thresh : Float) : Option HitTarget :=
  let pPI := nearestPoint lines target thresh
  let pCE := nearestCurveEnd lines target thresh
  let useCE := match pPI, pCE with
    | some pr, some (_, _, _, cePos) => decide (dist2 cePos target < dist2 pr.pos target)
    | none, some _ => true
    | _, _ => false
  match (if useCE then none else pPI), (if useCE then pCE else none) with
  | some pr, _ => some (.point pr)
  | _, some (l, p, isEntry, _) => some (.curveEnd l p isEntry)
  | none, none => none

/-- Bright lime for the curve-end brackets. -/
def BRACKET_COLOR : Color := GREEN

/-- Draw a green "[" bracket hugging a curve end. `anchor` is the curve endpoint and
    `tangent` is the unit direction *into* the curve, so the ticks point at the arc.
    Sized in screen pixels via `/ zoom`; one thick linear-spline polyline. -/
def drawBracket (anchor tangent : Vector2) (zoom : Float) : IO Unit := do
  let n := perp2 tangent
  let h := 12.0 / zoom
  let k := 8.0 / zoom
  let p1 := add2 anchor (scale2 h n)
  let p2 := sub2 anchor (scale2 h n)
  drawSplineLinear #[add2 p1 (scale2 k tangent), p1, p2, add2 p2 (scale2 k tangent)]
    (3.0 / zoom) BRACKET_COLOR

/-- Draw both brackets of a corner (entry faces along `uIn`, exit back along `-uOut`). -/
def drawCurveBrackets (ce : CurveEnd) (zoom : Float) : IO Unit := do
  drawBracket ce.entry ce.uIn zoom
  drawBracket ce.exit (scale2 (-1.0) ce.uOut) zoom

/-! ## Per-frame helpers -/

/-- Apply camera-only inputs: wheel zoom toward the cursor and middle-drag pan. -/
def updateCameraFromInput (cam : Camera2D) (enabled : Bool) : IO Camera2D := do
  let mut cam := cam
  let wheel ← getMouseWheelMove
  if enabled && wheel != 0.0 then
    let mp ← getMousePosition
    let mw ← getScreenToWorld2D mp cam
    let z := clampF MIN_ZOOM MAX_ZOOM (Float.exp (Float.log cam.zoom + 0.2 * wheel))
    cam := { cam with offset := mp, target := mw, zoom := z }

  if enabled && (← isMouseButtonDown MOUSE_BUTTON_MIDDLE) then
    let d ← getMouseDelta
    let g := -1.0 / cam.zoom
    cam := { cam with target := ⟨cam.target.x + d.x * g, cam.target.y + d.y * g⟩ }

  return cam

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

/-- Slowest sampled speed currently visible; used as the red end of speed view. -/
def minCurveSpeed (curves : Array (Array CurveSample)) : Float :=
  curves.foldl (fun m c => c.foldl (fun m s => min m s.speed) m) designSpeedF

/-- Speed-view legend: a vertical red→yellow→green bar (slowest…design speed). -/
def drawSpeedLegend (minSpeed : Float) : IO Unit := do
  let green  := Color.mk 40 200 40 255
  let yellow := Color.mk 230 200 40 255
  let red    := Color.mk 220 40 40 255
  let lx := 12.0; let ly := 92.0; let lw := 14.0; let lh := 130.0; let half := lh / 2.0
  drawRectangleGradientV (f2u lx) (f2u ly)          (f2u lw) (f2u half) green yellow
  drawRectangleGradientV (f2u lx) (f2u (ly + half)) (f2u lw) (f2u half) yellow red
  let tx := f2u (lx + lw + 4.0)
  drawText "speed" (f2u lx) (f2u (ly - 12.0)) FONT SECONDARY
  drawText s!"{fmtFixed (designSpeedF * MPS_TO_KMH) 0} km/h" tx (f2u ly) FONT FG
  drawText s!"{fmtFixed (minSpeed * MPS_TO_KMH) 0} km/h" tx (f2u (ly + lh - 7.0)) FONT FG

/-- Draw world-space route geometry and active edit feedback. Returns the current
    minimum speed so the screen-space legend can use the same range. -/
def drawWorldScene (cam : Camera2D) (lines : Array Line) (curves : Array (Array CurveSample))
    (view : Nat) (mode : Mode) : IO Float := do
  beginMode2D cam
  -- world-space line widths, kept constant in screen pixels via `/ zoom`
  let tangentW := 1.5 / cam.zoom
  let curveW   := 3.0 / cam.zoom
  for line in lines do
    if line.size ≥ 2 then
      drawSplineLinear (line.map (·.pos)) tangentW SECONDARY

  let minSpeed := minCurveSpeed curves
  for curve in curves do
    for i in [1:curve.size] do
      let s := curve[i]!
      let prev := curve[i-1]!
      let col := if view == 1 then s.segmentColor else speedColor minSpeed designSpeedF s.speed
      drawLineEx prev.pos s.pos curveW col

  for line in lines do
    for q in line do
      if q.winding != 0 then
        let col := if q.winding > 0 then ARC_COLOR else TRANSITION_COLOR
        drawCircleLinesV q.pos (9.0 / cam.zoom) col
      drawCircleV q.pos (4.0 / cam.zoom) POINT_COLOR

  -- feedback: snap highlight (PI dot or curve-end brackets) when idle, rubber-band to
  -- the cursor when building, brackets on the active corner while resizing.
  let mw ← getScreenToWorld2D (← getMousePosition) cam
  match mode with
  | .idle =>
      match hitTargetAt lines mw (SNAP_PX / cam.zoom) with
      | some (.curveEnd l p _) =>
          match curveEndAt lines l p with
          | some ce => drawCurveBrackets ce cam.zoom
          | none    => pure ()
      | some (.point pr) => drawCircleV pr.pos (7.0 / cam.zoom) REDO_COLOR
      | none => pure ()
  | .building idx atEnd _ _ =>
      let line := lines[idx]!
      if line.size ≥ 1 then
        drawLineEx (if atEnd then line[line.size - 1]!.pos else line[0]!.pos) mw (1.5 / cam.zoom) SECONDARY
  | .pressed lineIdx ptIdx _ | .dragging lineIdx ptIdx =>
      if lineIdx < lines.size then
        let line := lines[lineIdx]!
        if ptIdx < line.size then
          drawCircleV line[ptIdx]!.pos (7.0 / cam.zoom) REDO_COLOR
  | .bracketPressed lineIdx piIdx _ _ | .resizing lineIdx piIdx _ =>
      match curveEndAt lines lineIdx piIdx with
      | some ce => drawCurveBrackets ce cam.zoom
      | none    => pure ()
  endMode2D
  return minSpeed

/-! ## Per-frame step -/

def step (st : UI) : IO UI := do
  let dpi ← getWindowScaleDPI
  setMouseScale dpi.x dpi.y

  let mut cam := st.camera
  let mut hist := st.hist
  let lines := History.current hist
  let mut curves := st.curves
  let mut view := st.view
  let mut mode := st.mode
  let mut pending := st.pending
  let mut showInstructions := st.showInstructions
  let mut showFPS := st.showFPS
  let mut dirty := false
  -- a single line whose geometry changed this frame (a drag): its curve is resampled
  -- off-thread so the drag never blocks. `dirty` (structural change) rebuilds all
  -- lines synchronously. `finalizeIdx` forces one accurate sync resample on release.
  let mut dragIdx : Option Nat := none
  let mut finalizeIdx : Option Nat := none

  let f1Pressed ← isKeyPressed KEY_F1
  let f3Pressed ← isKeyPressed KEY_F3
  let escapePressed ← isKeyPressed KEY_ESCAPE
  if f1Pressed then showInstructions := !showInstructions
  if f3Pressed then showFPS := !showFPS
  if showInstructions && escapePressed then showInstructions := false

  cam ← updateCameraFromInput cam (!showInstructions)

  -- All map-editing input below is dead while the instructions overlay is up; only the
  -- F1/F3/Esc toggles handled above stay live. Guard the whole block once instead of
  -- repeating `!showInstructions` on every action. `let mut` reassignments inside an
  -- `unless` still thread back out, so `mode`/`hist`/`dirty`/… update as before.
  unless showInstructions do
    -- left-click press: when building, extend the active line; when idle, either grab
    -- the point we snapped onto (deferring click-vs-drag to release/move) or start a
    -- fresh separate line on empty space.
    let totalPts := lines.foldl (fun a l => a + l.size) 0
    if (← isMouseButtonPressed MOUSE_BUTTON_LEFT) then
      let m ← getScreenToWorld2D (← getMousePosition) cam
      match mode with
      | .building idx atEnd _ recorded =>
          if totalPts < MAX_PI then
            let liveLines := History.current hist
            hist := commitLines hist (addPIAtEnd! liveLines idx atEnd m) recorded
            mode := .building idx atEnd false true
            dirty := true
      | .idle =>
          -- snap onto whichever is closer: an existing PI (grab to drag) or a curve-end
          -- bracket (grab to resize). Empty space starts a fresh line.
          match hitTargetAt lines m (SNAP_PX / cam.zoom) with
          | some (.point pr) => mode := .pressed pr.lineIdx pr.ptIdx m  -- grabbed a point; wait
          | some (.curveEnd l p isEntry) => mode := .bracketPressed l p isEntry m
          | none =>
              if totalPts < MAX_PI then
                hist := History.record hist (lines.push #[{ pos := m }])
                mode := .building lines.size true true true     -- new line is now last
                dirty := true
      | _ => pure ()  -- pressed/dragging/resizing: edge already consumed below

    -- resolve a grabbed point: a release without movement is a click (resume the line
    -- if the point is an endpoint); moving past `DRAG_PX` begins a drag. While dragging,
    -- the point follows the cursor, updated in place so the whole drag is one undo step.
    match mode with
    | .pressed lineIdx ptIdx press =>
        let mw ← getScreenToWorld2D (← getMousePosition) cam
        if !(← isMouseButtonDown MOUSE_BUTTON_LEFT) then
          let line := lines[lineIdx]!
          mode := if ptIdx = 0 || ptIdx = line.size - 1
                  then .building lineIdx (ptIdx = line.size - 1) false false  -- resume from this end
                  else .idle
        else
          let t := DRAG_PX / cam.zoom
          if dist2 mw press > t * t then
            hist := History.record hist lines                   -- snapshot original once
            hist := History.setCurrent hist (setPIPos! lines lineIdx ptIdx mw)
            mode := .dragging lineIdx ptIdx
            dragIdx := some lineIdx
    | .dragging lineIdx ptIdx =>
        if !(← isMouseButtonDown MOUSE_BUTTON_LEFT) then
          mode := .idle                                         -- drop; state already recorded
          finalizeIdx := some lineIdx                           -- one exact resample on release
        else
          let mw ← getScreenToWorld2D (← getMousePosition) cam
          hist := History.setCurrent hist (setPIPos! lines lineIdx ptIdx mw)
          dragIdx := some lineIdx
    | .bracketPressed lineIdx piIdx isEntry press =>
        -- like a point press: release without moving is a no-op; past `DRAG_PX`, begin a
        -- resize (snapshot the original geometry once for a single undo step).
        let mw ← getScreenToWorld2D (← getMousePosition) cam
        if !(← isMouseButtonDown MOUSE_BUTTON_LEFT) then
          mode := .idle
        else
          let t := DRAG_PX / cam.zoom
          if dist2 mw press > t * t then
            hist := History.record hist lines
            mode := .resizing lineIdx piIdx isEntry
    | .resizing lineIdx piIdx isEntry =>
        if !(← isMouseButtonDown MOUSE_BUTTON_LEFT) then
          mode := .idle                                         -- drop; state already recorded
          finalizeIdx := some lineIdx                           -- one exact resample on release
        else
          let mw ← getScreenToWorld2D (← getMousePosition) cam
          if h : lineIdx < lines.size then
            let line := lines[lineIdx]
            if 1 ≤ piIdx ∧ piIdx + 1 < line.size then
              let a := line[piIdx-1]!.pos
              let b := line[piIdx]!.pos
              let c := line[piIdx+1]!.pos
              match cornerGeometry (v2ToV3 a) (v2ToV3 b) (v2ToV3 c) designParams line[piIdx]!.winding with
              | none => pure ()
              | some geom =>
                -- new budget = distance from the PI to the cursor projected onto the grabbed
                -- leg, clamped to [min-radius floor, ½·shorter leg] so it can't cross the PI
                -- nor make the arc tighter than `minRadius`. The budget is the unsigned
                -- distance along the leg line, so we take the magnitude of the projection:
                -- a reverse-winding loop's handles sit on the *extension* rays (ahead of the
                -- PI on the entry leg, behind it on the exit leg), flipping the raw sign.
                let uIn := v3ToV2 geom.uIn
                let uOut := v3ToV2 geom.uOut
                let hi := geom.maxBudget.val
                let lo := max 0.001 geom.minBudget.val
                let dRaw := if isEntry then dot2 (sub2 mw b) uIn else dot2 (sub2 mw b) uOut
                let d := if dRaw < 0.0 then -dRaw else dRaw
                let d' := max lo (min hi d)
                hist := History.setCurrent hist (setPIBudget! lines lineIdx piIdx d')
                dragIdx := some lineIdx
    | _ => pure ()

    -- Escape / right-click finishes the current line. A brand-new one-point draft is
    -- discarded so cancel behaves as if the alignment was never started.
    if (← isMouseButtonPressed MOUSE_BUTTON_RIGHT) || escapePressed then
      match mode with
      | .building idx _ true _ =>
          let liveLines := History.current hist
          if h : idx < liveLines.size then
            if liveLines[idx].size = 1 then
              hist := History.discardCurrentLeaf hist
              dirty := true
      | _ => pure ()
      mode := .idle

    -- Ctrl+Z undo / Ctrl+Shift+Z redo
    let ctrl  ← (· || ·) <$> isKeyDown KEY_LEFT_CONTROL <*> isKeyDown KEY_RIGHT_CONTROL
    let shift ← (· || ·) <$> isKeyDown KEY_LEFT_SHIFT   <*> isKeyDown KEY_RIGHT_SHIFT
    if ctrl && (← isKeyPressed KEY_Z) then
      hist := if shift then History.redo hist else History.undo hist
      mode := .idle
      dirty := true

    -- [ / ] cycle which branch redo will follow at a fork (no state change)
    if (← isKeyPressed KEY_LEFT_BRACKET)  then hist := History.cycleBranch hist (-1)
    if (← isKeyPressed KEY_RIGHT_BRACKET) then hist := History.cycleBranch hist 1

    -- L cycles an interior corner through short, left-loop, and right-loop winding.
    if (← isKeyPressed KEY_L) then
      match mode with
      | .idle =>
          let mw ← getScreenToWorld2D (← getMousePosition) cam
          match hitTargetAt lines mw (SNAP_PX / cam.zoom) with
          | some (.curveEnd l p _) =>
              hist := History.record hist (cyclePIWinding! lines l p)
              dirty := true
          | some (.point pr) =>
              if h : pr.lineIdx < lines.size then
                let line := lines[pr.lineIdx]
                if 1 ≤ pr.ptIdx ∧ pr.ptIdx + 1 < line.size then
                  hist := History.record hist (cyclePIWinding! lines pr.lineIdx pr.ptIdx)
                  dirty := true
          | none => pure ()
      | _ => pure ()

    -- 1 / 2 switch render view (segment type / speed). Recolour only — no resample.
    if (← isKeyPressed KEY_ONE) then view := 1
    if (← isKeyPressed KEY_TWO) then view := 2

  -- the current lines after any edits above; drop a stale active-line index
  let lines := History.current hist
  mode := mode.revalidate lines

  let cache ← updateCurveCache lines curves pending dirty dragIdx finalizeIdx
  curves := cache.1
  pending := cache.2

  -- draw
  beginDrawing
  clearBackground BG
  let minSpeed ← drawWorldScene cam lines curves view mode

  if showFPS then drawFPS 0 0
  if view == 2 then drawSpeedLegend minSpeed
  drawScaleBar cam dpi
  drawHistory hist
  -- hide the crosshair while dragging a bracket so it doesn't fight the green handles
  if showInstructions then
    drawInstructions showFPS view
  else
    match mode with
    | .resizing .. => pure ()
    | _            => drawMouse cam
  endDrawing

  return {
    camera := cam, hist := hist, curves := curves, view := view, mode := mode,
    showInstructions := showInstructions, showFPS := showFPS, pending := pending }

partial def loop (st : UI) : IO Unit := do
  if (← windowShouldClose) then
    closeWindow
  else
    loop (← step st)

def main : IO Unit := do
  setConfigFlags (FLAG_VSYNC_HINT ||| FLAG_WINDOW_HIGHDPI ||| FLAG_MSAA_4X_HINT)
  initWindow 640 480 "Track Geometry"
  setExitKey 0  -- KEY_NULL: don't let Escape close the window
  hideCursor
  setTraceLogLevel LOG_DEBUG
  let cam : Camera2D := { offset := ⟨0.0, 0.0⟩, target := ⟨0.0, 0.0⟩, rotation := 0.0, zoom := 1.0 }
  loop {
    camera := cam, hist := History.init #[], curves := #[], view := 1, mode := .idle,
    showInstructions := false, showFPS := false, pending := none }
