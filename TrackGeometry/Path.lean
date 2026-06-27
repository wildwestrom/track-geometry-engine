import TrackGeometry.Vec
import TrackGeometry.Segment

/-! # PI construction and alignment paths

`AnySegment`, `AlignmentPath`, corner solve, and `buildPath`.
-/

/-! ## PI-based (Point of Intersection) construction

The user places PIs — vertices of a tangent polyline. The alignment runs straight
along the legs and rounds each *interior* corner with a circular arc tangent to both
legs. The first and last PI are true endpoints (on the alignment); interior PIs are
cut (the arc misses them).

Radius is not supplied. Each corner gets a tangent *budget* — a fraction of the
shorter adjacent leg. Since the tangent pullback is `T = R·tan(Δ/2)`, the radius is
whatever fits the budget: `R = T / tan(Δ/2)`. Sharp corners get a small radius,
gentle corners a large one; near-straight corners are skipped entirely.

This produces an `AlignmentPath`: a flat array of type-correct segments with the
join continuity erased. Each piece carries its operating speed from the design model. -/

/-- A single geometry piece with its curvature indices hidden, so heterogeneous
    segments can share one array. `opSpeed` is the design operating speed (scene-units/s)
    for the piece — from `solveCorner` on curves, design-speed ceiling on straights. -/
structure AnySegment (α : Type) where
  cA : Curvature α
  cB : Curvature α
  seg : Segment α cA cB
  opSpeed : α

/-- Wrap a segment, inferring its curvature indices. `opSpeed` defaults to `0` when
    the scalar has `Zero` (unset → UI falls back to design-speed ceiling). -/
def AnySegment.of {α : Type} [Zero α] {cA cB : Curvature α} (s : Segment α cA cB)
    (opSpeed : α := 0) : AnySegment α :=
  ⟨cA, cB, s, opSpeed⟩

/-- Arc-length of the underlying segment. -/
def AnySegment.length [TrackScalar α] (e : AnySegment α) : α := e.seg.length

/-- Sample the underlying segment at local arc-length `t`. -/
def AnySegment.pointAt [TrackScalar α] (e : AnySegment α) (t : α) : Vec3 α := e.seg.pointAt t

/-- Sample the underlying segment's point and RMF at local arc-length `t`,
    propagated from incoming frame `fr` (see `Segment.frameAt`). -/
def AnySegment.frameAt [TrackScalar α] (e : AnySegment α) (fr : Frame α) (t : α) : Vec3 α × Frame α :=
  e.seg.frameAt fr t

/-- Advance `fr` past this segment (the propagation seed for the next segment). -/
def AnySegment.endFrame [TrackScalar α] (e : AnySegment α) (fr : Frame α) : Frame α :=
  e.seg.endFrame fr

/-- RMF at local arc-length `t` from a pre-aligned frame `fr`.
    The caller must pre-compute `fr.alignTo (normalize e.seg.startDir)` once per segment. -/
def AnySegment.rmfAt [TrackScalar α] (e : AnySegment α) (fr : Frame α) (t : α) : Frame α :=
  e.seg.rmfAt fr t

/-- Curvature magnitude at local arc-length `t` (see `Segment.curvatureAt`). -/
def AnySegment.curvatureAt [TrackScalar α] (e : AnySegment α) (t : α) : α :=
  e.seg.curvatureAt t

/-- Unit tangent at local arc-length `t` (see `Segment.tangentAt`). -/
def AnySegment.tangentAt [TrackScalar α] (e : AnySegment α) (t : α) : Vec3 α :=
  e.seg.tangentAt t

/-- A flat sequence of geometry pieces (straights and arcs), join continuity erased. -/
structure AlignmentPath (α : Type) where
  segments : Array (AnySegment α)

/-- Total arc-length: sum of the piece lengths. -/
def AlignmentPath.length [TrackScalar α] (path : AlignmentPath α) : α :=
  path.segments.foldl (fun acc e => acc + e.length) 0

/-- Walk pieces to global arc-length `s` and sample with `f` at the local parameter.
    `none` if out of range (same bounds as `pointAt`). -/
def AlignmentPath.sampleAt [TrackScalar α]
    (f : AnySegment α → α → β) (path : AlignmentPath α) (s : α) : Option β :=
  if s < 0 then none
  else
    let rec go (segs : List (AnySegment α)) (t : α) : Option β :=
      match segs with
      | [] => none
      | e :: rest =>
        let len := e.length
        if t ≤ len then some (f e t) else go rest (t - len)
    go path.segments.toList s

/-- Sample at global arc-length `s`, walking the pieces. `none` if out of range. -/
def AlignmentPath.pointAt [TrackScalar α] (path : AlignmentPath α) (s : α) : Option (Vec3 α) :=
  path.sampleAt (fun e t => e.pointAt t) s

/-- Curvature magnitude `κ(s)` at global arc-length `s` (`none` if out of range).
    Uses each piece's closed-form `curvatureAt` (unsigned; turn sense is in the plane binormal). -/
def AlignmentPath.curvatureAt [TrackScalar α] (path : AlignmentPath α) (s : α) : Option α :=
  path.sampleAt (fun e t => e.curvatureAt t) s

/-- The seed frame for the first segment, or `none` for an empty path. -/
def AlignmentPath.startFrame [TrackScalar α] (path : AlignmentPath α) : Option (Frame α) :=
  path.segments[0]?.map fun e => Frame.fromTangent e.seg.startDir

/-- Sample the point and RMF at global arc-length `s`, threading the frame from `fr₀`
    (defaults to the path's start frame). `none` if out of range. -/
def AlignmentPath.frameAt [TrackScalar α] (path : AlignmentPath α) (s : α)
    (fr₀ : Option (Frame α) := none) : Option (Vec3 α × Frame α) :=
  if s < 0 then none
  else
    let initFr : Frame α := match fr₀ with
      | some f => f
      | none => match path.segments[0]? with
        | some e => Frame.fromTangent e.seg.startDir
        | none => Frame.fromTangent (Vec3.mk 1 0 0)
    let rec go (segs : List (AnySegment α)) (t : α) (fr : Frame α) :
        Option (Vec3 α × Frame α) :=
      match segs with
      | [] => none
      | e :: rest =>
        let len := e.length
        if t ≤ len then some (e.frameAt fr t)
        else go rest (t - len) (e.endFrame fr)
    go path.segments.toList s initFr

/-- Design parameters for auto-radius PI construction.

    Transition length is the *minimum* spiral that keeps the ride within comfort
    limits. Each corner runs at its own
    operating speed `V = √(a_max·R)` (the fastest the circular arc allows under the
    lateral-acceleration limit), and the clothoid is then made just long enough to
    cap both lateral jerk and yaw (heading) angular acceleration:

      `Ls = max( V³/(R·j_max), V²/(R·α_max) )`.

    Units are interpreted with **1 scene unit = 1 metre** (so `a_max` is m/s²,
    `j_max` m/s³, `α_max` rad/s²). Setting `maxLateralAccel ≤ 0` switches the speed
    model off and recovers the pure circular fillet (no transitions). -/
structure DesignParams (α : Type) where
  /-- Fraction (≤ 0.5) of the shorter adjacent leg a single corner may consume. -/
  legBudget : α
  /-- Minimum permitted arc radius (world units; 1 unit = 1 m). No corner is rounded —
      or resized — tighter than this: the tangent budget is floored at `minRadius ·
      tan(Δ/2)`, the pullback that yields exactly this radius. A corner too sharp or
      whose legs are too short to reach it is rounded as gently as the legs allow
      (budget capped at half the shorter leg). Roughly an AREMA-style absolute floor for
      sharp standard-gauge (yard / industrial) track. `≤ 0` disables the floor. -/
  minRadius : α
  /-- Corners whose `|sin Δ|` is below this are treated as straight (no arc). -/
  straightThreshold : α
  /-- Maximum lateral (centripetal) acceleration tolerated on the circular arc.
      Fixes each corner's operating speed via `V = √(a_max·R)`. `≤ 0` disables the
      speed model, recovering a pure straight→arc→straight corner. -/
  maxLateralAccel : α
  /-- Maximum lateral jerk (rate of change of lateral acceleration) on the
      transition. Imposes `Ls ≥ V³/(R·j_max)`. `≤ 0` drops this criterion. -/
  maxLateralJerk : α
  /-- Maximum yaw angular acceleration (rate of change of heading rate) on the
      transition. Imposes `Ls ≥ V²/(R·α_max)`. `≤ 0` drops this criterion. -/
  maxYawAccel : α
  /-- Design-speed ceiling. Operating speed is capped, `V = min(maxDesignSpeed,
      √(a_max·R))`, so large-radius curves that *could* exceed it don't get oversized
      transitions, and straights run at this speed. `≤ 0` leaves the speed uncapped. -/
  maxDesignSpeed : α

/-- Directional and angular facts for one interior PI, independent of any chosen
    tangent budget. `none` means the corner is degenerate or near-straight. -/
structure CornerGeometry (α : Type) where
  /-- Unit direction along the incoming leg, pointing into the PI. -/
  uIn : Vec3 α
  /-- Unit direction along the outgoing leg, pointing away from the PI. -/
  uOut : Vec3 α
  /-- Unit binormal of the corner's plane, oriented so the curve turns *left* about it
      (i.e. rotating `uIn` toward `uOut` by the selected turn is a positive rotation about
      `binormal`). For a planar `z=0` corner this is `+ẑ` on a left turn and `−ẑ` on a
      right turn. -/
  binormal : Vec3 α
  /-- Signed `sin Δ` of the principal deflection; positive for a left turn. -/
  sinSigned : α
  /-- `cos Δ`. -/
  cosDelta : α
  /-- Signed total turn angle selected for this corner. Nonzero windings add full
      revolutions, allowing looped spiral-arc-spiral corners. -/
  turn : α
  /-- `tan(Δ₀/2)` of the *principal* deflection (always positive). Independent of
      winding: a wound corner sweeps the same fillet circle through extra revolutions. -/
  tanHalf : α
  /-- Unsigned selected turn angle `Δ`. -/
  delta : α
  /-- Shorter adjacent leg length. -/
  shorterLeg : α
  /-- Maximum tangent budget: half the shorter adjacent leg. -/
  maxBudget : α
  /-- Minimum tangent budget implied by `DesignParams.minRadius`, capped to `maxBudget`. -/
  minBudget : α

/-- Compute shared corner geometry for an interior PI. This is the common source for
    path construction and UI curve-end controls, so straight/degenerate detection and
    min/max budget bounds stay aligned. -/
def cornerGeometry [TrackScalar α] (a b c : Vec3 α) (dp : DesignParams α)
    (winding : Int := 0) :
    Option (CornerGeometry α) :=
  let dIn := b - a
  let dOut := c - b
  let nIn := Vec3.norm dIn
  let nOut := Vec3.norm dOut
  if nIn = 0 ∨ nOut = 0 then none
  else
    let uIn := (1 / nIn) • dIn
    let uOut := (1 / nOut) • dOut
    let sinSigned := Vec3.crossZ uIn uOut
    -- True |sin Δ| of the deflection, `‖uIn × uOut‖` — rotation-invariant, so a corner in
    -- a steep/tilted plane (where the `ẑ`-component `crossZ` is small) is not misread as
    -- straight. For planar `z=0` corners it equals `|crossZ|`.
    let sinAbs := Vec3.norm (Vec3.cross uIn uOut)
    let cosD := max (-1) (min 1 (Vec3.dot uIn uOut))
    let two : α := natToScalar 2
    let fullTurn := two * TrackScalar.pi
    let minor := TrackScalar.arccos cosD
    let principal := if sinSigned < 0 then -minor else minor
    let selected :=
      if sinAbs ≤ dp.straightThreshold then
        if winding = 0 then 0 else intToScalar winding * fullTurn
      else
        principal + intToScalar winding * fullTurn
    let delta := absScalar selected
    if delta ≤ dp.straightThreshold then none
    else
      let shorter := min nIn nOut
      let hi := (1 / two) * shorter
      -- `tan(Δ/2)` of the *selected* (possibly wound) turn. For a reflex turn
      -- (Δ ∈ (π, 2π), i.e. a reverse-winding loop) this is negative; that sign is
      -- exactly what flips the `K` term of the clothoid shift in the radius fit, so we
      -- keep it signed and let the consumers `absScalar` it where a magnitude is wanted.
      let cosT := TrackScalar.cos delta
      let tanHalf := TrackScalar.sin delta / (1 + cosT)
      let radiusFloorBudget := dp.minRadius * absScalar tanHalf
      let lo := min radiusFloorBudget hi
      -- Unit binormal of the corner's plane, oriented so a *positive* rotation about it
      -- carries `uIn` toward `uOut` along the selected turn. The geometric normal
      -- `uIn × uOut` already does this for the principal (minor) deflection; when the
      -- selected turn winds onto the opposite side (reflex / reverse loop) we flip it.
      -- For collinear legs (a wound loop on a straight) there is no leg-plane, so use
      -- `±ẑ` according to the turn sense.
      let cr := Vec3.cross uIn uOut
      let crNorm := Vec3.norm cr
      let binormal : Vec3 α :=
        if crNorm ≤ dp.straightThreshold then
          if selected > 0 then Vec3.mk 0 0 1 else Vec3.mk 0 0 (-1)
        else
          let nHat := (1 / crNorm) • cr
          let reversed := decide (selected > 0) != decide (sinSigned > 0)
          if reversed then (-(1 : α)) • nHat else nHat
      some { uIn := uIn, uOut := uOut, binormal := binormal, sinSigned := sinSigned,
             cosDelta := cosD, turn := selected, tanHalf := tanHalf, delta := delta,
             shorterLeg := shorter, maxBudget := hi, minBudget := lo }

/-- Whether the selected turn winds onto the *opposite* side from the principal
    deflection — a reverse-winding loop. When set, the corner is tangent to the legs on
    their extension rays (ahead of the PI on the entry leg, behind it on the exit leg)
    rather than the minor-fillet rays, so the tangent points flip sign. -/
def CornerGeometry.reversed [TrackScalar α] (g : CornerGeometry α) : Bool :=
  decide (g.turn > 0) != decide (g.sinSigned > 0)

/-- The entry tangent point (start of the curved run) for budget `budget` at PI `b`. -/
def CornerGeometry.entryPoint [TrackScalar α] (g : CornerGeometry α) (b : Vec3 α)
    (budget : α) : Vec3 α :=
  if g.reversed then b + budget • g.uIn else b - budget • g.uIn

/-- The exit tangent point (end of the curved run) for budget `budget` at PI `b`. -/
def CornerGeometry.exitTangentPoint [TrackScalar α] (g : CornerGeometry α) (b : Vec3 α)
    (budget : α) : Vec3 α :=
  if g.reversed then b - budget • g.uOut else b + budget • g.uOut

/-- A corner geometry plus the clamped tangent budget and its two tangent points. -/
structure CornerLayout (α : Type) extends CornerGeometry α where
  /-- The chosen tangent budget after override/default selection and clamping. -/
  budget : α
  /-- Where the straight leading into the corner ends. -/
  entryPoint : Vec3 α
  /-- Where the straight leaving the corner begins. -/
  exitPoint : Vec3 α

/-- Select and clamp the tangent budget for an interior PI, returning the tangent
    endpoints that consume that budget. An override is an absolute world-unit budget;
    `none` uses `dp.legBudget * shorter adjacent leg`. -/
def cornerLayout [TrackScalar α] (a b c : Vec3 α) (dp : DesignParams α)
    (override : Option α := none) (winding : Int := 0) : Option (CornerLayout α) :=
  match cornerGeometry a b c dp winding with
  | none => none
  | some g =>
      let cand := match override with
        | some o => o
        | none => dp.legBudget * g.shorterLeg
      let budget := max g.minBudget (min g.maxBudget cand)
      some { toCornerGeometry := g, budget := budget,
             entryPoint := g.entryPoint b budget, exitPoint := g.exitTangentPoint b budget }

/-- A solved corner at one interior PI: where the incoming straight ends
    (`entryPoint`), where the outgoing straight resumes (`exitPoint`), and the curved
    `pieces` between them (a circular arc, optionally bracketed by entry/exit clothoids). -/
structure CornerSolution (α : Type) where
  /-- Where the straight leading into the corner ends (start of the first piece). -/
  entryPoint : Vec3 α
  /-- Where the straight leaving the corner begins (end of the last piece). -/
  exitPoint : Vec3 α
  /-- Curved geometry through the corner, in order. -/
  pieces : Array (AnySegment α)
  /-- Operating speed this corner is designed for, `V = √(a_max·R)` from the fitted
      radius (`0` when the speed model is disabled). The transition lengths are the
      minimum that hold this speed within the jerk/yaw limits. -/
  opSpeed : α
  /-- The fitted (unsigned) arc radius — handy for speed restrictions / labels. -/
  radius : α

/-- Solve a non-degenerate corner from precomputed shared corner geometry. -/
def solveCornerWithGeometry [TrackScalar α] (b : Vec3 α) (budget : α)
    (dp : DesignParams α) (g : CornerGeometry α) : CornerSolution α :=
  let uIn := g.uIn
  let two : α := natToScalar 2
  -- Binormal of the corner's plane; all in-plane rotations and curvatures are about it,
  -- with unsigned magnitudes. Handedness (left/right, reflex windings) lives entirely in
  -- `B`'s orientation.
  -- Read its components into scalars once: used as the (cheap) axis of every in-plane
  -- rotation, so nested rotations stay shallow (see `rotateAxisC`).
  let B := g.binormal
  let bx := B 0; let bYc := B 1; let bz := B 2
  -- The selected turn is "reversed" when it winds onto the opposite side from the
  -- principal deflection (e.g. a right-going loop on a left corner). The minor fillet
  -- is tangent at `b - budget·uIn` / `b + budget·uOut`; the reverse arc is tangent to
  -- the same legs but on their *extension* rays, so the tangent bases flip sign.
  let entryBase := g.entryPoint b budget
  let exitBase  := g.exitTangentPoint b budget
  let tanHalf := g.tanHalf
  let safeDenom := fun (x : α) =>
    let ax := absScalar x
    if ax ≤ dp.straightThreshold then dp.straightThreshold else ax
  let Δ := g.delta
  -- Speed-derived spiral. Each corner runs at `V = √(a_max·R)`; the clothoid is
  -- the shortest that holds that speed within the jerk and yaw-accel limits. `θs`
  -- and `R` are mutually dependent, so we fixed-point from the pure-fillet radius.
  let aMax := dp.maxLateralAccel
  let cap := dp.maxDesignSpeed
  -- Operating speed at fitted radius `R`: the arc's `√(a_max·R)`, capped at the
  -- design speed (so over-fast curves don't get oversized transitions).
  let speedAt := fun (R : α) =>
    let v := TrackScalar.sqrt (aMax * R)
    if cap > 0 then min cap v else v
  -- Transition length demanded at fitted radius `R` (the max of the two criteria).
  let lsOf := fun (R : α) =>
    let V := speedAt R
    let lsJerk := if dp.maxLateralJerk > 0 then (V * V * V) / (R * dp.maxLateralJerk) else 0
    let lsYaw  := if dp.maxYawAccel   > 0 then (V * V)     / (R * dp.maxYawAccel)  else 0
    max lsJerk lsYaw
  -- Fitted radius for spiral angle `θ > 0` (unit-clothoid shift `(P, K)` at angle θ).
  let radiusOf := fun (θ : α) =>
    let Ls1 := two * θ
    let (X1, Y1) := clothoidOffset 0 (1 / Ls1) Ls1 clothoidPanels
    let P := Y1 - (1 - TrackScalar.cos θ)
    let K := X1 - TrackScalar.sin θ
    budget / safeDenom ((1 + P) * tanHalf + K)
  -- One step: radius → spiral angle `θs = Ls/(2R)`, clamped so an arc remains.
  let stepθ := fun (R : α) => min (lsOf R / (two * R)) (Δ / two)
  let θs :=
    if aMax ≤ 0 then 0
    else Id.run do
      let mut R := budget / safeDenom tanHalf -- seed: pure-fillet radius where available
      let mut θ := stepθ R
      for _ in [0:4] do
        if θ > 0 then
          R := radiusOf θ
          θ := stepθ R
      return θ
  if θs ≤ 0 then
    -- No transitions: classic circular fillet (straight → arc → straight).
    let absR := budget / safeDenom tanHalf
    let pc := entryBase
    let pt := exitBase
    let opSpeed := if aMax > 0 then speedAt absR else 0
    { entryPoint := pc, exitPoint := pt, opSpeed := opSpeed, radius := absR,
      pieces := #[AnySegment.of (Segment.arc absR pc pt uIn B (some Δ)) opSpeed] }
  else
    -- Symmetric spiral corner: fit the radius to the budget at the converged spiral angle.
    let absR := radiusOf θs
    let opSpeed := speedAt absR
    let Ls := two * absR * θs
    -- In-plane rotations use the scalar binormal `(bx,by,bz)` as a cheap axis, so the
    -- stored tangents stay shallow (cf. `rotateAxisC`); `sc` and the arc end are already
    -- scalar-assembled by `clothoidPoint`/`circleCenter`.
    let ts := entryBase                              -- entry tangent→spiral point
    let sc := clothoidPoint ts uIn 0 (1 / absR) Ls Ls B -- entry spiral end = arc start
    let tanSC := Vec3.rotateAxisC bx bYc bz θs uIn    -- tangent at sc
    let φ := Δ - two * θs                            -- circular arc central angle (≥ 0)
    let o := circleCenter sc tanSC absR B            -- arc center
    let cs := o + Vec3.rotateAxisC bx bYc bz φ (sc - o) -- arc end = exit spiral start
    let tanCS := Vec3.rotateAxisC bx bYc bz φ tanSC   -- tangent at cs
    let entrySeg := AnySegment.of
      (Segment.transitionIn (radius := absR) (startPt := ts) (startTangent := uIn)
        (binormal := B) (length := Ls)) opSpeed
    let exitSeg := AnySegment.of
      (Segment.transitionOut (radius := absR) (startPt := cs) (startTangent := tanCS)
        (binormal := B) (length := Ls)) opSpeed
    let pieces :=
      if φ ≤ dp.straightThreshold then #[entrySeg, exitSeg]
      else #[entrySeg, AnySegment.of (Segment.arc absR sc cs tanSC B (some φ)) opSpeed, exitSeg]
    { entryPoint := ts, exitPoint := exitSeg.pointAt Ls, pieces := pieces,
      opSpeed := opSpeed, radius := absR }

/-- Solve the corner at interior PI `b`, between prev PI `a` and next PI `c`, consuming
    `budget` of tangent length along each leg. Returns `none` when the legs are (near)
    collinear — the corner is straight and contributes nothing.

    With `dp.maxLateralAccel ≤ 0` this is the classic circular fillet: the tangent
    points sit `budget` back from `b` along each leg and `R = budget / tan(Δ/2)`, so the
    arc is exactly tangent to both legs.

    Otherwise the corner is the standard symmetric spiral: an entry clothoid, a circular
    arc, and an exit clothoid. The spiral angle `θs = Ls/(2R)` is speed-derived. The
    corner's operating speed is the fastest its arc
    allows, `V = √(a_max·R)`, and the transition is the shortest clothoid that keeps the
    ride within the comfort limits:

      `Ls = max( V³/(R·j_max), V²/(R·α_max) )`   (jerk- and yaw-acceleration-limited).

    This couples `θs` to `R`: the radius is fitted to the budget via the clothoid shift,
    `R = budget / ((1+P)·tan(Δ/2) + K)` with `(P, K)` from a unit clothoid of angle `θs`,
    while `θs` depends on `R` through `Ls`. Because `P, K` are tiny for realistic
    spirals, a short fixed-point iteration (seeded from the pure-fillet radius) converges
    to float precision. `θs` is clamped to `Δ/2` so a non-negative circular arc remains;
    very sharp corners saturate at a full-spiral corner (and then exceed the nominal
    jerk, the geometric price of a corner too tight for its speed). -/
def solveCorner [TrackScalar α] (a b c : Vec3 α) (budget : α) (dp : DesignParams α) :
    Option (CornerSolution α) :=
  match cornerGeometry a b c dp with
  | none => none
  | some g => some (solveCornerWithGeometry b budget dp g)

/-- Build an `AlignmentPath` from a polyline of PIs.

    The first and last PIs are endpoints. Each interior PI is rounded with a circular
    arc whose radius fits a tangent budget = `legBudget × (shorter adjacent leg)`.
    Near-collinear corners pass straight through.

    `overrides` optionally supplies a per-PI tangent budget (absolute world units) that
    replaces the auto `legBudget` value at that corner. Each override is clamped to
    `(0, ½ · shorter adjacent leg]` so a dragged control point can never cross the PI or
    overrun a leg. An out-of-range index or a `none` falls back to the auto budget. -/
def buildPath [TrackScalar α] (pts : Array (Vec3 α)) (dp : DesignParams α)
    (overrides : Array (Option α) := #[]) (windings : Array Int := #[]) :
    AlignmentPath α :=
  let n := pts.size
  if n < 2 then ⟨#[]⟩
  else
    let z : Vec3 α := Vec3.mk 0 0 0
    let get := fun i => (pts[i]?).getD z
    -- Straights run at the design-speed ceiling when set; otherwise leave `opSpeed = 0`
    -- (UI treats 0 as "unrestricted" and falls back to the same ceiling).
    let straightSpeed := if dp.maxDesignSpeed > 0 then dp.maxDesignSpeed else 0
    let out : Array (AnySegment α) := Id.run do
      let mut acc : Array (AnySegment α) := #[]
      let mut cursor : Vec3 α := get 0
      for i in [1 : n - 1] do
        let a := get (i - 1)
        let b := get i
        let c := get (i + 1)
        match cornerLayout a b c dp ((overrides[i]?).bind id) ((windings[i]?).getD 0) with
        | none => pure ()
        | some layout =>
          let sol := solveCornerWithGeometry b layout.budget dp layout.toCornerGeometry
          acc := acc.push (AnySegment.of (Segment.straight cursor sol.entryPoint) straightSpeed)
          for piece in sol.pieces do
            acc := acc.push piece
          cursor := sol.exitPoint
      acc := acc.push (AnySegment.of (Segment.straight cursor (get (n - 1))) straightSpeed)
      return acc
    ⟨out⟩
