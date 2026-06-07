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
def SNAP_PX : Float := 10.0
/-- Raylib `KEY_ESCAPE` (not in the generated binding set; defined here). -/
def KEY_ESCAPE : UInt32 := 256

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

/-- Auto-radius design parameters for the PI builder. -/
def designParams : DesignParams RFloat :=
  { legBudget := rf 0.3, straightThreshold := rf 0.001, transitionLengthRatio := rf 0.5 }

/-! ## UI state -/

/-- One alignment under construction: an ordered polyline of points of
    intersection (world coordinates). Each line is rounded into its own smooth
    alignment independently of the others. -/
abbrev Line := Array Vector2

/-- The line-building finite state machine.

    * `idle` — no line is active. A left-click on empty space starts a new line;
      a left-click snapped onto an existing endpoint resumes that line.
    * `building lineIdx atEnd` — left-clicks extend `lines[lineIdx]`, appending to
      its end when `atEnd`, otherwise prepending to its start. Escape / right-click
      returns to `idle`. -/
inductive Mode
  | idle
  | building (lineIdx : Nat) (atEnd : Bool)
  deriving Repr

/-- Drop back to `idle` if the active line index no longer exists (e.g. after an
    undo removed the line). Indices are otherwise stable across history moves. -/
def Mode.revalidate : Mode → Array Line → Mode
  | .building idx e, lines => if idx < lines.size then .building idx e else .idle
  | .idle, _ => .idle

structure UI where
  camera : Camera2D
  /-- Undo/redo *tree* of the placed lines (each a polyline of PIs in world
      coordinates). The current node's state is the live set of lines. -/
  hist : History.History (Array Line)
  /-- Cached smooth alignment per line, resampled only when the lines change. -/
  curves : Array (Array (Vector2 × Color))
  /-- Transient line-building state. Not part of the undo history. -/
  mode : Mode

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

/-- A line endpoint the cursor can snap to: which line, which end (`atEnd` =
    last point vs first point), and its world position. -/
structure Snap where
  lineIdx : Nat
  atEnd   : Bool
  pos     : Vector2

/-- Squared world distance between two points (avoids a `sqrt`). -/
@[inline] def dist2 (a b : Vector2) : Float :=
  let dx := a.x - b.x; let dy := a.y - b.y; dx * dx + dy * dy

/-- The line endpoint nearest `target` within `thresh` world units, if any.
    Each line offers its first point (`atEnd := false`) and last point
    (`atEnd := true`); a single-point line is treated as its end. -/
def nearestEndpoint (lines : Array Line) (target : Vector2) (thresh : Float) : Option Snap := Id.run do
  let mut best : Option Snap := none
  let mut bestD := thresh * thresh
  for h : i in [0:lines.size] do
    let line := lines[i]
    if h0 : line.size > 0 then
      let candidates :=
        if line.size = 1 then #[(true, line[0])]
        else #[(true, line[line.size - 1]!), (false, line[0])]
      for (atEnd, p) in candidates do
        let d := dist2 p target
        if d ≤ bestD then
          bestD := d
          best := some { lineIdx := i, atEnd, pos := p }
  return best

/-- Sample one line's smooth alignment into a polyline for drawing (empty if the
    line has fewer than two PIs). -/
def sampleCurve (line : Line) : Array (Vector2 × Color) := Id.run do
  let mut out := #[]
  if line.size ≥ 2 then
    let path := buildPath (line.map fun q => Vec3.mk (rf q.x) (rf q.y) (rf 0.0)) designParams
    let total := path.length |>.val
    if total > 0.0 then
      -- Sample each piece on its own so points carry their segment's color; a
      -- piece gets samples proportional to its share of the total length.
      for e in path.segments do
        let col := segColor e
        let segLen := e.length.val
        let nsamp := max 2 (Float.ceil (Float.ofNat CURVE_SAMPLES * segLen / total)).toUInt64.toNat
        for j in [0:nsamp + 1] do
          let t := segLen * Float.ofNat j / Float.ofNat nsamp
          let q := e.pointAt (rf t)
          out := out.push (⟨(q 0).val, (q 1).val⟩, col)
  return out

/-! ## Per-frame step -/

def step (st : UI) : IO UI := do
  let dpi ← getWindowScaleDPI
  setMouseScale dpi.x dpi.y

  let mut cam := st.camera
  let mut hist := st.hist
  let lines := History.current hist
  let mut curves := st.curves
  let mut mode := st.mode
  let mut dirty := false

  -- zoom toward the cursor
  let wheel ← getMouseWheelMove
  if wheel != 0.0 then
    let mp ← getMousePosition
    let mw ← getScreenToWorld2D mp cam
    let z := clampF MIN_ZOOM MAX_ZOOM (Float.exp (Float.log cam.zoom + 0.2 * wheel))
    cam := { cam with offset := mp, target := mw, zoom := z }

  -- middle-drag to pan
  if (← isMouseButtonDown MOUSE_BUTTON_MIDDLE) then
    let d ← getMouseDelta
    let g := -1.0 / cam.zoom
    cam := { cam with target := ⟨cam.target.x + d.x * g, cam.target.y + d.y * g⟩ }

  -- left-click: when building, extend the active line; when idle, resume a line
  -- whose endpoint we snapped onto, else start a fresh separate line.
  let totalPts := lines.foldl (fun a l => a + l.size) 0
  if (← isMouseButtonPressed MOUSE_BUTTON_LEFT) && totalPts < MAX_PI then
    let m ← getScreenToWorld2D (← getMousePosition) cam
    match mode with
    | .building idx atEnd =>
        let line := lines[idx]!
        let line' := if atEnd then line.push m else #[m] ++ line
        hist := History.record hist (lines.set! idx line')
        dirty := true                                   -- mode unchanged
    | .idle =>
        match nearestEndpoint lines m (SNAP_PX / cam.zoom) with
        | some s => mode := .building s.lineIdx s.atEnd  -- resume; no point added
        | none =>
            hist := History.record hist (lines.push #[m])
            mode := .building lines.size true            -- new line is now last
            dirty := true

  -- Escape / right-click finishes the current line (back to idle)
  if (← isMouseButtonPressed MOUSE_BUTTON_RIGHT) || (← isKeyPressed KEY_ESCAPE) then
    mode := .idle

  -- Ctrl+Z undo / Ctrl+Shift+Z redo
  let ctrl  ← (· || ·) <$> isKeyDown KEY_LEFT_CONTROL <*> isKeyDown KEY_RIGHT_CONTROL
  let shift ← (· || ·) <$> isKeyDown KEY_LEFT_SHIFT   <*> isKeyDown KEY_RIGHT_SHIFT
  if ctrl && (← isKeyPressed KEY_Z) then
    hist := if shift then History.redo hist else History.undo hist
    dirty := true

  -- [ / ] cycle which branch redo will follow at a fork (no state change)
  if (← isKeyPressed KEY_LEFT_BRACKET)  then hist := History.cycleBranch hist (-1)
  if (← isKeyPressed KEY_RIGHT_BRACKET) then hist := History.cycleBranch hist 1

  -- the current lines after any edits above; drop a stale active-line index
  let lines := History.current hist
  mode := mode.revalidate lines

  -- rebuild every line's cached curve only when the lines changed
  if dirty then
    curves := lines.map sampleCurve

  -- draw
  beginDrawing
  clearBackground BG
  beginMode2D cam
  -- world-space line widths, kept constant in screen pixels via `/ zoom`
  let tangentW := 1.5 / cam.zoom
  let curveW   := 3.0 / cam.zoom
  for line in lines do
    for i in [1:line.size] do
      drawLineEx line[i-1]! line[i]! tangentW SECONDARY
  for curve in curves do
    for i in [1:curve.size] do
      drawLineEx curve[i-1]!.1 curve[i]!.1 curveW curve[i]!.2
  for line in lines do
    for q in line do
      drawCircleV q (4.0 / cam.zoom) POINT_COLOR
  -- feedback: snap highlight when idle, rubber-band to the cursor when building
  let mw ← getScreenToWorld2D (← getMousePosition) cam
  match mode with
  | .idle =>
      match nearestEndpoint lines mw (SNAP_PX / cam.zoom) with
      | some s => drawCircleV s.pos (7.0 / cam.zoom) REDO_COLOR
      | none   => pure ()
  | .building idx atEnd =>
      let line := lines[idx]!
      if line.size ≥ 1 then
        drawLineEx (if atEnd then line[line.size - 1]! else line[0]!) mw (1.5 / cam.zoom) SECONDARY
  endMode2D

  drawFPS 0 0
  drawText s!"DPI Scale: {fmtFixed dpi.x 1} {fmtFixed dpi.y 1}   zoom: {fmtFixed cam.zoom 2}x"
    0 16 FONT FG
  drawText "left-click: place / continue line    right-click or Esc: finish    scroll: zoom    middle-drag: pan"
    0 28 FONT FG
  drawText "Ctrl+Z: undo    Ctrl+Shift+Z: redo    [ ]: switch branch"
    0 40 FONT FG
  drawScaleBar cam dpi
  drawHistory hist
  drawMouse cam
  endDrawing

  return { camera := cam, hist := hist, curves := curves, mode := mode }

partial def loop (st : UI) : IO Unit := do
  if (← windowShouldClose) then
    closeWindow
  else
    loop (← step st)

def main : IO Unit := do
  setConfigFlags (FLAG_VSYNC_HINT ||| FLAG_WINDOW_HIGHDPI)
  initWindow 640 480 "Track Geometry"
  setExitKey 0  -- KEY_NULL: don't let Escape close the window
  hideCursor
  setTraceLogLevel LOG_DEBUG
  let cam : Camera2D := { offset := ⟨0.0, 0.0⟩, target := ⟨0.0, 0.0⟩, rotation := 0.0, zoom := 1.0 }
  loop { camera := cam, hist := History.init #[], curves := #[], mode := .idle }
