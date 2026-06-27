import TrackGeometry.Vec

/-! # Design cant

Applied cant from curvature and speed: equilibrium height, deficiency, and
rolling the level frame about the tangent.
-/

/-! ### Design cant (from curvature and speed)

Railway **applied cant** is a design quantity on the rail plane: outer rail raised by height
`h` so that at design speed the lateral force is reduced. It is **not** inferred from path
torsion / RMF roll or from grade. Standard small-angle form (unsigned κ = 1/R):

  `h_eq = G · V² · κ / g`     equilibrium (balanced) cant
  `h`     = design applied cant (here: full equilibrium unless clamped later)
  `h_d`   = `h_eq − h`        cant deficiency (negative ⇒ excess)

The zero-cant reference is the gravity-aligned level frame (`Frame.fromTangent`). Rails sit
at `p ± (G/2) · N_φ` where `N_φ` is `N₀` rolled about `T` by `φ` with `sin φ = h/G`
(positive `h` ⇒ left rail high). Turn sense for the signed height comes from the corner
plane binormal (outer rail high).

`DesignParams` speed and clothoid length use the zero-cant model
`V = √(a_max·R)` and do not account for cant. -/

/-- Equilibrium cant height `h_eq = G · V² · κ / g` (small-angle). `κ` is curvature magnitude.
    Returns `0` if `g = 0`. -/
def equilibriumCant [TrackScalar α] (G g V κ : α) : α :=
  if g = 0 then 0 else G * V * V * κ / g

/-- Design applied cant height. Default policy: balanced track `h = h_eq` (full equilibrium
    at the given `V` and `κ`). Clamp / deficiency budgets can wrap this later. -/
def designCant [TrackScalar α] (G g V κ : α) : α :=
  equilibriumCant G g V κ

/-- Cant deficiency `h_d = h_eq − h` (negative ⇒ cant excess). -/
def cantDeficiency [TrackScalar α] (hEq h : α) : α := hEq - h

/-- Roll the level frame `(N₀, B₀)` about the track tangent so that cant height is `h`
    (`sin φ = h/G`, positive `h` ⇒ left rail high). `N₀`/`B₀` must already be the level
    axes for that tangent. Returns unit `(N_φ, B_φ)`. Falls back to the level frame if
    `|h| ≥ G` (or `G = 0`). -/
def cantedAxes [TrackScalar α] (G : α) (N0 B0 : Vec3 α) (h : α) : Vec3 α × Vec3 α :=
  if G = 0 then (N0, B0)
  else
    let sφ := h / G
    if sφ * sφ ≥ 1 then (N0, B0)
    else
      let cφ := TrackScalar.sqrt (1 - sφ * sφ)
      let N := cφ • N0 + sφ • B0
      let B := cφ • B0 - sφ • N0
      (N, B)
