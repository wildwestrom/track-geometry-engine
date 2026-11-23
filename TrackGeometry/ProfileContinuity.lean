import TrackGeometry.Real
import TrackGeometry.Budget
import Mathlib.Analysis.Calculus.Deriv.Add
import Mathlib.Analysis.Calculus.Deriv.Mul

set_option linter.missingDocs true

/-! # 1D vertical alignment calculus and continuity proofs

Machine-checked guarantees over `ℝ` for vertical alignment profiles (`TrackGeometry.Profile`):

* Exact calculus: `HasDerivAt` of `elevationAt` equals `gradeAt`, and `HasDerivAt` of `gradeAt`
  equals `curvatureAt`, on both `grade` and `parabola` segments.
* Junction C⁰ / C¹ continuity: elevation (`C⁰`) and grade (`C¹`) match across `grade → parabola`,
  `parabola → grade`, and touching `parabola → parabola` junctions.
* Builder invariants: `buildProfile` partitions the station range of strictly increasing PVIs
  with non-negative segment lengths and matches the start and end PVI elevations.
-/

private lemma natToScalar_two_real : (natToScalar 2 : ℝ) = 2 := by
  norm_num [natToScalar]

/-- The derivative of elevation along a constant-grade segment equals its grade. -/
theorem ProfileSegment.grade_hasDerivAt_elevation (s₀ L z₀ g u : ℝ) :
    HasDerivAt (fun x => (ProfileSegment.grade s₀ L z₀ g).elevationAt x)
      ((ProfileSegment.grade s₀ L z₀ g).gradeAt u) u := by
  change HasDerivAt (fun x : ℝ => z₀ + g * x) g u
  simpa using ((hasDerivAt_id u).const_mul g).const_add z₀

/-- The derivative of grade along a constant-grade segment equals its signed curvature. -/
theorem ProfileSegment.grade_hasDerivAt_grade (s₀ L z₀ g u : ℝ) :
    HasDerivAt (fun x => (ProfileSegment.grade s₀ L z₀ g).gradeAt x)
      ((ProfileSegment.grade s₀ L z₀ g).curvatureAt u) u := by
  change HasDerivAt (fun _ : ℝ => g) 0 u
  exact hasDerivAt_const u g

/-- The derivative of elevation along a parabolic vertical curve equals its grade. -/
theorem ProfileSegment.parabola_hasDerivAt_elevation (s₀ L z₀ g₁ g₂ u : ℝ) (hL : L ≠ 0) :
    HasDerivAt (fun x => (ProfileSegment.parabola s₀ L z₀ g₁ g₂).elevationAt x)
      ((ProfileSegment.parabola s₀ L z₀ g₁ g₂).gradeAt u) u := by
  change HasDerivAt
    (fun x : ℝ => z₀ + g₁ * x + (g₂ - g₁) / ((natToScalar 2 : ℝ) * L) * (x * x))
    (g₁ + (g₂ - g₁) / L * u) u
  have h1 : HasDerivAt (fun x : ℝ => z₀ + g₁ * x) (g₁ * 1) u :=
    ((hasDerivAt_id u).const_mul g₁).const_add z₀
  have h2 : HasDerivAt (fun x : ℝ => (g₂ - g₁) / ((natToScalar 2 : ℝ) * L) * (x * x))
      ((g₂ - g₁) / ((natToScalar 2 : ℝ) * L) * (1 * u + u * 1)) u :=
    ((hasDerivAt_id u).mul (hasDerivAt_id u)).const_mul ((g₂ - g₁) / ((natToScalar 2 : ℝ) * L))
  have h := h1.add h2
  have heq : g₁ * 1 + (g₂ - g₁) / ((natToScalar 2 : ℝ) * L) * (1 * u + u * 1) =
      g₁ + (g₂ - g₁) / L * u := by
    rw [natToScalar_two_real]
    field_simp [hL]
    ring
  rwa [heq] at h

/-- The derivative of grade along a parabolic vertical curve equals its signed curvature. -/
theorem ProfileSegment.parabola_hasDerivAt_grade (s₀ L z₀ g₁ g₂ u : ℝ) (hL : L ≠ 0) :
    HasDerivAt (fun x => (ProfileSegment.parabola s₀ L z₀ g₁ g₂).gradeAt x)
      ((ProfileSegment.parabola s₀ L z₀ g₁ g₂).curvatureAt u) u := by
  have _ := hL
  change HasDerivAt (fun x : ℝ => g₁ + (g₂ - g₁) / L * x) ((g₂ - g₁) / L) u
  simpa using ((hasDerivAt_id u).const_mul ((g₂ - g₁) / L)).const_add g₁

/-- Elevation is continuous at a grade-to-parabola junction. -/
theorem ProfileSegment.grade_parabola_elevationContinuous (s₀ L₁ z₀ g₁ L₂ g₂ : ℝ) :
    let seg1 := ProfileSegment.grade s₀ L₁ z₀ g₁
    let seg2 := ProfileSegment.parabola (s₀ + L₁) L₂ (z₀ + g₁ * L₁) g₁ g₂
    seg1.elevationAt seg1.length = seg2.elevationAt 0 := by
  dsimp only [ProfileSegment.elevationAt, ProfileSegment.length]
  ring

/-- Grade is continuous at a grade-to-parabola junction. -/
theorem ProfileSegment.grade_parabola_gradeContinuous (s₀ L₁ z₀ g₁ L₂ g₂ : ℝ) :
    let seg1 := ProfileSegment.grade s₀ L₁ z₀ g₁
    let seg2 := ProfileSegment.parabola (s₀ + L₁) L₂ (z₀ + g₁ * L₁) g₁ g₂
    seg1.gradeAt seg1.length = seg2.gradeAt 0 := by
  dsimp only [ProfileSegment.gradeAt, ProfileSegment.length]
  ring

/-- Elevation is continuous at a parabola-to-grade junction. -/
theorem ProfileSegment.parabola_grade_elevationContinuous (s₀ L₁ z₀ g₁ g₂ L₂ : ℝ)
    (hL₁ : L₁ ≠ 0) :
    let seg1 := ProfileSegment.parabola s₀ L₁ z₀ g₁ g₂
    let seg2 := ProfileSegment.grade (s₀ + L₁) L₂ (z₀ + (g₁ + g₂) / 2 * L₁) g₂
    seg1.elevationAt seg1.length = seg2.elevationAt 0 := by
  have _ := hL₁
  dsimp only [ProfileSegment.elevationAt, ProfileSegment.length]
  rw [natToScalar_two_real]
  field_simp [hL₁]
  ring

/-- Grade is continuous at a parabola-to-grade junction. -/
theorem ProfileSegment.parabola_grade_gradeContinuous (s₀ L₁ z₀ g₁ g₂ L₂ : ℝ)
    (hL₁ : L₁ ≠ 0) :
    let seg1 := ProfileSegment.parabola s₀ L₁ z₀ g₁ g₂
    let seg2 := ProfileSegment.grade (s₀ + L₁) L₂ (z₀ + (g₁ + g₂) / 2 * L₁) g₂
    seg1.gradeAt seg1.length = seg2.gradeAt 0 := by
  dsimp only [ProfileSegment.gradeAt, ProfileSegment.length]
  field_simp [hL₁]
  ring

/-- Elevation is continuous at a touching parabola-to-parabola junction. -/
theorem ProfileSegment.parabola_parabola_elevationContinuous (s₀ L₁ z₀ g₁ g₂ L₂ g₃ : ℝ)
    (hL₁ : L₁ ≠ 0) :
    let seg1 := ProfileSegment.parabola s₀ L₁ z₀ g₁ g₂
    let seg2 := ProfileSegment.parabola (s₀ + L₁) L₂ (z₀ + (g₁ + g₂) / 2 * L₁) g₂ g₃
    seg1.elevationAt seg1.length = seg2.elevationAt 0 := by
  have _ := hL₁
  dsimp only [ProfileSegment.elevationAt, ProfileSegment.length]
  rw [natToScalar_two_real]
  simp only [mul_zero, add_zero]
  field_simp [hL₁]
  ring

/-- Grade is continuous at a touching parabola-to-parabola junction. -/
theorem ProfileSegment.parabola_parabola_gradeContinuous (s₀ L₁ z₀ g₁ g₂ L₂ g₃ : ℝ)
    (hL₁ : L₁ ≠ 0) :
    let seg1 := ProfileSegment.parabola s₀ L₁ z₀ g₁ g₂
    let seg2 := ProfileSegment.parabola (s₀ + L₁) L₂ (z₀ + (g₁ + g₂) / 2 * L₁) g₂ g₃
    seg1.gradeAt seg1.length = seg2.gradeAt 0 := by
  dsimp only [ProfileSegment.gradeAt, ProfileSegment.length]
  simp only [mul_zero, add_zero]
  field_simp [hL₁]
  ring

private lemma absScalar_nonneg_real (x : ℝ) : 0 ≤ absScalar x := by
  unfold absScalar
  split_ifs <;> linarith

private lemma station_lt_of_lt (pvis : Array (PVI ℝ))
    (hinc : ∀ (i : Nat) (hi : i + 1 < pvis.size), pvis[i].station < pvis[i + 1].station) :
    ∀ (i j : Nat) (hij : i < j) (hj : j < pvis.size), pvis[i].station < pvis[j].station := by
  intro i j hij hj
  induction j with
  | zero => omega
  | succ j ih =>
    by_cases h : i = j
    · subst h
      exact hinc i hj
    · exact lt_trans (ih (by omega) (by omega)) (hinc j hj)

private lemma filterIncreasingPVIs_go_strict (pvis : Array (PVI ℝ))
    (pviSpeeds : Array (Option ℝ))
    (hinc : ∀ (i : Nat) (hi : i + 1 < pvis.size), pvis[i].station < pvis[i + 1].station) :
    ∀ (m i : Nat) (acc : Array (PVI ℝ × Option ℝ))
      (_hm : i + m = pvis.size)
      (_hacc_sz : acc.size = i),
      (∀ (j : Nat) (hj : j < i), (acc[j]'(by omega)).1 = pvis[j]'(by omega)) →
      let res := filterIncreasingPVIs.go pvis pviSpeeds i acc
      ∃ (_hsz : res.size = pvis.size),
        ∀ (j : Nat) (hj : j < pvis.size), (res[j]'(by omega)).1 = pvis[j] := by
  intro m
  induction m with
  | zero =>
    intro i acc hm hacc_sz hacc_eq
    have hi : ¬ (i < pvis.size) := by omega
    dsimp only
    unfold filterIncreasingPVIs.go
    simp only [hi, ↓reduceDIte]
    refine ⟨by omega, ?_⟩
    intro j hj
    exact hacc_eq j (by omega)
  | succ m ih =>
    intro i acc hm hacc_sz hacc_eq
    have hi : i < pvis.size := by omega
    dsimp only
    unfold filterIncreasingPVIs.go
    simp only [hi, ↓reduceDIte]
    split
    · apply ih (i + 1) (acc.push (pvis[i], (pviSpeeds[i]?).bind id)) (by omega) (by simp [hacc_sz])
      intro j hj
      by_cases hji : j < i
      · have hlt : j < acc.size := by omega
        rw [Array.getElem_push_lt hlt]
        exact hacc_eq j hji
      · have hjeq : j = i := by omega
        subst hjeq
        have hsz : j = acc.size := by omega
        simp [Array.getElem_push_eq, hsz]
    · rename_i hfalse
      exfalso
      cases hback : acc.back? with
      | none =>
        simp [hback] at hfalse
      | some lastPair =>
        have hpos : 0 < acc.size := by
          rw [Array.back?] at hback
          by_contra h0
          have hsz0 : acc.size = 0 := by omega
          simp [hsz0] at hback
        have hget : acc[acc.size - 1]'(by omega) = lastPair := by
          rw [Array.back?] at hback
          have hlt : acc.size - 1 < acc.size := by omega
          simp [hlt] at hback
          exact hback
        have hfst : lastPair.1 = pvis[i - 1]'(by omega) := by
          rw [← hget]
          have hidx : acc.size - 1 = i - 1 := by omega
          simpa only [hidx] using hacc_eq (i - 1) (by omega)
        have hlt : (pvis[i - 1]'(by omega)).station < pvis[i].station := by
          have hidx : i - 1 + 1 = i := by omega
          simpa only [hidx] using hinc (i - 1) (by omega)
        have hlt' : lastPair.1.station < pvis[i].station := by
          simpa [hfst] using hlt
        simp [hback, hlt'] at hfalse

private lemma filterIncreasingPVIs_strict (pvis : Array (PVI ℝ))
    (pviSpeeds : Array (Option ℝ))
    (hinc : ∀ (i : Nat) (hi : i + 1 < pvis.size), pvis[i].station < pvis[i + 1].station) :
    let res := filterIncreasingPVIs pvis pviSpeeds
    ∃ (_hsz : res.size = pvis.size),
      ∀ (j : Nat) (hj : j < pvis.size), (res[j]'(by omega)).1 = pvis[j] := by
  exact filterIncreasingPVIs_go_strict pvis pviSpeeds hinc pvis.size 0 #[] (by omega) rfl
    (fun j hj => by omega)

private lemma budgetHalfLen_nonneg (budgets : Array (Option ℝ)) (i : Nat) :
    0 ≤ budgetHalfLen budgets i := by
  unfold budgetHalfLen
  cases (budgets[i]?).bind id with
  | none => simp
  | some t =>
    dsimp only
    split_ifs <;> linarith

private lemma budgetHalfLen_eq_getD (budgets : Array (Option ℝ)) (i : Nat)
    (hnn : ∀ (b : ℝ), (budgets[i]?).bind id = some b → 0 ≤ b) :
    budgetHalfLen budgets i = ((budgets[i]?).bind id).getD 0 := by
  unfold budgetHalfLen
  cases h : (budgets[i]?).bind id with
  | none => rfl
  | some t =>
    simp only [Option.getD_some]
    have ht : 0 ≤ t := hnn t h
    split_ifs <;> linarith

private lemma resolveSharedLegs_none_of_ask_none (legLengths : Array ℝ)
    (asks : Array (Option ℝ)) (i : Nat) (h : (asks[i]?).bind id = none) :
    ((resolveSharedLegs legLengths asks)[i]?).bind id = none := by
  unfold resolveSharedLegs
  dsimp only
  by_cases hi : i < asks.size
  · have h' : asks[i] = none := by
      simpa [Array.getElem?_eq_getElem hi] using h
    simp [hi, h']
  · simp [hi]

private def SegmentChain (segs : Array (ProfileSegment ℝ)) (s₀ z₀ s₁ z₁ : ℝ) : Prop :=
  (segs.size = 0 ∧ s₀ = s₁ ∧ z₀ = z₁) ∨
  ∃ (hne : 0 < segs.size),
    (∀ (k : Nat) (hk : k < segs.size), 0 < segs[k].length) ∧
    (∀ (k : Nat) (hk : k + 1 < segs.size), segs[k].endStation = segs[k + 1].startStation) ∧
    segs[0].startStation = s₀ ∧
    segs[0].elevationAt 0 = z₀ ∧
    segs[segs.size - 1].endStation = s₁ ∧
    segs[segs.size - 1].elevationAt segs[segs.size - 1].length = z₁

private lemma SegmentChain.push (segs : Array (ProfileSegment ℝ)) (s₀ z₀ s₁ z₁ : ℝ)
    (seg : ProfileSegment ℝ)
    (hc : SegmentChain segs s₀ z₀ s₁ z₁)
    (hlen : 0 < seg.length)
    (hstart : seg.startStation = s₁)
    (hzstart : seg.elevationAt 0 = z₁) :
    SegmentChain (segs.push seg) s₀ z₀ seg.endStation (seg.elevationAt seg.length) := by
  right
  refine ⟨by simp, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro k hk
    by_cases hlt : k < segs.size
    · rw [Array.getElem_push_lt hlt]
      rcases hc with ⟨h0, _⟩ | ⟨_, hlen', _⟩
      · omega
      · exact hlen' k hlt
    · have hkeq : k = segs.size := by simp at hk; omega
      subst hkeq
      rw [Array.getElem_push_eq]
      exact hlen
  · intro k hk
    rcases hc with ⟨h0, _⟩ | ⟨hne, _, hadj, _, _, hend, _⟩
    · simp [h0] at hk
    · by_cases hlt : k + 1 < segs.size
      · rw [Array.getElem_push_lt (by omega), Array.getElem_push_lt hlt]
        exact hadj k hlt
      · have hkeq : k = segs.size - 1 := by simp at hk; omega
        have hklt : k < segs.size := by omega
        have hk1eq : k + 1 = segs.size := by omega
        rw [Array.getElem_push_lt hklt]
        simp only [hk1eq, Array.getElem_push_eq]
        rw [hstart, ← hend]
        simp only [hkeq]
  · rcases hc with ⟨h0, heq, _⟩ | ⟨hne, _, _, hfirst, _⟩
    · have h0' : (0 : Nat) = segs.size := by omega
      simp only [h0', Array.getElem_push_eq]
      rw [hstart, ← heq]
    · rw [Array.getElem_push_lt hne]
      exact hfirst
  · rcases hc with ⟨h0, _, hzeq⟩ | ⟨hne, _, _, _, hzfirst, _⟩
    · have h0' : (0 : Nat) = segs.size := by omega
      simp only [h0', Array.getElem_push_eq]
      rw [hzstart, ← hzeq]
    · rw [Array.getElem_push_lt hne]
      exact hzfirst
  · have hlast : (segs.push seg).size - 1 = segs.size := by simp
    simp only [hlast, Array.getElem_push_eq]
  · have hlast : (segs.push seg).size - 1 = segs.size := by simp
    simp only [hlast, Array.getElem_push_eq]

private lemma buildProfile_emit_chain
    (n : Nat) (pviAt : Nat → PVI ℝ) (grades : Array ℝ) (budgets : Array (Option ℝ))
    (s0 z0 : ℝ)
    (hBudgetLast : budgetHalfLen budgets (n - 1) = 0)
    (hLegSum : ∀ (k : Nat), k + 1 < n →
      budgetHalfLen budgets k + budgetHalfLen budgets (k + 1) ≤
        (pviAt (k + 1)).station - (pviAt k).station)
    (hGrades : ∀ (k : Nat), k + 1 < n →
      grades.getD k 0 * ((pviAt (k + 1)).station - (pviAt k).station) =
        (pviAt (k + 1)).elevation - (pviAt k).elevation) :
    ∀ (m k : Nat) (acc : Array (ProfileSegment ℝ)),
      k + m = n - 1 →
      SegmentChain acc s0 z0 ((pviAt k).station + budgetHalfLen budgets k)
        ((pviAt k).elevation + grades.getD k 0 * budgetHalfLen budgets k) →
      SegmentChain (buildProfile.emit n pviAt grades (natToScalar 2) budgets k acc)
        s0 z0 ((pviAt (n - 1)).station + budgetHalfLen budgets (n - 1))
        ((pviAt (n - 1)).elevation + grades.getD (n - 1) 0 * budgetHalfLen budgets (n - 1)) := by
  intro m
  induction m with
  | zero =>
    intro k acc hm hc0
    have hkeq : k = n - 1 := by omega
    have hk_not_lt : ¬ (k + 1 < n) := by omega
    unfold buildProfile.emit
    simp only [hk_not_lt, ↓reduceIte]
    simpa [hkeq] using hc0
  | succ m ih =>
    intro k acc hm hc0
    have hk_lt : k + 1 < n := by omega
    unfold buildProfile.emit
    simp only [hk_lt, ↓reduceIte]
    set a := pviAt k
    set b := pviAt (k + 1)
    set g := grades.getD k 0
    set tStart := budgetHalfLen budgets k
    set tEnd := budgetHalfLen budgets (k + 1)
    set sStart := a.station + tStart
    set sEnd := b.station - tEnd
    set gradeLen := sEnd - sStart
    have hfit : tStart + tEnd ≤ b.station - a.station := hLegSum k hk_lt
    have hgrade_eq : g * (b.station - a.station) = b.elevation - a.elevation := hGrades k hk_lt
    have hgrade_nn : 0 ≤ gradeLen := by
      show 0 ≤ (b.station - tEnd) - (a.station + tStart)
      linarith
    set acc1 :=
      if 0 < gradeLen then
        acc.push (.grade sStart gradeLen (a.elevation + g * tStart) g)
      else
        acc
    have hc1 : SegmentChain acc1 s0 z0 sEnd (b.elevation - g * tEnd) := by
      dsimp only [acc1]
      split_ifs with hpos
      · have hzstart : (ProfileSegment.grade sStart gradeLen (a.elevation + g * tStart) g).elevationAt 0 =
            a.elevation + g * tStart := by
          dsimp only [ProfileSegment.elevationAt]
          ring
        have hpush := SegmentChain.push acc s0 z0 sStart (a.elevation + g * tStart)
          (.grade sStart gradeLen (a.elevation + g * tStart) g) hc0 hpos rfl hzstart
        have hend : (ProfileSegment.grade sStart gradeLen (a.elevation + g * tStart) g).endStation =
            sEnd := by
          show sStart + (sEnd - sStart) = sEnd
          ring
        have hzend : (ProfileSegment.grade sStart gradeLen (a.elevation + g * tStart) g).elevationAt
            (ProfileSegment.grade sStart gradeLen (a.elevation + g * tStart) g).length =
            b.elevation - g * tEnd := by
          show (a.elevation + g * tStart) + g * ((b.station - tEnd) - (a.station + tStart)) =
            b.elevation - g * tEnd
          have hlin : (a.elevation + g * tStart) + g * ((b.station - tEnd) - (a.station + tStart)) =
              a.elevation + g * (b.station - a.station) - g * tEnd := by ring
          linarith
        rwa [hend, hzend] at hpush
      · have hzero : sStart = sEnd := by
          have : gradeLen ≤ 0 := not_lt.mp hpos
          show a.station + tStart = b.station - tEnd
          linarith
        have hzzero : a.elevation + g * tStart = b.elevation - g * tEnd := by
          have hdiff : b.station - a.station = tStart + tEnd := by
            show b.station - a.station = tStart + tEnd
            linarith [hzero]
          rw [hdiff] at hgrade_eq
          linarith
        rwa [← hzero, ← hzzero]
    set acc2 :=
      if k + 2 < n ∧ 0 < tEnd then
        let gNext := grades.getD (k + 1) 0
        acc1.push (.parabola (b.station - tEnd) ((natToScalar 2 : ℝ) * tEnd)
          (b.elevation - g * tEnd) g gNext)
      else
        acc1
    have hc2 : SegmentChain acc2 s0 z0 (b.station + tEnd)
        (b.elevation + grades.getD (k + 1) 0 * tEnd) := by
      dsimp only [acc2]
      split_ifs with hpar
      · have hlen_par : 0 < (ProfileSegment.parabola (b.station - tEnd)
            ((natToScalar 2 : ℝ) * tEnd) (b.elevation - g * tEnd) g
            (grades.getD (k + 1) 0)).length := by
          show 0 < (natToScalar 2 : ℝ) * tEnd
          rw [natToScalar_two_real]
          linarith [hpar.2]
        have hzstart : (ProfileSegment.parabola (b.station - tEnd)
            ((natToScalar 2 : ℝ) * tEnd) (b.elevation - g * tEnd) g
            (grades.getD (k + 1) 0)).elevationAt 0 = b.elevation - g * tEnd := by
          dsimp only [ProfileSegment.elevationAt]
          ring
        have hpush := SegmentChain.push acc1 s0 z0 sEnd (b.elevation - g * tEnd)
          (.parabola (b.station - tEnd) ((natToScalar 2 : ℝ) * tEnd) (b.elevation - g * tEnd) g
            (grades.getD (k + 1) 0)) hc1 hlen_par rfl hzstart
        have hend : (ProfileSegment.parabola (b.station - tEnd) ((natToScalar 2 : ℝ) * tEnd)
            (b.elevation - g * tEnd) g (grades.getD (k + 1) 0)).endStation =
            b.station + tEnd := by
          show (b.station - tEnd) + (natToScalar 2 : ℝ) * tEnd = b.station + tEnd
          rw [natToScalar_two_real]
          ring
        have hzend : (ProfileSegment.parabola (b.station - tEnd) ((natToScalar 2 : ℝ) * tEnd)
            (b.elevation - g * tEnd) g (grades.getD (k + 1) 0)).elevationAt
            (ProfileSegment.parabola (b.station - tEnd) ((natToScalar 2 : ℝ) * tEnd)
              (b.elevation - g * tEnd) g (grades.getD (k + 1) 0)).length =
            b.elevation + grades.getD (k + 1) 0 * tEnd := by
          dsimp only [ProfileSegment.elevationAt, ProfileSegment.length]
          rw [natToScalar_two_real]
          have htne : tEnd ≠ 0 := ne_of_gt hpar.2
          field_simp [htne]
          ring
        rwa [hend, hzend] at hpush
      · have htEnd0 : tEnd = 0 := by
          by_cases hk2 : k + 2 < n
          · have hnotpos : ¬ (0 < tEnd) := fun h => hpar ⟨hk2, h⟩
            have hnn : 0 ≤ tEnd := budgetHalfLen_nonneg budgets (k + 1)
            linarith
          · have hk1 : k + 1 = n - 1 := by omega
            show budgetHalfLen budgets (k + 1) = 0
            rw [hk1]
            exact hBudgetLast
        have heq : sEnd = b.station + tEnd := by
          show b.station - tEnd = b.station + tEnd
          linarith
        have hzeq : b.elevation - g * tEnd = b.elevation + grades.getD (k + 1) 0 * tEnd := by
          rw [htEnd0]
          ring
        rwa [← heq, ← hzeq]
    exact ih (k + 1) acc2 (by omega) hc2

private lemma buildProfile_chain
    (pvis : Array (PVI ℝ)) (policy : ProfilePolicy ℝ) (pviSpeeds : Array (Option ℝ))
    (hsize : 2 ≤ pvis.size)
    (hinc : ∀ (i : Nat) (hi : i + 1 < pvis.size), pvis[i].station < pvis[i + 1].station) :
    let segs := (buildProfile pvis policy pviSpeeds).segments
    ∃ (hne : 0 < segs.size),
      (∀ (k : Nat) (hk : k < segs.size), 0 < segs[k].length) ∧
      (∀ (k : Nat) (hk : k + 1 < segs.size), segs[k].endStation = segs[k + 1].startStation) ∧
      segs[0].startStation = pvis[0].station ∧
      segs[0].elevationAt 0 = pvis[0].elevation ∧
      segs[segs.size - 1].endStation = pvis[pvis.size - 1].station ∧
      segs[segs.size - 1].elevationAt segs[segs.size - 1].length = pvis[pvis.size - 1].elevation := by
  dsimp only
  suffices hchain :
      SegmentChain (buildProfile pvis policy pviSpeeds).segments
        pvis[0].station pvis[0].elevation
        pvis[pvis.size - 1].station pvis[pvis.size - 1].elevation by
    rcases hchain with ⟨_, heq, _⟩ | hok
    · have hlt : pvis[0].station < pvis[pvis.size - 1].station :=
        station_lt_of_lt pvis hinc 0 (pvis.size - 1) (by omega) (by omega)
      linarith
    · exact hok
  obtain ⟨hkept_sz, hkept_eq⟩ := filterIncreasingPVIs_strict pvis pviSpeeds hinc
  unfold buildProfile
  dsimp only
  have hn_not_lt : ¬ ((filterIncreasingPVIs pvis pviSpeeds).size < 2) := by omega
  simp only [hn_not_lt, ↓reduceIte]
  set kept := filterIncreasingPVIs pvis pviSpeeds
  set n := kept.size
  set zeroPVI : PVI ℝ := ⟨0, 0⟩
  set pviAt : Nat → PVI ℝ := fun i => (kept[i]?).map Prod.fst |>.getD zeroPVI
  set speedAt : Nat → Option ℝ := fun i => (kept[i]?).bind Prod.snd
  set legLengths : Array ℝ := (Array.range (n - 1)).map fun k =>
    (pviAt (k + 1)).station - (pviAt k).station
  set grades : Array ℝ := (Array.range (n - 1)).map fun k =>
    let a := pviAt k
    let b := pviAt (k + 1)
    (b.elevation - a.elevation) / (b.station - a.station)
  set two : ℝ := natToScalar 2
  set asks : Array (Option ℝ) := (Array.range n).map fun i =>
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
  set budgets := resolveSharedLegs legLengths asks
  have hpviAt : ∀ (i : Nat) (hi : i < n), pviAt i = pvis[i]'(by omega) := by
    intro i hi
    show ((kept[i]?).map Prod.fst).getD zeroPVI = pvis[i]'(by omega)
    have hlt : i < kept.size := hi
    simp only [Array.getElem?_eq_getElem hlt, Option.map_some, Option.getD_some]
    exact hkept_eq i (by omega)
  have hLegs : ∀ (k : Nat) (l : ℝ), legLengths[k]? = some l → 0 ≤ l := by
    intro k l hl
    by_cases hk : k < n - 1
    · simp only [legLengths, Array.getElem?_map, Array.getElem?_range, hk, ↓reduceIte,
        Option.map_some, Option.some.injEq] at hl
      rw [← hl, hpviAt (k + 1) (by omega), hpviAt k (by omega)]
      have := hinc k (by omega)
      linarith
    · simp [legLengths, hk] at hl
  have hAsks : ∀ (i : Nat) (a : ℝ), (asks[i]?).bind id = some a → 0 ≤ a := by
    intro i a ha
    by_cases hi : i < n
    · simp only [asks, Array.getElem?_map, Array.getElem?_range, hi, ↓reduceIte,
        Option.map_some, Option.bind_some] at ha
      dsimp only [id] at ha
      by_cases h1 : 1 ≤ i ∧ i + 1 < n
      · simp only [h1, and_self, ↓reduceIte] at ha
        by_cases h2 :
            grades.getD i 0 = grades.getD (i - 1) 0 ∨
              policy.verticalRadius
                (match speedAt i with
                 | some v => if policy.designSpeed > 0 then min v policy.designSpeed else v
                 | none => policy.designSpeed) ≤ 0
        · simp only [h2, ↓reduceIte] at ha
          cases ha
        · simp only [h2, ↓reduceIte, Option.some.injEq] at ha
          rw [← ha]
          have hrV : 0 < policy.verticalRadius
              (match speedAt i with
               | some v => if policy.designSpeed > 0 then min v policy.designSpeed else v
               | none => policy.designSpeed) :=
            not_le.mp (not_or.mp h2).2
          have htwo : (0 : ℝ) < two := by
            show (0 : ℝ) < natToScalar 2
            rw [natToScalar_two_real]
            norm_num
          exact div_nonneg (mul_nonneg (le_of_lt hrV) (absScalar_nonneg_real _)) (le_of_lt htwo)
      · simp [h1] at ha
    · simp [asks, hi] at ha
  have hAsk0 : (asks[0]?).bind id = none := by
    have h0 : 0 < n := by omega
    simp [asks, h0]
  have hAskLast : (asks[n - 1]?).bind id = none := by
    have hlast : n - 1 < n := by omega
    have hnot : ¬ (1 ≤ n - 1 ∧ n - 1 + 1 < n) := by omega
    simp [asks, hlast, hnot]
  have hBudget0 : budgetHalfLen budgets 0 = 0 := by
    have hb0 : (budgets[0]?).bind id = none :=
      resolveSharedLegs_none_of_ask_none legLengths asks 0 hAsk0
    unfold budgetHalfLen
    rw [hb0]
  have hBudgetLast : budgetHalfLen budgets (n - 1) = 0 := by
    have hblast : (budgets[n - 1]?).bind id = none :=
      resolveSharedLegs_none_of_ask_none legLengths asks (n - 1) hAskLast
    unfold budgetHalfLen
    rw [hblast]
  have hLegSum : ∀ (k : Nat), k + 1 < n →
      budgetHalfLen budgets k + budgetHalfLen budgets (k + 1) ≤
        (pviAt (k + 1)).station - (pviAt k).station := by
    intro k hk
    have hnn_k : ∀ b, (budgets[k]?).bind id = some b → 0 ≤ b :=
      fun b hb => TrackGeometry.Budget.resolveSharedLegs_budget_nonneg legLengths asks hLegs hAsks k b hb
    have hnn_k1 : ∀ b, (budgets[k + 1]?).bind id = some b → 0 ≤ b :=
      fun b hb => TrackGeometry.Budget.resolveSharedLegs_budget_nonneg legLengths asks hLegs hAsks (k + 1) b hb
    rw [budgetHalfLen_eq_getD budgets k hnn_k, budgetHalfLen_eq_getD budgets (k + 1) hnn_k1]
    have hsum := TrackGeometry.Budget.resolveSharedLegs_leg_sum_le legLengths asks hLegs hAsks k
    have hget : legLengths.getD k 0 = (pviAt (k + 1)).station - (pviAt k).station := by
      have hk' : k < n - 1 := by omega
      simp [legLengths, Array.getD, hk']
    simpa [budgets, hget] using hsum
  have hGrades : ∀ (k : Nat), k + 1 < n →
      grades.getD k 0 * ((pviAt (k + 1)).station - (pviAt k).station) =
        (pviAt (k + 1)).elevation - (pviAt k).elevation := by
    intro k hk
    have hk' : k < n - 1 := by omega
    have hget : grades.getD k 0 =
        ((pviAt (k + 1)).elevation - (pviAt k).elevation) /
          ((pviAt (k + 1)).station - (pviAt k).station) := by
      simp [grades, Array.getD, hk']
    rw [hget]
    have hlt : (pviAt k).station < (pviAt (k + 1)).station := by
      rw [hpviAt k (by omega), hpviAt (k + 1) (by omega)]
      exact hinc k (by omega)
    have hne : (pviAt (k + 1)).station - (pviAt k).station ≠ 0 := by linarith
    exact div_mul_cancel₀ _ hne
  have hStartEq : pvis[0].station = (pviAt 0).station + budgetHalfLen budgets 0 := by
    rw [hpviAt 0 (by omega), hBudget0, add_zero]
  have hStartZEq : pvis[0].elevation =
      (pviAt 0).elevation + grades.getD 0 0 * budgetHalfLen budgets 0 := by
    rw [hpviAt 0 (by omega), hBudget0, mul_zero, add_zero]
  have hEndEq : pvis[pvis.size - 1].station =
      (pviAt (n - 1)).station + budgetHalfLen budgets (n - 1) := by
    rw [hpviAt (n - 1) (by omega), hBudgetLast, add_zero]
    have hidx : pvis.size - 1 = n - 1 := by omega
    simp only [hidx]
  have hEndZEq : pvis[pvis.size - 1].elevation =
      (pviAt (n - 1)).elevation + grades.getD (n - 1) 0 * budgetHalfLen budgets (n - 1) := by
    rw [hpviAt (n - 1) (by omega), hBudgetLast, mul_zero, add_zero]
    have hidx : pvis.size - 1 = n - 1 := by omega
    simp only [hidx]
  rw [hEndEq, hEndZEq]
  refine Eq.mp ?_ (buildProfile_emit_chain n pviAt grades budgets
    pvis[0].station pvis[0].elevation hBudgetLast hLegSum hGrades
    (n - 1) 0 #[] (by omega) (Or.inl ⟨rfl, hStartEq, hStartZEq⟩))
  apply congrArg (fun x => SegmentChain x _ _ _ _)
  congr 1
  dsimp only [budgets, asks, speedAt, pviAt, two]
  congr 1
  apply congrArg (fun f => Array.map f (Array.range n))
  funext i
  by_cases h1 : 1 ≤ i ∧ i + 1 < n
  · simp only [h1, and_self, ↓reduceIte]
    refine ite_congr ?_ (fun _ => rfl) (fun _ => ?_)
    · apply congrArg (fun x => grades.getD i 0 = grades.getD (i - 1) 0 ∨ policy.verticalRadius x ≤ 0)
      cases kept[i]?.bind Prod.snd with
      | none => rfl
      | some v => exact ite_congr rfl (fun _ => rfl) (fun _ => rfl)
    · apply congrArg (fun x => some (policy.verticalRadius x *
        absScalar (grades.getD i 0 - grades.getD (i - 1) 0) / natToScalar 2))
      cases kept[i]?.bind Prod.snd with
      | none => rfl
      | some v => exact ite_congr rfl (fun _ => rfl) (fun _ => rfl)
  · simp only [h1, ↓reduceIte]

/-- A profile built from strictly increasing points of intersection partitions their station
span with non-negative segment lengths and matching adjacent endpoints. -/
theorem buildProfile_stationPartition
    (pvis : Array (PVI ℝ)) (policy : ProfilePolicy ℝ) (pviSpeeds : Array (Option ℝ))
    (hsize : 2 ≤ pvis.size)
    (hinc : ∀ (i : Nat) (hi : i + 1 < pvis.size), pvis[i].station < pvis[i + 1].station) :
    let segs := (buildProfile pvis policy pviSpeeds).segments
    ∃ (hne : 0 < segs.size),
      (∀ (k : Nat) (hk : k < segs.size), 0 ≤ segs[k].length) ∧
      (∀ (k : Nat) (hk : k + 1 < segs.size), segs[k].endStation = segs[k + 1].startStation) ∧
      segs[0].startStation = pvis[0].station ∧
      segs[segs.size - 1].endStation = pvis[pvis.size - 1].station := by
  obtain ⟨hne, hlen, hadj, hfirst, _, hlast, _⟩ :=
    buildProfile_chain pvis policy pviSpeeds hsize hinc
  exact ⟨hne, fun k hk => le_of_lt (hlen k hk), hadj, hfirst, hlast⟩

private lemma seg_endStation_lt_of_lt (segs : Array (ProfileSegment ℝ))
    (hlen : ∀ (k : Nat) (hk : k < segs.size), 0 < segs[k].length)
    (hadj : ∀ (k : Nat) (hk : k + 1 < segs.size), segs[k].endStation = segs[k + 1].startStation) :
    ∀ (i j : Nat) (hij : i < j) (hj : j < segs.size),
      segs[i].endStation < segs[j].endStation := by
  intro i j hij hj
  induction j with
  | zero => omega
  | succ j ih =>
    have hstep : segs[j].endStation < segs[j + 1].endStation := by
      have h1 := hadj j hj
      have h2 := hlen (j + 1) hj
      show segs[j].endStation < segs[j + 1].startStation + segs[j + 1].length
      linarith
    by_cases h : i = j
    · subst h
      exact hstep
    · exact lt_trans (ih (by omega) (by omega)) hstep

private lemma list_findSome?_eq_last {α β : Type} (l : List α) (f : α → Option β) (a : α) (b : β)
    (hne : l ≠ [])
    (hlast : l.getLast hne = a)
    (hinit : ∀ (i : Nat) (hi : i + 1 < l.length), f l[i] = none)
    (hfa : f a = some b) :
    l.findSome? f = some b := by
  induction l with
  | nil => exact absurd rfl hne
  | cons x xs ih =>
    cases xs with
    | nil =>
      simp only [List.getLast_singleton] at hlast
      subst hlast
      simp [List.findSome?, hfa]
    | cons y ys =>
      have hfx : f x = none := hinit 0 (by simp)
      simp only [List.findSome?, hfx]
      apply ih (List.cons_ne_nil y ys)
      · simpa using hlast
      · intro i hi
        exact hinit (i + 1) (by simpa using hi)

private lemma elevationAt_endpoints_of_chain
    (segs : Array (ProfileSegment ℝ)) (s₀ z₀ s₁ z₁ : ℝ)
    (hne : 0 < segs.size)
    (hlen : ∀ (k : Nat) (hk : k < segs.size), 0 < segs[k].length)
    (hadj : ∀ (k : Nat) (hk : k + 1 < segs.size), segs[k].endStation = segs[k + 1].startStation)
    (hfirst_s : segs[0].startStation = s₀)
    (hfirst_z : segs[0].elevationAt 0 = z₀)
    (hlast_s : segs[segs.size - 1].endStation = s₁)
    (hlast_z : segs[segs.size - 1].elevationAt segs[segs.size - 1].length = z₁) :
    (ProfilePath.mk segs).elevationAt s₀ = some z₀ ∧
    (ProfilePath.mk segs).elevationAt s₁ = some z₁ := by
  unfold ProfilePath.elevationAt ProfilePath.sampleAt
  dsimp only
  constructor
  · cases hlist : segs.toList with
    | nil =>
      have hlen0 : segs.size = 0 := by
        simpa [Array.length_toList] using congrArg List.length hlist
      omega
    | cons hd tl =>
      have hhd : hd = segs[0] := by
        have h0 : segs.toList[0]'(by rw [Array.length_toList]; exact hne) = segs[0] := by
          simp
        rw [← h0]
        simp [hlist]
      have hcond : hd.startStation ≤ s₀ ∧ s₀ ≤ hd.endStation := by
        rw [hhd]
        have h0len := hlen 0 hne
        show segs[0].startStation ≤ s₀ ∧
          s₀ ≤ segs[0].startStation + segs[0].length
        exact ⟨by linarith, by linarith⟩
      simp only [List.findSome?, hcond, and_self, ↓reduceIte]
      congr 1
      rw [hhd, hfirst_s, sub_self, hfirst_z]
  · have hne_list : segs.toList ≠ [] := by
      intro hnil
      have hlen0 : segs.size = 0 := by
        simpa [Array.length_toList] using congrArg List.length hnil
      omega
    have hgetLast : segs.toList.getLast hne_list = segs[segs.size - 1] := by
      rw [List.getLast_eq_getElem]
      simp [Array.length_toList]
    apply list_findSome?_eq_last segs.toList _ (segs[segs.size - 1]) z₁
      hne_list hgetLast
    · intro i hi
      have hi' : i + 1 < segs.size := by simpa [Array.length_toList] using hi
      have hlt : segs[i].endStation < segs[segs.size - 1].endStation :=
        seg_endStation_lt_of_lt segs hlen hadj i (segs.size - 1) (by omega) (by omega)
      have hget : segs.toList[i] = segs[i] := by simp
      rw [hget]
      have hnot : ¬ (segs[i].startStation ≤ s₁ ∧ s₁ ≤ segs[i].endStation) := by
        intro ⟨_, hle⟩
        linarith
      simp [hnot]
    · have hlen_last := hlen (segs.size - 1) (by omega)
      have hend : segs[segs.size - 1].endStation =
          segs[segs.size - 1].startStation + segs[segs.size - 1].length := rfl
      have hcond : segs[segs.size - 1].startStation ≤ s₁ ∧
          s₁ ≤ segs[segs.size - 1].endStation :=
        ⟨by linarith, by linarith⟩
      simp only [hcond, and_self, ↓reduceIte]
      congr 1
      have hsub : s₁ - segs[segs.size - 1].startStation =
          segs[segs.size - 1].length := by
        linarith
      rw [hsub, hlast_z]

/-- A profile built from strictly increasing points of intersection reproduces the first and
last elevations at the first and last stations. -/
theorem buildProfile_endpoints
    (pvis : Array (PVI ℝ)) (policy : ProfilePolicy ℝ) (pviSpeeds : Array (Option ℝ))
    (hsize : 2 ≤ pvis.size)
    (hinc : ∀ (i : Nat) (hi : i + 1 < pvis.size), pvis[i].station < pvis[i + 1].station) :
    let path := buildProfile pvis policy pviSpeeds
    path.elevationAt pvis[0].station = some pvis[0].elevation ∧
    path.elevationAt pvis[pvis.size - 1].station = some pvis[pvis.size - 1].elevation := by
  dsimp only
  obtain ⟨hne, hlen, hadj, hfirst_s, hfirst_z, hlast_s, hlast_z⟩ :=
    buildProfile_chain pvis policy pviSpeeds hsize hinc
  exact elevationAt_endpoints_of_chain _ _ _ _ _ hne hlen hadj hfirst_s hfirst_z hlast_s hlast_z
