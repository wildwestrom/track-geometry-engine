import TrackGeometry.UI.Draw
import TrackGeometry.UI.Input

/-! # Track Geometry — interactive UI (in Lean)

The top-level frame loop. The UI lives in `TrackGeometry.UI.*`: math/formatting helpers
(`Util`), constants and theme (`Config`), the orbit camera (`Camera`), the editor state
and off-thread curve sampling (`State`), cursor hit-testing (`Pick`), drawing (`Draw`),
and the input handlers (`Input`). It all calls the geometry engine (`TrackGeometry.Lib`)
directly and the generated Raylib bindings (`TrackGeometry.Raylib`). The only C left in
the project is the generated FFI shim. -/

open Raylib

def step (st : UI) : IO UI := do
  -- F1/F3/Esc toggles stay live even while the instructions overlay is up.
  let mut showInstructions := st.showInstructions
  let mut showFPS := st.showFPS
  let mut showTicks := st.showTicks
  let mut showCoords := st.showCoords
  let escapePressed ← isKeyPressed KEY_ESCAPE
  if (← isKeyPressed KEY_F1) then showInstructions := !showInstructions
  if (← isKeyPressed KEY_F3) then showFPS := !showFPS
  if (← isKeyPressed KEY_F4) then showTicks := !showTicks
  if (← isKeyPressed KEY_F5) then showCoords := !showCoords
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
    showInstructions, showFPS, showTicks, showCoords, hist := e.hist }

  return {
    camera := orbit, hist := e.hist, curves := curves, view := e.view, mode := mode,
    showInstructions := showInstructions, showFPS := showFPS, showTicks := showTicks,
    showCoords := showCoords, pending := pending }

partial def loop (st : UI) : IO Unit := do
  if (← windowShouldClose) then
    closeWindow
  else
    loop (← step st)

def main : IO Unit := do
  setConfigFlags (FLAG_VSYNC_HINT ||| FLAG_WINDOW_HIGHDPI ||| FLAG_MSAA_4X_HINT ||| FLAG_WINDOW_RESIZABLE)
  initWindow 1280 720 "Track Geometry"
  setExitKey 0  -- KEY_NULL: don't let Escape close the window
  hideCursor
  setTraceLogLevel LOG_DEBUG
  let cam : OrbitCam := { target := ⟨0.0, 0.0, 0.0⟩, distance := 200.0, yaw := -1.0, pitch := 0.9 }
  loop {
    camera := cam, hist := History.init #[], curves := #[], view := .segmentType, mode := .idle,
    showInstructions := false, showFPS := false, showTicks := false, showCoords := false,
    pending := none }
