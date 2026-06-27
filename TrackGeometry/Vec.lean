/-! # Scalar typeclass and 3D vectors

`TrackScalar`, `Vec3`, and small scalar helpers shared by the geometry core.
-/

/-! ## Scalar typeclass for track geometry

`TrackScalar α` captures everything we need from a scalar type to do track geometry:
basic arithmetic, order, trig functions, and square roots. Clothoid offsets are
obtained by Gauss–Legendre quadrature over these primitives, so no special
integral functions are needed in the interface.

We deliberately extend only the individual operation typeclasses that both `ℝ` and
`Float` satisfy, avoiding `Field` and `LinearOrder` (which `Float` doesn't satisfy).

`Zero`/`One` give us `0`/`1` literals. We avoid `2` in generic code (use `1+1` instead)
because `OfNat α 2` can't be a superclass (value parameter).

`DecidableEq`/`DecidableRel` are NOT superclasses (they're `abbrev`s, not `class`es),
but we provide them as fields and derive global instances below.
-/

class TrackScalar (α : Type) extends
  Add α, Sub α, Mul α, Div α, Neg α,
  Zero α, One α,
  LT α, LE α, Max α, Min α where
  cos : α → α
  sin : α → α
  arccos : α → α
  sqrt : α → α
  pi : α
  decEq : (a b : α) → Decidable (a = b)
  decLe : (a b : α) → Decidable (a ≤ b)
  decLt : (a b : α) → Decidable (a < b)

/-- Every `TrackScalar` carries decidability of equality and order. -/
instance [h : TrackScalar α] : DecidableEq α := h.decEq
instance [h : TrackScalar α] : DecidableRel (· ≤ · : α → α → Prop) := h.decLe
instance [h : TrackScalar α] : DecidableRel (· < · : α → α → Prop) := h.decLt

/-! ## 3D vector type

`Vec3 α` is `Fin 3 → α` — three components of scalar type `α`.
Use `Vec3.mk x y z` to construct vectors.
All arithmetic (`+`, `-`, `•`, etc.) comes from the `Pi` instances automatically.
-/

def Vec3 (α : Type) := Fin 3 → α

namespace Vec3

variable {α : Type}

-- Explicit instances: `Vec3 α` is reducible to `Fin 3 → α`, but Pi instances for
-- `HAdd`/`HSub`/`HSMul` aren't reliably found, so we provide our own.
instance [Add α] : Add (Vec3 α) := ⟨λ v w i => v i + w i⟩
instance [Sub α] : Sub (Vec3 α) := ⟨λ v w i => v i - w i⟩
instance [Neg α] : Neg (Vec3 α) := ⟨λ v i => -v i⟩
instance [Mul α] : SMul α (Vec3 α) := ⟨λ r v i => r * v i⟩

/-- Construct a vector from three components. -/
def mk (x y z : α) : Vec3 α := fun i => if i = 0 then x else if i = 1 then y else z

/-- Dot product. -/
def dot [Add α] [Mul α] (v w : Vec3 α) : α := (v 0 * w 0) + (v 1 * w 1) + (v 2 * w 2)

/-- Squared Euclidean norm (avoids sqrt when not needed). -/
def normSq [Add α] [Mul α] (v : Vec3 α) : α := dot v v

/-- Euclidean norm. -/
def norm [TrackScalar α] (v : Vec3 α) : α := TrackScalar.sqrt (normSq v)

/-- Euclidean distance. -/
def dist [TrackScalar α] (v w : Vec3 α) : α := norm (v - w)

/-- Rotate 90° counterclockwise in the XY-plane, preserving Z. -/
def perp [Neg α] (v : Vec3 α) : Vec3 α := mk (-v 1) (v 0) (v 2)

/-- Full 3D cross product. -/
def cross [Mul α] [Add α] [Sub α] (v w : Vec3 α) : Vec3 α :=
  mk (v 1 * w 2 - v 2 * w 1) (v 2 * w 0 - v 0 * w 2) (v 0 * w 1 - v 1 * w 0)

/-- Z-component of the 3D cross product (signed magnitude of the 2D cross product).
    Positive when `w` is counterclockwise from `v` in the XY-plane. -/
def crossZ [Mul α] [Add α] [Sub α] (v w : Vec3 α) : α := (cross v w) 2

/-- Linear interpolation: `lerp p q t = p + t • (q - p)`. -/
def lerp [Add α] [Sub α] [SMul α (Vec3 α)] (p q : Vec3 α) (t : α) : Vec3 α := p + t • (q - p)

/-- Unit vector in the direction of `v`. Returns `v` unchanged if it has zero length,
    so callers never divide by zero. -/
def normalize [TrackScalar α] (v : Vec3 α) : Vec3 α :=
  let n2 := normSq v
  if n2 = 0 then v else (1 / TrackScalar.sqrt n2) • v

/-- Rotate `v` about the **unit** axis given by *scalar* components `(nx, ny, nz)` by
    angle `φ`, via Rodrigues' formula, returning a `Vec3.mk` of scalar expressions.

    Why a scalar axis: `Vec3 α = Fin 3 → α` values are unevaluated closures, and the axis
    of `rotateAxis` is read ~6× per call (in `n·v`, `n×v`, and the `n` term). When that
    axis is itself a nested `cross`/`normalize` expression (the corner binormal), the cost
    compounds multiplicatively through nested rotations and explodes — whereas a cheap
    (literal / scalar) axis keeps a single rotation's reads `O(1)`. Callers read the
    binormal's three components into scalars *once* and pass them here, so nested rotations
    about the same tilted plane stay cheap. -/
def rotateAxisC [TrackScalar α] (nx ny nz φ : α) (v : Vec3 α) : Vec3 α :=
  let c := TrackScalar.cos φ
  let s := TrackScalar.sin φ
  let vx := v 0; let vy := v 1; let vz := v 2
  let d := nx * vx + ny * vy + nz * vz
  let k := d * (1 - c)
  mk (c * vx + s * (ny * vz - nz * vy) + k * nx)
     (c * vy + s * (nz * vx - nx * vz) + k * ny)
     (c * vz + s * (nx * vy - ny * vx) + k * nz)

/-- Rotate `v` about the **unit** axis `n` by angle `φ`, via Rodrigues' rotation
    formula `v cosφ + (n × v) sinφ + n (n·v)(1 − cosφ)`. Reads `n`'s components into
    scalars and defers to `rotateAxisC`. For `n = ẑ` and a planar `v` this reduces
    exactly to a 2D rotation in the XY-plane. -/
def rotateAxis [TrackScalar α] (n : Vec3 α) (φ : α) (v : Vec3 α) : Vec3 α :=
  rotateAxisC (n 0) (n 1) (n 2) φ v

/-- Rotate `v` by the rotation-vector (axis-angle) `ω`: the axis is `ω̂` and the angle
    is `‖ω‖`. This is the exponential map of `so(3)` applied to `v`; it is how a Frenet
    frame is advanced by an instantaneous Darboux vector `ω = τT + κB`. Returns `v`
    unchanged for `ω = 0`. -/
def rotateBy [TrackScalar α] (ω : Vec3 α) (v : Vec3 α) : Vec3 α :=
  let φ2 := normSq ω
  if φ2 = 0 then v
  else
    let φ := TrackScalar.sqrt φ2
    rotateAxis ((1 / φ) • ω) φ v

end Vec3

/-- `natToScalar` injects a `Nat` into `α` by repeated addition from `Zero`/`One`.
    O(n), but only ever called on small constants (quadrature orders, panel counts).
    Lets generic `[TrackScalar α]` code use integer literals beyond `0`/`1` without an
    `OfNat` superclass. -/
def natToScalar [TrackScalar α] : Nat → α
  | 0 => 0
  | n + 1 => natToScalar n + 1

/-- Inject an `Int` into `α`. Used for per-corner turn windings. -/
def intToScalar [TrackScalar α] : Int → α
  | .ofNat n => natToScalar n
  | .negSucc n => -natToScalar (n + 1)

/-- Absolute value using only the order operations in `TrackScalar`. -/
def absScalar [TrackScalar α] (x : α) : α := if x < 0 then -x else x

