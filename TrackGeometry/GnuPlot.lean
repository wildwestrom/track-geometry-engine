import TrackGeometry.Lib
import TrackGeometry.Real

/-! ## GNUPlot CSV output for railway alignments

This module provides functions to sample a `RailwayAlignment` at regular intervals
and produce CSV data suitable for plotting with GNUPlot.

### Usage with GNUPlot

Once you have a CSV file, plot it with:

```gnuplot
set datafile separator ","
plot "alignment.csv" using 1:2 with lines title "Alignment"
```

### Usage from Lean

```lean
#eval do
  let csv := GnuPlot.alignmentToCSV myAlignment 1000 (λ (x : ℝ) => GnuPlot.formatReal x)
  IO.FS.writeFile "alignment.csv" csv
```
-/

namespace GnuPlot

open Vec3

section Sampling

/-! ## Uniform sampling

All sampling functions use fuel-based recursion (`fuel : Nat` decreases each step)
for termination, avoiding the need for `Nat`→`α` casts and keeping the code
computable for any `[TrackScalar α]`. -/

/-- Sample `numPts` points uniformly along a `RailwayAlignment`.

    Returns a list of `(arcLength, point)` pairs. The first point is at s=0,
    the last at s=totalLength.

    If `numPts < 2`, returns at least the start point. -/
def sampleUniform [TrackScalar α] {cA cB : Curvature α}
    (align : RailwayAlignment α cA cB) (numPts : Nat) : List (α × Vec3 α) :=
  let totalLen := align.length
  if numPts ≤ 1 then
    match align.pointAt 0 with
    | some p => [(0, p)]
    | none => []
  else
    let numSteps := numPts - 1
    let step : α := totalLen / natToScalar numSteps
    let rec go (fuel : Nat) (s : α) (acc : List (α × Vec3 α)) : List (α × Vec3 α) :=
      if fuel = 0 then acc
      else
        match align.pointAt s with
        | some p => go (fuel - 1) (s + step) (acc ++ [(s, p)])
        | none => go (fuel - 1) (s + step) acc
    let pts := go numPts 0 []
    -- Ensure the final point is at totalLen
    match align.pointAt totalLen with
    | some p =>
      match pts with
      | (sLast, _) :: _ =>
        if sLast < totalLen then pts ++ [(totalLen, p)] else pts
      | [] => [(totalLen, p)]
    | none => pts

/-- Sample points along a `RailwayAlignment` at a fixed arc-length interval `stepSize`.

    The last point is always at the total alignment length (even if it doesn't fall
    exactly on the grid). Uses a generous fuel bound to guarantee termination. -/
def sampleByStep [TrackScalar α] {cA cB : Curvature α}
    (align : RailwayAlignment α cA cB) (stepSize : α) : List (α × Vec3 α) :=
  let totalLen := align.length
  if stepSize = 0 then
    match align.pointAt 0, align.pointAt totalLen with
    | some p0, some pEnd => [(0, p0), (totalLen, pEnd)]
    | some p0, none => [(0, p0)]
    | none, _ => []
  else
    -- Use a generous fuel bound: 100000 steps max, which at stepSize=0.01
    -- covers 1000 units of arc-length — more than enough for track geometry.
    let maxFuel := 100000
    let rec go (fuel : Nat) (s : α) (acc : List (α × Vec3 α)) : List (α × Vec3 α) :=
      if fuel = 0 then acc
      else if s > totalLen then acc
      else
        match align.pointAt s with
        | some p => go (fuel - 1) (s + stepSize) (acc ++ [(s, p)])
        | none => go (fuel - 1) (s + stepSize) acc
    let pts := go maxFuel 0 []
    -- Ensure the final point is included
    match align.pointAt totalLen with
    | some p =>
      match pts with
      | (sLast, _) :: _ =>
        if sLast < totalLen then pts ++ [(totalLen, p)] else pts
      | [] => [(totalLen, p)]
    | none => pts

/-- Sample `numPts` points uniformly along an `AlignmentPath` (the PI-builder output).
    Mirrors `sampleUniform` but walks the flat piece array instead of a
    join-indexed `RailwayAlignment`. -/
def samplePathUniform [TrackScalar α]
    (path : AlignmentPath α) (numPts : Nat) : List (α × Vec3 α) :=
  let totalLen := path.length
  if numPts ≤ 1 then
    match path.pointAt 0 with
    | some p => [(0, p)]
    | none => []
  else
    let numSteps := numPts - 1
    let step : α := totalLen / natToScalar numSteps
    let rec go (fuel : Nat) (s : α) (acc : List (α × Vec3 α)) : List (α × Vec3 α) :=
      if fuel = 0 then acc
      else
        match path.pointAt s with
        | some p => go (fuel - 1) (s + step) (acc ++ [(s, p)])
        | none => go (fuel - 1) (s + step) acc
    let pts := go numPts 0 []
    match path.pointAt totalLen with
    | some p =>
      match pts with
      | (sLast, _) :: _ => if sLast < totalLen then pts ++ [(totalLen, p)] else pts
      | [] => [(totalLen, p)]
    | none => pts

end Sampling

section Formatting

/-- Format a `Float` for CSV output. -/
def formatFloat (x : Float) : String :=
  Float.toString x

/-- Format an `ℝ` value for CSV output.

    Marked `unsafe` because `Real.instRepr` is unsafe (ℝ has no finite representation).
    This is fine for `#eval` / IO-based CSV export; do not use in proofs. -/
@[inline] unsafe def formatReal (x : ℝ) : String :=
  let fmt := repr x
  fmt.pretty 80

/-- Render a `Vec3 α` as a CSV row: `arcLength,x,y,z`.

    The caller must supply a formatting function `fmt : α → String`. -/
def vec3ToCSVRow (fmt : α → String) (s : α) (p : Vec3 α) : String :=
  s!"{fmt s},{fmt (p 0)},{fmt (p 1)},{fmt (p 2)}"

/-- Build a complete CSV string from sampled points.

    Each line is: `arcLength, x, y, z`. The first line is an optional header.

    You must supply a formatter. For `ℝ`, use `GnuPlot.formatReal`.
    For `RFloat`, use `λ x => GnuPlot.formatFloat x.val`. -/
def toCSVString
    (samples : List (α × Vec3 α))
    (fmt : α → String)
    (includeHeader : Bool := true) : String :=
  let header := if includeHeader then "arcLength,x,y,z\n" else ""
  let rows := samples.map λ (s, p) => vec3ToCSVRow fmt s p
  header ++ String.intercalate "\n" rows ++ "\n"

/-- Convenience: sample uniformly and produce a CSV string in one call.

    This is the main entry point for quick export.

    Example:
    ```lean
    #eval GnuPlot.alignmentToCSV myAlignment 1000 (λ (x : ℝ) => GnuPlot.formatReal x)
    ``` -/
def alignmentToCSV [TrackScalar α] {cA cB : Curvature α}
    (align : RailwayAlignment α cA cB)
    (numPts : Nat := 1000)
    (fmt : α → String)
    (includeHeader : Bool := true) : String :=
  let samples := sampleUniform align numPts
  toCSVString samples fmt includeHeader

/-- Convenience: sample an `AlignmentPath` uniformly and produce a CSV string. -/
def pathToCSV [TrackScalar α]
    (path : AlignmentPath α)
    (numPts : Nat := 1000)
    (fmt : α → String)
    (includeHeader : Bool := true) : String :=
  let samples := samplePathUniform path numPts
  toCSVString samples fmt includeHeader

/-- Convenience: sample by step size and produce a CSV string. -/
def alignmentToCSVByStep [TrackScalar α] {cA cB : Curvature α}
    (align : RailwayAlignment α cA cB)
    (stepSize : α)
    (fmt : α → String)
    (includeHeader : Bool := true) : String :=
  let samples := sampleByStep align stepSize
  toCSVString samples fmt includeHeader

/-- Render an array of placed control points as a CSV string with columns `x,y,label`.
    The label column contains `(x, y)` suitable for GNUPlot `with labels point`. -/
def placedPointsToCSV
    (points : Array (Vec3 α))
    (fmt : α → String)
    (includeHeader : Bool := true) : String :=
  let header := if includeHeader then "x,y,label\n" else ""
  let rows := points.toList.map λ p =>
    let x := fmt (p 0)
    let y := fmt (p 1)
    s!"{x},{y},\"({x}, {y})\""
  header ++ String.intercalate "\n" rows ++ "\n"

end Formatting

section IO

/-- Write a CSV file to disk. Convenience wrapper around `IO.FS.writeFile`. -/
def writeCSV (path : String) (csv : String) : IO Unit :=
  IO.FS.writeFile path csv

/-- Sample an alignment and write directly to a file.

    Usage:
    ```lean
    #eval GnuPlot.saveAlignment "track.csv" myAlignment 1000 (λ (x : ℝ) => GnuPlot.formatReal x)
    ``` -/
@[inline] unsafe def saveAlignment [TrackScalar α] {cA cB : Curvature α}
    (path : String)
    (align : RailwayAlignment α cA cB)
    (numPts : Nat := 1000)
    (fmt : α → String) : IO Unit :=
  let csv := alignmentToCSV align numPts fmt
  writeCSV path csv

/-- Generate a GNUPlot script snippet to overlay multiple alignments with optional
    labeled control-point overlays.

    Each entry is a `(filePath, title, pointsFilePath?)` triple. When `pointsFilePath`
    is `some path`, a second plot entry is added that draws the placed control points
    with coordinate labels (using `with labels point`). -/
def gnuplotScript (files : List (String × String × Option String)) : String :=
  let header :=
    "set datafile separator \",\"\n" ++
    "set key autotitle columnhead\n" ++
    "set xlabel \"x (m)\"\n" ++
    "set ylabel \"y (m)\"\n" ++
    "set size ratio -1\n"
  let entries : List String := files.flatMap λ (path, title, pts) =>
    let alignEntry := s!"\"{path}\" using 2:3 with lines title \"{title}\""
    match pts with
    | none => [alignEntry]
    | some ptsPath =>
      [alignEntry,
       s!"\"{ptsPath}\" using 1:2:3 with labels point pt 7 ps 1.5 lc rgb \"red\" notitle"]
  let plotCmds := entries.zip (List.range entries.length) |>.map λ (entry, i) =>
    let sep := if i == 0 then "plot" else "     "
    s!"{sep} {entry}"
  header ++ String.intercalate ", \\\n" plotCmds ++ "\n"

end IO

end GnuPlot
