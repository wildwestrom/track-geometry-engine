import TrackGeometry.Lib
import TrackGeometry.GnuPlot

open GnuPlot

/-- Rotate a vector in the XY plane, preserving Z. -/
def rotateXY (angle : RFloat) (v : Vec3 RFloat) : Vec3 RFloat :=
  let c := TrackScalar.cos angle
  let s := TrackScalar.sin angle
  Vec3.mk (c * v 0 - s * v 1) (s * v 0 + c * v 1) (v 2)

/-- Tangent direction at the end of a linear-curvature transition. -/
def transitionInEndTangent (radius length : RFloat) (startTangent : Vec3 RFloat) : Vec3 RFloat :=
  rotateXY (length / (⟨2.0⟩ * radius)) startTangent

/-- Point reached after `arcLen` along an arc from `startPt` with `startTangent`. -/
def arcPointAfter (radius : RFloat) (startPt startTangent : Vec3 RFloat) (arcLen : RFloat) : Vec3 RFloat :=
  let seg : Segment RFloat (.curved radius) (.curved radius) :=
    Segment.arc radius startPt startPt startTangent
  seg.pointAt arcLen

-- Example 1: Straight section, transition to 500m radius curve, then arc
def example1Params : Vec3 RFloat × Vec3 RFloat × Vec3 RFloat × Vec3 RFloat :=
  let p0 := Vec3.mk ⟨0.0⟩ ⟨0.0⟩ ⟨0.0⟩
  let p1 := Vec3.mk ⟨10.0⟩ ⟨0.0⟩ ⟨0.0⟩
  let radius : RFloat := ⟨500.0⟩
  let transitionLen : RFloat := ⟨15.0⟩
  let arcLen : RFloat := ⟨140.0⟩
  let dir0to1 := Vec3.mk ⟨1.0⟩ ⟨0.0⟩ ⟨0.0⟩
  let p2 := transitionPoint p1 dir0to1 0 (1 / radius) transitionLen transitionLen .clothoid
  let dirAtP2 := transitionInEndTangent radius transitionLen dir0to1
  let p3 := arcPointAfter radius p2 dirAtP2 arcLen
  (p0, p1, p2, p3)

def rfloatExample1 : RailwayAlignment RFloat .straight (.curved ⟨500.0⟩) :=
  let (p0, p1, p2, p3) := example1Params
  let radius : RFloat := ⟨500.0⟩
  let transitionLen : RFloat := ⟨15.0⟩
  let dir0to1 := Vec3.mk ⟨1.0⟩ ⟨0.0⟩ ⟨0.0⟩
  let dirAtP2 := transitionInEndTangent radius transitionLen dir0to1
  RailwayAlignment.append
    (RailwayAlignment.append
      (RailwayAlignment.single (Segment.straight p0 p1))
      (Segment.transitionIn radius (.gn 2) p1 dir0to1 transitionLen .clothoid))
    (Segment.arc radius p2 p3 dirAtP2)

-- PI-based placement. Points are points of intersection (PIs): the alignment runs
-- along the legs and rounds each interior corner with a circular arc. The radius is
-- auto-selected to fit a tangent budget; only the first/last PI lie on the line.
def designParams : DesignParams RFloat :=
  { legBudget := ⟨0.4⟩, straightThreshold := ⟨0.02⟩, transitionLengthRatio := ⟨0.5⟩ }

-- Example 2: one interior corner.
def example2PIs : Array (Vec3 RFloat) := #[
  Vec3.mk ⟨0.0⟩   ⟨0.0⟩  ⟨0.0⟩,
  Vec3.mk ⟨100.0⟩ ⟨0.0⟩  ⟨0.0⟩,
  Vec3.mk ⟨200.0⟩ ⟨80.0⟩ ⟨0.0⟩
]

-- Example 3: several corners (sharper, both turn directions).
def example3PIs : Array (Vec3 RFloat) := #[
  Vec3.mk ⟨20.0⟩   ⟨40.0⟩   ⟨0.0⟩,
  Vec3.mk ⟨-100.0⟩ ⟨-100.0⟩ ⟨0.0⟩,
  Vec3.mk ⟨50.0⟩   ⟨-50.0⟩  ⟨0.0⟩,
  Vec3.mk ⟨75.0⟩   ⟨80.0⟩   ⟨0.0⟩
]

def main : IO Unit := do
  let fmt : RFloat → String := λ x => formatFloat x.val

  -- Example 1
  let csv1 := alignmentToCSV rfloatExample1 1000 fmt
  writeCSV "scripts/example1.csv" csv1
  let (p0, p1, p2, p3) := example1Params
  let pts1 := placedPointsToCSV #[p0, p1, p2, p3] fmt
  writeCSV "scripts/example1_points.csv" pts1

  -- Example 2
  let path2 := buildPath example2PIs designParams
  writeCSV "scripts/example2.csv" (pathToCSV path2 1000 fmt)
  writeCSV "scripts/example2_points.csv" (placedPointsToCSV example2PIs fmt)

  -- Example 3
  let path3 := buildPath example3PIs designParams
  writeCSV "scripts/example3.csv" (pathToCSV path3 1000 fmt)
  writeCSV "scripts/example3_points.csv" (placedPointsToCSV example3PIs fmt)

  let gp := gnuplotScript [
    ("scripts/example1.csv", "Example 1 (manually placing segments)",
     some "scripts/example1_points.csv"),
    ("scripts/example2.csv", "Example 2 (PI: one corner)",
     some "scripts/example2_points.csv"),
    ("scripts/example3.csv", "Example 3 (PI: several corners)",
     some "scripts/example3_points.csv"),
  ]
  writeCSV "scripts/plot.gnuplot" gp

  IO.println "Done!"
  IO.println "  scripts/plot.gnuplot"
