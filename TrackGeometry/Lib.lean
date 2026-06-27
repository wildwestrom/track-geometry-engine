import TrackGeometry.Vec
import TrackGeometry.Segment
import TrackGeometry.Cant
import TrackGeometry.Path
import TrackGeometry.RFloat

/-! # Track geometry core

Convenience re-export of the geometry engine modules:

* `TrackGeometry.Vec` — `TrackScalar`, `Vec3`, scalar helpers
* `TrackGeometry.Segment` — segments, clothoids, RMF frames
* `TrackGeometry.Cant` — design cant from curvature and speed
* `TrackGeometry.Path` — PI builder, `AlignmentPath`, `buildPath`
* `TrackGeometry.RFloat` — computable `Float` scalar instance
-/
