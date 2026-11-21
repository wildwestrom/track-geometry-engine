import TrackGeometry.Real

/-! # Bisection bracket invariant and error bound

Machine-checked convergence guarantees over `ℝ` for the fixed-count bracketed bisection
used by `solveCornerParams` (`TrackGeometry.Design`).

Every theorem in this module is proven directly over `ℝ` without any extra axioms
(in particular, it does not depend on `clothoidOffset_eq_exact`).
-/

namespace TrackGeometry.Bisection

@[simp] private lemma natToScalar_two_real : (natToScalar 2 : ℝ) = 2 := by
  norm_num [natToScalar]

/-! ## 1. Generic bisection invariants and width contraction -/

/-- One bisection step preserves the root-bracketing invariant `f lo ≤ target ≤ f hi`. -/
theorem bisectStep_preserves_bracket (f : ℝ → ℝ) (target lo hi : ℝ)
    (hlo : f lo ≤ target) (hhi : target ≤ f hi) :
    let (lo', hi') := bisectStep f target lo hi
    f lo' ≤ target ∧ target ≤ f hi' := by
  dsimp only [bisectStep]
  split_ifs with h
  · exact ⟨h, hhi⟩
  · exact ⟨hlo, le_of_not_ge h⟩

/-- Running `n` bisection steps preserves the root-bracketing invariant `f lo ≤ target ≤ f hi`. -/
theorem bisect_preserves_bracket (f : ℝ → ℝ) (target lo hi : ℝ) (n : Nat)
    (hlo : f lo ≤ target) (hhi : target ≤ f hi) :
    let (lo', hi') := bisect f target n lo hi
    f lo' ≤ target ∧ target ≤ f hi' := by
  induction n generalizing lo hi with
  | zero => exact ⟨hlo, hhi⟩
  | succ n ih =>
    simp only [bisect]
    have hstep := bisectStep_preserves_bracket f target lo hi hlo hhi
    exact ih (bisectStep f target lo hi).1 (bisectStep f target lo hi).2 hstep.1 hstep.2

/-- One bisection step cuts the bracket width exactly in half. -/
theorem bisectStep_width (f : ℝ → ℝ) (target lo hi : ℝ) :
    let (lo', hi') := bisectStep f target lo hi
    hi' - lo' = (hi - lo) / 2 := by
  dsimp only [bisectStep]
  rw [natToScalar_two_real]
  split_ifs <;> ring

/-- Running `n` bisection steps shrinks the bracket width to `(hi - lo) / 2 ^ n`. -/
theorem bisect_width (f : ℝ → ℝ) (target lo hi : ℝ) (n : Nat) :
    let (lo', hi') := bisect f target n lo hi
    hi' - lo' = (hi - lo) / 2 ^ n := by
  induction n generalizing lo hi with
  | zero =>
    simp [bisect]
  | succ n ih =>
    simp only [bisect]
    have hstep : (bisectStep f target lo hi).2 - (bisectStep f target lo hi).1 = (hi - lo) / 2 :=
      bisectStep_width f target lo hi
    have hrec : (bisect f target n (bisectStep f target lo hi).1 (bisectStep f target lo hi).2).2 -
        (bisect f target n (bisectStep f target lo hi).1 (bisectStep f target lo hi).2).1 =
        ((bisectStep f target lo hi).2 - (bisectStep f target lo hi).1) / 2 ^ n :=
      ih (bisectStep f target lo hi).1 (bisectStep f target lo hi).2
    show (bisect f target n (bisectStep f target lo hi).1 (bisectStep f target lo hi).2).2 -
        (bisect f target n (bisectStep f target lo hi).1 (bisectStep f target lo hi).2).1 =
        (hi - lo) / 2 ^ (n + 1)
    rw [hrec, hstep]
    ring

/-- One bisection step keeps an ordered bracket ordered and nested inside `[lo, hi]`. -/
theorem bisectStep_nested (f : ℝ → ℝ) (target lo hi : ℝ) (hle : lo ≤ hi) :
    let (lo', hi') := bisectStep f target lo hi
    lo ≤ lo' ∧ lo' ≤ hi' ∧ hi' ≤ hi := by
  dsimp only [bisectStep]
  rw [natToScalar_two_real]
  split_ifs <;> refine ⟨by linarith, by linarith, by linarith⟩

/-- Running `n` bisection steps keeps an ordered bracket ordered and nested inside `[lo, hi]`. -/
theorem bisect_nested (f : ℝ → ℝ) (target lo hi : ℝ) (n : Nat) (hle : lo ≤ hi) :
    let (lo', hi') := bisect f target n lo hi
    lo ≤ lo' ∧ lo' ≤ hi' ∧ hi' ≤ hi := by
  induction n generalizing lo hi with
  | zero =>
    exact ⟨le_refl lo, hle, le_refl hi⟩
  | succ n ih =>
    simp only [bisect]
    have hstep := bisectStep_nested f target lo hi hle
    have hrec := ih (bisectStep f target lo hi).1 (bisectStep f target lo hi).2 hstep.2.1
    exact ⟨le_trans hstep.1 hrec.1, hrec.2.1, le_trans hrec.2.2 hstep.2.2⟩

/-- Any value inside the final `n`-step bracket lies within `(hi - lo) / 2 ^ (n + 1)` of
the final midpoint. -/
theorem bisect_midpoint_error (f : ℝ → ℝ) (target lo hi r : ℝ) (n : Nat)
    (hrlo : (bisect f target n lo hi).1 ≤ r) (hrhi : r ≤ (bisect f target n lo hi).2) :
    |(bisect f target n lo hi).1 + (bisect f target n lo hi).2 - 2 * r| / 2
      ≤ (hi - lo) / 2 ^ (n + 1) := by
  have hw := bisect_width f target lo hi n
  set lo' := (bisect f target n lo hi).1
  set hi' := (bisect f target n lo hi).2
  have habs : |lo' + hi' - 2 * r| ≤ hi' - lo' := by
    rw [abs_le]
    constructor <;> linarith
  have hdiv : |lo' + hi' - 2 * r| / 2 ≤ (hi' - lo') / 2 := by
    linarith
  have hpow : (hi' - lo') / 2 = (hi - lo) / 2 ^ (n + 1) := by
    rw [hw]
    ring
  linarith

/-! ## 2. Specialization to `SpeedModel.pullback` and `solveCornerParams` -/

/-- Evaluating `SpeedModel.pullback` at zero radius always returns zero. -/
lemma pullback_zero (sm : SpeedModel ℝ) (tanHalf delta : ℝ) :
    sm.pullback tanHalf delta 0 = 0 := by
  simp [SpeedModel.pullback]

/-- Each bisection step on `SpeedModel.pullback` preserves `pullback(lo) ≤ budget ≤ pullback(hi)`. -/
theorem pullback_bisectStep_preserves_bracket (sm : SpeedModel ℝ)
    (tanHalf delta budget lo hi : ℝ)
    (hlo : sm.pullback tanHalf delta lo ≤ budget)
    (hhi : budget ≤ sm.pullback tanHalf delta hi) :
    let (lo', hi') := bisectStep (sm.pullback tanHalf delta) budget lo hi
    sm.pullback tanHalf delta lo' ≤ budget ∧ budget ≤ sm.pullback tanHalf delta hi' :=
  bisectStep_preserves_bracket (sm.pullback tanHalf delta) budget lo hi hlo hhi

/-- Running `n` bisection steps on `SpeedModel.pullback` preserves
`pullback(lo) ≤ budget ≤ pullback(hi)`. -/
theorem pullback_bisect_preserves_bracket (sm : SpeedModel ℝ)
    (tanHalf delta budget lo hi : ℝ) (n : Nat)
    (hlo : sm.pullback tanHalf delta lo ≤ budget)
    (hhi : budget ≤ sm.pullback tanHalf delta hi) :
    let (lo', hi') := bisect (sm.pullback tanHalf delta) budget n lo hi
    sm.pullback tanHalf delta lo' ≤ budget ∧ budget ≤ sm.pullback tanHalf delta hi' :=
  bisect_preserves_bracket (sm.pullback tanHalf delta) budget lo hi n hlo hhi

/-- Running `n` bisection steps on `SpeedModel.pullback` shrinks the bracket width to
`(hi - lo) / 2 ^ n`. -/
theorem pullback_bisect_width (sm : SpeedModel ℝ)
    (tanHalf delta budget lo hi : ℝ) (n : Nat) :
    let (lo', hi') := bisect (sm.pullback tanHalf delta) budget n lo hi
    hi' - lo' = (hi - lo) / 2 ^ n :=
  bisect_width (sm.pullback tanHalf delta) budget lo hi n

/-- Initial search bracket `(R_lo, R_hi)` selected by `solveCornerParamsBisect` after the
design-speed cap regime split. -/
noncomputable def solveCornerInitialBracket (budget tanHalf delta : ℝ) (sm : SpeedModel ℝ) : ℝ × ℝ :=
  let rFillet := budget / tanHalf
  let pb := sm.pullback tanHalf delta
  if sm.maxDesignSpeed > 0 then
    let rCap := sm.maxDesignSpeed * sm.maxDesignSpeed / sm.maxLateralAccel
    if pb rCap ≥ budget then
      (0, min rCap rFillet)
    else
      (rCap, rFillet)
  else
    (0, rFillet)

/-- The initial bracket chosen by `solveCornerParams` satisfies the root-bracketing
invariant whenever `budget > 0` and the pure-fillet radius has pullback at least `budget`. -/
theorem solveCornerInitialBracket_valid (budget tanHalf delta : ℝ) (sm : SpeedModel ℝ)
    (hbudget : budget > 0)
    (hfillet : budget ≤ sm.pullback tanHalf delta (budget / tanHalf)) :
    let (lo₀, hi₀) := solveCornerInitialBracket budget tanHalf delta sm
    sm.pullback tanHalf delta lo₀ ≤ budget ∧ budget ≤ sm.pullback tanHalf delta hi₀ := by
  dsimp only [solveCornerInitialBracket]
  split_ifs with hspd hcap
  · refine ⟨by rw [pullback_zero]; exact le_of_lt hbudget, ?_⟩
    rcases min_cases (sm.maxDesignSpeed * sm.maxDesignSpeed / sm.maxLateralAccel)
      (budget / tanHalf) with ⟨hmin, _⟩ | ⟨hmin, _⟩
    · rw [hmin]; exact hcap
    · rw [hmin]; exact hfillet
  · exact ⟨le_of_not_ge hcap, hfillet⟩
  · exact ⟨by rw [pullback_zero]; exact le_of_lt hbudget, hfillet⟩

/-- For a standard corner (`tanHalf > 0`, `budget > 0`, `maxLateralAccel > 0`), the 52-step
bisection inside `solveCornerParams` preserves the root-bracketing invariant, narrows the
initial bracket `(R_lo, R_hi)` to width `(R_hi - R_lo) / 2 ^ 52`, and returns the final
bracket's midpoint as the solved radius. -/
theorem solveCornerParams_bisect_convergence (budget tanHalf delta straightThreshold : ℝ)
    (sm : SpeedModel ℝ)
    (htan : tanHalf > 0) (hbudget : budget > 0) (hlat : sm.maxLateralAccel > 0)
    (hlo₀ : sm.pullback tanHalf delta (solveCornerInitialBracket budget tanHalf delta sm).1 ≤ budget)
    (hhi₀ : budget ≤ sm.pullback tanHalf delta (solveCornerInitialBracket budget tanHalf delta sm).2) :
    let br := solveCornerInitialBracket budget tanHalf delta sm
    let res := bisect (sm.pullback tanHalf delta) budget bisectionSteps br.1 br.2
    (solveCornerParams budget tanHalf delta sm straightThreshold).radius = (res.1 + res.2) / 2
      ∧ (sm.pullback tanHalf delta res.1 ≤ budget ∧ budget ≤ sm.pullback tanHalf delta res.2)
      ∧ res.2 - res.1 = (br.2 - br.1) / 2 ^ 52 := by
  set br := solveCornerInitialBracket budget tanHalf delta sm
  set res := bisect (sm.pullback tanHalf delta) budget bisectionSteps br.1 br.2
  have hrad :
      (solveCornerParams budget tanHalf delta sm straightThreshold).radius
        = (res.1 + res.2) / 2 := by
    have hlat' : ¬ sm.maxLateralAccel ≤ 0 := not_le.mpr hlat
    have hbudget' : ¬ budget ≤ 0 := not_le.mpr hbudget
    unfold solveCornerParams
    simp only [htan, ↓reduceIte]
    unfold solveCornerParamsBisect
    simp only [hlat', hbudget', ↓reduceIte]
    have hbr :
        (if sm.maxDesignSpeed > 0 then
          let rCap := sm.maxDesignSpeed * sm.maxDesignSpeed / sm.maxLateralAccel
          if sm.pullback tanHalf delta rCap ≥ budget then
            (0, min rCap (budget / tanHalf))
          else
            (rCap, budget / tanHalf)
        else
          (0, budget / tanHalf)) = br := rfl
    change (let x := if sm.maxDesignSpeed > 0 then
          let rCap := sm.maxDesignSpeed * sm.maxDesignSpeed / sm.maxLateralAccel
          if sm.pullback tanHalf delta rCap ≥ budget then
            (0, min rCap (budget / tanHalf))
          else
            (rCap, budget / tanHalf)
        else
          (0, budget / tanHalf)
      let y := bisect (sm.pullback tanHalf delta) budget bisectionSteps x.1 x.2
      let R := (y.1 + y.2) / natToScalar 2
      let θs := sm.spiralAngle R delta
      let opSpeed := sm.speedAt R
      if θs ≤ 0 then
        ({ radius := R, spiralAngle := 0, spiralLength := 0, arcAngle := delta, opSpeed := opSpeed } : CornerParams ℝ)
      else
        { radius := R, spiralAngle := θs, spiralLength := natToScalar 2 * R * θs,
          arcAngle := delta - natToScalar 2 * θs, opSpeed := opSpeed }).radius = (res.1 + res.2) / 2
    rw [hbr]
    dsimp only
    change (if sm.spiralAngle ((res.1 + res.2) / natToScalar 2) delta ≤ 0 then
        ({ radius := (res.1 + res.2) / natToScalar 2, spiralAngle := 0, spiralLength := 0,
           arcAngle := delta, opSpeed := sm.speedAt ((res.1 + res.2) / natToScalar 2) } : CornerParams ℝ)
      else
        { radius := (res.1 + res.2) / natToScalar 2,
          spiralAngle := sm.spiralAngle ((res.1 + res.2) / natToScalar 2) delta,
          spiralLength := natToScalar 2 * ((res.1 + res.2) / natToScalar 2) *
            sm.spiralAngle ((res.1 + res.2) / natToScalar 2) delta,
          arcAngle := delta - natToScalar 2 *
            sm.spiralAngle ((res.1 + res.2) / natToScalar 2) delta,
          opSpeed := sm.speedAt ((res.1 + res.2) / natToScalar 2) }).radius
      = (res.1 + res.2) / 2
    split_ifs <;> exact congrArg ((res.1 + res.2) / ·) natToScalar_two_real
  have hinv : sm.pullback tanHalf delta res.1 ≤ budget ∧ budget ≤ sm.pullback tanHalf delta res.2 :=
    pullback_bisect_preserves_bracket sm tanHalf delta budget br.1 br.2 bisectionSteps hlo₀ hhi₀
  have hwid : res.2 - res.1 = (br.2 - br.1) / 2 ^ 52 := by
    have h : res.2 - res.1 = (br.2 - br.1) / 2 ^ bisectionSteps :=
      pullback_bisect_width sm tanHalf delta budget br.1 br.2 bisectionSteps
    have h52 : (2 : ℝ) ^ bisectionSteps = 2 ^ 52 := rfl
    rw [h, h52]
  exact ⟨hrad, hinv, hwid⟩

end TrackGeometry.Bisection
