# TF3 track geometry mod: research notes

Goal: an in-game tool that lays **new** track between two existing track segments (picked like in Auto Track Connector). The alignment starts as the connection between them. The player splits it by adding **turns** (horizontal PIs) at chosen spots, then drags them and resizes each curve with brackets. A separate set of **elevation PIs** controls the vertical profile, which never follows the terrain. The player previews the result, can pick a different alignment, and then builds. Built track is ordinary game track, so to change it you destroy it and rebuild. The geometry core is ported from the Lean code (`TrackGeometry/*.lean`) to Teal, with the Lean code serving as the spec.

## Lean → Lua

There is no Lean 4 → Lua backend. Lean compiles only to C/LLVM, and a custom backend would mean writing a separate executable that consumes `.olean` files. So we **port the core by hand** (Vec, Segment/clothoid sampling, corner solve, `buildPath`). `Cant.lean` is not ported: the mod builds without cant, and the centreline code does not depend on it. The `RFloat` instance is the reference for numeric behaviour.

## Where things live

| What | Path |
|---|---|
| Game install | `~/.local/share/guix-sandbox-home/.local/share/Steam/steamapps/common/Transport Fever 3/` |
| API type defs | `<install>/api/tealdef/api/{type,cmd,engine,gui}.d.tl` |
| GUI / React defs | `<install>/base/tealdef/scripts/builtin.d.tl` (components), `react`, etc. |
| mod.io mods (subscribed) | `~/.local/share/guix-sandbox-home/mod.io/common/10640/mods/<id>/` |
| mod.io id → name | `.../mod.io/common/10640/metadata/state.json` |
| Our staging copy | `.../userdata/75515556/3493540/local/staging_area/track_geometry/` (`./sync.sh`) |
| Log | `.../local/crash_dump/stdout.txt` (current session only) |

Reference mods:
- **Auto Track Connector**: mod.io `6429593`, modId `ethan_track_connector`. Teal, ~10k lines.
- **Real Track Cant**: mod.io `6418700`, modId `devers_1`. Lua, comments in French.

## How track is built (from Auto Track Connector)

See `6429593/content/track_connector/tc_proposal.script.tl`, `proposals.makeProposal` (~L395–640).

- Build an `api.type.SimpleProposal`. Fill `proposal.streetProposal.nodesToAdd` / `edgesToAdd` (also `edgesToRemove` and `nodeConfigsToAdd/Remove`, which we don't need for new track).
  - **Fill plain Lua tables and assign each list whole** (`sp.edgesToAdd = edges`). Reading a list field off the native proposal returns a copy, so `sp.edgesToAdd[i] = e` is lost. The proposal then stays empty, and the dry run and the build both "succeed" with cost 0 and nothing built.
- New entities use **negative ids**: edges `-1..-m` first, then nodes `-(m+1)..`. To attach to existing track, use the existing node's entity id for `node0`/`node1`.
- Node: `api.type.NodeAndEntity.new()`, set `entity` and `comp.position = Vec3f`.
- Edge: `api.type.SegmentAndEntity.new()`, set `type = 1` (track) and these `comp` fields:
  - `node0`, `node1`, `position0`, `position1`
  - **`tangent0`, `tangent1`**: each edge is a **cubic Hermite**. Tangents are scaled by a length `T`, and their z-component is slope × T.
  - `type = BaseEdgeType.NORMAL` with `typeIndex = -1`, or BRIDGE/TUNNEL with a bridge/tunnel type id
  - `roadType = RoadType.TRACK`, `roadTemplate = <track template name>`, `laneConfigs = template.laneConfigs`, `roadStyle = template.streetStyle`
  - `distance = template.trackDistance` (5 m). Without it, embankments and noise barriers break.
  - `e.playerOwned` with `owned.player = api.engine.util.getPlayer()`
- Templates: `api.res.streetTemplateRep.find(name)` / `.get(id)`.
- Tangent length for an arc-like Hermite piece (`tc_planner.script.tl` `planner.tangentLength`): with chord `c` and turn `φ`, `r = c / (2 sin(φ/2))` and `T = 4 r tan(φ/4)` (`T = c` if φ ≈ 0).
  - **Consequence for us:** there are no native clothoids, so we sample our alignment into short pieces with exact position and heading at every node, and the Hermite fills in between. Piece length decides accuracy, especially through spirals.
- Dry run (cost, collisions, errors) with no building: `api.engine.util.proposal.makeProposalData(proposal, context)`, then read `data.costs`, `data.errorState.{critical,messages,warnings}` and `data.collisionInfo.collisionEntities`.
- Build: `api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true), callback)`. Track Connector does this from its **game script** (`tc_engine.script.tl`, registered via `track_connector.gs.lua`). The GUI sends it events with `api.cmd.makeScriptingSendEventCmd("", "TrackConnector", name, param)`.
- Crash traps they hit (the game dies; `pcall` won't catch it):
  - a proposal that names a node that no longer exists
  - NaN coordinates
  - zero-length pieces (< 0.1 m)

  Validate before every preview or build.
- Reading existing track: `api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)` gives node0/1, position0/1 and tangent0/1. `streetSystem.getNodeStreetSegments(node)` lists a node's edges. `forEachEntityWithComponent` refuses BASE_EDGE.
- Terrain under the mouse: `api.gui.mouse.hasTerrainPosition()` / `getTerrainPosition()`.

## How the tool / UI works (from Auto Track Connector)

- **Registering a tool:** a `.res.lua` with `type = "construction_tool"` and `getDefinitionFn` pointing at a function. That function returns `{ name, icon, action = "ACTION_CUSTOM", params, menuCategory = { categories = {{ category = "rail_tools" }} }, customAction = { recipe = <React recipe> } }`. See `tc_gui.script.tl` `TcToolDefinition` (~L4811).
- **Tool body:** a React recipe (`react.RegisterRecipe`) that returns `builtin.ActionDescriptor{ tool = "construction", onBack, children = {...} }` (~L4516–4630). Its children:
  - `builtin.Selector{ onHover, onSelect, onSelectSecondary, filter, onProcessMouseEvent = function(evt) ... }`. This takes raw mouse events (`evt.button`, `evt.type` = Pressed/Released/Clicked). **Use it for dragging control points.**
  - `builtin.ProposalViewer{ simpleProposal, onCreateProposalData, proposalId, entityForRefundableContext }` shows the game's see-through **ghost** and reports cost and errors. **Only one ProposalViewer at a time**; a second one is fatal.
  - `builtin.ActionTooltip(...)` for the hint text at the mouse.
- Per-frame tick: `engine_react_util.useStepStateTimer(fn, 0.05)`, or `react.onStep`.
- GUI modules are loaded with `ug_require "::/gui/main/react.lua"`, `"::/gui/main/builtin.lua"`, etc. Our own modules use `require("<modId>::/path/file.script.tl")`.
- Lua limit: at most 200 locals in a file's main chunk, and each Teal record counts as one. Their tool failed to load at 201.

### Gizmo primitives (from `builtin.d.tl`), not yet tried

- `builtin.EdgeRenderable{ edges = {Type.EdgeRenderable.Edge.new(EdgeGeometry)}, ignoreDepth }`. Each edge has `colors`, `width`, `offsetZ` and `stepSize`, and `EdgeGeometry` can be STRAIGHT, ARC or CUBIC_SPLINE. Candidate uses:
  - the PI polyline (start → PIs → end) as straight lines
  - arcs and spirals coloured by curvature
  - tangent ticks

  This is the gizmo layer, separate from the ghost.
- `ProposalViewerParam.controlPointInfo = Type.ControlPointInfo.new(pos, offsetZ, radius, State)`, with State Normal/Hover/Dragging/Idle. This looks like the game's own drag-handle marker. It allows one per viewer, so the PI handles probably need `EdgeRenderable` circles or HUD icons instead.
- `builtin.MissionArrowRenderable`, `api.gui.util.spawnEphemeralHudImage(...)`: fallback markers.

## Cant: leave it to Real Track Cant, optionally

The engine has no cant, and we don't compute any. **RTC is never a required dependency.** We build with the base track templates (never RTC's `_dvp` variants); a player who wants cant can upgrade the built track to RTC's canted track type, and RTC cants it from its curvature. Our curvature is a clean clothoid profile, so RTC's smoothing should behave well.

How RTC works, for reference: in `postRunFn` it generates variants of every track type (`_dvp` is the one the menu builds; `_dv`, `_dvs` and `_dvf` are internal). A game script watches `builder.proposalApply` and swaps segments to the right variant. It then places `devers_render.con` constructions with tilted models and rolls the trains. Its target cant is 0.8 × `11.8 V²/R` mm, capped at `40 + 0.46 V` mm (clamped to 60–200), and smoothed over `clamp(1.2 V, 40, 240)` m.

## Plan / milestones

1. **Proposal smoke test.** From a game script event, build one hard-coded alignment (straight → spiral → arc → spiral → straight) as Hermite pieces between two new nodes. Check the dry-run cost and errors, then build.
   - Implemented: `tg_alignment.script.tl` samples the alignment (no game API), `tg_engine.script.tl` handles the `tg_smoke` event (dry run, then build if asked and nothing is critical), and `tg_gui.script.tl` adds **TG dry run** / **TG build** buttons to the game bar. They start at the camera centre and head the way the camera faces. Results are logged with the `[westrom_track_geometry] smoke` prefix.
   - `./check.sh` type-checks every `.tl` file (it symlinks `.tlpath/` so `tl` resolves `<modId>::/` requires) and runs `test/*_test.lua` offline.
2. **Port the core to Teal.** Vec, segment sampling (clothoids by Gauss–Legendre quadrature, as in Lean), corner solve and `buildPath`, plus a sampler that emits nodes every ~N m.
   - Implemented: `tg_geometry.script.tl` ports `Vec`, `Segment` (no RMF frames) and `Path` (no windings), keeping Lean's operation order. `tg_alignment.script.tl` samples a path into nodes `{x, y, heading, s, k}`: one at every segment boundary and evenly spaced ones in between, at most `step` apart. It drops a node closer than `MIN_PIECE` (1 m) to the previous one, so a zero-length straight between two corners never becomes a crash-sized piece. The smoke test now builds through three PIs ahead of the camera (350 m legs, 40° left) with the UI's design parameters. The grade is still linear between the terrain heights at the ends; elevation comes in milestone 5.
   - Test: `lake exe fixtures` (`Fixtures.lean`) runs `buildPath` over 10 PI fixtures and writes `test/fixtures.lua` with every float as its IEEE bit pattern. `test/geometry_test.lua` checks the port against it: every length, radius, speed, point, tangent and curvature is **bit-exact** (tolerance 1e-9). Regenerate the fixtures after changing the Lean core.
   - Verified in game: TG build lays the 693 m smoke path as 73 pieces and 74 nodes (147 entities). Cost 124,711, no errors or collisions.
3. **Tool skeleton.** Register the construction tool and pick the start and end segments as in Track Connector. Their ends fix the start and end headings.
4. **Horizontal editing.** Add a turn at a spot on the alignment, drag turns over the terrain, and resize a curve with its brackets (per-turn budget). Draw the gizmos with `EdgeRenderable`.
5. **Vertical editing.** Elevation PIs placed along the chainage, with editable heights. Grade can be linear between them or transitioned, whichever is simpler.
6. **Ghost and build.** `ProposalViewer` with the sampled proposal shows cost and errors. The player can go back and change the alignment, then confirm, which sends a game-script event that calls `makeWorldBuildProposalCmd`.

Out of scope: editing existing track, re-editing after a build, following the terrain, computing cant ourselves, depending on RTC, an undo tree, loop winding.

## Hot reload

GUI and game scripts hot-reload. Set `debugMode = true` in `settings.lua` while the game is closed (the game rewrites the file at startup), run `./sync.sh`, then press **Shift + RAlt + R** (GUI) or **RAlt + F5** (game scripts) in game. The game re-reads the `.script.tl` files from the staging area, logs "React component reloaded: … ms" for the GUI, and remounts the recipes. `track_geometry/tg_gui.script.tl` (an invisible game-bar plugin, `tg_probe.res.lua`) logs its `VERSION` on load and mount, so the log shows whether the new code runs.

- With `debugMode` off, the debug keys do nothing and a sync has no effect until the next launch.
- Debug mode turns a mod's global write (`_G` `__newindex`) into an error. Mod scripts have no `rawget`/`rawset`, so we keep state in locals.
- A Lua error during reload logs "ReactFramework::Load() failed" with the stack. Fix the file, sync and reload again; no restart needed.
- The keys can be sent from a shell: gamescope runs the game on its own X display (`:1`), so `DISPLAY=:1 xdotool keydown Alt_R keydown Shift_L key r keyup Shift_L keyup Alt_R` reaches the game without touching desktop focus.
- **RAlt + F5** reloads game scripts. It logs "Reloading Lua StateProvider" and re-runs `tg_engine.script.tl` from the staging area in every Lua state that runs it (about 10 here). Module-level locals start fresh: the probe's `updated` flag resets and "first update" prints again with the new `VERSION`.
- New resource files (a new `.gs.lua` or `.res.lua`) need a restart; the game only finds them at startup.
- **RAlt + R** logs only "Stylesheets reloaded"; it does not re-run our scripts.
- **Plain F5 shadows RAlt + F5.** F5 is bound to *Show/Hide Warehouse Statistics* by default, and while it is, RAlt + F5 only opens that window. Set it to `<None>` in Settings → Keyboard and the reload works.

## Open questions

- Vertical profile is **not in the Lean spec**: `buildPath` solves corners in 3D (tilted corner planes). The mod runs horizontal PIs through it at z = 0 and lays elevation on top as new code. Do we spec that in Lean too?
- How does the game itself transition grade (Hermite tangent z = slope × T)? Is a linear grade between elevation PIs good enough visually?
- Max piece length that keeps a Hermite within, say, 5 cm of the clothoid. With 10 m pieces on the smoke path (R ≈ 233 m, 40 m spirals) the worst Hermite midpoint is 0.01 mm off, so pieces can be much longer; not measured yet.
- Does `EdgeRenderable` work inside a construction tool's `ActionDescriptor`? Not tried yet.
