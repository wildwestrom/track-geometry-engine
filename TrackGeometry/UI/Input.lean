import TrackGeometry.UI.Pick

/-! # Per-frame input handling

The mouse/keyboard edit handlers: left-press dispatch, the press→click/drag and
drag→release skeletons, and the keyboard/right-click edits. Each handler threads one
`Edit` accumulator through the frame. -/

open Raylib

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
              let b := line[piIdx]!.pos
              let layouts := lineLayouts line
              let dragBounds := lineDragBounds line layouts
              match (layouts[piIdx]?).bind id, (dragBounds[piIdx]?).bind id with
              | some geom, some bounds =>
                -- new budget = distance from the PI to the cursor projected onto the grabbed
                -- leg, clamped to [min-radius floor, room the neighbouring curves leave] so it
                -- can't cross the PI, overlap a neighbour, nor make the arc tighter than
                -- `minRadius`. The budget is the unsigned distance
                -- along the leg line, so we take the magnitude of the projection: a reverse-
                -- winding loop's handles sit on the *extension* rays, flipping the raw sign.
                let uIn := ofGeo geom.uIn
                let uOut := ofGeo geom.uOut
                let hi := bounds.maxBudget.val
                let lo := max 0.001 bounds.minBudget.val
                let dRaw := if isEntry then dot3 (sub3 mw b) uIn else dot3 (sub3 mw b) uOut
                let d := if dRaw < 0.0 then -dRaw else dRaw
                let d' := max lo (min hi d)
                return { e with hist := History.setCurrent e.hist (setPIBudget! lines lineIdx piIdx d'),
                                dragIdx := some lineIdx }
              | _, _ => return e
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
  if (← isKeyPressed KEY_ONE) then e := { e with view := .segmentType }
  if (← isKeyPressed KEY_TWO) then e := { e with view := .speed }
  return e
