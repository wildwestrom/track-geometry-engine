import TrackGeometry.Scalar
import TrackGeometry.Clothoid
import TrackGeometry.Design
import TrackGeometry.Planar
import TrackGeometry.Vec
import TrackGeometry.Segment
import TrackGeometry.Cant
import TrackGeometry.Path
import TrackGeometry.RFloat

/-! # Track geometry core

Convenience re-export of the geometry engine modules:

* `TrackGeometry.Scalar` — `TrackScalar` and scalar helpers
* `TrackGeometry.Clothoid` — Gauss–Legendre clothoid quadrature and shift
* `TrackGeometry.Design` — `SpeedModel`, `LayoutPolicy`, `CornerParams`, `solveCornerParams`, PI budget allocation stages (`desiredBudgets`, `resolveSharedLegs`, `cornerDragBounds`)
* `TrackGeometry.Planar` — 2D horizontal alignment (`Vec2`, `TurnDir`, `Segment2D`, `AlignmentPath2D`, `buildPath2D`)
* `TrackGeometry.Vec` — `Vec3` 3D vector operations
* `TrackGeometry.Segment` — segments, clothoid placement, RMF frames
* `TrackGeometry.Cant` — design cant from curvature and speed
* `TrackGeometry.Path` — PI builder, `AlignmentPath`, `buildPath`
* `TrackGeometry.RFloat` — computable `Float` scalar instance
-/
