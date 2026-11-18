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

On Windows, use the PowerShell versions: `check.ps1`, `sync.ps1`, and `agent-scripts/{ship,tflog,tfapi,jjctx}.ps1`. They take the same arguments, but as PowerShell parameters (`tflog.ps1 -All -N 100 REGEX...`, `tfapi.ps1 PATTERN -A 5`). Run `rep` and `show` as `python agent-scripts/rep` and `python agent-scripts/show`, because `python3` there is the Microsoft Store stub. Pipe `rep`'s blocks from PowerShell 7 (`pwsh`): Windows PowerShell 5.1 pipes text to native programs as ASCII.
