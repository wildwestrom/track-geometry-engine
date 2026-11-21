import TrackGeometry.Clothoid

/-! # Corner design parameters and scalar solver

Shared speed/comfort model (`SpeedModel`), polyline layout policy (`LayoutPolicy`),
solved scalar corner parameters (`CornerParams`), the scalar corner solver
(`solveCornerParams`), and the scalar PI tangent-budget pipeline (`desiredBudgets`,
`resolveSharedLegs`, `cornerDragBounds`) used by both 2D and 3D alignments.

For standard corners (`tanHalf > 0`), `solveCornerParams` solves `pullback(R) = budget`
with 52-step fixed-count bracketed bisection, splitting the search bracket at the
design-speed cap radius `R_cap = maxDesignSpeed² / maxLateralAccel`. For 3D
reverse-winding loops (`tanHalf ≤ 0`), it isolates the legacy 4-step fixed-point fallback.

This module has no `Vec3`, `Segment`, or Mathlib dependency so it stays shared across 2D
and 3D code and compilable to C over `RFloat`.
-/

/-- Number of fixed bisection iterations used to solve for the circular arc radius.

Fifty-two iterations shrink the bracket width by `2^52`, matching IEEE-754 double-precision
mantissa accuracy without depending on a floating-point termination test. -/
def bisectionSteps : Nat := 52

/-- Speed and comfort limits that size operating speed and clothoid transition length.

Each corner runs at the fastest operating speed its circular arc allows under the
lateral-acceleration limit, capped at the design speed: `V = min(maxDesignSpeed, √(a_max·R))`.
Entry and exit clothoids are sized to the shortest length that keeps both lateral jerk
and yaw angular acceleration within limits: `Ls = max(V³/(R·j_max), V²/(R·α_max))`.

Units use 1 scene unit = 1 metre (`maxLateralAccel` in m/s², `maxLateralJerk` in m/s³,
`maxYawAccel` in rad/s², `maxDesignSpeed` in m/s). Setting `maxLateralAccel ≤ 0` disables
the speed model and yields pure circular fillets with no transitions. -/
structure SpeedModel (α : Type) where
  /-- Maximum lateral acceleration tolerated on a circular arc (m/s²).
      Fixes corner operating speed via `V = √(a_max·R)`; values `≤ 0` disable the speed
      model and produce pure circular fillets. -/
  maxLateralAccel : α
  /-- Maximum lateral jerk tolerated on a clothoid transition (m/s³).
      Imposes `Ls ≥ V³/(R·j_max)`; values `≤ 0` disable this criterion. -/
  maxLateralJerk : α
  /-- Maximum yaw angular acceleration tolerated on a clothoid transition (rad/s²).
      Imposes `Ls ≥ V²/(R·α_max)`; values `≤ 0` disable this criterion. -/
  maxYawAccel : α
  /-- Maximum design operating speed (m/s).
      Caps corner operating speed via `V = min(maxDesignSpeed, √(a_max·R))` and sets the
      speed on straights; values `≤ 0` leave speed uncapped. -/
  maxDesignSpeed : α

/-- Layout policy controlling automatic corner budgets and minimum radius enforcement.

Separates polyline-level corner sizing from the speed model and collinearity threshold. -/
structure LayoutPolicy (α : Type) where
  /-- Fraction (at most 0.5) of the shorter adjacent leg used as a corner's automatic budget.
      Corners adjacent to path endpoints take all remaining room instead. -/
  legBudget : α
  /-- Minimum permitted circular arc radius in world units (1 unit = 1 m).
      A corner's tangent budget is floored at the pullback needed to reach this radius,
      capped to available leg room; values `≤ 0` disable the floor. -/
  minRadius : α

/-- Scalar geometric and speed parameters of a solved corner.

Produced by `solveCornerParams` and passed directly to 2D and 3D corner segment builders
so segment construction does not depend on `SpeedModel`. -/
structure CornerParams (α : Type) where
  /-- Fitted unsigned circular arc radius. -/
  radius : α
  /-- Clothoid spiral turn angle `θs = Ls / (2R)` on each side (`0` for a pure circular arc). -/
  spiralAngle : α
  /-- Arc length `Ls = 2·R·θs` of each symmetric clothoid transition (`0` for a pure arc). -/
  spiralLength : α
  /-- Central turn angle `φ = Δ - 2·θs` of the circular arc (`≥ 0`). -/
  arcAngle : α
  /-- Design operating speed for the corner (`0` when the speed model is disabled). -/
  opSpeed : α

/-- Compute the operating speed on a circular arc of radius `R`.

Returns `0` when the speed model is disabled or `R ≤ 0`; otherwise returns
`√(maxLateralAccel · R)`, capped at `maxDesignSpeed` when positive. -/
def SpeedModel.speedAt [TrackScalar α] (sm : SpeedModel α) (R : α) : α :=
  if sm.maxLateralAccel ≤ 0 ∨ R ≤ 0 then 0
  else
    let v := TrackScalar.sqrt (sm.maxLateralAccel * R)
    if sm.maxDesignSpeed > 0 then min sm.maxDesignSpeed v else v

/-- Compute the required clothoid transition length on an arc of radius `R`.

Returns the larger of the jerk-limited and yaw-acceleration-limited lengths at
`sm.speedAt R`, or `0` when the speed model is disabled or `R ≤ 0`. -/
def SpeedModel.transitionLength [TrackScalar α] (sm : SpeedModel α) (R : α) : α :=
  if sm.maxLateralAccel ≤ 0 ∨ R ≤ 0 then 0
  else
    let V := sm.speedAt R
    let lsJerk := if sm.maxLateralJerk > 0 then (V * V * V) / (R * sm.maxLateralJerk) else 0
    let lsYaw  := if sm.maxYawAccel   > 0 then (V * V)     / (R * sm.maxYawAccel)  else 0
    max lsJerk lsYaw

/-- Compute the spiral turn angle `θs = Ls / (2R)` for deflection `delta` and radius `R`.

Clamps the angle to `delta / 2` so the remaining circular arc angle stays non-negative,
and returns `0` when the speed model is disabled or `R ≤ 0`. -/
def SpeedModel.spiralAngle [TrackScalar α] (sm : SpeedModel α) (R delta : α) : α :=
  if sm.maxLateralAccel ≤ 0 ∨ R ≤ 0 then 0
  else
    let two : α := natToScalar 2
    min (sm.transitionLength R / (two * R)) (delta / two)

/-- Compute the tangent pullback consumed by a corner of arc radius `R`.

Returns `0` when `R ≤ 0`. For `R > 0`, returns `R · tanHalf` when no transition is needed
and `R · ((1 + P) · tanHalf + K)` otherwise, where `(P, K)` is the unit clothoid shift at
`sm.spiralAngle R delta`. -/
def SpeedModel.pullback [TrackScalar α] (sm : SpeedModel α) (tanHalf delta R : α) : α :=
  if R ≤ 0 then 0
  else
    let θ := if sm.maxLateralAccel ≤ 0 then 0 else sm.spiralAngle R delta
    if θ ≤ 0 then R * tanHalf
    else
      let (P, K) := clothoidShift θ
      R * ((1 + P) * tanHalf + K)

/-- Compute the minimum tangent budget needed to achieve an arc radius of `lp.minRadius`.

Returns `0` when `lp.minRadius ≤ 0`. Accounts for the clothoid transitions demanded by `sm`
at `lp.minRadius` and takes magnitudes so reverse-winding loops with negative `tanHalf`
still produce a non-negative budget. -/
def radiusFloorBudget [TrackScalar α] (lp : LayoutPolicy α) (sm : SpeedModel α)
    (tanHalf delta : α) : α :=
  let R := lp.minRadius
  if R ≤ 0 then 0
  else
    let θ := if sm.maxLateralAccel ≤ 0 then 0 else sm.spiralAngle R delta
    if θ ≤ 0 then R * absScalar tanHalf
    else
      let (P, K) := clothoidShift θ
      R * absScalar ((1 + P) * tanHalf + K)

/-- Perform one step of bracketed bisection for `f R = target` on `[lo, hi]`.

Evaluates `f` at the midpoint `(lo + hi) / 2` and keeps the half-interval that preserves
`f lo ≤ target ≤ f hi`. -/
def bisectStep [TrackScalar α] (f : α → α) (target lo hi : α) : α × α :=
  let mid := (lo + hi) / natToScalar 2
  if f mid ≤ target then (mid, hi) else (lo, mid)

/-- Run `n` fixed iterations of bracketed bisection for `f R = target` on `[lo, hi]`.

Returns the narrowed bracket `(lo', hi')` of width `(hi - lo) / 2^n`. -/
def bisect [TrackScalar α] (f : α → α) (target : α) : Nat → α → α → α × α
  | 0, lo, hi => (lo, hi)
  | n + 1, lo, hi =>
    let (lo', hi') := bisectStep f target lo hi
    bisect f target n lo' hi'

/-- Solve scalar corner parameters for a standard corner (`tanHalf > 0`) by bisection.

Computes the pure-fillet radius `R_fillet = budget / tanHalf`, splits the initial search
bracket at `R_cap = maxDesignSpeed² / maxLateralAccel` when a design-speed ceiling is
active (`[0, min R_cap R_fillet]` if `pullback(R_cap) ≥ budget`, otherwise
`[R_cap, R_fillet]`), and runs `bisectionSteps` (52) fixed bisection iterations. -/
def solveCornerParamsBisect [TrackScalar α] (budget tanHalf delta : α)
    (sm : SpeedModel α) : CornerParams α :=
  let two : α := natToScalar 2
  if sm.maxLateralAccel ≤ 0 then
    let R := budget / tanHalf
    { radius := R, spiralAngle := 0, spiralLength := 0, arcAngle := delta, opSpeed := 0 }
  else if budget ≤ 0 then
    { radius := 0, spiralAngle := 0, spiralLength := 0, arcAngle := delta, opSpeed := 0 }
  else
    let rFillet := budget / tanHalf
    let pb := sm.pullback tanHalf delta
    let (lo₀, hi₀) : α × α :=
      if sm.maxDesignSpeed > 0 then
        let rCap := sm.maxDesignSpeed * sm.maxDesignSpeed / sm.maxLateralAccel
        if pb rCap ≥ budget then
          (0, min rCap rFillet)
        else
          (rCap, rFillet)
      else
        (0, rFillet)
    let (lo, hi) := bisect pb budget bisectionSteps lo₀ hi₀
    let R := (lo + hi) / two
    let θs := sm.spiralAngle R delta
    let opSpeed := sm.speedAt R
    if θs ≤ 0 then
      { radius := R, spiralAngle := 0, spiralLength := 0, arcAngle := delta, opSpeed := opSpeed }
    else
      let Ls := two * R * θs
      let φ := delta - two * θs
      { radius := R, spiralAngle := θs, spiralLength := Ls, arcAngle := φ, opSpeed := opSpeed }

/-- Solve scalar corner parameters for a 3D reverse-winding loop (`tanHalf ≤ 0`) via the
legacy fixed-point fallback.

Seeds from the pure-fillet radius and runs four fixed-point iterations coupling spiral
angle and radius through the clothoid shift. -/
def solveCornerParamsReverseFallback [TrackScalar α] (budget tanHalf delta : α)
    (sm : SpeedModel α) (straightThreshold : α) : CornerParams α :=
  let two : α := natToScalar 2
  let safeDenom := fun (x : α) =>
    let ax := absScalar x
    if ax ≤ straightThreshold then straightThreshold else ax
  let radiusOf := fun (θ : α) =>
    let (P, K) := clothoidShift θ
    budget / safeDenom ((1 + P) * tanHalf + K)
  let θs :=
    if sm.maxLateralAccel ≤ 0 then 0
    else Id.run do
      let mut R := budget / safeDenom tanHalf
      let mut θ := sm.spiralAngle R delta
      for _ in [0:4] do
        if θ > 0 then
          R := radiusOf θ
          θ := sm.spiralAngle R delta
      return θ
  if θs ≤ 0 then
    let R := budget / safeDenom tanHalf
    let opSpeed := if sm.maxLateralAccel > 0 then sm.speedAt R else 0
    { radius := R, spiralAngle := 0, spiralLength := 0, arcAngle := delta, opSpeed := opSpeed }
  else
    let R := radiusOf θs
    let opSpeed := sm.speedAt R
    let Ls := two * R * θs
    let φ := delta - two * θs
    { radius := R, spiralAngle := θs, spiralLength := Ls, arcAngle := φ, opSpeed := opSpeed }

/-- Solve the scalar radius, transition geometry, arc sweep, and operating speed of a corner.

For standard corners (`tanHalf > 0`), solves `pullback(R) = budget` via 52-step fixed-count
bracketed bisection with the `R_cap` regime split. For 3D reverse-winding loops
(`tanHalf ≤ 0`), delegates to the isolated fixed-point fallback. -/
def solveCornerParams [TrackScalar α] (budget tanHalf delta : α)
    (sm : SpeedModel α) (straightThreshold : α) : CornerParams α :=
  if tanHalf > 0 then
    solveCornerParamsBisect budget tanHalf delta sm
  else
    solveCornerParamsReverseFallback budget tanHalf delta sm straightThreshold

/-- Scalar per-corner bounds supplied to the PI tangent-budget allocation stages.

Captures the two scalar facts each curving corner contributes to budget allocation,
independent of 2D or 3D coordinates. -/
structure CornerBudgetSpec (α : Type) where
  /-- Length of the shorter adjacent leg, which is the corner's standalone maximum budget. -/
  shorterLeg : α
  /-- Minimum tangent budget required to satisfy the minimum-radius floor, before clamping
      to available leg room. -/
  floorBudget : α

/-- Allowed tangent-budget range for interactively dragging a corner's UI bracket.

Produced by `cornerDragBounds` so path construction does not compute UI drag-room limits. -/
structure DragBounds (α : Type) where
  /-- Lower bound on the dragged budget, given by the minimum-radius floor capped to
      `maxBudget`. -/
  minBudget : α
  /-- Upper bound on the dragged budget, given by the room neighbouring corners leave on
      both adjacent legs. -/
  maxBudget : α

/-- Test whether PI `i` in an `n`-point polyline is an auto-sized end corner.

An interior corner adjacent to either polyline endpoint with no manual override expands
into all remaining room on its legs and shrinks down to its floor when its neighbour grows. -/
private def isAutoEndCorner (n i : Nat) (overrides : Array (Option α)) : Bool :=
  (i = 1 ∨ i + 2 = n) ∧ ((overrides[i]?).bind id).isNone

/-- Compute each PI's desired tangent budget before shared-leg conflict resolution.

Each curving corner starts from its manual override or `lp.legBudget * shorterLeg`, clamped
to its own standalone `[min floorBudget shorterLeg, shorterLeg]` range. An auto-sized end
corner (adjacent to either polyline endpoint with no override) instead asks for all room
left on both legs by its neighbour's base ask, clamped to the same standalone range.
Returns an array indexed like `corners` with `none` at non-curving PIs. -/
def desiredBudgets [TrackScalar α] (legLengths : Array α)
    (corners : Array (Option (CornerBudgetSpec α)))
    (lp : LayoutPolicy α) (overrides : Array (Option α) := #[]) :
    Array (Option α) :=
  let n := corners.size
  let cornerAt := fun i => (corners[i]?).bind id
  let legLen := fun (k : Nat) => legLengths.getD k 0
  let clampAsk := fun (c : CornerBudgetSpec α) (cand : α) =>
    let lo := min c.floorBudget c.shorterLeg
    max lo (min c.shorterLeg cand)
  -- What each corner asks before auto-sized end corners expand into remaining room.
  let base : Array α := (Array.range n).map fun i =>
    match cornerAt i with
    | none => 0
    | some c => clampAsk c (((overrides[i]?).bind id).getD (lp.legBudget * c.shorterLeg))
  -- Room on leg `k` (whose far end is PI `j`) left by the neighbour's base ask.
  let free := fun (j k : Nat) =>
    if (cornerAt j).isSome then legLen k - base.getD j 0 else legLen k
  (Array.range n).map fun i =>
    match cornerAt i with
    | none => none
    | some c =>
        if isAutoEndCorner n i overrides then
          some (clampAsk c (min (free (i - 1) (i - 1)) (free (i + 1) i)))
        else
          some (base.getD i 0)

/-- Resolve desired corner budgets across shared legs so adjacent curves never overlap.

On a leg whose far end does not curve, a corner takes up to the full leg length. On a leg
shared by two curving corners, both keep their desired budget when their sum fits in the
leg; otherwise the leg is split proportionally (`len * ai / (ai + aj)`). Each corner
receives the lesser of its two adjacent legs' shares. -/
def resolveSharedLegs [TrackScalar α] (legLengths : Array α)
    (asks : Array (Option α)) : Array (Option α) :=
  let n := asks.size
  let askAt := fun i => (asks[i]?).bind id
  let legLen := fun (k : Nat) => legLengths.getD k 0
  -- What a corner asking `ai` may take of leg `k`, whose far end is PI `j`.
  let share := fun (ai : α) (j k : Nat) =>
    let len := legLen k
    match askAt j with
    | some aj => if ai + aj ≤ len then ai else len * ai / (ai + aj)
    | none => min ai len
  (Array.range n).map fun i =>
    match askAt i with
    | none => none
    | some ai => some (min (share ai (i - 1) (i - 1)) (share ai (i + 1) i))

/-- Compute the interactive bracket-drag budget limits `[minBudget, maxBudget]` for each PI.

For each curving corner, `maxBudget` is the lesser of the rooms left on its two adjacent
legs after subtracting the neighbouring corner's resolved budget — or, for an auto-sized
end corner, its standalone minimum-radius floor so widening a neighbour can shrink it.
`minBudget` is the corner's minimum-radius floor capped to `maxBudget`. -/
def cornerDragBounds [TrackScalar α] (legLengths : Array α)
    (corners : Array (Option (CornerBudgetSpec α)))
    (budgets : Array (Option α))
    (overrides : Array (Option α) := #[]) :
    Array (Option (DragBounds α)) :=
  let n := corners.size
  let cornerAt := fun i => (corners[i]?).bind id
  let budgetAt := fun i => ((budgets[i]?).bind id).getD 0
  let legLen := fun (k : Nat) => legLengths.getD k 0
  -- An auto-sized end corner can shrink to its floor, so it leaves room down to that.
  let room := fun (j k : Nat) =>
    match cornerAt j with
    | none => legLen k
    | some c =>
        let used :=
          if isAutoEndCorner n j overrides then min c.floorBudget c.shorterLeg
          else budgetAt j
        legLen k - used
  (Array.range n).map fun i =>
    match cornerAt i with
    | none => none
    | some c =>
        let hi := min (room (i - 1) (i - 1)) (room (i + 1) i)
        let lo := min c.floorBudget hi
        some { minBudget := lo, maxBudget := hi }
