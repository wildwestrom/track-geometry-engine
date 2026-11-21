import TrackGeometry.Design
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
  /-- `tan(Δ/2)` of the selected (possibly wound) turn. Positive for standard turns and
      negative for reflex reverse-winding loops. -/
  tanHalf : α
  /-- Unsigned selected turn angle `Δ`. -/
  delta : α
  /-- Shorter adjacent leg length. -/
  shorterLeg : α
  /-- Minimum tangent budget required to satisfy `minRadius`, before clamping to leg room. -/
  floorBudget : α

/-- Extract the scalar budget specification needed by `desiredBudgets` and `cornerDragBounds`. -/
def CornerGeometry.budgetSpec (g : CornerGeometry α) : CornerBudgetSpec α :=
  { shorterLeg := g.shorterLeg, floorBudget := g.floorBudget }

/-- Compute shared corner geometry for an interior PI. This is the common source for
    path construction and UI curve-end controls, so straight/degenerate detection and
    minimum-radius floors stay aligned. -/
def cornerGeometry [TrackScalar α] (a b c : Vec3 α)
    (lp : LayoutPolicy α) (sm : SpeedModel α) (straightThreshold : α)
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
      if sinAbs ≤ straightThreshold then
        if winding = 0 then 0 else intToScalar winding * fullTurn
      else
        principal + intToScalar winding * fullTurn
    let delta := absScalar selected
    if delta ≤ straightThreshold then none
    else
      let shorter := min nIn nOut
      -- `tan(Δ/2)` of the *selected* (possibly wound) turn. For a reflex turn
      -- (Δ ∈ (π, 2π), i.e. a reverse-winding loop) this is negative; that sign is
      -- exactly what flips the `K` term of the clothoid shift in the radius fit, so we
      -- keep it signed and let the consumers `absScalar` it where a magnitude is wanted.
      let cosT := TrackScalar.cos delta
      let tanHalf := TrackScalar.sin delta / (1 + cosT)
      let floor := radiusFloorBudget lp sm tanHalf delta
      -- Unit binormal of the corner's plane, oriented so a *positive* rotation about it
      -- carries `uIn` toward `uOut` along the selected turn. The geometric normal
      -- `uIn × uOut` already does this for the principal (minor) deflection; when the
      -- selected turn winds onto the opposite side (reflex / reverse loop) we flip it.
      -- For collinear legs (a wound loop on a straight) there is no leg-plane, so use
      -- `±ẑ` according to the turn sense.
      let cr := Vec3.cross uIn uOut
      let crNorm := Vec3.norm cr
      let binormal : Vec3 α :=
        if crNorm ≤ straightThreshold then
          if selected > 0 then Vec3.mk 0 0 1 else Vec3.mk 0 0 (-1)
        else
          let nHat := (1 / crNorm) • cr
          let reversed := decide (selected > 0) != decide (sinSigned > 0)
          if reversed then (-(1 : α)) • nHat else nHat
      some { uIn := uIn, uOut := uOut, binormal := binormal, sinSigned := sinSigned,
             cosDelta := cosD, turn := selected, tanHalf := tanHalf, delta := delta,
             shorterLeg := shorter, floorBudget := floor }

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
    `none` uses `lp.legBudget * shorter adjacent leg`. This sees the corner alone; on a
    path, `cornerLayouts` also keeps it clear of its neighbours. -/
def cornerLayout [TrackScalar α] (a b c : Vec3 α)
    (lp : LayoutPolicy α) (sm : SpeedModel α) (straightThreshold : α)
    (override : Option α := none) (winding : Int := 0) : Option (CornerLayout α) :=
  match cornerGeometry a b c lp sm straightThreshold winding with
  | none => none
  | some g =>
      let cand := match override with
        | some o => o
        | none => lp.legBudget * g.shorterLeg
      let lo := min g.floorBudget g.shorterLeg
      let budget := max lo (min g.shorterLeg cand)
      some { toCornerGeometry := g, budget := budget,
             entryPoint := g.entryPoint b budget, exitPoint := g.exitTangentPoint b budget }

/-- Compute the Euclidean length of each leg (`k` from PI `k` to PI `k + 1`) of a 3D polyline. -/
def polylineLegLengths [TrackScalar α] (pts : Array (Vec3 α)) : Array α :=
  let n := pts.size
  let z : Vec3 α := Vec3.mk 0 0 0
  let get := fun i => (pts[i]?).getD z
  (Array.range (n - 1)).map fun k => Vec3.norm (get (k + 1) - get k)

/-- Resolve the corners of a 3D PI polyline by composing `desiredBudgets` and `resolveSharedLegs`.

Indexed like `pts` (`none` at the two endpoints and at interior PIs that do not curve).
Each curving corner's desired budget is computed by `desiredBudgets` and reconciled across
shared legs by `resolveSharedLegs` so adjacent curves never overlap. UI bracket-drag limits
are computed separately by `cornerDragBounds` when needed by the UI. -/
def cornerLayouts [TrackScalar α] (pts : Array (Vec3 α))
    (lp : LayoutPolicy α) (sm : SpeedModel α) (straightThreshold : α)
    (overrides : Array (Option α) := #[]) (windings : Array Int := #[]) :
    Array (Option (CornerLayout α)) :=
  let n := pts.size
  let z : Vec3 α := Vec3.mk 0 0 0
  let get := fun i => (pts[i]?).getD z
  let legLengths := polylineLegLengths pts
  let geoms : Array (Option (CornerGeometry α)) := (Array.range n).map fun i =>
    if 1 ≤ i ∧ i + 1 < n then
      cornerGeometry (get (i - 1)) (get i) (get (i + 1)) lp sm straightThreshold
        ((windings[i]?).getD 0)
    else none
  let specs : Array (Option (CornerBudgetSpec α)) := geoms.map (·.map CornerGeometry.budgetSpec)
  let asks := desiredBudgets legLengths specs lp overrides
  let budgets := resolveSharedLegs legLengths asks
  (Array.range n).map fun i =>
    match (geoms[i]?).bind id, (budgets[i]?).bind id with
    | some g, some bud =>
        let b := get i
        some { toCornerGeometry := g, budget := bud,
               entryPoint := g.entryPoint b bud, exitPoint := g.exitTangentPoint b bud }
    | _, _ => none

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

/-- Construct the 3D segments for a corner from solved scalar `CornerParams` and
precomputed `CornerGeometry`, without depending on `SpeedModel`. -/
def buildCorner3D [TrackScalar α] (b : Vec3 α) (budget : α)
    (g : CornerGeometry α) (cp : CornerParams α) (straightThreshold : α) :
    CornerSolution α :=
  let uIn := g.uIn
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
  if cp.spiralAngle ≤ 0 then
    -- No transitions: classic circular fillet (straight → arc → straight).
    let absR := cp.radius
    let pc := entryBase
    let arcSeg := Segment.arc absR pc uIn B cp.arcAngle
    let pt := arcSeg.pointAt arcSeg.length
    { entryPoint := pc, exitPoint := pt, opSpeed := cp.opSpeed, radius := absR,
      pieces := #[AnySegment.of arcSeg cp.opSpeed] }
  else
    -- Symmetric spiral corner: entry clothoid, optional circular arc, exit clothoid.
    let absR := cp.radius
    let θs := cp.spiralAngle
    let Ls := cp.spiralLength
    let φ := cp.arcAngle
    let opSpeed := cp.opSpeed
    -- In-plane rotations use the scalar binormal `(bx,by,bz)` as a cheap axis, so the
    -- stored tangents stay shallow (cf. `rotateAxisC`); `sc` and `cs` are already
    -- scalar-assembled by `clothoidPoint` and `Segment.pointAt`.
    let ts := entryBase                              -- entry tangent→spiral point
    let sc := clothoidPoint ts uIn 0 (1 / absR) Ls Ls B -- entry spiral end = arc start
    let tanSC := Vec3.rotateAxisC bx bYc bz θs uIn    -- tangent at sc
    let arcSeg := Segment.arc absR sc tanSC B φ
    let cs := arcSeg.pointAt arcSeg.length           -- arc end = exit spiral start
    let tanCS := Vec3.rotateAxisC bx bYc bz φ tanSC   -- tangent at cs
    let entrySeg := AnySegment.of
      (Segment.transitionIn (radius := absR) (startPt := ts) (startTangent := uIn)
        (binormal := B) (length := Ls)) opSpeed
    let exitSeg := AnySegment.of
      (Segment.transitionOut (radius := absR) (startPt := cs) (startTangent := tanCS)
        (binormal := B) (length := Ls)) opSpeed
    let pieces :=
      if φ ≤ straightThreshold then #[entrySeg, exitSeg]
      else #[entrySeg, AnySegment.of arcSeg opSpeed, exitSeg]
    { entryPoint := ts, exitPoint := exitSeg.pointAt Ls, pieces := pieces,
      opSpeed := opSpeed, radius := absR }

/-- Solve a non-degenerate corner from precomputed shared corner geometry by delegating
scalar parameter solving to `solveCornerParams` and 3D segment assembly to `buildCorner3D`. -/
def solveCornerWithGeometry [TrackScalar α] (b : Vec3 α) (budget : α)
    (sm : SpeedModel α) (straightThreshold : α) (g : CornerGeometry α) : CornerSolution α :=
  let cp := solveCornerParams budget g.tanHalf g.delta sm straightThreshold
  buildCorner3D b budget g cp straightThreshold

/-- Solve the corner at interior PI `b`, between prev PI `a` and next PI `c`, consuming
    `budget` of tangent length along each leg. Returns `none` when the legs are (near)
    collinear — the corner is straight and contributes nothing.

    With `sm.maxLateralAccel ≤ 0` this is the classic circular fillet: the tangent
    points sit `budget` back from `b` along each leg and `R = budget / tan(Δ/2)`, so the
    arc is exactly tangent to both legs.

    Otherwise the corner is the standard symmetric spiral: an entry clothoid, a circular
    arc, and an exit clothoid whose scalar parameters are solved by `solveCornerParams`
    (52-step bracketed bisection for `tanHalf > 0`, fixed-point fallback for 3D reverse
    loops) and assembled in 3D by `buildCorner3D`. -/
def solveCorner [TrackScalar α] (a b c : Vec3 α) (budget : α)
    (lp : LayoutPolicy α) (sm : SpeedModel α) (straightThreshold : α) :
    Option (CornerSolution α) :=
  match cornerGeometry a b c lp sm straightThreshold with
  | none => none
  | some g => some (solveCornerWithGeometry b budget sm straightThreshold g)

/-- Build an `AlignmentPath` from a polyline of PIs.

    The first and last PIs are endpoints. Each interior PI is rounded with a circular
    arc whose radius fits a tangent budget: `lp.legBudget × (shorter adjacent leg)`, or all the
    room it has at the first and last corners (see `cornerLayouts`). Near-collinear corners
    pass straight through.

    `overrides` optionally supplies a per-PI tangent budget (absolute world units) that
    replaces the auto value at that corner. The budgets are resolved by
    `cornerLayouts`, so a dragged control point can never cross the PI, overrun a leg or
    overlap the neighbouring curve. An out-of-range index or a `none` falls back to the
    auto budget. -/
def buildPath [TrackScalar α] (pts : Array (Vec3 α))
    (lp : LayoutPolicy α) (sm : SpeedModel α) (straightThreshold : α)
    (overrides : Array (Option α) := #[]) (windings : Array Int := #[]) :
    AlignmentPath α :=
  let n := pts.size
  if n < 2 then ⟨#[]⟩
  else
    let z : Vec3 α := Vec3.mk 0 0 0
    let get := fun i => (pts[i]?).getD z
    -- Straights run at the design-speed ceiling when set; otherwise leave `opSpeed = 0`
    -- (UI treats 0 as "unrestricted" and falls back to the same ceiling).
    let straightSpeed := if sm.maxDesignSpeed > 0 then sm.maxDesignSpeed else 0
    let layouts := cornerLayouts pts lp sm straightThreshold overrides windings
    let out : Array (AnySegment α) := Id.run do
      let mut acc : Array (AnySegment α) := #[]
      let mut cursor : Vec3 α := get 0
      for i in [1 : n - 1] do
        let b := get i
        match (layouts[i]?).bind id with
        | none => pure ()
        | some layout =>
          let sol := solveCornerWithGeometry b layout.budget sm straightThreshold layout.toCornerGeometry
          acc := acc.push (AnySegment.of (Segment.straight cursor sol.entryPoint) straightSpeed)
          for piece in sol.pieces do
            acc := acc.push piece
          cursor := sol.exitPoint
      acc := acc.push (AnySegment.of (Segment.straight cursor (get (n - 1))) straightSpeed)
      return acc
    ⟨out⟩
