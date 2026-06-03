import TrackGeometry.Lib
import Mathlib.Analysis.SpecialFunctions.Trigonometric.Inverse

/-! ## `ℝ` instance for `TrackScalar`

This module provides the exact, real-number (`ℝ`) instance of `TrackScalar`, using
mathlib's `Real.cos`, `Real.sin`, `Real.arccos` and `Real.sqrt`.

It is deliberately kept separate from `TrackGeometry.Lib` so that the computable core
(everything over `RFloat`) carries **no Mathlib dependency** and can be compiled to C
and linked into a host program (see `TrackGeometry.FFI`). The `ℝ` instance here is
`noncomputable` and exists only for proofs / `#eval`-free reasoning.
-/

/-- Exact `TrackScalar` instance for `ℝ`. Uses mathlib's trig functions; clothoid
    offsets are obtained by Gauss–Legendre quadrature over these (see
    `clothoidOffset`), so no Fresnel primitives are part of the interface. -/
noncomputable instance : TrackScalar ℝ where
  cos := Real.cos
  sin := Real.sin
  arccos := Real.arccos
  sqrt := Real.sqrt
  pi := Real.pi
  beq a b := a == b
  decEq a b := inferInstanceAs (Decidable (a = b))
  decLe a b := inferInstanceAs (Decidable (a ≤ b))
  decLt a b := inferInstanceAs (Decidable (a < b))
