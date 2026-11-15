# TF3 track geometry mod

An in-game tool that lays new track the way the game's builder does: click, move, click. Each end is a free track end or open ground. The player adds turns (horizontal PIs), drags them, resizes curves with brackets, edits a separate vertical profile (elevation points), previews the ghost and builds. Built track is ordinary game track.

The geometry core is a hand port of the Lean code (`TrackGeometry/*.lean`) to Teal. There is no Lean → Lua backend. Lean is the spec, `RFloat` is the numeric reference, and `Cant.lean` is not ported. `lake exe fixtures` writes `test/fixtures.lua` (floats as IEEE bits), and `test/geometry_test.lua` checks the port bit-exact against it. **Regenerate the fixtures after changing the Lean core.**

Out of scope: editing existing track, re-editing after a build, following the terrain, computing cant, depending on RTC, an undo tree, loop winding.

## Trying a change in game

Run `./check.sh` (type-checks every `.tl` and runs `test/*_test.lua`), then `./sync.sh`, then reload the map. The game reads the mod only from the staging copy, when a map loads, so an unsynced change looks like a bug in game.

## Modules

Only `tg_gui`, `tg_world` and `tg_proposal` touch the game API. The rest have a `test/<name>_test.lua`.

| Module | Role |
|---|---|
| `tg_geometry` | Port of Vec, Segment, Path (`buildPath`), same operation order as Lean |
| `tg_alignment` | Samples a path into nodes; skips pieces under `MIN_PIECE` (1 m) and zero-length segments |
| `tg_ends` | `End` (tagged by `kind`: `track`, `ground`), starting layouts, `snap` |
| `tg_edit` | The alignment being edited: turns, budgets, elevation points, `hit` |
| `tg_profile` | Vertical profile |
| `tg_plan` | What the ghost shows and the tool builds: `dense` (every 10 m) and `built` pieces |
| `tg_structures` | Bridge/tunnel classification per piece |
| `tg_readout` | Speed/grade summary and badges |
| `tg_session` | Tool state machine: events in (`tick`, `mouse`, `click`, `back`), requests out |
| `tg_proposal` | Sampled nodes → `SimpleProposal` |
| `tg_world` | Every game-world read, guarded. Holds the crash traps |
| `tg_gui` | React recipes, windows, gizmos; turns game callbacks into session events |

## Design decisions

- **Budgets** (Lean `cornerLayouts`, "leg minus neighbour"): a corner's own legs bound it by the whole shorter leg. A shared leg is split in proportion when the two asks do not fit. End curves with no override take all the room to the path end and give way to neighbours down to the radius floor.
- **Radius floor** is 40 m, the tightest the game builds (found by experiment). The floor budget accounts for transition spirals (`DesignParams.radiusFloorBudget`), so no arc goes under 40 m.
- **Starting layouts** depend on the ends: straight, corner, s-curve, long s-curve (> 800 m), arc or turn on the ray (one ground end). Straight detection uses 1e-6 rad / 2 mm because game positions are single precision. A track ending mid-curve joins with a curvature jump. That is accepted.
- **Vertical profile is not in Lean**, by choice. Horizontal PIs go through `buildPath` at z = 0 and the profile is laid on top. It is a monotone cubic (Fritsch–Carlson / PCHIP) through the elevation points. A C² clamped spline was dropped because it made a level span dip ahead of a climb. End grades come from the existing track, so the joins have no kink. A ground end uses its span's chord grade. PVIs (straight grades plus parabolic curves) are the likely next model.
- **Grade limit** is the template's `maxSlopeBuild`. Drags stop at the limit. A height set directly may exceed it, and then the build is refused ("too steep"). Points within `MIN_SPAN` (20 m) of an end or of another point are "too close": they are left out of the profile and refuse the build.
- **Piece length**: a Hermite with `T = 4r tan(φ/4)` follows the curve within mm even over long pieces. So built pieces are cut at `MAX_TURN` (15°) of turn with no length limit, plus a node at every structure boundary and elevation point. The 10 m `dense` path is only for structures, the readout and picking.
- **Cant**: none. Build with base templates, never RTC's `_dvp`. A player can upgrade to RTC's canted track afterwards. RTC targets 0.8 × `11.8 V²/R` mm, capped at `40 + 0.46 V` (60–200), smoothed over `clamp(1.2 V, 40, 240)` m.
- **Removal** is right-click on the thing under the mouse. Still to do: a linear undo stack so Esc out of editing keeps the alignment.

## Where things live

| What | Path |
|---|---|
| Game install | `~/.local/share/guix-sandbox-home/.local/share/Steam/steamapps/common/Transport Fever 3/` |
| API type defs | `<install>/api/tealdef/api/{type,cmd,engine,gui}.d.tl` |
| GUI / React defs | `<install>/base/tealdef/scripts/builtin.d.tl` |
| Game GUI sources | `<install>/base/content/gui.zip` (`construction_react_util.tl`, `builtin.lua`, `gui/construction/tools/`) |
| mod.io mods | `~/.local/share/guix-sandbox-home/mod.io/common/10640/mods/<id>/` (id → name: `../metadata/state.json`) |
| Staging copy | `.../userdata/75515556/3493540/local/staging_area/track_geometry/` |
| Log | `.../local/crash_dump/stdout.txt` (current session only) |

Reference mods: **Auto Track Connector** (`6429593`, Teal, `tc_proposal`, `tc_gui`, `tc_planner`), **Real Track Cant** (`6418700`, Lua, French comments), **Gleis- und Straßenbauanzeige** (`6418902`, `preview.lua`), **Realistic Track Gradients** (`6433559`, sets `maxSlopeBuild`).

## Building track (proposals)

- Build an `api.type.SimpleProposal` and fill `streetProposal.nodesToAdd` / `edgesToAdd`. **Fill plain Lua tables and assign each list whole.** Reading a list field returns a copy, so `sp.edgesToAdd[i] = e` is silently lost and the proposal builds nothing at cost 0.
- New entities take negative ids: edges `-1..-m` first, then nodes `-(m+1)..`. Use an existing node's entity id to attach to it.
- Node: `NodeAndEntity.new()`, with `entity` and `comp.position`.
- Edge: `SegmentAndEntity.new()` with `type = 1`. It needs `node0/1`, `position0/1`, `tangent0/1` (a cubic Hermite: tangent scaled by `T`, z = slope × T), `type = BaseEdgeType.NORMAL` (`typeIndex = -1`) or BRIDGE/TUNNEL with a type id, `roadType = TRACK`, `roadTemplate`, `laneConfigs`, `roadStyle = template.streetStyle`, `distance = template.trackDistance` (without it, embankments break), and `playerOwned`.
- Edges are only Hermites. `EdgeGeometry` ARC is for drawing only.
- Dry run: `api.engine.util.proposal.makeProposalData(proposal, context)` gives `costs`, `errorState`, `collisionInfo`. Build: `api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(p, ctx, false, true), cb)`, sent from the GUI.
- **Crash traps** (fatal, `pcall` won't catch them): naming a node that no longer exists, NaN coordinates, pieces under 0.1 m. Validate before every preview or build.
- Reading track: `getComponent(e, BASE_EDGE)`; `streetSystem.getNodeStreetSegments(node)`. `forEachEntityWithComponent` refuses BASE_EDGE.
- The proposal's `comp.type` is taken literally. The game's drag tool picks bridges and tunnels natively (track: bridge above 6 + 6 m, tunnel below 9 + 6 m), so `tg_structures` does the same itself (bridge over water or > 12 m up, tunnel > 15 m down), with types picked as the menu auto-selects them (`menu_category_util`).
- `ProposalData.entity2tn` gives each proposed piece's transport-network edge, and its `curveSpeedLimit` (m/s) is the game's own curve speed. The Speed Limit layer only paints built track.
- **How the game's builder eases grade** (reverse engineered): one Hermite per drag with `z'(u) = e + (s0 − e)(1 − u)²`, with no vertical-curve minimum. Templates have `maxSlopeBuild = 0.085`, `maxSlope = 0.13`, `maxSlopeShape = 0.16`.

## Tool and GUI

- Register the tool with a `.res.lua` of `type = "construction_tool"`, whose `getDefinitionFn` returns `{ action = "ACTION_CUSTOM", customAction = { recipe }, menuCategory = rail_tools, params }`. Inside the recipe, `params.setActionFn(fn, key)` while `isActive`. `fn` returns `builtin.ActionDescriptor{ tool = "construction", children }`.
- Children: `builtin.Selector{ onProcessMouseEvent }` takes raw mouse events (return true from `Pressed` to keep the camera off a drag). `builtin.ProposalViewer` draws the ghost, and **only one may exist at a time** (a second is fatal). `EdgeRenderable` draws gizmos (STRAIGHT or ARC, `angle = 2π` for a circle). `builtin.FullScreenComponent` hosts the badges.
- `getCurrentParams` returns only the Settings-window params (`location = Default`). Params are option switches only, with no one-shot button.
- **The game runs Lua 5.2.** Use `math.atan2`, since two-argument `math.atan` ignores `x`.
- A file's main chunk allows at most 200 locals, and each Teal record counts as one.
- Requires: `ug_require "::/gui/main/react.lua"` for game GUI; `require("<modId>::/path/file.script.tl")` for our own.
- Grab radius: 2% of `getCameraData()[3]` (camera distance) stays constant on screen.
- Shift: `api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")`. Ctrl + left drag belongs to the camera.

## GUI pitfalls

- **`os.clock()` is CPU time summed over threads**, not wall time. Count tool ticks or frames instead.
- **Restricted outside a game-bar plugin's `react.onStep`**: `api.gui.mouse.getTerrainPosition` and `api.gui.camera.world2Screen` return "API is currently restricted". `TgProbe` reads them (and `getEye`) there and hands them over. `terrain.getHeightAt` and `isOnWater` work anywhere.
- **Right-click / Esc**: both arrive as "back". The tool never sees the right press (the camera keeps it). It sees the release, and "back" comes only after a still click. One input's "back" can arrive several times (selector, input action, `onBack`), so swallow repeats for `RIGHT_TICKS`. Capture `IA_CLOSE_TOPMOST_WINDOW` so the construction menu stays open.
- **Ghost throttling**: the game's check of each ghost is what makes drags stutter. Remake at most every `GHOST_TICKS` (4) and only after the last `onCreateProposalData` (or `GHOST_WAIT` (20) ticks). Mod Lua has no threads.
- **Picking on bridges**: the ground under the mouse lies far behind a raised track, so pick along the view ray (`getEye()` through the ground point).
- **A window recipe must wrap `builtin.Window`** with `react.RegisterWrapperRecipe`, or it fails `NodeStorage.cpp:51`. **Opening a window from `onStep` crashes** with the same assertion. Open windows from a click via `windowContainer:get():getApi().addSingletonWindow`. `ToggleButtonGroup` indices are 1-based. A window gets its params once, so poll the session with its own `useStepStateTimer`.
- **Badges layout**: the full-screen recipe must return a layout (a `Component` kills the GUI with "Recipe child must be a layout"). It shrinks to its children unless `tg_gui.css.lua` sets `gravity = {-1, -1}`. `size` in `meta.styleSheet` is ignored, and inline styles have no `gravity`. There is no text HUD primitive.
- The builder's native tick/cross is `BuildControlComp` (C++ only). Its icons are in `gui/construction/build_control/`.
- **Mouse cursor**: `ActionDescriptor{ mouseCursor = id }` sets it while the tool is active. The Teal def leaves the field out, but the game's own construction tools pass it (`construction_react_util.tl`). Ids are in `gui_react_util.tl` (`getMouseCursorInteger`): "Rail" = 1024 is the track builder's (seen in game).
- **Control point** (the builder's white dot, with a blue ring while dragging): `ProposalViewerParam.controlPointInfo = builtin.type.ControlPointInfo.new(Vec3f pos, offsetZ, radius, State)`, State one of Normal, Hover, Dragging, Idle, IdleOverEdge. One per viewer, which is enough for the end under the mouse (`tg_session.cursor`). With no ghost, a viewer with an empty `SimpleProposal` holds it. It works in game, on the empty viewer too: the dot, and the ring while dragging. Seen in game: Normal a grey dot, Hover a grey dot ringed blue, Dragging a white dot ringed blue, Idle a white ring, IdleOverEdge a blue ring, Invalid nothing. The road builder uses Idle (ground), IdleOverEdge (over track or road) and Dragging, and so does the tool. How the game draws it (reverse engineered, `builderRendererUI`, around `0x11ef110` in the binary): screen-space round sprites, D = 12 px × UI scale across. Normal: a D dot of grey 0.75. Hover and Dragging: a 2D disc of blue (40, 91, 123) under a D dot, grey 0.75 for Hover and white for Dragging, so it reads as a ringed dot. Idle and IdleOverEdge: one dot, white for Idle and a style colour (the renderer's own field, not settable) for IdleOverEdge, of diameter min(D, 2D − p), where p is `radius` projected to pixels. So the dot shrinks as the radius grows on screen and is gone past 2D. With radius 0 it is a full solid dot, which is the track builder's look. `offsetZ` and `radius` are ignored by the other states. C++ also has states 6 and 7 (more style colours), which the Lua enum does not expose. `VANILLA_CURSOR = false` in `tg_gui` draws gizmo circles instead (they are also drawn when making the control point fails).
- **Untested in game**: the track-type settings, and the elevation box (whether `DoubleSpinBox` follows a new `value` and fires `onValueChange` for it, and whether typing digits fires game hotkeys; if so, try `inputActionBubbleUpFilter = filterOutAll()`).
