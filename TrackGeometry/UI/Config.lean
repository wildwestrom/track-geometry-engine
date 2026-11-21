import TrackGeometry.UI.Util

/-! # UI constants & theme

Sizing/snapping constants, colors, the auto-radius design parameters, the speed-view
colour ramp, and per-segment colour/speed lookups. -/

open Raylib

def FONT : UInt32 := 8
def MAX_PI : Nat := 512
def CURVE_SAMPLES : Nat := 400
/-- Snap radius, in screen pixels, for grabbing a line endpoint. Converted to
    world units per frame (`SNAP_PX / zoom`) so it's zoom-independent. -/
def SNAP_PX : Float := 5.0
/-- How far (screen pixels) the cursor must move after pressing on a point before it
    counts as a drag rather than a click. Below this, a press+release is a click. -/
def DRAG_PX : Float := 4.0

def BG : Color := BLACK
def FG : Color := WHITE
def SECONDARY : Color := GRAY
def POINT_COLOR : Color := RED
/-- Highlight for the branch `redo` will follow next. -/
def REDO_COLOR : Color := GREEN
/-- Bright lime for the curve-end markers. -/
def BRACKET_COLOR : Color := GREEN

/-! ### Per-segment-type colors for the smooth alignment. -/
def STRAIGHT_COLOR   : Color := Color.mk 102 191 255 255
def ARC_COLOR        : Color := Color.mk 255 161   0 255
def TRANSITION_COLOR : Color := Color.mk 230 110 200 255

/-- Color for a path piece, by segment type. -/
def segColor (e : AnySegment RFloat) : Color :=
  match e with
  | ⟨_, _, .straight .., _⟩      => STRAIGHT_COLOR
  | ⟨_, _, .arc .., _⟩           => ARC_COLOR
  | ⟨_, _, .transitionIn .., _⟩  => TRANSITION_COLOR
  | ⟨_, _, .transitionOut .., _⟩ => TRANSITION_COLOR

/-- Layout policy for the PI builder. `minRadius` is a hard floor (1 scene unit = 1 m):
    40 m is the tightest radius the game builds (found experimentally). -/
def layoutPolicy : LayoutPolicy RFloat :=
  { legBudget := rf 0.3, minRadius := rf 40.0 }

/-- Speed and comfort model for the PI builder (1 scene unit = 1 m): `V = √(a_max·R)` per
    corner, clothoid sized to the larger of the jerk- and yaw-acceleration-limited lengths.
    `maxLateralAccel` sizes `V` as the full lateral budget under the zero-cant model. -/
def speedModel : SpeedModel RFloat :=
  { maxLateralAccel := rf 1.2, maxLateralJerk := rf 0.5, maxYawAccel := rf 0.2,
    maxDesignSpeed := rf 83.3333 }  -- 300 km/h

/-- Collinearity threshold: corners whose `|sin Δ|` is at or below this are treated as straight. -/
def straightThreshold : RFloat := rf 0.001

/-! ### Speed view: per-segment operating speed and a green→red colour ramp. -/

def MPS_TO_KMH : Float := 3.6
/-- Design-speed ceiling, as a raw `Float`. -/
def designSpeedF : Float := speedModel.maxDesignSpeed.val

/-- Speed-view colour-ramp endpoints (m/s), an absolute scale independent of the
    route. Anything at or below `SPEED_RAMP_MIN` is red; at or above `SPEED_RAMP_MAX`
    is green. -/
def SPEED_RAMP_MIN : Float := 30.0  / MPS_TO_KMH   -- 30 km/h
def SPEED_RAMP_MAX : Float := 300.0 / MPS_TO_KMH   -- 300 km/h

/-- Operating speed (scene-units/s) stored on the path piece by `buildPath` /
    `solveCorner`. Falls back to the design-speed ceiling when `opSpeed` is unset (`0`),
    which matches unrestricted straights under a disabled speed model. -/
def segSpeed (e : AnySegment RFloat) : Float :=
  let v := e.opSpeed.val
  if v > 0.0 then v else designSpeedF

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

/-! ### Translate gizmo (X/Y/Z axis handles) sizing and colours. -/

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

/-! ### Track rails (extruded rectangles along the centerline) -/

/-- Half of standard-gauge track (≈ 1435 mm / 2). 1 scene unit = 1 m. Rails sit at
    `pos ± TRACK_HALF_GAUGE • normal` (design-cant lateral from level frame). -/
def TRACK_HALF_GAUGE : Float := 0.72
/-- Full gauge `G` for cant height `h = G · sin φ`. -/
def TRACK_GAUGE : Float := 2.0 * TRACK_HALF_GAUGE
/-- Half-width of each rail head ribbon. -/
def RAIL_HALF_WIDTH : Float := 0.05
/-- Extrusion height along the track binormal (keeps rails above the ground / centerline). -/
def RAIL_HEIGHT : Float := 0.12
/-- Solid steel colour for both rails, independent of type and speed views. -/
def RAIL_COLOR : Color := Color.mk 90 95 105 255

/-! ### Cant / gravity

Design applied cant comes from curvature and operating speed:
`h = h_eq = G · V² · κ / g` (balanced). Rails bank by rolling the level frame about `T`.
`maxLateralAccel` in `speedModel` sizes speed as the full lateral acceleration at zero cant;
cant does not affect speed or clothoid length. -/

/-- Gravitational acceleration (m/s²); 1 scene unit = 1 m. -/
def GRAVITY : Float := 9.81
/-- Metres → millimetres for cant HUD labels. -/
def M_TO_MM : Float := 1000.0

/-- Equilibrium cant height (m). Thin Float facade over `equilibriumCant`. -/
@[inline] def equilibriumCantF (V κ : Float) : Float :=
  (equilibriumCant (rf TRACK_GAUGE) (rf GRAVITY) (rf V) (rf κ)).val

/-- Design applied cant magnitude (m). Thin Float facade over `designCant`. -/
@[inline] def designCantF (V κ : Float) : Float :=
  (designCant (rf TRACK_GAUGE) (rf GRAVITY) (rf V) (rf κ)).val

/-- Cant deficiency (m). Thin Float facade over `cantDeficiency`. -/
@[inline] def cantDeficiencyF (hEq h : Float) : Float :=
  (cantDeficiency (rf hEq) (rf h)).val

/-! ### Frame tick visualization (design-cant lateral, same as rails) -/

/-- Half-length of one tick as a fraction of the camera distance (screen-constant). -/
def TICK_HALF_W : Float := 0.02
/-- Draw a tick every Nth curve sample. -/
def TICK_EVERY : Nat := 6
/-- Color for the +N side (left of travel, design-cant frame). -/
def TICK_LEFT_COLOR : Color := Color.mk 0 220 80 255
/-- Color for the −N side (right of travel, design-cant frame). -/
def TICK_RIGHT_COLOR : Color := Color.mk 220 60 60 255
