# Agent notes

- After any change under `track_geometry/`, run `agent-scripts/ship` (check.sh, then sync.sh on a pass) before handing back: the game reads only the synced staging copy.
- Mod reference (game API, gotchas, what was found in game or reverse engineered; not design decisions, which live in the code and the git history): `NOTES.md`.

## Agent scripts

`agent-scripts/` has one-call helpers. Use one whenever it covers what you're about to do; its header comment gives the usage.

- Text edits, one or many, across files: `agent-scripts/rep` with blocks on stdin.
- Code around a match, or a whole function: `agent-scripts/show PATTERN FILE... [--block]`.
- Game log after an in-game test: `agent-scripts/tflog [ERE...]`.
- Game API (Teal definitions): `agent-scripts/tfapi PATTERN`.
- Repo state (status, recent log, diffstat): `agent-scripts/jjctx`.
