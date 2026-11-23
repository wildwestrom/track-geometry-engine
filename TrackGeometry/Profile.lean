import TrackGeometry.Design

set_option linter.missingDocs true

/-! # 1D vertical alignment (Profile)

Standalone 1D vertical alignment core built on `TrackScalar` and `TrackGeometry.Design`:

* `PVI` — vertical point of intersection (station and elevation)
* `ProfileSegment` — constant-grade tangents (`grade`) and symmetric quadratic vertical curves
  (`parabola`), with local-offset elevation, grade, and curvature queries
* `ProfilePath` — ordered sequence of vertical segments with global-station elevation, grade,
  and curvature queries
* `ProfilePolicy` — vertical design limits controlling curve radius sizing
* `buildProfile` — PVI-based 1D vertical profile builder reusing `resolveSharedLegs`

This module carries no Mathlib dependency so it stays compilable to C over `RFloat` and directly
usable in `ℝ` proofs.
-/

/-- A vertical point of intersection defining a break in grade along a profile. -/
structure PVI (α : Type) where
  /-- Horizontal distance coordinate along the alignment. -/
  station : α
  /-- Vertical height at this point of intersection. -/
  elevation : α

/-- A single piece of a vertical alignment profile, either a constant grade or a vertical parabola. -/
inductive ProfileSegment (α : Type) where
  /-- A straight tangent segment of constant slope starting at a given station and elevation. -/
  | grade (startStation length startElevation grade : α)
  /-- A symmetric quadratic vertical curve smoothly transitioning from an entry grade to an exit grade. -/
  | parabola (startStation length startElevation startGrade endGrade : α)

/-- Starting horizontal station of a vertical segment. -/
def ProfileSegment.startStation (seg : ProfileSegment α) : α :=
  match seg with
  | .grade s₀ _ _ _ => s₀
  | .parabola s₀ _ _ _ _ => s₀

/-- Horizontal length of a vertical segment. -/
def ProfileSegment.length (seg : ProfileSegment α) : α :=
  match seg with
  | .grade _ len _ _ => len
  | .parabola _ len _ _ _ => len

/-- Ending horizontal station of a vertical segment. -/
def ProfileSegment.endStation [TrackScalar α] (seg : ProfileSegment α) : α :=
  seg.startStation + seg.length

/-- Elevation at a local horizontal offset from the start of a vertical segment. -/
def ProfileSegment.elevationAt [TrackScalar α] (seg : ProfileSegment α) (u : α) : α :=
  match seg with
  | .grade _ _ z₀ g => z₀ + g * u
  | .parabola _ len z₀ g₁ g₂ =>
    z₀ + g₁ * u + (g₂ - g₁) / (natToScalar 2 * len) * (u * u)

/-- Longitudinal slope at a local horizontal offset from the start of a vertical segment. -/
def ProfileSegment.gradeAt [TrackScalar α] (seg : ProfileSegment α) (u : α) : α :=
  match seg with
  | .grade _ _ _ g => g
  | .parabola _ len _ g₁ g₂ => g₁ + (g₂ - g₁) / len * u

/-- Signed rate of grade change at a local horizontal offset from the start of a vertical segment, negative on crests and positive on sags. -/
def ProfileSegment.curvatureAt [TrackScalar α] (seg : ProfileSegment α) (_u : α) : α :=
  match seg with
  | .grade _ _ _ _ => 0
  | .parabola _ len _ g₁ g₂ => (g₂ - g₁) / len

/-- An ordered sequence of vertical alignment segments forming a continuous profile. -/
structure ProfilePath (α : Type) where
  /-- The ordered vertical segments making up the profile. -/
  segments : Array (ProfileSegment α)

/-- Total horizontal length of a vertical profile. -/
def ProfilePath.length [TrackScalar α] (path : ProfilePath α) : α :=
  path.segments.foldl (fun acc seg => acc + seg.length) 0

/-- Evaluate a segment query at a given global station along a vertical profile, or none if out of range. -/
def ProfilePath.sampleAt [TrackScalar α]
    (f : ProfileSegment α → α → β) (path : ProfilePath α) (s : α) : Option β :=
  path.segments.toList.findSome? fun seg =>
    if seg.startStation ≤ s ∧ s ≤ seg.endStation then
      some (f seg (s - seg.startStation))
    else
      none

/-- Elevation along a vertical profile at a given global station, or none if out of range. -/
def ProfilePath.elevationAt [TrackScalar α] (path : ProfilePath α) (s : α) : Option α :=
  path.sampleAt (fun seg u => seg.elevationAt u) s

/-- Longitudinal slope along a vertical profile at a given global station, or none if out of range. -/
def ProfilePath.gradeAt [TrackScalar α] (path : ProfilePath α) (s : α) : Option α :=
  path.sampleAt (fun seg u => seg.gradeAt u) s

/-- Signed rate of grade change along a vertical profile at a given global station, negative on crests and positive on sags, or none if out of range. -/
def ProfilePath.curvatureAt [TrackScalar α] (path : ProfilePath α) (s : α) : Option α :=
  path.sampleAt (fun seg u => seg.curvatureAt u) s

/-- Vertical design policy governing the radius of parabolic vertical curves.

Deliberately omits a near-collinear grade threshold: only an exact zero grade change passes
straight through without a vertical curve. -/
structure ProfilePolicy (α : Type) where
  /-- Maximum vertical acceleration tolerated on a vertical curve in metres per second squared.

  Values less than or equal to zero disable the speed-based radius formula and fall back to the
  minimum vertical radius. -/
  maxVerticalAccel : α
  /-- Track top or design speed in metres per second, used as the default speed at each point of
  intersection and as an upper cap on per-point speeds when positive. -/
  designSpeed : α
  /-- Minimum permitted vertical curve radius in metres.

  Floors the speed-based radius `V² / maxVerticalAccel`; values less than or equal to zero
  disable the floor. -/
  minVerticalRadius : α

/-- Unsigned target vertical curve radius in metres for a given speed.

Computes `max policy.minVerticalRadius (speed * speed / policy.maxVerticalAccel)` when
`policy.maxVerticalAccel > 0` and `speed > 0`, falling back to `policy.minVerticalRadius`
otherwise. Values less than or equal to zero disable vertical curves; crest versus sag direction
is determined by the sign of the grade change rather than the sign of this radius. -/
def ProfilePolicy.verticalRadius [TrackScalar α] (policy : ProfilePolicy α) (speed : α) : α :=
  if policy.maxVerticalAccel > 0 ∧ speed > 0 then
    max policy.minVerticalRadius (speed * speed / policy.maxVerticalAccel)
  else
    policy.minVerticalRadius

/-- Filter points of intersection to keep only strictly increasing stations with their optional speeds. -/
def filterIncreasingPVIs [TrackScalar α] (pvis : Array (PVI α))
    (pviSpeeds : Array (Option α)) : Array (PVI α × Option α) :=
  let rec go (i : Nat) (acc : Array (PVI α × Option α)) : Array (PVI α × Option α) :=
    if hi : i < pvis.size then
      let p := pvis[i]
      let spd := (pviSpeeds[i]?).bind id
      let keep :=
        match acc.back? with
        | none => true
        | some (last, _) => last.station < p.station
      go (i + 1) (if keep then acc.push (p, spd) else acc)
    else
      acc
  termination_by pvis.size - i
  go 0 #[]

/-- Return the positive tangent half-length allocated to a point of intersection, or zero if none. -/
def budgetHalfLen [TrackScalar α] (budgets : Array (Option α)) (i : Nat) : α :=
  match (budgets[i]?).bind id with
  | some t => if t > 0 then t else 0
  | none => 0

/-- Build a vertical profile from ordered points of intersection and a vertical design policy.

Non-increasing points of intersection (`station ≤ lastKept.station`) are filtered out up front
before building legs so no zero- or negative-length legs are emitted. Fewer than two remaining
points of intersection yield an empty profile. Endpoints have free grades (callers snapping to
existing track insert a guide point of intersection). Each interior point of intersection is
rounded with a symmetric parabolic curve whose radius is `policy.verticalRadius V` (using the
optional per-point speed capped at `designSpeed` when provided and `designSpeed` otherwise).
When the resulting radius is non-positive (`R_v ≤ 0`) or the adjacent grades are equal
(`g_out = g_in`), the profile passes sharply through the point of intersection with no parabola.
Overlapping curves on shared legs are shrunk proportionally via `resolveSharedLegs`, with no
automatic expansion of end corners. Manual tangent-length overrides and grade-change thresholds
are deliberately omitted from the core specification. -/
def buildProfile [TrackScalar α] (pvis : Array (PVI α)) (policy : ProfilePolicy α)
    (pviSpeeds : Array (Option α) := #[]) : ProfilePath α :=
  let kept := filterIncreasingPVIs pvis pviSpeeds
  let n := kept.size
  if n < 2 then ⟨#[]⟩
  else
    let zeroPVI : PVI α := ⟨0, 0⟩
    let pviAt (i : Nat) : PVI α := (kept[i]?).map Prod.fst |>.getD zeroPVI
    let speedAt (i : Nat) : Option α := (kept[i]?).bind Prod.snd
    let legLengths : Array α := (Array.range (n - 1)).map fun k =>
      (pviAt (k + 1)).station - (pviAt k).station
    let grades : Array α := (Array.range (n - 1)).map fun k =>
      let a := pviAt k
      let b := pviAt (k + 1)
      (b.elevation - a.elevation) / (b.station - a.station)
    let two : α := natToScalar 2
    let asks : Array (Option α) := (Array.range n).map fun i =>
      if 1 ≤ i ∧ i + 1 < n then
        let gIn := grades.getD (i - 1) 0
        let gOut := grades.getD i 0
        let effSpeed :=
          match speedAt i with
          | some v => if policy.designSpeed > 0 then min v policy.designSpeed else v
          | none => policy.designSpeed
        let rV := policy.verticalRadius effSpeed
        if gOut = gIn ∨ rV ≤ 0 then none
        else some (rV * absScalar (gOut - gIn) / two)
      else
        none
    let budgets := resolveSharedLegs legLengths asks
    let rec emit (k : Nat) (acc : Array (ProfileSegment α)) : Array (ProfileSegment α) :=
      if k + 1 < n then
        let a := pviAt k
        let b := pviAt (k + 1)
        let g := grades.getD k 0
        let tStart := budgetHalfLen budgets k
        let tEnd := budgetHalfLen budgets (k + 1)
        let sStart := a.station + tStart
        let sEnd := b.station - tEnd
        let gradeLen := sEnd - sStart
        let acc :=
          if 0 < gradeLen then
            acc.push (.grade sStart gradeLen (a.elevation + g * tStart) g)
          else
            acc
        let acc :=
          if k + 2 < n ∧ 0 < tEnd then
            let gNext := grades.getD (k + 1) 0
            acc.push (.parabola (b.station - tEnd) (two * tEnd) (b.elevation - g * tEnd) g gNext)
          else
            acc
        emit (k + 1) acc
      else
        acc
    termination_by n - k
    ⟨emit 0 #[]⟩
