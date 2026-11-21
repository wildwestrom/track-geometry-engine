import TrackGeometry.Real

/-! # Shared-leg budget non-overlap invariants

Machine-checked guarantees over `ℝ` for the shared-leg conflict resolution stage
`resolveSharedLegs` (`TrackGeometry.Design`):

* Every resolved corner budget is non-negative when all requested budgets and leg lengths
  are non-negative.
* No two adjacent corners ever overlap on a shared leg (`budget[k] + budget[k + 1] ≤ legLen[k]`).

Every theorem in this module is proven directly over `ℝ` without any extra axioms
(in particular, it does not depend on `clothoidOffset_eq_exact`).
-/

namespace TrackGeometry.Budget

private lemma legLen_nonneg (legLengths : Array ℝ)
    (hLegs : ∀ (k : Nat) (l : ℝ), legLengths[k]? = some l → 0 ≤ l) (k : Nat) :
    0 ≤ legLengths.getD k 0 := by
  rw [Array.getD_eq_getD_getElem?]
  cases h : legLengths[k]? with
  | none => simp
  | some l =>
    simp only [Option.getD_some]
    exact hLegs k l h

private noncomputable def legShare (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (ai : ℝ) (j k : Nat) : ℝ :=
  let len := legLengths.getD k 0
  match (asks[j]?).bind id with
  | some aj => if ai + aj ≤ len then ai else len * ai / (ai + aj)
  | none => min ai len

private lemma resolveSharedLegs_getElem?_bind (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (i : Nat) :
    ((resolveSharedLegs legLengths asks)[i]?).bind id =
      match (asks[i]?).bind id with
      | none => none
      | some ai =>
          some (min (legShare legLengths asks ai (i - 1) (i - 1))
                    (legShare legLengths asks ai (i + 1) i)) := by
  unfold resolveSharedLegs
  dsimp only
  by_cases hi : i < asks.size
  · simp only [Array.getElem?_map, Array.getElem?_range, hi, ↓reduceIte,
      Option.map_some, Option.bind_some, legShare]
    dsimp only [id]
    cases (asks[i]?).bind id with
    | none => rfl
    | some ai =>
      dsimp only
      congr 1
      congr 1
      · cases (asks[i - 1]?).bind id with
        | none => rfl
        | some aj => exact ite_congr rfl (fun _ => rfl) (fun _ => rfl)
      · cases (asks[i + 1]?).bind id with
        | none => rfl
        | some aj => exact ite_congr rfl (fun _ => rfl) (fun _ => rfl)
  · simp only [Array.getElem?_map, Array.getElem?_range, hi, ↓reduceIte,
      Array.getElem?_eq_none (Nat.le_of_not_lt hi), Option.map_none, Option.bind_none]

private lemma legShare_nonneg (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (ai : ℝ) (j k : Nat)
    (hai : 0 ≤ ai)
    (hlen : 0 ≤ legLengths.getD k 0)
    (haj : ∀ (aj : ℝ), (asks[j]?).bind id = some aj → 0 ≤ aj) :
    0 ≤ legShare legLengths asks ai j k := by
  dsimp only [legShare]
  cases h : (asks[j]?).bind id with
  | none =>
    exact le_min hai hlen
  | some aj =>
    dsimp only
    have haj' : 0 ≤ aj := haj aj h
    split_ifs
    · exact hai
    · exact div_nonneg (mul_nonneg hlen hai) (add_nonneg hai haj')

private lemma legShare_le_legLen (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (ai : ℝ) (j k : Nat)
    (hlen : 0 ≤ legLengths.getD k 0)
    (haj : ∀ (aj : ℝ), (asks[j]?).bind id = some aj → 0 ≤ aj) :
    legShare legLengths asks ai j k ≤ legLengths.getD k 0 := by
  dsimp only [legShare]
  cases h : (asks[j]?).bind id with
  | none =>
    exact min_le_right ai (legLengths.getD k 0)
  | some aj =>
    dsimp only
    have haj' : 0 ≤ aj := haj aj h
    split_ifs with hsum
    · linarith
    · have hpos : 0 < ai + aj := by linarith
      rw [div_le_iff₀ hpos]
      nlinarith

private lemma legShare_pair_add_le (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (k : Nat) (ak ak1 : ℝ)
    (hk : (asks[k]?).bind id = some ak)
    (hk1 : (asks[k + 1]?).bind id = some ak1)
    (hlen : 0 ≤ legLengths.getD k 0) :
    legShare legLengths asks ak (k + 1) k + legShare legLengths asks ak1 k k
      ≤ legLengths.getD k 0 := by
  dsimp only [legShare]
  rw [hk1, hk]
  dsimp only
  rw [add_comm ak1 ak]
  split_ifs with hsum
  · exact hsum
  · have hpos : 0 < ak + ak1 := by linarith
    have hne : ak + ak1 ≠ 0 := ne_of_gt hpos
    have heq :
        legLengths.getD k 0 * ak / (ak + ak1) + legLengths.getD k 0 * ak1 / (ak + ak1)
          = legLengths.getD k 0 := by
      field_simp [hne]
    exact le_of_eq heq

/-- Resolving shared legs preserves the number of entries in the asks array. -/
theorem resolveSharedLegs_size (legLengths : Array ℝ) (asks : Array (Option ℝ)) :
    (resolveSharedLegs legLengths asks).size = asks.size := by
  simp [resolveSharedLegs]

/-- Every corner budget returned by `resolveSharedLegs` is non-negative when all requested
budgets and leg lengths are non-negative. -/
theorem resolveSharedLegs_budget_nonneg (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (hLegs : ∀ (k : Nat) (l : ℝ), legLengths[k]? = some l → 0 ≤ l)
    (hAsks : ∀ (i : Nat) (a : ℝ), (asks[i]?).bind id = some a → 0 ≤ a)
    (i : Nat) (b : ℝ)
    (hb : ((resolveSharedLegs legLengths asks)[i]?).bind id = some b) :
    0 ≤ b := by
  rw [resolveSharedLegs_getElem?_bind] at hb
  cases h : (asks[i]?).bind id with
  | none =>
    rw [h] at hb
    cases hb
  | some ai =>
    rw [h] at hb
    simp only [Option.some.injEq] at hb
    rw [← hb]
    have hai : 0 ≤ ai := hAsks i ai h
    exact le_min
      (legShare_nonneg legLengths asks ai (i - 1) (i - 1) hai (legLen_nonneg legLengths hLegs _)
        (hAsks (i - 1)))
      (legShare_nonneg legLengths asks ai (i + 1) i hai (legLen_nonneg legLengths hLegs _)
        (hAsks (i + 1)))

/-- No two adjacent curving corners overlap on their shared leg when leg lengths are
non-negative. -/
theorem resolveSharedLegs_shared_leg_non_overlap (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (hLegs : ∀ (k : Nat) (l : ℝ), legLengths[k]? = some l → 0 ≤ l)
    (k : Nat) (bk bk1 : ℝ)
    (hbk : ((resolveSharedLegs legLengths asks)[k]?).bind id = some bk)
    (hbk1 : ((resolveSharedLegs legLengths asks)[k + 1]?).bind id = some bk1) :
    bk + bk1 ≤ legLengths.getD k 0 := by
  rw [resolveSharedLegs_getElem?_bind] at hbk hbk1
  cases hk : (asks[k]?).bind id with
  | none =>
    rw [hk] at hbk
    cases hbk
  | some ak =>
    cases hk1 : (asks[k + 1]?).bind id with
    | none =>
      rw [hk1] at hbk1
      cases hbk1
    | some ak1 =>
      rw [hk] at hbk
      rw [hk1] at hbk1
      simp only [Option.some.injEq] at hbk
      simp only [Nat.add_sub_cancel, Option.some.injEq] at hbk1
      have h1 : bk ≤ legShare legLengths asks ak (k + 1) k := by
        rw [← hbk]
        exact min_le_right _ _
      have h2 : bk1 ≤ legShare legLengths asks ak1 k k := by
        rw [← hbk1]
        exact min_le_left _ _
      have hpair := legShare_pair_add_le legLengths asks k ak ak1 hk hk1
        (legLen_nonneg legLengths hLegs k)
      linarith

/-- For any in-bounds leg index `k`, the sum of resolved budgets at corners `k` and `k + 1`
never exceeds `legLengths[k]`. -/
theorem resolveSharedLegs_shared_leg_non_overlap_of_lt (legLengths : Array ℝ)
    (asks : Array (Option ℝ))
    (hLegs : ∀ (k : Nat) (l : ℝ), legLengths[k]? = some l → 0 ≤ l)
    (k : Nat) (hk : k < legLengths.size) (bk bk1 : ℝ)
    (hbk : ((resolveSharedLegs legLengths asks)[k]?).bind id = some bk)
    (hbk1 : ((resolveSharedLegs legLengths asks)[k + 1]?).bind id = some bk1) :
    bk + bk1 ≤ legLengths[k] := by
  have h := resolveSharedLegs_shared_leg_non_overlap legLengths asks hLegs k bk bk1 hbk hbk1
  simpa [Array.getD, hk] using h

/-- The combined tangent budget consumed from both ends of any leg (counting a non-curving
endpoint as `0`) never exceeds that leg's length when all requested budgets and leg lengths
are non-negative. -/
theorem resolveSharedLegs_leg_sum_le (legLengths : Array ℝ) (asks : Array (Option ℝ))
    (hLegs : ∀ (k : Nat) (l : ℝ), legLengths[k]? = some l → 0 ≤ l)
    (hAsks : ∀ (i : Nat) (a : ℝ), (asks[i]?).bind id = some a → 0 ≤ a)
    (k : Nat) :
    (((resolveSharedLegs legLengths asks)[k]?).bind id).getD 0
      + (((resolveSharedLegs legLengths asks)[k + 1]?).bind id).getD 0
      ≤ legLengths.getD k 0 := by
  have hlen : 0 ≤ legLengths.getD k 0 := legLen_nonneg legLengths hLegs k
  cases hbk : ((resolveSharedLegs legLengths asks)[k]?).bind id with
  | none =>
    cases hbk1 : ((resolveSharedLegs legLengths asks)[k + 1]?).bind id with
    | none =>
      simpa using hlen
    | some bk1 =>
      rw [resolveSharedLegs_getElem?_bind] at hbk1
      cases hk1 : (asks[k + 1]?).bind id with
      | none =>
        rw [hk1] at hbk1
        cases hbk1
      | some ak1 =>
        rw [hk1] at hbk1
        simp only [Nat.add_sub_cancel, Option.some.injEq] at hbk1
        have hle : bk1 ≤ legShare legLengths asks ak1 k k := by
          rw [← hbk1]
          exact min_le_left _ _
        have hshare := legShare_le_legLen legLengths asks ak1 k k hlen (hAsks k)
        simp only [Option.getD_none, Option.getD_some, zero_add]
        exact le_trans hle hshare
  | some bk =>
    cases hbk1 : ((resolveSharedLegs legLengths asks)[k + 1]?).bind id with
    | none =>
      rw [resolveSharedLegs_getElem?_bind] at hbk
      cases hk : (asks[k]?).bind id with
      | none =>
        rw [hk] at hbk
        cases hbk
      | some ak =>
        rw [hk] at hbk
        simp only [Option.some.injEq] at hbk
        have hle : bk ≤ legShare legLengths asks ak (k + 1) k := by
          rw [← hbk]
          exact min_le_right _ _
        have hshare := legShare_le_legLen legLengths asks ak (k + 1) k hlen (hAsks (k + 1))
        simp only [Option.getD_some, Option.getD_none, add_zero]
        exact le_trans hle hshare
    | some bk1 =>
      simp only [Option.getD_some]
      exact resolveSharedLegs_shared_leg_non_overlap legLengths asks hLegs k bk bk1 hbk hbk1

end TrackGeometry.Budget
