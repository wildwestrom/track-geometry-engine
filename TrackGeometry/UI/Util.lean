import TrackGeometry.Lib
import TrackGeometry.Raylib

/-! # UI utilities

Small numeric/formatting helpers, 3D vector math over raylib's `Vector3`, ray/plane
and screen-space geometry, and conversions between raylib vectors and the geometry
engine's `Vec3 RFloat`. -/

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

/-- Float → screen coordinate (raylib `int`, mapped to `UInt32` by the binding). -/
@[inline] def f2u (x : Float) : UInt32 := x.toUInt32

/-! ## Small 3D vector helpers (raylib `Vector3`, world space). -/

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

/-- Gravity-aligned lateral/up axes for a unit tangent `T`: thin Float facade over
    `Frame.fromTangent` (single source of truth in the geometry core). Returns `(N, B)`. -/
def levelNB (T : Vector3) : Vector3 × Vector3 :=
  let fr := Frame.fromTangent (toGeo T)
  (ofGeo fr.N, ofGeo fr.B)

/-- Roll level axes by design cant height `h`: Float facade over `cantedAxes`.
    Returns unit `(N_φ, B_φ)` for rails / ticks. -/
def cantedNB (gauge : Float) (T : Vector3) (h : Float) : Vector3 × Vector3 :=
  let fr := Frame.fromTangent (toGeo T)
  let (N, B) := cantedAxes (rf gauge) fr.N fr.B (rf h)
  (ofGeo N, ofGeo B)

/-- Sign of design cant for outer-rail-high: path principal normal is `B_plane × T`;
    when that aligns with level left (`N₀`), the turn is left and cant is negative
    (right rail high). Returns `±1` (or `+1` if indeterminate). -/
def cantTurnSign (T Bplane : Vector3) : Float :=
  let (N0, _) := levelNB T
  let nPath := cross3 (norm3 Bplane) (norm3 T)
  let s := dot3 nPath N0
  if s < 0.0 then 1.0 else -1.0

/-! ## Ray / screen-space geometry -/

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

/-- Squared distance between two screen points (avoids a `sqrt`). -/
@[inline] def dist2 (a b : Vector2) : Float :=
  let dx := a.x - b.x; let dy := a.y - b.y; dx * dx + dy * dy

/-- Project a world point to screen space, or `none` when it lies behind the camera
    (where raylib's projection would still yield a spurious on-screen point). -/
def worldToScreenFront? (p : Vector3) (cam : Camera3D) : IO (Option Vector2) := do
  if dot3 (sub3 p cam.position) (sub3 cam.target cam.position) > 0.0 then
    return some (← getWorldToScreen p cam)
  else
    return none

/-- Distance from point `p` to segment `[a,b]`, all in 2D screen space. -/
def distToSeg (p a b : Vector2) : Float :=
  let abx := b.x - a.x; let aby := b.y - a.y
  let len2 := abx * abx + aby * aby
  let t := if len2 < 1e-9 then 0.0
           else clampF 0.0 1.0 (((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)
  let dx := p.x - (a.x + t * abx); let dy := p.y - (a.y + t * aby)
  Float.sqrt (dx * dx + dy * dy)

/-- True if either key is currently held (e.g. left or right Shift). -/
@[inline] def isKeyDownEither (a b : UInt32) : IO Bool :=
  (· || ·) <$> isKeyDown a <*> isKeyDown b
