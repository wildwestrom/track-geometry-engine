/-! ## Undo/redo *tree*

A linear undo/redo loses information: undo a few steps, make a new edit, and the
redo branch is gone. This module instead keeps a **tree** of states. Every recorded
edit becomes a child of the current node; undo walks to the parent; redo walks to a
child. Undoing and then editing creates a *new* branch while the old branch stays
reachable, so no edit is ever lost.

The structure is a flat arena (`nodes : Array (Node σ)`) addressed by index, plus a
`current` pointer. It is generic over the state type `σ` and carries no `DecidableEq`
constraint — the caller decides when an edit is worth recording. -/

namespace History

/-- One state in the history tree. `children` are stored in creation order; `active`
    selects which child `redo` follows (and which branch the cursor came back from). -/
structure Node (σ : Type) where
  state    : σ
  /-- Index of the parent node in the arena; `none` for the root. -/
  parent   : Option Nat
  /-- Indices of child nodes, in creation order. -/
  children : Array Nat
  /-- Index *into `children`* of the active redo target (meaningful when nonempty). -/
  active   : Nat
  deriving Inhabited

/-- A history tree: an arena of nodes plus the index of the current node. -/
structure History (σ : Type) where
  nodes   : Array (Node σ)
  current : Nat
  deriving Inhabited

variable {σ : Type} [Inhabited σ]

/-- A fresh history containing a single root node holding `s`. -/
def init (s : σ) : History σ :=
  { nodes := #[{ state := s, parent := none, children := #[], active := 0 }], current := 0 }

/-- The node the cursor is currently on. -/
@[inline] def curNode (h : History σ) : Node σ := h.nodes[h.current]!

/-- The state at the current node. -/
@[inline] def current (h : History σ) : σ := (curNode h).state

/-- Record `s` as a new child of the current node and move the cursor onto it. The
    new child becomes the parent's active redo target. -/
def record (h : History σ) (s : σ) : History σ :=
  let newIdx := h.nodes.size
  let cur := curNode h
  let cur' := { cur with children := cur.children.push newIdx, active := cur.children.size }
  let newNode : Node σ := { state := s, parent := some h.current, children := #[], active := 0 }
  { nodes := (h.nodes.set! h.current cur').push newNode, current := newIdx }

/-- Replace the current node's state in place, without creating a new node. Used for
    continuous edits (e.g. dragging a point) where every intermediate frame would
    otherwise become its own undo step; record once at the start, then update here. -/
def setCurrent (h : History σ) (s : σ) : History σ :=
  { h with nodes := h.nodes.set! h.current { curNode h with state := s } }

/-- Discard the current node if it is the newest leaf and move back to its parent.
    This is for edits that were recorded speculatively and then canceled before they
    became real user-visible history. -/
def discardCurrentLeaf (h : History σ) : History σ :=
  let cur := curNode h
  match cur.parent with
  | none => h
  | some p =>
      let parent := h.nodes[p]!
      let lastChild := parent.children[parent.children.size - 1]?
      if cur.children.size = 0 && h.current + 1 = h.nodes.size && lastChild == some h.current then
        let oldChildCount := parent.children.size
        let parent' :=
          { parent with
            children := parent.children.pop
            active := if oldChildCount ≤ 1 then 0 else min parent.active (oldChildCount - 2) }
        { nodes := (h.nodes.set! p parent').pop, current := p }
      else h

/-- Move the cursor to the parent, if any. Child/active metadata is left intact so a
    following `redo` returns to the same place. -/
def undo (h : History σ) : History σ :=
  match (curNode h).parent with
  | none   => h
  | some p => { h with current := p }

/-- Move the cursor to the active child, if any. -/
def redo (h : History σ) : History σ :=
  let cur := curNode h
  match cur.children[cur.active]? with
  | none   => h
  | some c => { h with current := c }

/-- Rotate which child the current node's `redo` will follow. `dir ≥ 0` advances,
    `dir < 0` goes back. No-op unless the current node has at least two children. -/
def cycleBranch (h : History σ) (dir : Int) : History σ :=
  let cur := curNode h
  let n := cur.children.size
  if n ≤ 1 then h
  else
    let step := if dir ≥ 0 then 1 else n - 1
    let a := (cur.active + step) % n
    { h with nodes := h.nodes.set! h.current { cur with active := a } }

/-! ### Read helpers for the HUD -/

/-- Total number of recorded states. -/
@[inline] def size (h : History σ) : Nat := h.nodes.size

/-- Whether `undo` would move (the current node has a parent). -/
@[inline] def canUndo (h : History σ) : Bool := ((curNode h).parent).isSome

/-- Whether `redo` would move (the current node has children). -/
@[inline] def canRedo (h : History σ) : Bool := (curNode h).children.size > 0

/-- How many redo branches leave the current node. -/
@[inline] def branchCount (h : History σ) : Nat := (curNode h).children.size

end History
