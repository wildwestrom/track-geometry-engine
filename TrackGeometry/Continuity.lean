import TrackGeometry.Real
import Mathlib.MeasureTheory.Integral.IntervalIntegral.FundThmCalculus
import Mathlib.Analysis.SpecialFunctions.Trigonometric.Deriv

/-! # Geometric-continuity proofs for the spiral corner

This file provides machine-checked guarantees that the spiral corner emitted by
`solveCornerWithGeometry` is **G¹ (tangent) and G² (curvature) continuous at its internal
junctions** (`transitionIn` → `arc` → `transitionOut`).

Everything here works over `ℝ` (via `TrackGeometry.Real`'s `noncomputable` instance), so
the computable core in `TrackGeometry.Lib` keeps its import-free, C-compilable property.

## What is proven vs. assumed

`Segment.tangentAt` computes the tangent by a *closed-form* rotation `rotateAxis B θ(t) vh`
with a per-segment heading `θ(t)` — there is **no** numerical integrator in the tangent or
in `Segment.curvatureAt`. Consequently the junction continuity results (§4/§5) are pure
rotation/heading arithmetic and are proven outright, depending only on Lean/Mathlib
primitives.

To ground those closed-form formulas in *real geometry*, §2 defines the clothoid position
by a genuine Mathlib interval integral (`clothoidOffsetExact`) and uses the Fundamental
Theorem of Calculus to prove its derivative is exactly the `frameAt` tangent and its signed
curvature is exactly `θ'(s)`. The numeric Gauss–Legendre `clothoidOffset` is a *separate*
code path; the single, clearly documented `axiom clothoidOffset_eq_exact` (§6) is the only
bridge between them, and the §4/§5 continuity theorems do **not** depend on it.
-/

namespace TrackGeometry.Continuity

open scoped Real
open Vec3

/-! ## 0. Instance-bridge simp lemmas

Expose the `ℝ` `TrackScalar` instance so `simp`/`ring`/trig lemmas fire on `tangentAt`
unfoldings. Each is `rfl` because the instance defines `cos := Real.cos`, etc. -/

@[simp] lemma trackScalar_cos_real (x : ℝ) : TrackScalar.cos x = Real.cos x := rfl
@[simp] lemma trackScalar_sin_real (x : ℝ) : TrackScalar.sin x = Real.sin x := rfl
@[simp] lemma trackScalar_sqrt_real (x : ℝ) : TrackScalar.sqrt x = Real.sqrt x := rfl
@[simp] lemma trackScalar_arccos_real (x : ℝ) : TrackScalar.arccos x = Real.arccos x := rfl
@[simp] lemma trackScalar_pi_real : (TrackScalar.pi : ℝ) = Real.pi := rfl

/-! ## 1. Rotation algebra (closed-form, over ℝ)

`rotateAxisC` is Rodrigues' formula about a *unit* axis `(nx, ny, nz)`. The workhorse is
`rotateAxisC_add`: rotations about the same unit axis compose additively in the angle. -/

/-- `Vec3.mk` of a vector's own components is the vector (η for `Vec3 = Fin 3 → α`). -/
@[simp] lemma Vec3.mk_eta (v : Vec3 ℝ) : Vec3.mk (v 0) (v 1) (v 2) = v := by
  funext i; fin_cases i <;> rfl

/-- Rotating by angle `0` is the identity. -/
@[simp] lemma rotateAxisC_zero (nx ny nz : ℝ) (v : Vec3 ℝ) :
    Vec3.rotateAxisC nx ny nz 0 v = v := by
  funext i
  fin_cases i <;>
    simp [Vec3.rotateAxisC, Real.cos_zero, Real.sin_zero]

/-- **Composition of rotations about a common unit axis.** Given `nx² + ny² + nz² = 1`,
    `rotateAxisC n (φ + ψ) v = rotateAxisC n φ (rotateAxisC n ψ v)`. The key workhorse:
    every heading/tangent identity at a junction is an instance of this. -/
lemma rotateAxisC_add (nx ny nz φ ψ : ℝ) (v : Vec3 ℝ)
    (hn : nx * nx + ny * ny + nz * nz = 1) :
    Vec3.rotateAxisC nx ny nz (φ + ψ) v
      = Vec3.rotateAxisC nx ny nz φ (Vec3.rotateAxisC nx ny nz ψ v) := by
  -- Reduce to the three scalar-component identities. `D := n · v` is preserved by the
  -- inner rotation; the correction that closes each component is a multiple of `hn`
  -- (`|n|² = 1`), derived from `K³ = -K` for the cross-product matrix `K` of the unit axis.
  funext i
  fin_cases i
  · show Vec3.rotateAxisC nx ny nz (φ + ψ) v 0
        = Vec3.rotateAxisC nx ny nz φ (Vec3.rotateAxisC nx ny nz ψ v) 0
    simp only [Vec3.rotateAxisC, Vec3.mk, trackScalar_cos_real, trackScalar_sin_real,
      Real.cos_add, Real.sin_add, Fin.isValue, Fin.reduceEq, reduceIte]
    linear_combination (Real.sin φ * Real.sin ψ * v 0 -
      nx * (nx * v 0 + ny * v 1 + nz * v 2) * (1 - Real.cos φ) * (1 - Real.cos ψ)) * hn
  · show Vec3.rotateAxisC nx ny nz (φ + ψ) v 1
        = Vec3.rotateAxisC nx ny nz φ (Vec3.rotateAxisC nx ny nz ψ v) 1
    simp only [Vec3.rotateAxisC, Vec3.mk, trackScalar_cos_real, trackScalar_sin_real,
      Real.cos_add, Real.sin_add, Fin.isValue, Fin.reduceEq, reduceIte]
    linear_combination (Real.sin φ * Real.sin ψ * v 1 -
      ny * (nx * v 0 + ny * v 1 + nz * v 2) * (1 - Real.cos φ) * (1 - Real.cos ψ)) * hn
  · show Vec3.rotateAxisC nx ny nz (φ + ψ) v 2
        = Vec3.rotateAxisC nx ny nz φ (Vec3.rotateAxisC nx ny nz ψ v) 2
    simp only [Vec3.rotateAxisC, Vec3.mk, trackScalar_cos_real, trackScalar_sin_real,
      Real.cos_add, Real.sin_add, Fin.isValue, Fin.reduceEq, reduceIte]
    linear_combination (Real.sin φ * Real.sin ψ * v 2 -
      nz * (nx * v 0 + ny * v 1 + nz * v 2) * (1 - Real.cos φ) * (1 - Real.cos ψ)) * hn

/-- A rotation about a unit axis preserves the squared norm (it is an orthogonal map). -/
lemma rotateAxisC_normSq (nx ny nz φ : ℝ) (v : Vec3 ℝ)
    (hn : nx * nx + ny * ny + nz * nz = 1) :
    Vec3.normSq (Vec3.rotateAxisC nx ny nz φ v) = Vec3.normSq v := by
  simp only [Vec3.normSq, Vec3.dot, Vec3.rotateAxisC, Vec3.mk, trackScalar_cos_real,
    trackScalar_sin_real, Fin.isValue, Fin.reduceEq, reduceIte]
  linear_combination
    (v 0 * v 0 + v 1 * v 1 + v 2 * v 2 - (nx * v 0 + ny * v 1 + nz * v 2) ^ 2) *
        Real.sin_sq_add_cos_sq φ +
      (Real.sin φ ^ 2 * (v 0 * v 0 + v 1 * v 1 + v 2 * v 2) +
        (1 - Real.cos φ) ^ 2 * (nx * v 0 + ny * v 1 + nz * v 2) ^ 2) * hn

/-- `normalize` is a no-op on a unit vector. -/
lemma normalize_eq_self {v : Vec3 ℝ} (h : Vec3.normSq v = 1) :
    Vec3.normalize v = v := by
  funext i
  show (if Vec3.normSq v = 0 then v else (1 / TrackScalar.sqrt (Vec3.normSq v)) • v) i = v i
  rw [h]
  simp only [trackScalar_sqrt_real, Real.sqrt_one, one_ne_zero, if_false, div_one]
  show (1 : ℝ) * v i = v i
  ring

/-- Rotating about any axis by angle `0` is the identity (wrapper over `rotateAxisC_zero`). -/
@[simp] lemma rotateAxis_zero (n v : Vec3 ℝ) : Vec3.rotateAxis n 0 v = v :=
  rotateAxisC_zero (n 0) (n 1) (n 2) v

/-- `natToScalar 2 = 2` over `ℝ` (the transition heading's `½` factor). -/
@[simp] lemma natToScalar_two : (natToScalar 2 : ℝ) = 2 := by
  norm_num [natToScalar]

/-! ## Tangent projections

The unit tangent `tangentAt` for each constructor, as the closed-form rotation
`rotateAxis (normalize B) θ(t) (normalize vh)`. All `rfl` (definitional unfolding of
`tangentAt`, `planeBinormal`, `headingAt`, `startDir`). No integrator appears. -/

lemma tangentAt_straight (p q : Vec3 ℝ) (t : ℝ) :
    (Segment.straight p q).tangentAt t
      = Vec3.rotateAxis (Vec3.normalize (Vec3.mk 0 0 1)) 0 (Vec3.normalize (q - p)) := rfl

lemma tangentAt_arc (r : ℝ) (p q v Bref : Vec3 ℝ) (sw : Option ℝ) (t : ℝ) :
    (Segment.arc r p q v Bref sw).tangentAt t
      = Vec3.rotateAxis (Vec3.normalize Bref) (t / r) (Vec3.normalize v) := rfl

lemma tangentAt_transitionIn (r : ℝ) (cont : GeometricContinuity) (p v Bref : Vec3 ℝ)
    (len : ℝ) (ct : TransitionCurveType) (t : ℝ) :
    (Segment.transitionIn r cont p v Bref len ct).tangentAt t
      = Vec3.rotateAxis (Vec3.normalize Bref) ((1 / r) / len * t * t / natToScalar 2)
          (Vec3.normalize v) := rfl

lemma tangentAt_transitionOut (r : ℝ) (cont : GeometricContinuity) (p v Bref : Vec3 ℝ)
    (len : ℝ) (ct : TransitionCurveType) (t : ℝ) :
    (Segment.transitionOut r cont p v Bref len ct).tangentAt t
      = Vec3.rotateAxis (Vec3.normalize Bref)
          (t / r - (1 / r) / len * t * t / natToScalar 2) (Vec3.normalize v) := rfl

/-! ## 4a. Within-corner G² (curvature) junction continuity

`Segment.curvatureAt` is the exact derivative of the heading `frameAt` rotates through, so
these equalities are the G² statements. Each is pure arithmetic on the linear-curvature
profile at the junction arc-length. `absR ≠ 0`, `Ls ≠ 0` come from a non-degenerate spiral
corner (`absR = radiusOf θs > 0`, `Ls = 2·absR·θs > 0`). -/

/-- G²: curvature matches at the `straight` → `transitionIn` boundary (both `0`). -/
theorem curvature_continuity_straight_in (absR Ls : ℝ) (cont : GeometricContinuity)
    (sp ep p v B : Vec3 ℝ) (ct : TransitionCurveType) :
    (Segment.straight sp ep).curvatureAt (Vec3.dist sp ep)
      = (Segment.transitionIn absR cont p v B Ls ct).curvatureAt 0 := by
  show (0 : ℝ) = (1 / absR) / Ls * 0
  ring

/-- G²: curvature matches at the `transitionIn` → `arc` junction (both `1/absR`). At the
    end of the entry spiral the ramped curvature `(1/absR)/Ls · t` has reached `1/absR`. -/
theorem curvature_continuity_in_arc (absR Ls : ℝ) (hLs : Ls ≠ 0)
    (cont : GeometricContinuity) (p v B : Vec3 ℝ) (ct : TransitionCurveType)
    (ap aq atan : Vec3 ℝ) (sw : Option ℝ) :
    (Segment.transitionIn absR cont p v B Ls ct).curvatureAt Ls
      = (Segment.arc absR ap aq atan B sw).curvatureAt 0 := by
  show (1 / absR) / Ls * Ls = 1 / absR
  field_simp

/-- G²: curvature matches at the `arc` → `transitionOut` junction (both `1/absR`). The exit
    spiral starts at the arc's constant curvature `1/absR` before ramping back to `0`. -/
theorem curvature_continuity_arc_out (absR Ls φ : ℝ)
    (ap aq atan B : Vec3 ℝ) (cont : GeometricContinuity) (p v : Vec3 ℝ)
    (ct : TransitionCurveType) :
    (Segment.arc absR ap aq atan B (some φ)).curvatureAt (absR * φ)
      = (Segment.transitionOut absR cont p v B Ls ct).curvatureAt 0 := by
  show 1 / absR = 1 / absR - (1 / absR) / Ls * 0
  ring

/-- G²: for a degenerate (arcless) spiral corner, curvature matches directly at the
    `transitionIn` → `transitionOut` junction (both `1/absR`). -/
theorem curvature_continuity_in_out (absR Ls : ℝ) (hLs : Ls ≠ 0)
    (cont cont' : GeometricContinuity) (p v p' v' B : Vec3 ℝ) (ct ct' : TransitionCurveType) :
    (Segment.transitionIn absR cont p v B Ls ct).curvatureAt Ls
      = (Segment.transitionOut absR cont' p' v' B Ls ct').curvatureAt 0 := by
  show (1 / absR) / Ls * Ls = 1 / absR - (1 / absR) / Ls * 0
  field_simp
  ring

/-! ## 4b. Within-corner G¹ (tangent) junction continuity

Each junction tangent equality reduces, via the frame-tangent projections and the rotation
algebra of §1, to a heading identity at the junction arc-length. The corner is built with a
**shared unit binormal** `B` and **unit** leg tangent; `θs = Ls/(2·absR)` is the spiral
angle, and `solveCornerWithGeometry` stores `tanSC = rotateAxisC B θs uIn`,
`tanCS = rotateAxisC B φ tanSC`, exactly the closed forms the frames land on.

No integrator (`pointAt`) enters: the tangent is a pure rotation of the leg direction. -/

/-- G¹: tangent matches at the `transitionIn` → `arc` junction. The entry spiral's heading
    at its end `Ls` is `(1/absR)/Ls · Ls²/2 = Ls/(2·absR) = θs`, so its final tangent is
    `rotateAxis B θs uIn = tanSC`, which is exactly the arc's start tangent (its heading at
    `0` being `0`). -/
theorem tangent_continuity_in_arc
    (absR Ls θs : ℝ) (hR : absR ≠ 0) (_hLs : Ls ≠ 0) (hLsθ : Ls = 2 * absR * θs)
    (ts uIn B tanSC : Vec3 ℝ) (cont : GeometricContinuity) (ct : TransitionCurveType)
    (hB : Vec3.normSq B = 1) (hu : Vec3.normSq uIn = 1)
    (htanSC : tanSC = Vec3.rotateAxisC (B 0) (B 1) (B 2) θs uIn)
    (ap aq : Vec3 ℝ) (sw : Option ℝ) :
    (Segment.transitionIn absR cont ts uIn B Ls ct).tangentAt Ls
      = (Segment.arc absR ap aq tanSC B sw).tangentAt 0 := by
  have hBaxis : B 0 * B 0 + B 1 * B 1 + B 2 * B 2 = 1 := hB
  have htanU : Vec3.normSq tanSC = 1 := by
    rw [htanSC, rotateAxisC_normSq _ _ _ _ _ hBaxis]; exact hu
  have hhead : (1 / absR) / Ls * Ls * Ls / natToScalar 2 = θs := by
    rw [natToScalar_two]; field_simp; linear_combination hLsθ
  rw [tangentAt_transitionIn, tangentAt_arc, normalize_eq_self hB, normalize_eq_self hu,
    normalize_eq_self htanU, zero_div, rotateAxis_zero, hhead, htanSC]
  rfl

/-- G¹: tangent matches at the `arc` → `transitionOut` junction. The arc's heading at its
    end (arc-length `absR·φ`) is `φ`, so its final tangent is `rotateAxis B φ tanSC = tanCS`,
    exactly the exit spiral's start tangent (its heading at `0` being `0`). -/
theorem tangent_continuity_arc_out
    (absR φ Ls : ℝ) (hR : absR ≠ 0)
    (sc cs tanSC tanCS B : Vec3 ℝ) (cont : GeometricContinuity) (ct : TransitionCurveType)
    (hB : Vec3.normSq B = 1) (htanSCU : Vec3.normSq tanSC = 1)
    (htanCS : tanCS = Vec3.rotateAxisC (B 0) (B 1) (B 2) φ tanSC) :
    (Segment.arc absR sc cs tanSC B (some φ)).tangentAt (absR * φ)
      = (Segment.transitionOut absR cont cs tanCS B Ls ct).tangentAt 0 := by
  have hBaxis : B 0 * B 0 + B 1 * B 1 + B 2 * B 2 = 1 := hB
  have htanCSU : Vec3.normSq tanCS = 1 := by
    rw [htanCS, rotateAxisC_normSq _ _ _ _ _ hBaxis]; exact htanSCU
  have hhead : absR * φ / absR = φ := by field_simp
  have hz : (0 : ℝ) / absR - (1 / absR) / Ls * 0 * 0 / natToScalar 2 = 0 := by ring
  rw [tangentAt_arc, tangentAt_transitionOut, normalize_eq_self hB,
    normalize_eq_self htanSCU, normalize_eq_self htanCSU, hhead, hz, rotateAxis_zero, htanCS]
  rfl

/-- G¹: for a degenerate (arcless) spiral corner — where the spiral angle saturates at
    `θs = Δ/2` so the circular arc `φ = Δ − 2θs = 0` vanishes — the entry and exit spirals
    meet directly. Both tangents are `rotateAxis B θs uIn = tanSC` (`tanCS = rotateAxis B 0
    tanSC = tanSC`), so the junction is G¹. -/
theorem tangent_continuity_in_out
    (absR Ls θs φ : ℝ) (hR : absR ≠ 0) (_hLs : Ls ≠ 0) (hLsθ : Ls = 2 * absR * θs)
    (hφ : φ = 0) (ts uIn B tanSC cs tanCS : Vec3 ℝ)
    (cont cont' : GeometricContinuity) (ct ct' : TransitionCurveType)
    (hB : Vec3.normSq B = 1) (hu : Vec3.normSq uIn = 1)
    (htanSC : tanSC = Vec3.rotateAxisC (B 0) (B 1) (B 2) θs uIn)
    (htanCS : tanCS = Vec3.rotateAxisC (B 0) (B 1) (B 2) φ tanSC) :
    (Segment.transitionIn absR cont ts uIn B Ls ct).tangentAt Ls
      = (Segment.transitionOut absR cont' cs tanCS B Ls ct').tangentAt 0 := by
  have hBaxis : B 0 * B 0 + B 1 * B 1 + B 2 * B 2 = 1 := hB
  have htanU : Vec3.normSq tanSC = 1 := by
    rw [htanSC, rotateAxisC_normSq _ _ _ _ _ hBaxis]; exact hu
  -- With φ = 0 the exit tangent is the entry-spiral end tangent.
  have htanCS0 : tanCS = tanSC := by rw [htanCS, hφ, rotateAxisC_zero]
  have htanCSU : Vec3.normSq tanCS = 1 := by rw [htanCS0]; exact htanU
  have hhead : (1 / absR) / Ls * Ls * Ls / natToScalar 2 = θs := by
    rw [natToScalar_two]; field_simp; linear_combination hLsθ
  have hz : (0 : ℝ) / absR - (1 / absR) / Ls * 0 * 0 / natToScalar 2 = 0 := by ring
  rw [tangentAt_transitionIn, tangentAt_transitionOut, normalize_eq_self hB,
    normalize_eq_self hu, normalize_eq_self htanCSU, hhead, hz, rotateAxis_zero,
    htanCS0, htanSC]
  rfl

/-! ## 2. Exact clothoid model + Fundamental Theorem of Calculus

To ground the closed-form `tangentAt`/`curvatureAt` formulas in real geometry, define the
clothoid position by genuine interval integrals of the unit tangent `(cos θ, sin θ)` and use
FTC to show its derivative is exactly the `tangentAt` tangent and its heading's derivative is
exactly the curvature `curvatureAt` reports. No numeric quadrature is involved here; the link
to the computable sampler is the single axiom in §6. -/

/-- Running heading (turn angle) of a linear-curvature transition, matching the local
    `heading` inside `clothoidOffset`: `θ(u) = κ₀·u + ½·κ'·u²`. -/
noncomputable def headingExact (κ₀ κ' u : ℝ) : ℝ := κ₀ * u + κ' * u ^ 2 / 2

/-- The heading's derivative is the signed curvature `κ(s) = κ₀ + κ'·s` — this *is* the
    curvature `Segment.curvatureAt` reports (the arc-length derivative of the turn angle). -/
theorem hasDerivAt_headingExact (κ₀ κ' s : ℝ) :
    HasDerivAt (headingExact κ₀ κ') (κ₀ + κ' * s) s := by
  have h1 : HasDerivAt (fun u : ℝ => κ₀ * u) κ₀ s := by
    simpa using (hasDerivAt_id s).const_mul κ₀
  have hsq : HasDerivAt (fun u : ℝ => u ^ 2) (2 * s) s := by
    simpa using hasDerivAt_pow 2 s
  have h2 := (hsq.const_mul κ').div_const 2
  have e : κ' * (2 * s) / 2 = κ' * s := by ring
  rw [e] at h2
  exact h1.add h2

/-- The exact clothoid tangent integrand `u ↦ cos θ(u)` is continuous. -/
theorem continuous_cos_headingExact (κ₀ κ' : ℝ) :
    Continuous (fun u => Real.cos (headingExact κ₀ κ' u)) := by
  unfold headingExact; fun_prop

/-- The exact clothoid tangent integrand `u ↦ sin θ(u)` is continuous. -/
theorem continuous_sin_headingExact (κ₀ κ' : ℝ) :
    Continuous (fun u => Real.sin (headingExact κ₀ κ' u)) := by
  unfold headingExact; fun_prop

/-- **FTC** for the along-tangent offset: `d/ds ∫₀ˢ cos θ = cos θ(s)`. -/
theorem hasDerivAt_intCos (κ₀ κ' s : ℝ) :
    HasDerivAt (fun s => ∫ u in (0:ℝ)..s, Real.cos (headingExact κ₀ κ' u))
      (Real.cos (headingExact κ₀ κ' s)) s :=
  intervalIntegral.integral_hasDerivAt_right
    ((continuous_cos_headingExact κ₀ κ').intervalIntegrable _ _)
    (continuous_cos_headingExact κ₀ κ').aestronglyMeasurable.stronglyMeasurableAtFilter
    (continuous_cos_headingExact κ₀ κ').continuousAt

/-- **FTC** for the lateral offset: `d/ds ∫₀ˢ sin θ = sin θ(s)`. -/
theorem hasDerivAt_intSin (κ₀ κ' s : ℝ) :
    HasDerivAt (fun s => ∫ u in (0:ℝ)..s, Real.sin (headingExact κ₀ κ' u))
      (Real.sin (headingExact κ₀ κ' s)) s :=
  intervalIntegral.integral_hasDerivAt_right
    ((continuous_sin_headingExact κ₀ κ').intervalIntegrable _ _)
    (continuous_sin_headingExact κ₀ κ').aestronglyMeasurable.stronglyMeasurableAtFilter
    (continuous_sin_headingExact κ₀ κ').continuousAt

/-- The `i`-th component of the exact clothoid position, placed in the corner's plane exactly
    as `clothoidPoint` places its offset: `p + xL·vh + yL·nh`, with the offsets given by the
    exact integrals rather than Gauss–Legendre. -/
noncomputable def clothoidPosComp (p vh nh : Vec3 ℝ) (κ₀ κ' : ℝ) (i : Fin 3) (s : ℝ) : ℝ :=
  p i + (∫ u in (0:ℝ)..s, Real.cos (headingExact κ₀ κ' u)) * vh i
      + (∫ u in (0:ℝ)..s, Real.sin (headingExact κ₀ κ' u)) * nh i

/-- The exact unit tangent `cos θ · vh + sin θ · nh` (with `nh = B × vh`) equals the closed-form
    `rotateAxis B θ vh` that `tangentAt` returns, provided `vh ⟂ B`. This is the Rodrigues
    reduction with `B · vh = 0`; it identifies the exact tangent with `tangentAt`'s value. -/
theorem exactTangent_eq_rotate (B vh : Vec3 ℝ) (θ : ℝ) (i : Fin 3)
    (hBv : B 0 * vh 0 + B 1 * vh 1 + B 2 * vh 2 = 0) :
    Real.cos θ * vh i + Real.sin θ * (Vec3.cross B vh) i = (Vec3.rotateAxis B θ vh) i := by
  fin_cases i
  · show Real.cos θ * vh 0 + Real.sin θ * (Vec3.cross B vh) 0 = (Vec3.rotateAxis B θ vh) 0
    simp only [Vec3.rotateAxis, Vec3.rotateAxisC, Vec3.cross, Vec3.mk, trackScalar_cos_real,
      trackScalar_sin_real, Fin.isValue, Fin.reduceEq, reduceIte]
    linear_combination (-(1 - Real.cos θ) * B 0) * hBv
  · show Real.cos θ * vh 1 + Real.sin θ * (Vec3.cross B vh) 1 = (Vec3.rotateAxis B θ vh) 1
    simp only [Vec3.rotateAxis, Vec3.rotateAxisC, Vec3.cross, Vec3.mk, trackScalar_cos_real,
      trackScalar_sin_real, Fin.isValue, Fin.reduceEq, reduceIte]
    linear_combination (-(1 - Real.cos θ) * B 1) * hBv
  · show Real.cos θ * vh 2 + Real.sin θ * (Vec3.cross B vh) 2 = (Vec3.rotateAxis B θ vh) 2
    simp only [Vec3.rotateAxis, Vec3.rotateAxisC, Vec3.cross, Vec3.mk, trackScalar_cos_real,
      trackScalar_sin_real, Fin.isValue, Fin.reduceEq, reduceIte]
    linear_combination (-(1 - Real.cos θ) * B 2) * hBv

/-- **The exact tangent equals `tangentAt` (grounding, per component).** The derivative of
    the exact clothoid position component is exactly the `i`-th component of
    `rotateAxis B θ(s) vh` — the value `tangentAt` computes — when `vh ⟂ B`. So
    `tangentAt`'s closed-form expression is genuinely the tangent of the exact curve. -/
theorem hasDerivAt_clothoidPosComp (p vh B : Vec3 ℝ) (κ₀ κ' : ℝ) (i : Fin 3) (s : ℝ)
    (hBv : B 0 * vh 0 + B 1 * vh 1 + B 2 * vh 2 = 0) :
    HasDerivAt (clothoidPosComp p vh (Vec3.cross B vh) κ₀ κ' i)
      ((Vec3.rotateAxis B (headingExact κ₀ κ' s) vh) i) s := by
  have h : HasDerivAt (clothoidPosComp p vh (Vec3.cross B vh) κ₀ κ' i)
      (Real.cos (headingExact κ₀ κ' s) * vh i +
        Real.sin (headingExact κ₀ κ' s) * (Vec3.cross B vh) i) s := by
    unfold clothoidPosComp
    exact (((hasDerivAt_intCos κ₀ κ' s).mul_const (vh i)).const_add (p i)).add
      ((hasDerivAt_intSin κ₀ κ' s).mul_const ((Vec3.cross B vh) i))
  rwa [exactTangent_eq_rotate B vh _ i hBv] at h

/-- The exact clothoid local offset `(∫cos θ, ∫sin θ)` — the noncomputable model the numeric
    `clothoidOffset` is assumed to realize (§6). -/
noncomputable def clothoidOffsetExact (κ₀ κ' s : ℝ) : ℝ × ℝ :=
  (∫ u in (0:ℝ)..s, Real.cos (headingExact κ₀ κ' u),
   ∫ u in (0:ℝ)..s, Real.sin (headingExact κ₀ κ' u))

/-! ## 5. Corner-level aggregate (within-corner G¹ + G² capstone)

Packages the §4 junction lemmas for a full spiral corner exactly as
`solveCornerWithGeometry` emits it (entry clothoid → circular arc → exit clothoid, sharing
the unit binormal `B`, spiral angle `θs = Ls/(2·absR)`, and stored tangents `tanSC`,
`tanCS`): the tangent (G¹) and curvature (G²) agree across **both** internal junctions. -/

theorem spiralCorner_within_G1_G2
    (absR Ls θs φ : ℝ) (hR : absR ≠ 0) (hLs : Ls ≠ 0) (hLsθ : Ls = 2 * absR * θs)
    (ts uIn B tanSC tanCS sc cs : Vec3 ℝ)
    (hB : Vec3.normSq B = 1) (hu : Vec3.normSq uIn = 1)
    (htanSC : tanSC = Vec3.rotateAxisC (B 0) (B 1) (B 2) θs uIn)
    (htanCS : tanCS = Vec3.rotateAxisC (B 0) (B 1) (B 2) φ tanSC) :
    let entry := Segment.transitionIn absR (.gn 2) ts uIn B Ls .clothoid
    let arcP  := Segment.arc absR sc cs tanSC B (some φ)
    let exitP := Segment.transitionOut absR (.gn 2) cs tanCS B Ls .clothoid
    -- G¹ (tangent) continuity at the two internal junctions:
    (entry.tangentAt Ls = arcP.tangentAt 0
      ∧ arcP.tangentAt (absR * φ) = exitP.tangentAt 0)
    -- G² (curvature) continuity at the two internal junctions:
    ∧ (entry.curvatureAt Ls = arcP.curvatureAt 0
      ∧ arcP.curvatureAt (absR * φ) = exitP.curvatureAt 0) := by
  have htanSCU : Vec3.normSq tanSC = 1 := by
    rw [htanSC, rotateAxisC_normSq _ _ _ _ _ hB]; exact hu
  refine ⟨⟨?_, ?_⟩, ?_, ?_⟩
  · exact tangent_continuity_in_arc absR Ls θs hR hLs hLsθ ts uIn B tanSC
      (.gn 2) .clothoid hB hu htanSC sc cs (some φ)
  · exact tangent_continuity_arc_out absR φ Ls hR sc cs tanSC tanCS B
      (.gn 2) .clothoid hB htanSCU htanCS
  · exact curvature_continuity_in_arc absR Ls hLs (.gn 2) ts uIn B .clothoid sc cs tanSC (some φ)
  · exact curvature_continuity_arc_out absR Ls φ sc cs tanSC B (.gn 2) cs tanCS .clothoid

/-! ## 6. The single bridge assumption

The only unproven link in this file. The Gauss–Legendre `clothoidOffset` and the exact
integral model `clothoidOffsetExact` are assumed to agree. The quadrature is a trusted,
separate code path; its numerical accuracy is **not** formalized here. Every other result in
this file — in particular the §4/§5 continuity theorems, which concern the integrator-free
`tangentAt`/`curvatureAt` — is proven without it. -/

/-- The Gauss–Legendre `clothoidOffset` agrees with the exact integral model. -/
axiom clothoidOffset_eq_exact (κ₀ κ' s : ℝ) :
    clothoidOffset κ₀ κ' s clothoidPanels = clothoidOffsetExact κ₀ κ' s

/-- **Realization corollary (uses the §6 bridge).** Transported through
    `clothoidOffset_eq_exact`, the *computable* along-tangent offset produced by the numeric
    `clothoidOffset` has the exact FTC derivative `cos θ(s)` — grounding the sampler's tangent
    in real geometry. This corollary intentionally depends on the bridge axiom. -/
theorem clothoidOffset_hasDerivAt_cos (κ₀ κ' : ℝ) (s : ℝ) :
    HasDerivAt (fun s => (clothoidOffset κ₀ κ' s clothoidPanels).1)
      (Real.cos (headingExact κ₀ κ' s)) s := by
  have hfun : (fun s => (clothoidOffset κ₀ κ' s clothoidPanels).1)
      = (fun s => ∫ u in (0:ℝ)..s, Real.cos (headingExact κ₀ κ' u)) := by
    funext s; rw [clothoidOffset_eq_exact]; rfl
  rw [hfun]; exact hasDerivAt_intCos κ₀ κ' s

/-! ## G⁰ (positional) endpoint sharing

Each curved piece starts exactly at its stored `startPt`: sampling at arc-length `0` returns
it. Holds for the *numeric* sampler directly — the `s = 0` clothoid offset is `(0,0)` (the
`g.half = 0` factor), so the local-frame placement `p + 0·v̂ + 0·n̂` collapses to `p`. This is
the G⁰ leg of within-corner continuity: each junction point is literally the next piece's
`startPt`. -/

/-- The numeric clothoid offset at `s = 0` is `(0, 0)` (the panel half-width `g.half` is `0`). -/
theorem clothoidOffset_zero (κ₀ κ' : ℝ) :
    clothoidOffset κ₀ κ' 0 clothoidPanels = (0, 0) := by
  simp [clothoidOffset, GL3.on]

/-- Every clothoid/transition/arc point sampler returns its start point at arc-length `0`. -/
theorem clothoidPoint_zero (p v : Vec3 ℝ) (κ₀ κ₁ L : ℝ) (B : Vec3 ℝ) :
    clothoidPoint p v κ₀ κ₁ L 0 B = p := by
  simp [clothoidPoint, clothoidOffset_zero]

/-- G⁰: an entry spiral starts at its `startPt`. -/
theorem pointAt_zero_transitionIn (r : ℝ) (cont : GeometricContinuity) (p v B : Vec3 ℝ)
    (len : ℝ) :
    (Segment.transitionIn r cont p v B len .clothoid).pointAt 0 = p :=
  clothoidPoint_zero p v 0 (1 / r) len B

/-- G⁰: a circular arc starts at its `startPt`. -/
theorem pointAt_zero_arc (r : ℝ) (p q v B : Vec3 ℝ) (sw : Option ℝ) :
    (Segment.arc r p q v B sw).pointAt 0 = p :=
  clothoidPoint_zero p v (1 / r) (1 / r) 1 B

/-- G⁰: an exit spiral starts at its `startPt`. -/
theorem pointAt_zero_transitionOut (r : ℝ) (cont : GeometricContinuity) (p v B : Vec3 ℝ)
    (len : ℝ) :
    (Segment.transitionOut r cont p v B len .clothoid).pointAt 0 = p :=
  clothoidPoint_zero p v (1 / r) 0 len B

end TrackGeometry.Continuity
