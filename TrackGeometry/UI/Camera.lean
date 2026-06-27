import TrackGeometry.UI.Util

/-! # Orbit camera

The orbit camera state, its raylib `Camera3D` projection, and the camera-only input
handling (wheel dolly, middle-drag orbit, Shift+middle-drag pan). -/

open Raylib

def CAM_FOVY : Float := 60.0
def MIN_DIST : Float := 1.0
/-- Max orbit distance, kept under raylib's far-clip (`RL_CULL_DISTANCE_FAR`) so the
    target plane never falls outside the view frustum when zoomed all the way out. -/
def MAX_DIST : Float := 9000.0

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
