import TrackGeometry.Vec

/-! # Computable Float scalar (`RFloat`)

Newtype around `Float` with structural `DecidableEq` and a `TrackScalar` instance.
-/

/-- Computable `Float` wrapper. `RFloat` is a newtype around `Float` with structural
    `DecidableEq` (treating `NaN = NaN`), making `TrackScalar RFloat` fully computable
    (unlike raw `Float` which lacks `DecidableEq`).

    Use `⟨x⟩` to wrap a `Float` literal, e.g. `⟨2.0⟩`. -/
structure RFloat where
  val : Float
  deriving Repr

namespace RFloat

/-- `Float.toBits` is injective: a `Float` is uniquely determined by its 64-bit
    IEEE-754 representation (`toBits`/`ofBits` are a bijection). This is true by
    construction, but unprovable in-kernel because `Float`'s payload type is
    `opaque` (see `FloatSpec` in `Init.Data.Float`) — Lean exposes decidable `<`/`≤`
    for `Float` but deliberately no decidable `=`. -/
axiom Float.toBits_inj {a b : Float} (h : a.toBits = b.toBits) : a = b

/-- Computable `DecidableEq` for `RFloat`, deciding propositional equality via the
    underlying bit pattern. Unlike a `Float.beq`-based version, this matches `=`
    exactly: bitwise-identical NaNs are equal, and `+0.0`/`-0.0` are distinct. -/
instance : DecidableEq RFloat := λ a b =>
  if h : a.val.toBits = b.val.toBits then
    isTrue (by cases a; cases b; exact congrArg RFloat.mk (Float.toBits_inj h))
  else
    isFalse (λ hab => h (by rw [hab]))

instance : Add RFloat := ⟨λ a b => ⟨a.val + b.val⟩⟩
instance : Sub RFloat := ⟨λ a b => ⟨a.val - b.val⟩⟩
instance : Mul RFloat := ⟨λ a b => ⟨a.val * b.val⟩⟩
instance : Div RFloat := ⟨λ a b => ⟨a.val / b.val⟩⟩
instance : Neg RFloat := ⟨λ a => ⟨-a.val⟩⟩
instance : Zero RFloat := ⟨⟨0⟩⟩
instance : One RFloat := ⟨⟨1⟩⟩
instance : LT RFloat := ⟨λ a b => a.val < b.val⟩
instance : LE RFloat := ⟨λ a b => a.val ≤ b.val⟩
instance : Max RFloat := ⟨λ a b => ⟨max a.val b.val⟩⟩
instance : Min RFloat := ⟨λ a b => ⟨min a.val b.val⟩⟩

end RFloat

/-- Computable `TrackScalar` instance for `RFloat`. All operations delegate to `Float`.
    Clothoid offsets come from Gauss–Legendre quadrature over these primitives, so no
    Fresnel functions are needed here. -/
instance : TrackScalar RFloat where
  cos x := ⟨Float.cos x.val⟩
  sin x := ⟨Float.sin x.val⟩
  arccos x := ⟨Float.acos x.val⟩
  sqrt x := ⟨Float.sqrt x.val⟩
  pi := ⟨2 * Float.acos 0⟩
  decEq a b := inferInstanceAs (Decidable (a = b))
  decLe a b := Float.decLe a.val b.val
  decLt a b := Float.decLt a.val b.val
