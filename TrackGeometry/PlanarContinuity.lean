import TrackGeometry.Real
import Mathlib.Analysis.SpecialFunctions.Trigonometric.Deriv

/-! # 2D within-corner geometric continuity proofs

Machine-checked guarantees over `ℝ` that 2D horizontal spiral corners constructed by
`buildCorner2D` (`TrackGeometry.Planar`) satisfy:

* Axiom-free exact arc-length derivative (`HasDerivAt`) and G⁰ endpoint closure for analytic
  2D circular arcs (`Segment2D.arc`).
* G⁰ positional endpoint sharing, G¹ tangent continuity, and G² (unsigned and signed)
  curvature continuity across every internal junction of a 2D spiral corner:
  `straight → transitionIn → arc → transitionOut → straight` as well as the saturated arcless
  `straight → transitionIn → transitionOut → straight` case.

Every theorem in this module is proven directly over `ℝ` without any extra axioms; in
particular, this module does not import or depend on `clothoidOffset_eq_exact`.
-/

namespace TrackGeometry.PlanarContinuity

open scoped Real

/-! ## 0. Instance-bridge simp lemmas -/

@[simp] private lemma trackScalar_cos_real (x : ℝ) : TrackScalar.cos x = Real.cos x := rfl
@[simp] private lemma trackScalar_sin_real (x : ℝ) : TrackScalar.sin x = Real.sin x := rfl
@[simp] private lemma trackScalar_sqrt_real (x : ℝ) : TrackScalar.sqrt x = Real.sqrt x := rfl
@[simp] private lemma natToScalar_two_real : (natToScalar 2 : ℝ) = 2 := by
  norm_num [natToScalar]

/-! ## 1. 2D vector and rotation algebra -/

private lemma vec2_ext {v w : Vec2 ℝ} (hx : v.x = w.x) (hy : v.y = w.y) : v = w := by
  cases v; cases w; simp only [Vec2.mk.injEq]; exact ⟨hx, hy⟩

@[simp] private lemma vec2_add_x (v w : Vec2 ℝ) : (v + w).x = v.x + w.x := rfl
@[simp] private lemma vec2_add_y (v w : Vec2 ℝ) : (v + w).y = v.y + w.y := rfl
@[simp] private lemma vec2_sub_x (v w : Vec2 ℝ) : (v - w).x = v.x - w.x := rfl
@[simp] private lemma vec2_sub_y (v w : Vec2 ℝ) : (v - w).y = v.y - w.y := rfl
@[simp] private lemma vec2_neg_x (v : Vec2 ℝ) : (-v).x = -v.x := rfl
@[simp] private lemma vec2_neg_y (v : Vec2 ℝ) : (-v).y = -v.y := rfl
@[simp] private lemma vec2_smul_x (r : ℝ) (v : Vec2 ℝ) : (r • v).x = r * v.x := rfl
@[simp] private lemma vec2_smul_y (r : ℝ) (v : Vec2 ℝ) : (r • v).y = r * v.y := rfl
@[simp] private lemma vec2_perp_x (v : Vec2 ℝ) : v.perp.x = -v.y := rfl
@[simp] private lemma vec2_perp_y (v : Vec2 ℝ) : v.perp.y = v.x := rfl

private lemma vec2_rotate_zero (v : Vec2 ℝ) : Vec2.rotate 0 v = v := by
  apply vec2_ext <;> simp [Vec2.rotate, Real.cos_zero, Real.sin_zero]

private lemma vec2_rotate_add (φ ψ : ℝ) (v : Vec2 ℝ) :
    Vec2.rotate (φ + ψ) v = Vec2.rotate φ (Vec2.rotate ψ v) := by
  apply vec2_ext <;>
    · simp only [Vec2.rotate, trackScalar_cos_real, trackScalar_sin_real,
        Real.cos_add, Real.sin_add]
      ring

private lemma vec2_rotate_normSq (φ : ℝ) (v : Vec2 ℝ) :
    Vec2.normSq (Vec2.rotate φ v) = Vec2.normSq v := by
  simp only [Vec2.normSq, Vec2.dot, Vec2.rotate, trackScalar_cos_real, trackScalar_sin_real]
  linear_combination (v.x * v.x + v.y * v.y) * Real.sin_sq_add_cos_sq φ

private lemma turnDir_rotate_zero (dir : TurnDir) (v : Vec2 ℝ) :
    dir.rotate 0 v = v := by
  simp [TurnDir.rotate, vec2_rotate_zero]

private lemma turnDir_rotate_add (dir : TurnDir) (φ ψ : ℝ) (v : Vec2 ℝ) :
    dir.rotate (φ + ψ) v = dir.rotate φ (dir.rotate ψ v) := by
  simp only [TurnDir.rotate, mul_add]
  exact vec2_rotate_add (dir.sign * φ) (dir.sign * ψ) v

private lemma turnDir_rotate_normSq (dir : TurnDir) (φ : ℝ) (v : Vec2 ℝ) :
    Vec2.normSq (dir.rotate φ v) = Vec2.normSq v :=
  vec2_rotate_normSq (dir.sign * φ) v

private lemma turnDir_rotate_eq_lincomb (dir : TurnDir) (θ : ℝ) (v : Vec2 ℝ) :
    dir.rotate θ v = Real.cos θ • v + Real.sin θ • dir.normal v := by
  cases dir
  · apply vec2_ext <;>
      · simp only [TurnDir.rotate, TurnDir.sign, TurnDir.normal, Vec2.rotate,
          trackScalar_cos_real, trackScalar_sin_real, vec2_add_x, vec2_add_y,
          vec2_smul_x, vec2_smul_y, vec2_perp_x, vec2_perp_y, one_mul]
        ring
  · apply vec2_ext <;>
      · simp only [TurnDir.rotate, TurnDir.sign, TurnDir.normal, Vec2.rotate,
          trackScalar_cos_real, trackScalar_sin_real, vec2_add_x, vec2_add_y,
          vec2_smul_x, vec2_smul_y, vec2_neg_x, vec2_neg_y, vec2_perp_x, vec2_perp_y,
          neg_mul, one_mul, Real.cos_neg, Real.sin_neg]
        ring

private lemma turnDir_normal_normal (dir : TurnDir) (v : Vec2 ℝ) :
    dir.normal (dir.normal v) = -v := by
  cases dir <;> apply vec2_ext <;> simp [TurnDir.normal]

private lemma vec2_normalize_eq_self {v : Vec2 ℝ} (h : Vec2.normSq v = 1) :
    Vec2.normalize v = v := by
  unfold Vec2.normalize
  rw [h]
  simp only [one_ne_zero, ↓reduceIte, trackScalar_sqrt_real, Real.sqrt_one, div_one]
  apply vec2_ext <;> simp

private lemma vec2_normalize_smul_pos {d : ℝ} {u : Vec2 ℝ}
    (hd : 0 < d) (hu : Vec2.normSq u = 1) :
    Vec2.normalize (d • u) = u := by
  have hnsq : Vec2.normSq (d • u) = d ^ 2 := by
    have hu' : u.x * u.x + u.y * u.y = 1 := hu
    simp only [Vec2.normSq, Vec2.dot, vec2_smul_x, vec2_smul_y]
    linear_combination d ^ 2 * hu'
  have hne : d ^ 2 ≠ 0 := pow_ne_zero 2 (ne_of_gt hd)
  unfold Vec2.normalize
  rw [hnsq]
  simp only [hne, ↓reduceIte, trackScalar_sqrt_real, Real.sqrt_sq (le_of_lt hd)]
  apply vec2_ext <;>
    · simp only [vec2_smul_x, vec2_smul_y]
      field_simp [ne_of_gt hd]

/-! ## 2. Analytic 2D circular arc continuity (axiom-free)

`Segment2D.arc` evaluates positions analytically via `sin` and `cos` in the local
`(v̂, dir.normal v̂)` frame. Its exact derivative (`HasDerivAt` matching `Segment2D.tangentAt`)
and G⁰ start/end closure are proven directly over `ℝ` without any quadrature axiom. -/

/-- Center of a 2D circular arc of radius `r` starting at `p` with tangent `v` and turn
handedness `dir`. -/
noncomputable def circleCenter2D (p v : Vec2 ℝ) (r : ℝ) (dir : TurnDir) : Vec2 ℝ :=
  p + r • dir.normal (Vec2.normalize v)

private lemma arc2D_pointAt_x (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (sw opSpeed t : ℝ) :
    ((Segment2D.arc r p v dir sw opSpeed).pointAt t).x
      = p.x + (r * Real.sin (t / r)) * (Vec2.normalize v).x
          + (r * (1 - Real.cos (t / r))) * (dir.normal (Vec2.normalize v)).x := rfl

private lemma arc2D_pointAt_y (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (sw opSpeed t : ℝ) :
    ((Segment2D.arc r p v dir sw opSpeed).pointAt t).y
      = p.y + (r * Real.sin (t / r)) * (Vec2.normalize v).y
          + (r * (1 - Real.cos (t / r))) * (dir.normal (Vec2.normalize v)).y := rfl

/-- The arc-length derivative of the X coordinate of a 2D analytic circular arc matches the
X coordinate of `Segment2D.tangentAt`. -/
theorem hasDerivAt_arc2D_pointAt_x (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (sw opSpeed t : ℝ)
    (hr : r ≠ 0) :
    HasDerivAt (fun s => ((Segment2D.arc r p v dir sw opSpeed).pointAt s).x)
      (((Segment2D.arc r p v dir sw opSpeed).tangentAt t).x) t := by
  have hθ : HasDerivAt (fun s : ℝ => s / r) (1 / r) t := by
    simpa using (hasDerivAt_id t).div_const r
  have hsin : HasDerivAt (fun s : ℝ => r * Real.sin (s / r)) (Real.cos (t / r)) t := by
    have h := ((Real.hasDerivAt_sin (t / r)).comp t hθ).const_mul r
    have heq : r * (Real.cos (t / r) * (1 / r)) = Real.cos (t / r) := by field_simp
    rwa [heq] at h
  have hcos : HasDerivAt (fun s : ℝ => r * (1 - Real.cos (s / r))) (Real.sin (t / r)) t := by
    have h := (((Real.hasDerivAt_cos (t / r)).comp t hθ).const_sub 1).const_mul r
    have heq : r * -(-Real.sin (t / r) * (1 / r)) = Real.sin (t / r) := by field_simp
    rwa [heq] at h
  have hpos :
      HasDerivAt
        (fun s =>
          p.x + (r * Real.sin (s / r)) * (Vec2.normalize v).x
              + (r * (1 - Real.cos (s / r))) * (dir.normal (Vec2.normalize v)).x)
        (Real.cos (t / r) * (Vec2.normalize v).x
          + Real.sin (t / r) * (dir.normal (Vec2.normalize v)).x) t :=
    ((hsin.mul_const (Vec2.normalize v).x).const_add p.x).add
      (hcos.mul_const (dir.normal (Vec2.normalize v)).x)
  have htan :
      ((Segment2D.arc r p v dir sw opSpeed).tangentAt t).x
        = Real.cos (t / r) * (Vec2.normalize v).x
          + Real.sin (t / r) * (dir.normal (Vec2.normalize v)).x := by
    change (dir.rotate (t / r) (Vec2.normalize v)).x = _
    rw [turnDir_rotate_eq_lincomb]
    rfl
  rw [htan]
  exact hpos

/-- The arc-length derivative of the Y coordinate of a 2D analytic circular arc matches the
Y coordinate of `Segment2D.tangentAt`. -/
theorem hasDerivAt_arc2D_pointAt_y (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (sw opSpeed t : ℝ)
    (hr : r ≠ 0) :
    HasDerivAt (fun s => ((Segment2D.arc r p v dir sw opSpeed).pointAt s).y)
      (((Segment2D.arc r p v dir sw opSpeed).tangentAt t).y) t := by
  have hθ : HasDerivAt (fun s : ℝ => s / r) (1 / r) t := by
    simpa using (hasDerivAt_id t).div_const r
  have hsin : HasDerivAt (fun s : ℝ => r * Real.sin (s / r)) (Real.cos (t / r)) t := by
    have h := ((Real.hasDerivAt_sin (t / r)).comp t hθ).const_mul r
    have heq : r * (Real.cos (t / r) * (1 / r)) = Real.cos (t / r) := by field_simp
    rwa [heq] at h
  have hcos : HasDerivAt (fun s : ℝ => r * (1 - Real.cos (s / r))) (Real.sin (t / r)) t := by
    have h := (((Real.hasDerivAt_cos (t / r)).comp t hθ).const_sub 1).const_mul r
    have heq : r * -(-Real.sin (t / r) * (1 / r)) = Real.sin (t / r) := by field_simp
    rwa [heq] at h
  have hpos :
      HasDerivAt
        (fun s =>
          p.y + (r * Real.sin (s / r)) * (Vec2.normalize v).y
              + (r * (1 - Real.cos (s / r))) * (dir.normal (Vec2.normalize v)).y)
        (Real.cos (t / r) * (Vec2.normalize v).y
          + Real.sin (t / r) * (dir.normal (Vec2.normalize v)).y) t :=
    ((hsin.mul_const (Vec2.normalize v).y).const_add p.y).add
      (hcos.mul_const (dir.normal (Vec2.normalize v)).y)
  have htan :
      ((Segment2D.arc r p v dir sw opSpeed).tangentAt t).y
        = Real.cos (t / r) * (Vec2.normalize v).y
          + Real.sin (t / r) * (dir.normal (Vec2.normalize v)).y := by
    change (dir.rotate (t / r) (Vec2.normalize v)).y = _
    rw [turnDir_rotate_eq_lincomb]
    rfl
  rw [htan]
  exact hpos

/-- Sampling a 2D circular arc at arc-length `0` returns its start point. -/
theorem pointAt_zero_arc2D (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (sw opSpeed : ℝ) :
    (Segment2D.arc r p v dir sw opSpeed).pointAt 0 = p := by
  apply vec2_ext <;>
    simp [arc2D_pointAt_x, arc2D_pointAt_y, Real.sin_zero, Real.cos_zero]

/-- Sampling a 2D circular arc at arc-length `r * sw` lands at its exact local-frame
endpoint `p + (r · sin sw) · v̂ + (r · (1 - cos sw)) · dir.normal v̂`. -/
theorem pointAt_end_arc2D (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (sw opSpeed : ℝ) (hr : r ≠ 0) :
    (Segment2D.arc r p v dir sw opSpeed).pointAt (r * sw)
      = p + (r * Real.sin sw) • Vec2.normalize v
          + (r * (1 - Real.cos sw)) • dir.normal (Vec2.normalize v) := by
  have hdiv : r * sw / r = sw := by field_simp
  apply vec2_ext
  · rw [arc2D_pointAt_x, hdiv]; rfl
  · rw [arc2D_pointAt_y, hdiv]; rfl

/-- When `0 ≤ r * sw`, sampling a 2D circular arc at its length agrees with sampling at
`r * sw`. -/
theorem pointAt_length_arc2D (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (sw opSpeed : ℝ)
    (h : 0 ≤ r * sw) :
    (Segment2D.arc r p v dir sw opSpeed).pointAt (Segment2D.arc r p v dir sw opSpeed).length
      = (Segment2D.arc r p v dir sw opSpeed).pointAt (r * sw) := by
  have hlen : (Segment2D.arc r p v dir sw opSpeed).length = r * sw := by
    show absScalar (r * sw) = r * sw
    simp [absScalar, not_lt.mpr h]
  rw [hlen]

/-- Sampling a 2D circular arc at arc-length `r * sw` equals rotating the start point around
the circle center by angle `sw` in the arc's turn direction. -/
theorem pointAt_end_arc2D_eq_rotate_about_center (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir)
    (sw opSpeed : ℝ) (hr : r ≠ 0) :
    (Segment2D.arc r p v dir sw opSpeed).pointAt (r * sw)
      = circleCenter2D p v r dir + dir.rotate sw (p - circleCenter2D p v r dir) := by
  rw [pointAt_end_arc2D r p v dir sw opSpeed hr, turnDir_rotate_eq_lincomb]
  unfold circleCenter2D
  set vh := Vec2.normalize v
  cases dir <;>
    · apply vec2_ext <;>
        · simp [TurnDir.normal]
          ring

/-! ## 3. G⁰ positional endpoint sharing -/

private lemma clothoidOffset_zero_real (κ₀ κ' : ℝ) :
    clothoidOffset κ₀ κ' 0 clothoidPanels = (0, 0) := by
  simp [clothoidOffset, GL3.on]

/-- Evaluating a 2D clothoid point at arc-length `0` returns its start point. -/
theorem clothoidPoint2D_zero (p v : Vec2 ℝ) (dir : TurnDir) (κ₀ κ₁ L : ℝ) :
    clothoidPoint2D p v dir κ₀ κ₁ L 0 = p := by
  unfold clothoidPoint2D
  dsimp only
  rw [clothoidOffset_zero_real]
  apply vec2_ext <;> simp

/-- Sampling a 2D straight segment at arc-length `0` returns its start point. -/
theorem pointAt_zero_straight2D (p q : Vec2 ℝ) (opSpeed : ℝ) :
    (Segment2D.straight p q opSpeed).pointAt 0 = p := by
  unfold Segment2D.pointAt Vec2.lerp
  dsimp only
  split_ifs <;> (apply vec2_ext <;> simp)

/-- Sampling a 2D straight segment at its length returns its end point. -/
theorem pointAt_end_straight2D (p q : Vec2 ℝ) (opSpeed : ℝ) :
    (Segment2D.straight p q opSpeed).pointAt (Segment2D.straight p q opSpeed).length = q := by
  change (Segment2D.straight p q opSpeed).pointAt (Vec2.dist p q) = q
  unfold Segment2D.pointAt Vec2.lerp
  dsimp only
  split_ifs with hlen
  · have hnsq : Vec2.normSq (p - q) = 0 := by
      have hsq : Real.sqrt (Vec2.normSq (p - q)) = 0 := hlen
      have hnn : 0 ≤ Vec2.normSq (p - q) := by
        show 0 ≤ (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
        nlinarith [sq_nonneg (p.x - q.x), sq_nonneg (p.y - q.y)]
      exact (Real.sqrt_eq_zero hnn).mp hsq
    have hsum : (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 = 0 := by
      have h0 : (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) = 0 := hnsq
      linarith
    have hx : p.x = q.x := by nlinarith [sq_nonneg (p.x - q.x), sq_nonneg (p.y - q.y)]
    have hy : p.y = q.y := by nlinarith [sq_nonneg (p.x - q.x), sq_nonneg (p.y - q.y)]
    apply vec2_ext <;> simp [hx, hy]
  · rw [div_self hlen]
    apply vec2_ext <;> simp

/-- Sampling a 2D entry clothoid transition at arc-length `0` returns its start point. -/
theorem pointAt_zero_transitionIn2D (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (len opSpeed : ℝ) :
    (Segment2D.transitionIn r p v dir len opSpeed).pointAt 0 = p :=
  clothoidPoint2D_zero p v dir 0 (1 / r) len

/-- Sampling a 2D exit clothoid transition at arc-length `0` returns its start point. -/
theorem pointAt_zero_transitionOut2D (r : ℝ) (p v : Vec2 ℝ) (dir : TurnDir) (len opSpeed : ℝ) :
    (Segment2D.transitionOut r p v dir len opSpeed).pointAt 0 = p :=
  clothoidPoint2D_zero p v dir (1 / r) 0 len

/-- Positional (G⁰) continuity at the `straight → transitionIn` junction. -/
theorem pointAt_continuity_straight_in_2D (absR Ls straightSpeed opSpeed : ℝ)
    (inPt ts uIn : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.straight inPt ts straightSpeed).pointAt
        (Segment2D.straight inPt ts straightSpeed).length
      = (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).pointAt 0 := by
  rw [pointAt_end_straight2D, pointAt_zero_transitionIn2D]

/-- Positional (G⁰) continuity at the `transitionIn → arc` junction when the arc starts at
the entry transition endpoint `sc`. -/
theorem pointAt_continuity_in_arc_2D (absR Ls φ opSpeed : ℝ)
    (ts uIn tanSC : Vec2 ℝ) (dir : TurnDir) :
    let sc := clothoidPoint2D ts uIn dir 0 (1 / absR) Ls Ls
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).pointAt Ls
      = (Segment2D.arc absR sc tanSC dir φ opSpeed).pointAt 0 := by
  dsimp only
  rw [pointAt_zero_arc2D]
  rfl

/-- Positional (G⁰) continuity at the `arc → transitionOut` junction when the exit transition
starts at the analytic arc endpoint. -/
theorem pointAt_continuity_arc_out_2D (absR Ls φ opSpeed : ℝ)
    (hr : absR ≠ 0) (h : 0 ≤ absR * φ)
    (sc tanSC tanCS : Vec2 ℝ) (dir : TurnDir) :
    let arcSeg := Segment2D.arc absR sc tanSC dir φ opSpeed
    let cs := sc + (absR * Real.sin φ) • Vec2.normalize tanSC
                 + (absR * (1 - Real.cos φ)) • dir.normal (Vec2.normalize tanSC)
    arcSeg.pointAt arcSeg.length
      = (Segment2D.transitionOut absR cs tanCS dir Ls opSpeed).pointAt 0 := by
  dsimp only
  rw [pointAt_length_arc2D absR sc tanSC dir φ opSpeed h,
    pointAt_end_arc2D absR sc tanSC dir φ opSpeed hr,
    pointAt_zero_transitionOut2D]

/-- Positional (G⁰) continuity at the `transitionIn → transitionOut` junction for a saturated
arcless 2D spiral corner. -/
theorem pointAt_continuity_in_out_2D (absR Ls opSpeed : ℝ)
    (ts uIn tanSC : Vec2 ℝ) (dir : TurnDir) :
    let sc := clothoidPoint2D ts uIn dir 0 (1 / absR) Ls Ls
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).pointAt Ls
      = (Segment2D.transitionOut absR sc tanSC dir Ls opSpeed).pointAt 0 := by
  dsimp only
  rw [pointAt_zero_transitionOut2D]
  rfl

/-- Positional (G⁰) continuity at the `transitionOut → straight` junction when the outgoing
straight starts at the exit transition endpoint. -/
theorem pointAt_continuity_out_straight_2D (absR Ls opSpeed straightSpeed : ℝ)
    (cs tanCS outPt : Vec2 ℝ) (dir : TurnDir) :
    let exitSeg := Segment2D.transitionOut absR cs tanCS dir Ls opSpeed
    exitSeg.pointAt Ls
      = (Segment2D.straight (exitSeg.pointAt Ls) outPt straightSpeed).pointAt 0 := by
  dsimp only
  rw [pointAt_zero_straight2D]

/-! ## 4. Within-corner G² curvature continuity -/

/-- Unsigned G² curvature continuity at the `straight → transitionIn` junction (both `0`). -/
theorem curvature_continuity_straight_in_2D (absR Ls straightSpeed opSpeed : ℝ)
    (inPt ts uIn : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.straight inPt ts straightSpeed).curvatureAt
        (Segment2D.straight inPt ts straightSpeed).length
      = (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).curvatureAt 0 := by
  show (0 : ℝ) = (1 / absR) / Ls * 0
  ring

/-- Signed G² curvature continuity at the `straight → transitionIn` junction (both `0`). -/
theorem signedCurvature_continuity_straight_in_2D (absR Ls straightSpeed opSpeed : ℝ)
    (inPt ts uIn : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.straight inPt ts straightSpeed).signedCurvatureAt
        (Segment2D.straight inPt ts straightSpeed).length
      = (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).signedCurvatureAt 0 := by
  show (0 : ℝ) = dir.sign * ((1 / absR) / Ls * 0)
  ring

/-- Unsigned G² curvature continuity at the `transitionIn → arc` junction (both `1 / absR`). -/
theorem curvature_continuity_in_arc_2D (absR Ls φ opSpeed : ℝ) (hLs : Ls ≠ 0)
    (ts uIn sc tanSC : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).curvatureAt Ls
      = (Segment2D.arc absR sc tanSC dir φ opSpeed).curvatureAt 0 := by
  show (1 / absR) / Ls * Ls = 1 / absR
  field_simp

/-- Signed G² curvature continuity at the `transitionIn → arc` junction. -/
theorem signedCurvature_continuity_in_arc_2D (absR Ls φ opSpeed : ℝ) (hLs : Ls ≠ 0)
    (ts uIn sc tanSC : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).signedCurvatureAt Ls
      = (Segment2D.arc absR sc tanSC dir φ opSpeed).signedCurvatureAt 0 := by
  show dir.sign * ((1 / absR) / Ls * Ls) = dir.sign * (1 / absR)
  field_simp

/-- Unsigned G² curvature continuity at the `arc → transitionOut` junction (both `1 / absR`). -/
theorem curvature_continuity_arc_out_2D (absR Ls φ opSpeed : ℝ)
    (sc tanSC cs tanCS : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.arc absR sc tanSC dir φ opSpeed).curvatureAt (absR * φ)
      = (Segment2D.transitionOut absR cs tanCS dir Ls opSpeed).curvatureAt 0 := by
  show 1 / absR = 1 / absR - (1 / absR) / Ls * 0
  ring

/-- Signed G² curvature continuity at the `arc → transitionOut` junction. -/
theorem signedCurvature_continuity_arc_out_2D (absR Ls φ opSpeed : ℝ)
    (sc tanSC cs tanCS : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.arc absR sc tanSC dir φ opSpeed).signedCurvatureAt (absR * φ)
      = (Segment2D.transitionOut absR cs tanCS dir Ls opSpeed).signedCurvatureAt 0 := by
  show dir.sign * (1 / absR) = dir.sign * (1 / absR - (1 / absR) / Ls * 0)
  ring

/-- Unsigned G² curvature continuity at the `transitionIn → transitionOut` junction of a
saturated arcless 2D spiral corner (both `1 / absR`). -/
theorem curvature_continuity_in_out_2D (absR Ls opSpeed : ℝ) (hLs : Ls ≠ 0)
    (ts uIn sc tanSC : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).curvatureAt Ls
      = (Segment2D.transitionOut absR sc tanSC dir Ls opSpeed).curvatureAt 0 := by
  show (1 / absR) / Ls * Ls = 1 / absR - (1 / absR) / Ls * 0
  field_simp
  ring

/-- Signed G² curvature continuity at the `transitionIn → transitionOut` junction of a
saturated arcless 2D spiral corner. -/
theorem signedCurvature_continuity_in_out_2D (absR Ls opSpeed : ℝ) (hLs : Ls ≠ 0)
    (ts uIn sc tanSC : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).signedCurvatureAt Ls
      = (Segment2D.transitionOut absR sc tanSC dir Ls opSpeed).signedCurvatureAt 0 := by
  show dir.sign * ((1 / absR) / Ls * Ls) = dir.sign * (1 / absR - (1 / absR) / Ls * 0)
  field_simp
  ring

/-- Unsigned G² curvature continuity at the `transitionOut → straight` junction (both `0`). -/
theorem curvature_continuity_out_straight_2D (absR Ls opSpeed straightSpeed : ℝ) (hLs : Ls ≠ 0)
    (cs tanCS stPt outPt : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.transitionOut absR cs tanCS dir Ls opSpeed).curvatureAt Ls
      = (Segment2D.straight stPt outPt straightSpeed).curvatureAt 0 := by
  show 1 / absR - (1 / absR) / Ls * Ls = 0
  field_simp
  ring

/-- Signed G² curvature continuity at the `transitionOut → straight` junction (both `0`). -/
theorem signedCurvature_continuity_out_straight_2D (absR Ls opSpeed straightSpeed : ℝ)
    (hLs : Ls ≠ 0) (cs tanCS stPt outPt : Vec2 ℝ) (dir : TurnDir) :
    (Segment2D.transitionOut absR cs tanCS dir Ls opSpeed).signedCurvatureAt Ls
      = (Segment2D.straight stPt outPt straightSpeed).signedCurvatureAt 0 := by
  show dir.sign * (1 / absR - (1 / absR) / Ls * Ls) = 0
  field_simp
  ring

/-! ## 5. Within-corner G¹ tangent continuity -/

/-- Tangent (G¹) continuity at the `straight → transitionIn` junction when the incoming
straight arrives along the unit direction `uIn`. -/
theorem tangent_continuity_straight_in_2D (absR Ls dIn straightSpeed opSpeed : ℝ)
    (hdIn : 0 < dIn) (inPt ts uIn : Vec2 ℝ) (dir : TurnDir)
    (huIn : Vec2.normSq uIn = 1) (hin : ts - inPt = dIn • uIn) :
    (Segment2D.straight inPt ts straightSpeed).tangentAt
        (Segment2D.straight inPt ts straightSpeed).length
      = (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).tangentAt 0 := by
  change Vec2.normalize (ts - inPt)
    = dir.rotate ((1 / absR) / Ls * 0 * 0 / natToScalar 2) (Vec2.normalize uIn)
  have hz : (1 / absR) / Ls * 0 * 0 / (natToScalar 2 : ℝ) = 0 := by ring
  rw [hin, vec2_normalize_smul_pos hdIn huIn, vec2_normalize_eq_self huIn, hz,
    turnDir_rotate_zero]

/-- Tangent (G¹) continuity at the `transitionIn → arc` junction. -/
theorem tangent_continuity_in_arc_2D (absR Ls θs φ opSpeed : ℝ)
    (hR : absR ≠ 0) (_hLs : Ls ≠ 0) (hLsθ : Ls = 2 * absR * θs)
    (ts uIn sc tanSC : Vec2 ℝ) (dir : TurnDir)
    (huIn : Vec2.normSq uIn = 1) (htanSC : tanSC = dir.rotate θs uIn) :
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).tangentAt Ls
      = (Segment2D.arc absR sc tanSC dir φ opSpeed).tangentAt 0 := by
  change dir.rotate ((1 / absR) / Ls * Ls * Ls / natToScalar 2) (Vec2.normalize uIn)
    = dir.rotate (0 / absR) (Vec2.normalize tanSC)
  have htanU : Vec2.normSq tanSC = 1 := by
    rw [htanSC, turnDir_rotate_normSq]; exact huIn
  have hhead : (1 / absR) / Ls * Ls * Ls / (natToScalar 2 : ℝ) = θs := by
    rw [natToScalar_two_real]; field_simp; linear_combination hLsθ
  rw [vec2_normalize_eq_self huIn, vec2_normalize_eq_self htanU, hhead, zero_div,
    turnDir_rotate_zero, htanSC]

/-- Tangent (G¹) continuity at the `arc → transitionOut` junction. -/
theorem tangent_continuity_arc_out_2D (absR φ Ls opSpeed : ℝ) (hR : absR ≠ 0)
    (sc cs tanSC tanCS : Vec2 ℝ) (dir : TurnDir)
    (htanSCU : Vec2.normSq tanSC = 1) (htanCS : tanCS = dir.rotate φ tanSC) :
    (Segment2D.arc absR sc tanSC dir φ opSpeed).tangentAt (absR * φ)
      = (Segment2D.transitionOut absR cs tanCS dir Ls opSpeed).tangentAt 0 := by
  change dir.rotate (absR * φ / absR) (Vec2.normalize tanSC)
    = dir.rotate (0 / absR - (1 / absR) / Ls * 0 * 0 / natToScalar 2) (Vec2.normalize tanCS)
  have htanCSU : Vec2.normSq tanCS = 1 := by
    rw [htanCS, turnDir_rotate_normSq]; exact htanSCU
  have hhead : absR * φ / absR = φ := by field_simp
  have hz : (0 : ℝ) / absR - (1 / absR) / Ls * 0 * 0 / (natToScalar 2 : ℝ) = 0 := by ring
  rw [vec2_normalize_eq_self htanSCU, vec2_normalize_eq_self htanCSU, hhead, hz,
    turnDir_rotate_zero, htanCS]

/-- Tangent (G¹) continuity at the `transitionIn → transitionOut` junction of a saturated
arcless 2D spiral corner. -/
theorem tangent_continuity_in_out_2D (absR Ls θs opSpeed : ℝ)
    (hR : absR ≠ 0) (_hLs : Ls ≠ 0) (hLsθ : Ls = 2 * absR * θs)
    (ts uIn sc tanSC : Vec2 ℝ) (dir : TurnDir)
    (huIn : Vec2.normSq uIn = 1) (htanSC : tanSC = dir.rotate θs uIn) :
    (Segment2D.transitionIn absR ts uIn dir Ls opSpeed).tangentAt Ls
      = (Segment2D.transitionOut absR sc tanSC dir Ls opSpeed).tangentAt 0 := by
  change dir.rotate ((1 / absR) / Ls * Ls * Ls / natToScalar 2) (Vec2.normalize uIn)
    = dir.rotate (0 / absR - (1 / absR) / Ls * 0 * 0 / natToScalar 2) (Vec2.normalize tanSC)
  have htanU : Vec2.normSq tanSC = 1 := by
    rw [htanSC, turnDir_rotate_normSq]; exact huIn
  have hhead : (1 / absR) / Ls * Ls * Ls / (natToScalar 2 : ℝ) = θs := by
    rw [natToScalar_two_real]; field_simp; linear_combination hLsθ
  have hz : (0 : ℝ) / absR - (1 / absR) / Ls * 0 * 0 / (natToScalar 2 : ℝ) = 0 := by ring
  rw [vec2_normalize_eq_self huIn, vec2_normalize_eq_self htanU, hhead, hz,
    turnDir_rotate_zero, htanSC]

/-- Tangent (G¹) continuity at the `transitionOut → straight` junction when the outgoing
straight leaves along `uOut = dir.rotate θs tanStart`. -/
theorem tangent_continuity_out_straight_2D (absR Ls θs dOut opSpeed straightSpeed : ℝ)
    (hR : absR ≠ 0) (_hLs : Ls ≠ 0) (hLsθ : Ls = 2 * absR * θs) (hdOut : 0 < dOut)
    (cs tanStart stPt outPt uOut : Vec2 ℝ) (dir : TurnDir)
    (htanU : Vec2.normSq tanStart = 1) (huOut : uOut = dir.rotate θs tanStart)
    (hout : outPt - stPt = dOut • uOut) :
    (Segment2D.transitionOut absR cs tanStart dir Ls opSpeed).tangentAt Ls
      = (Segment2D.straight stPt outPt straightSpeed).tangentAt 0 := by
  change dir.rotate (Ls / absR - (1 / absR) / Ls * Ls * Ls / natToScalar 2)
      (Vec2.normalize tanStart)
    = Vec2.normalize (outPt - stPt)
  have huOutU : Vec2.normSq uOut = 1 := by
    rw [huOut, turnDir_rotate_normSq]; exact htanU
  have hhead : Ls / absR - (1 / absR) / Ls * Ls * Ls / (natToScalar 2 : ℝ) = θs := by
    rw [natToScalar_two_real]; field_simp; linear_combination hLsθ
  rw [vec2_normalize_eq_self htanU, hhead, hout, vec2_normalize_smul_pos hdOut huOutU, huOut]

/-! ## 6. Corner-level aggregates for `buildCorner2D` -/

/-- A 2D spiral corner with a circular arc built by `buildCorner2D` emits three pieces
`#[entrySeg, arcSeg, exitSeg]` and satisfies G⁰ positional endpoint sharing, G¹ tangent
continuity, and G² (unsigned and signed) curvature continuity across all four junctions
`straight → transitionIn → arc → transitionOut → straight`. -/
theorem buildCorner2D_spiral_arc_G0_G1_G2
    (b : Vec2 ℝ) (budget straightThreshold straightSpeed dIn dOut : ℝ)
    (g : CornerGeometry2D ℝ) (cp : CornerParams ℝ)
    (inPt outPt : Vec2 ℝ)
    (hθs : 0 < cp.spiralAngle)
    (hφ : straightThreshold < cp.arcAngle)
    (hR : cp.radius ≠ 0) (hLs : cp.spiralLength ≠ 0)
    (hLsθ : cp.spiralLength = 2 * cp.radius * cp.spiralAngle)
    (hRφ : 0 ≤ cp.radius * cp.arcAngle)
    (hΔ : cp.arcAngle + 2 * cp.spiralAngle = g.delta)
    (hdIn : 0 < dIn) (hdOut : 0 < dOut)
    (huIn : Vec2.normSq g.uIn = 1)
    (huOut : g.uOut = g.turnDir.rotate g.delta g.uIn)
    (hin : (buildCorner2D b budget g cp straightThreshold).entryPoint - inPt = dIn • g.uIn)
    (hout : outPt - (buildCorner2D b budget g cp straightThreshold).exitPoint = dOut • g.uOut) :
    let sol := buildCorner2D b budget g cp straightThreshold
    let ts := g.entryPoint b budget
    let sc := clothoidPoint2D ts g.uIn g.turnDir 0 (1 / cp.radius) cp.spiralLength cp.spiralLength
    let tanSC := g.turnDir.rotate cp.spiralAngle g.uIn
    let entrySeg := Segment2D.transitionIn cp.radius ts g.uIn g.turnDir cp.spiralLength cp.opSpeed
    let arcSeg := Segment2D.arc cp.radius sc tanSC g.turnDir cp.arcAngle cp.opSpeed
    let cs := arcSeg.pointAt arcSeg.length
    let tanCS := g.turnDir.rotate cp.arcAngle tanSC
    let exitSeg := Segment2D.transitionOut cp.radius cs tanCS g.turnDir cp.spiralLength cp.opSpeed
    let inStraight := Segment2D.straight inPt sol.entryPoint straightSpeed
    let outStraight := Segment2D.straight sol.exitPoint outPt straightSpeed
    sol.pieces = #[entrySeg, arcSeg, exitSeg]
      -- G⁰ positional endpoint sharing:
      ∧ (inStraight.pointAt inStraight.length = entrySeg.pointAt 0
        ∧ entrySeg.pointAt entrySeg.length = arcSeg.pointAt 0
        ∧ arcSeg.pointAt arcSeg.length = exitSeg.pointAt 0
        ∧ exitSeg.pointAt exitSeg.length = outStraight.pointAt 0)
      -- G¹ tangent continuity:
      ∧ (inStraight.tangentAt inStraight.length = entrySeg.tangentAt 0
        ∧ entrySeg.tangentAt entrySeg.length = arcSeg.tangentAt 0
        ∧ arcSeg.tangentAt arcSeg.length = exitSeg.tangentAt 0
        ∧ exitSeg.tangentAt exitSeg.length = outStraight.tangentAt 0)
      -- G² unsigned curvature continuity:
      ∧ (inStraight.curvatureAt inStraight.length = entrySeg.curvatureAt 0
        ∧ entrySeg.curvatureAt entrySeg.length = arcSeg.curvatureAt 0
        ∧ arcSeg.curvatureAt arcSeg.length = exitSeg.curvatureAt 0
        ∧ exitSeg.curvatureAt exitSeg.length = outStraight.curvatureAt 0)
      -- G² signed curvature continuity:
      ∧ (inStraight.signedCurvatureAt inStraight.length = entrySeg.signedCurvatureAt 0
        ∧ entrySeg.signedCurvatureAt entrySeg.length = arcSeg.signedCurvatureAt 0
        ∧ arcSeg.signedCurvatureAt arcSeg.length = exitSeg.signedCurvatureAt 0
        ∧ exitSeg.signedCurvatureAt exitSeg.length = outStraight.signedCurvatureAt 0) := by
  have hθs' : ¬ cp.spiralAngle ≤ 0 := not_le.mpr hθs
  have hφ' : ¬ cp.arcAngle ≤ straightThreshold := not_le.mpr hφ
  have hsol :
      buildCorner2D b budget g cp straightThreshold =
        let ts := g.entryPoint b budget
        let sc := clothoidPoint2D ts g.uIn g.turnDir 0 (1 / cp.radius) cp.spiralLength cp.spiralLength
        let tanSC := g.turnDir.rotate cp.spiralAngle g.uIn
        let entrySeg := Segment2D.transitionIn cp.radius ts g.uIn g.turnDir cp.spiralLength cp.opSpeed
        let arcSeg := Segment2D.arc cp.radius sc tanSC g.turnDir cp.arcAngle cp.opSpeed
        let cs := arcSeg.pointAt arcSeg.length
        let tanCS := g.turnDir.rotate cp.arcAngle tanSC
        let exitSeg := Segment2D.transitionOut cp.radius cs tanCS g.turnDir cp.spiralLength cp.opSpeed
        { entryPoint := ts, exitPoint := exitSeg.pointAt cp.spiralLength,
          pieces := #[entrySeg, arcSeg, exitSeg], opSpeed := cp.opSpeed, radius := cp.radius } := by
    unfold buildCorner2D
    simp only [hθs', hφ', ↓reduceIte]
  dsimp only
  set ts := g.entryPoint b budget
  set sc := clothoidPoint2D ts g.uIn g.turnDir 0 (1 / cp.radius) cp.spiralLength cp.spiralLength
  set tanSC := g.turnDir.rotate cp.spiralAngle g.uIn
  set entrySeg := Segment2D.transitionIn cp.radius ts g.uIn g.turnDir cp.spiralLength cp.opSpeed
  set arcSeg := Segment2D.arc cp.radius sc tanSC g.turnDir cp.arcAngle cp.opSpeed
  set cs := arcSeg.pointAt arcSeg.length
  set tanCS := g.turnDir.rotate cp.arcAngle tanSC
  set exitSeg := Segment2D.transitionOut cp.radius cs tanCS g.turnDir cp.spiralLength cp.opSpeed
  have hentry : (buildCorner2D b budget g cp straightThreshold).entryPoint = ts := by
    rw [hsol]
  have hexit : (buildCorner2D b budget g cp straightThreshold).exitPoint
      = exitSeg.pointAt cp.spiralLength := by
    rw [hsol]
  have hpieces : (buildCorner2D b budget g cp straightThreshold).pieces
      = #[entrySeg, arcSeg, exitSeg] := by
    rw [hsol]
  have harcLen : arcSeg.length = cp.radius * cp.arcAngle := by
    show absScalar (cp.radius * cp.arcAngle) = cp.radius * cp.arcAngle
    simp [absScalar, not_lt.mpr hRφ]
  have htanSCU : Vec2.normSq tanSC = 1 := by
    change Vec2.normSq (g.turnDir.rotate cp.spiralAngle g.uIn) = 1
    rw [turnDir_rotate_normSq]; exact huIn
  have htanCSU : Vec2.normSq tanCS = 1 := by
    change Vec2.normSq (g.turnDir.rotate cp.arcAngle tanSC) = 1
    rw [turnDir_rotate_normSq]; exact htanSCU
  have huOutCS : g.uOut = g.turnDir.rotate cp.spiralAngle tanCS := by
    rw [huOut, ← hΔ]
    change g.turnDir.rotate (cp.arcAngle + 2 * cp.spiralAngle) g.uIn
      = g.turnDir.rotate cp.spiralAngle (g.turnDir.rotate cp.arcAngle (g.turnDir.rotate cp.spiralAngle g.uIn))
    have hsum : cp.arcAngle + 2 * cp.spiralAngle = cp.spiralAngle + (cp.arcAngle + cp.spiralAngle) := by
      ring
    rw [hsum, turnDir_rotate_add, turnDir_rotate_add]
  rw [hentry] at hin
  rw [hexit] at hout
  refine ⟨hpieces, ⟨?_, ?_, ?_, ?_⟩, ⟨?_, ?_, ?_, ?_⟩, ⟨?_, ?_, ?_, ?_⟩, ⟨?_, ?_, ?_, ?_⟩⟩
  · rw [hentry]
    exact pointAt_continuity_straight_in_2D cp.radius cp.spiralLength straightSpeed cp.opSpeed
      inPt ts g.uIn g.turnDir
  · exact pointAt_continuity_in_arc_2D cp.radius cp.spiralLength cp.arcAngle cp.opSpeed
      ts g.uIn tanSC g.turnDir
  · rw [pointAt_zero_transitionOut2D]
  · rw [hexit]
    exact pointAt_continuity_out_straight_2D cp.radius cp.spiralLength cp.opSpeed straightSpeed
      cs tanCS outPt g.turnDir
  · rw [hentry]
    exact tangent_continuity_straight_in_2D cp.radius cp.spiralLength dIn straightSpeed cp.opSpeed
      hdIn inPt ts g.uIn g.turnDir huIn hin
  · exact tangent_continuity_in_arc_2D cp.radius cp.spiralLength cp.spiralAngle cp.arcAngle
      cp.opSpeed hR hLs hLsθ ts g.uIn sc tanSC g.turnDir huIn rfl
  · rw [harcLen]
    exact tangent_continuity_arc_out_2D cp.radius cp.arcAngle cp.spiralLength cp.opSpeed hR
      sc cs tanSC tanCS g.turnDir htanSCU rfl
  · rw [hexit]
    exact tangent_continuity_out_straight_2D cp.radius cp.spiralLength cp.spiralAngle dOut
      cp.opSpeed straightSpeed hR hLs hLsθ hdOut cs tanCS (exitSeg.pointAt cp.spiralLength)
      outPt g.uOut g.turnDir htanCSU huOutCS hout
  · rw [hentry]
    exact curvature_continuity_straight_in_2D cp.radius cp.spiralLength straightSpeed cp.opSpeed
      inPt ts g.uIn g.turnDir
  · exact curvature_continuity_in_arc_2D cp.radius cp.spiralLength cp.arcAngle cp.opSpeed hLs
      ts g.uIn sc tanSC g.turnDir
  · rw [harcLen]
    exact curvature_continuity_arc_out_2D cp.radius cp.spiralLength cp.arcAngle cp.opSpeed
      sc tanSC cs tanCS g.turnDir
  · rw [hexit]
    exact curvature_continuity_out_straight_2D cp.radius cp.spiralLength cp.opSpeed straightSpeed
      hLs cs tanCS (exitSeg.pointAt cp.spiralLength) outPt g.turnDir
  · rw [hentry]
    exact signedCurvature_continuity_straight_in_2D cp.radius cp.spiralLength straightSpeed
      cp.opSpeed inPt ts g.uIn g.turnDir
  · exact signedCurvature_continuity_in_arc_2D cp.radius cp.spiralLength cp.arcAngle cp.opSpeed
      hLs ts g.uIn sc tanSC g.turnDir
  · rw [harcLen]
    exact signedCurvature_continuity_arc_out_2D cp.radius cp.spiralLength cp.arcAngle cp.opSpeed
      sc tanSC cs tanCS g.turnDir
  · rw [hexit]
    exact signedCurvature_continuity_out_straight_2D cp.radius cp.spiralLength cp.opSpeed
      straightSpeed hLs cs tanCS (exitSeg.pointAt cp.spiralLength) outPt g.turnDir

/-- A saturated arcless 2D spiral corner built by `buildCorner2D` emits two pieces
`#[entrySeg, exitSeg]` and satisfies G⁰ positional endpoint sharing, G¹ tangent continuity,
and G² (unsigned and signed) curvature continuity across all three junctions
`straight → transitionIn → transitionOut → straight`. -/
theorem buildCorner2D_spiral_arcless_G0_G1_G2
    (b : Vec2 ℝ) (budget straightThreshold straightSpeed dIn dOut : ℝ)
    (g : CornerGeometry2D ℝ) (cp : CornerParams ℝ)
    (inPt outPt : Vec2 ℝ)
    (hθs : 0 < cp.spiralAngle)
    (hφ : cp.arcAngle ≤ straightThreshold)
    (hR : cp.radius ≠ 0) (hLs : cp.spiralLength ≠ 0)
    (hLsθ : cp.spiralLength = 2 * cp.radius * cp.spiralAngle)
    (hΔ : 2 * cp.spiralAngle = g.delta)
    (hdIn : 0 < dIn) (hdOut : 0 < dOut)
    (huIn : Vec2.normSq g.uIn = 1)
    (huOut : g.uOut = g.turnDir.rotate g.delta g.uIn)
    (hin : (buildCorner2D b budget g cp straightThreshold).entryPoint - inPt = dIn • g.uIn)
    (hout : outPt - (buildCorner2D b budget g cp straightThreshold).exitPoint = dOut • g.uOut) :
    let sol := buildCorner2D b budget g cp straightThreshold
    let ts := g.entryPoint b budget
    let sc := clothoidPoint2D ts g.uIn g.turnDir 0 (1 / cp.radius) cp.spiralLength cp.spiralLength
    let tanSC := g.turnDir.rotate cp.spiralAngle g.uIn
    let entrySeg := Segment2D.transitionIn cp.radius ts g.uIn g.turnDir cp.spiralLength cp.opSpeed
    let exitSeg := Segment2D.transitionOut cp.radius sc tanSC g.turnDir cp.spiralLength cp.opSpeed
    let inStraight := Segment2D.straight inPt sol.entryPoint straightSpeed
    let outStraight := Segment2D.straight sol.exitPoint outPt straightSpeed
    sol.pieces = #[entrySeg, exitSeg]
      -- G⁰ positional endpoint sharing:
      ∧ (inStraight.pointAt inStraight.length = entrySeg.pointAt 0
        ∧ entrySeg.pointAt entrySeg.length = exitSeg.pointAt 0
        ∧ exitSeg.pointAt exitSeg.length = outStraight.pointAt 0)
      -- G¹ tangent continuity:
      ∧ (inStraight.tangentAt inStraight.length = entrySeg.tangentAt 0
        ∧ entrySeg.tangentAt entrySeg.length = exitSeg.tangentAt 0
        ∧ exitSeg.tangentAt exitSeg.length = outStraight.tangentAt 0)
      -- G² unsigned curvature continuity:
      ∧ (inStraight.curvatureAt inStraight.length = entrySeg.curvatureAt 0
        ∧ entrySeg.curvatureAt entrySeg.length = exitSeg.curvatureAt 0
        ∧ exitSeg.curvatureAt exitSeg.length = outStraight.curvatureAt 0)
      -- G² signed curvature continuity:
      ∧ (inStraight.signedCurvatureAt inStraight.length = entrySeg.signedCurvatureAt 0
        ∧ entrySeg.signedCurvatureAt entrySeg.length = exitSeg.signedCurvatureAt 0
        ∧ exitSeg.signedCurvatureAt exitSeg.length = outStraight.signedCurvatureAt 0) := by
  have hθs' : ¬ cp.spiralAngle ≤ 0 := not_le.mpr hθs
  have hsol :
      buildCorner2D b budget g cp straightThreshold =
        let ts := g.entryPoint b budget
        let sc := clothoidPoint2D ts g.uIn g.turnDir 0 (1 / cp.radius) cp.spiralLength cp.spiralLength
        let tanSC := g.turnDir.rotate cp.spiralAngle g.uIn
        let entrySeg := Segment2D.transitionIn cp.radius ts g.uIn g.turnDir cp.spiralLength cp.opSpeed
        let exitSeg := Segment2D.transitionOut cp.radius sc tanSC g.turnDir cp.spiralLength cp.opSpeed
        { entryPoint := ts, exitPoint := exitSeg.pointAt cp.spiralLength,
          pieces := #[entrySeg, exitSeg], opSpeed := cp.opSpeed, radius := cp.radius } := by
    unfold buildCorner2D
    simp only [hθs', hφ, ↓reduceIte]
  dsimp only
  set ts := g.entryPoint b budget
  set sc := clothoidPoint2D ts g.uIn g.turnDir 0 (1 / cp.radius) cp.spiralLength cp.spiralLength
  set tanSC := g.turnDir.rotate cp.spiralAngle g.uIn
  set entrySeg := Segment2D.transitionIn cp.radius ts g.uIn g.turnDir cp.spiralLength cp.opSpeed
  set exitSeg := Segment2D.transitionOut cp.radius sc tanSC g.turnDir cp.spiralLength cp.opSpeed
  have hentry : (buildCorner2D b budget g cp straightThreshold).entryPoint = ts := by
    rw [hsol]
  have hexit : (buildCorner2D b budget g cp straightThreshold).exitPoint
      = exitSeg.pointAt cp.spiralLength := by
    rw [hsol]
  have hpieces : (buildCorner2D b budget g cp straightThreshold).pieces
      = #[entrySeg, exitSeg] := by
    rw [hsol]
  have htanSCU : Vec2.normSq tanSC = 1 := by
    change Vec2.normSq (g.turnDir.rotate cp.spiralAngle g.uIn) = 1
    rw [turnDir_rotate_normSq]; exact huIn
  have huOutSC : g.uOut = g.turnDir.rotate cp.spiralAngle tanSC := by
    rw [huOut, ← hΔ]
    change g.turnDir.rotate (2 * cp.spiralAngle) g.uIn
      = g.turnDir.rotate cp.spiralAngle (g.turnDir.rotate cp.spiralAngle g.uIn)
    have hsum : 2 * cp.spiralAngle = cp.spiralAngle + cp.spiralAngle := by ring
    rw [hsum, turnDir_rotate_add]
  rw [hentry] at hin
  rw [hexit] at hout
  refine ⟨hpieces, ⟨?_, ?_, ?_⟩, ⟨?_, ?_, ?_⟩, ⟨?_, ?_, ?_⟩, ⟨?_, ?_, ?_⟩⟩
  · rw [hentry]
    exact pointAt_continuity_straight_in_2D cp.radius cp.spiralLength straightSpeed cp.opSpeed
      inPt ts g.uIn g.turnDir
  · exact pointAt_continuity_in_out_2D cp.radius cp.spiralLength cp.opSpeed ts g.uIn tanSC g.turnDir
  · rw [hexit]
    exact pointAt_continuity_out_straight_2D cp.radius cp.spiralLength cp.opSpeed straightSpeed
      sc tanSC outPt g.turnDir
  · rw [hentry]
    exact tangent_continuity_straight_in_2D cp.radius cp.spiralLength dIn straightSpeed cp.opSpeed
      hdIn inPt ts g.uIn g.turnDir huIn hin
  · exact tangent_continuity_in_out_2D cp.radius cp.spiralLength cp.spiralAngle cp.opSpeed
      hR hLs hLsθ ts g.uIn sc tanSC g.turnDir huIn rfl
  · rw [hexit]
    exact tangent_continuity_out_straight_2D cp.radius cp.spiralLength cp.spiralAngle dOut
      cp.opSpeed straightSpeed hR hLs hLsθ hdOut sc tanSC (exitSeg.pointAt cp.spiralLength)
      outPt g.uOut g.turnDir htanSCU huOutSC hout
  · rw [hentry]
    exact curvature_continuity_straight_in_2D cp.radius cp.spiralLength straightSpeed cp.opSpeed
      inPt ts g.uIn g.turnDir
  · exact curvature_continuity_in_out_2D cp.radius cp.spiralLength cp.opSpeed hLs
      ts g.uIn sc tanSC g.turnDir
  · rw [hexit]
    exact curvature_continuity_out_straight_2D cp.radius cp.spiralLength cp.opSpeed straightSpeed
      hLs sc tanSC (exitSeg.pointAt cp.spiralLength) outPt g.turnDir
  · rw [hentry]
    exact signedCurvature_continuity_straight_in_2D cp.radius cp.spiralLength straightSpeed
      cp.opSpeed inPt ts g.uIn g.turnDir
  · exact signedCurvature_continuity_in_out_2D cp.radius cp.spiralLength cp.opSpeed hLs
      ts g.uIn sc tanSC g.turnDir
  · rw [hexit]
    exact signedCurvature_continuity_out_straight_2D cp.radius cp.spiralLength cp.opSpeed
      straightSpeed hLs sc tanSC (exitSeg.pointAt cp.spiralLength) outPt g.turnDir

end TrackGeometry.PlanarContinuity
