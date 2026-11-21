/-! # Scalar interface for track geometry

Shared scalar typeclass (`TrackScalar`) and basic scalar helpers (`natToScalar`,
`intToScalar`, `absScalar`) used by both 2D and 3D geometry modules.

This module has no Mathlib dependency so the computable geometry core can be compiled
to C over `RFloat`, while proofs instantiate the same interface over `ℝ`.
-/

/-- Numeric scalar operations needed for track geometry calculations.

Captures basic arithmetic, ordering, trigonometric functions, square roots, and
decidable comparisons without requiring algebraic laws that floating-point numbers do
not satisfy. Clothoid offsets are obtained by Gauss–Legendre quadrature over these
primitives, so no special integral functions are needed in the interface. -/
class TrackScalar (α : Type) extends
  Add α, Sub α, Mul α, Div α, Neg α,
  Zero α, One α,
  LT α, LE α, Max α, Min α where
  /-- Cosine of an angle in radians. -/
  cos : α → α
  /-- Sine of an angle in radians. -/
  sin : α → α
  /-- Inverse cosine, returning an angle in radians. -/
  arccos : α → α
  /-- Non-negative square root. -/
  sqrt : α → α
  /-- The circle constant π (ratio of circumference to diameter). -/
  pi : α
  /-- Test whether two scalars are equal. -/
  decEq : (a b : α) → Decidable (a = b)
  /-- Test whether one scalar is less than or equal to another. -/
  decLe : (a b : α) → Decidable (a ≤ b)
  /-- Test whether one scalar is strictly less than another. -/
  decLt : (a b : α) → Decidable (a < b)

/-- Every track scalar supports decidable equality. -/
instance [h : TrackScalar α] : DecidableEq α := h.decEq

/-- Every track scalar supports decidable less-than-or-equal comparisons. -/
instance [h : TrackScalar α] : DecidableRel (· ≤ · : α → α → Prop) := h.decLe

/-- Every track scalar supports decidable strict less-than comparisons. -/
instance [h : TrackScalar α] : DecidableRel (· < · : α → α → Prop) := h.decLt

/-- Convert a non-negative integer into a scalar value by repeated addition.

Runs in time linear in the integer and is intended for small constants such as
quadrature orders and panel counts. -/
def natToScalar [TrackScalar α] : Nat → α
  | 0 => 0
  | n + 1 => natToScalar n + 1

/-- Convert a signed integer into a scalar value.

Used for signed turn counts such as per-corner windings. -/
def intToScalar [TrackScalar α] : Int → α
  | .ofNat n => natToScalar n
  | .negSucc n => -natToScalar (n + 1)

/-- Compute the absolute value of a scalar. -/
def absScalar [TrackScalar α] (x : α) : α := if x < 0 then -x else x
