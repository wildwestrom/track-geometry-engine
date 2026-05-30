# Track Geometry Engine

This is a track geometry engine.

## Story

It all started in the summer of 2025. I was playing Transport Fever 2, but I was frustrated by the track building tools. I kept trying to find new ways to build the tracks so the curves would look nice and smooth, but I could never get them just right. It was from this frustration that I went down the rabbit hole of curves and track geometry.

## Developer workflow

*TODO*: Add more instructions.

For now, we can run the following commands to see the results of our work.

```shell
lake env lean --run scripts/dump_csv.lean
gnuplot --persist scripts/plot.gnuplot
```

## Planning

Here's sort of a picture of what I want this to do.

I want to be able to move around control points, kind of like a vector graphics editing program. It should be easy to click and drag to make a new line. I should also be able to move around these control points and have the curves make sense. This is why alignments should probably be based on the PI (Point of Intersection) approach as opposed to stationing.

The alignments will be composed of straight lines, circular arcs, and transition curves. These transition curves may be clothoids, bloss curves, sinusoidal curves, or some other type of curve.

Superelevation or cant should be calculated. I don't know how real railways do this, but I'm assuming it's based on curvature and expected speed.

I should be able to see multiple heatmap views of top speed, cant deficiency/excess, angular acceleration, jerk, etc. along the alignment by toggling through various info views. For example, the top speed view could show the line in various colors, from red meaning slow to green meaning fast, along with some numbers to show the actual top speed in km/h.
