import TrackGeometry.UI.Pick

/-! # Drawing

The 3D world pass (grid, tangent polylines, curves, PI markers, edit feedback) and the
screen-space HUD (crosshair, instructions modal, undo-tree, speed legend/labels), tied
together by `render`. -/

open Raylib

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
def drawInstructions (showFPS : Bool) (view : RenderView) (showTicks : Bool) (showCoords : Bool) :
    IO Unit := do
  let sw := Float.ofNat (← getScreenWidth).toNat
  let sh := Float.ofNat (← getScreenHeight).toNat
  let panelW := min (sw - 48.0) 560.0
  let panelH := min (sh - 48.0) 348.0
  let x := max 12.0 ((sw - panelW) / 2.0)
  let y := max 12.0 ((sh - panelH) / 2.0)
  let bg := Color.mk 0 0 0 232
  drawRectangle (f2u x) (f2u y) (f2u panelW) (f2u panelH) bg
  drawText "Instructions" (f2u (x + 16.0)) (f2u (y + 14.0)) 20 FG
  drawText "Press F1 or Esc to return." (f2u (x + 16.0)) (f2u (y + 42.0)) FONT SECONDARY
  let typeLabel := if view == .segmentType then "[type]" else "type"
  let speedLabel := if view == .speed then "[speed]" else "speed"
  let rows := #[
    ("F1", "toggle instructions"),
    ("F3", s!"toggle FPS ({if showFPS then "shown" else "hidden"})"),
    ("F4", s!"toggle frame ticks ({if showTicks then "shown" else "hidden"})"),
    ("F5", s!"toggle point coordinates ({if showCoords then "shown" else "hidden"})"),
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
    ("1 / 2", s!"view: {typeLabel} / {speedLabel}"),
    ("Cant", "design bank h = G V² κ / g (outer rail high); HUD: peak h / eq / def (mm)")
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

/-! ## World-space markers -/

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

/-! ## Cant HUD -/

/-- Peak |design cant|, |equilibrium cant|, and |deficiency| across all samples (m).
    Balanced design → applied ≈ equilibrium, deficiency ≈ 0 on curves. -/
def cantPeaks (curves : Array (Array CurveSample)) : Float × Float × Float := Id.run do
  let mut maxH := 0.0
  let mut maxEq := 0.0
  let mut maxDef := 0.0
  for curve in curves do
    for cs in curve do
      let h := cs.cant
      let hAbs := if h < 0.0 then -h else h
      let hEq := equilibriumCantF cs.speed cs.kappa
      let hD := cantDeficiencyF hEq hAbs
      maxH := max maxH hAbs
      maxEq := max maxEq (if hEq < 0.0 then -hEq else hEq)
      maxDef := max maxDef (if hD < 0.0 then -hD else hD)
  (maxH, maxEq, maxDef)

/-- Bottom-left cant summary: peak design / equilibrium / deficiency in mm. -/
def drawCantSummary (curves : Array (Array CurveSample)) : IO Unit := do
  let hasSamples := curves.any (·.size > 0)
  if !hasSamples then pure ()
  else
    let (maxH, maxEq, maxDef) := cantPeaks curves
    let sh := Float.ofNat (← getScreenHeight).toNat
    let x := 8.0
    let y0 := sh - 52.0
    drawText "cant (peak |·|)" (f2u x) (f2u y0) FONT SECONDARY
    drawText s!"h  {fmtFixed (maxH * M_TO_MM) 0} mm" (f2u x) (f2u (y0 + 12.0)) FONT FG
    drawText s!"eq {fmtFixed (maxEq * M_TO_MM) 0} mm" (f2u x) (f2u (y0 + 24.0)) FONT FG
    drawText s!"def {fmtFixed (maxDef * M_TO_MM) 0} mm" (f2u x) (f2u (y0 + 36.0)) FONT FG

/-! ## Speed view overlays -/

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
  for curve in curves do
    for cs in curve do
      if let some spd := cs.label then
        if let some sp ← worldToScreenFront? cs.pos cam then
          let txt := s!"{fmtFixed (spd * MPS_TO_KMH) 0} km/h"
          let w := (← measureText txt FONT).toNat.toFloat
          let x := sp.x - w / 2.0
          let y := sp.y - 4.0
          -- a 1px dark shadow keeps the number legible over any track colour
          drawText txt (f2u (x + 1.0)) (f2u (y + 1.0)) FONT BG
          drawText txt (f2u x) (f2u y) FONT FG

/-- A world point formatted as `"(x, y, z)"`, one decimal place. Shared by the always-on
    point labels and the drag readout. -/
def coordText (p : Vector3) : String :=
  s!"({fmtFixed p.x 1}, {fmtFixed p.y 1}, {fmtFixed p.z 1})"

/-- Point-coordinate labels (F5 toggle): every PI's world coordinates drawn beside it at
    all times, not just while dragging. A 2D overlay, so it runs after the 3D pass; points
    behind the camera are skipped. -/
def drawPointLabels (cam : Camera3D) (lines : Array Line) : IO Unit := do
  for line in lines do
    for q in line do
      if let some sp ← worldToScreenFront? q.pos cam then
        let txt := coordText q.pos
        let x := sp.x + 8.0
        let y := sp.y - 4.0
        -- a 1px dark shadow keeps the text legible over any background
        drawText txt (f2u (x + 1.0)) (f2u (y + 1.0)) FONT BG
        drawText txt (f2u x) (f2u y) FONT FG

/-! ## Track rails -/

/-- One quad as two triangles, both windings so the face is visible from either side
    without a cull-mode toggle. Vertices are in the order A–B–C–D around the face. -/
def drawRailQuad (a b c d : Vector3) (col : Color) : IO Unit := do
  drawTriangle3D a b c col
  drawTriangle3D a c d col
  drawTriangle3D a c b col
  drawTriangle3D a d c col

/-- Cross-section corners of one rail at `pos` with design-cant axes `N`/`B`:
    `(inner, outer)` on the top face and `(innerB, outerB)` on the bottom.
    `side` is `+1` for +N, `−1` for −N. -/
@[inline] def railCorners (pos n b : Vector3) (side : Float) :
    Vector3 × Vector3 × Vector3 × Vector3 :=
  let g := TRACK_HALF_GAUGE
  let rw := RAIL_HALF_WIDTH
  let h := RAIL_HEIGHT
  let center := add3 pos (scale3 (side * g) n)
  let nOff := scale3 (side * rw) n
  let up := scale3 h b
  let outerB := add3 center nOff
  let innerB := sub3 center nOff
  let outerT := add3 outerB up
  let innerT := add3 innerB up
  (innerT, outerT, innerB, outerB)

/-- Extrude rectangular rails along a sampled centerline. Each consecutive sample pair
    contributes a short prism for the left and right rails (top + outer/inner sides).
    Orientation is the **design-cant** frame on each sample: level axes rolled about `T`
    so bank follows `h = ± G V² κ / g` (outer rail high). -/
def drawRails (curve : Array CurveSample) : IO Unit := do
  let col := RAIL_COLOR
  for i in [1:curve.size] do
    let s0 := curve[i - 1]!
    let s1 := curve[i]!
    if len3 (sub3 s1.pos s0.pos) < 1e-9 then pure ()
    else
      for side in ([1.0, -1.0] : List Float) do
        let (i0t, o0t, i0b, o0b) := railCorners s0.pos s0.normal s0.binormal side
        let (i1t, o1t, i1b, o1b) := railCorners s1.pos s1.normal s1.binormal side
        -- top face
        drawRailQuad i0t o0t o1t i1t col
        -- outer vertical side
        drawRailQuad o0b o0t o1t o1b col
        -- inner vertical side
        drawRailQuad i0t i0b i1b i1t col

/-! ## The frame -/

/-- Everything one frame needs to draw: the orbit camera and its distance (for screen-
    constant sizing), the lines and their cached curves, the active render `view` and FSM
    `mode`, the cursor, the two HUD toggles, and the history for the undo-tree overlay. -/
structure Scene where
  cam              : Camera3D
  dist             : Float
  lines            : Array Line
  curves           : Array (Array CurveSample)
  view             : RenderView
  mode             : Mode
  mouse            : Vector2
  showInstructions : Bool
  showFPS          : Bool
  showTicks        : Bool
  showCoords       : Bool
  hist             : History.History (Array Line)

/-- Draw world-space route geometry and active edit feedback inside a 3D pass. `s.dist` is
    the camera distance, used to keep point/marker sizes roughly constant on screen. -/
def drawWorldScene (s : Scene) : IO Unit := do
  beginMode3D s.cam
  let ptR := s.dist * 0.005
  -- Grid and tangent polylines are coplanar with the curves (z = 0). Draw them with depth
  -- write disabled so the colored curves always win the depth test without z-fighting.
  -- rlDrawRenderBatchActive flushes the rlgl batch before toggling the GL state; without it
  -- the toggle has no effect because the actual draw call happens at EndMode3D.
  rlDrawRenderBatchActive
  rlDisableDepthMask
  drawGroundGrid s.cam.target s.dist (Color.mk 45 45 45 255)
  for line in s.lines do
    if line.size ≥ 2 then
      for i in [1:line.size] do
        drawLine3D line[i-1]!.pos line[i]!.pos SECONDARY
  rlDrawRenderBatchActive
  rlEnableDepthMask

  -- Solid rails under the colored centerline (depth-tested; height sits above the ground).
  for curve in s.curves do
    drawRails curve

  for curve in s.curves do
    for i in [1:curve.size] do
      let cs := curve[i]!
      let prev := curve[i-1]!
      let col := match s.view with
        | .segmentType => cs.segmentColor
        | .speed       => speedColor SPEED_RAMP_MIN SPEED_RAMP_MAX cs.speed
      drawLine3D prev.pos cs.pos col

  if s.showTicks then
    -- Same design-cant lateral as the rails, so ticks match rail bank.
    let hw := TICK_HALF_W * s.dist
    let mut tickI : Nat := 0
    for curve in s.curves do
      for i in [0:curve.size] do
        if tickI % TICK_EVERY == 0 then
          let cs := curve[i]!
          let n := cs.normal
          let left  := add3 cs.pos (scale3   hw n)
          let right := add3 cs.pos (scale3 (-hw) n)
          drawLine3D cs.pos left  TICK_LEFT_COLOR
          drawLine3D cs.pos right TICK_RIGHT_COLOR
        tickI := tickI + 1

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

/-- The full-screen draw for one frame: the 3D scene, HUD overlays, and either the
    instructions modal or the cursor crosshair (hidden behind a position readout while a
    marker is being dragged). -/
def render (s : Scene) : IO Unit := do
  beginDrawing
  clearBackground BG
  drawWorldScene s
  if s.showFPS then drawFPS 0 0
  if s.view == .speed then
    drawSpeedLegend
    drawSpeedLabels s.cam s.curves
  drawCantSummary s.curves
  if s.showCoords then drawPointLabels s.cam s.lines
  drawHistory s.hist
  -- hide the crosshair while dragging a marker so it doesn't fight the green handles
  if s.showInstructions then
    drawInstructions s.showFPS s.view s.showTicks s.showCoords
  else
    match s.mode with
    | .resizing .. => pure ()
    | .dragging lineIdx ptIdx _ | .axisDragging lineIdx ptIdx _ _ =>
        if let some q := getPI? s.lines lineIdx ptIdx then
          drawText (coordText q.pos) (f2u (s.mouse.x + 8.0)) (f2u (s.mouse.y - 14.0)) FONT FG
        drawMouse s.cam s.mouse (showCoords := false)
    | _            => drawMouse s.cam s.mouse
  endDrawing
