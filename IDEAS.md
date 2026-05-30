# Planning

Here's sort of a picture of what I want this to do.

I want to be able to move around control points, kind of like a vector graphics editing program. It should be easy to click and drag to make a new line. I should also be able to move around these control points and have the curves make sense. This is why alignments should probably be based on the PI (Point of Intersection) approach as opposed to stationing.

The alignments will be composed of straight lines, circular arcs, and transition curves. These transition curves may be clothoids, bloss curves, sinusoidal curves, or some other type of curve.

Superelevation or cant should be calculated. I don't know how real railways do this, but I'm assuming it's based on curvature and expected speed.

I should be able to see multiple heatmap views of top speed, cant deficiency/excess, angular acceleration, jerk, etc. along the alignment by toggling through various info views. For example, the top speed view could show the line in various colors, from red meaning slow to green meaning fast, along with some numbers to show the actual top speed in km/h.

The type system should not allow a straight line to directly attach to a circular arc if we require G^2 continuity, at least in most cases. At low speeds turnouts and such do have so called "virtual transitions" which are G^1 continuous. At very high speeds, we may want G^3 or G^4 continuity at a minimum. Two straight lines of course can be proven to be G^infinity continuous.

The first use case I suppose is to just define a placement routine. Imagine we're clicking points with a mouse. For each point, we enter a different state of the alignment. Before we click there's no alignment. First click starts constructing the alignment by specifying a single point and no segments. The second click creates a straight line segment. The next segment will be either straight or curved depending on a snapping threshold, and so on. 

Another thing I may want to do is be able to view geometric continuity at each point. I should be able to toggle something that displays G^n for the class of geometric continuity at each join.

It would be really nice if I could create a smart algorithm that picks a curve appropriate for the level of continuity desired, but that seems too complicated for now.
