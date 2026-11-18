# agent-scripts

Helpers so the agent runs one command instead of rebuilding the same tool calls. Details are in each script's header comment.

- `rep`: exact-text replacements across files from stdin blocks; writes nothing unless every block matches.
- `show PATTERN FILE...`: matches with line numbers and context, or the whole block with `--block`.
- `ship`: `check.sh` with only the failures shown; runs `sync.sh` if it passes.
- `tflog [ERE...]`: the game log since the last mod load, filtered to the mod's lines.
- `tfapi PATTERN`: grep the game's Teal API definitions.
- `jjctx [N]`: `jj st`, recent log, and diffstat.

Windows: `ship.ps1`, `tflog.ps1`, `tfapi.ps1` and `jjctx.ps1` do the same jobs in PowerShell (5.1 or 7). They find Steam and the game install through `../tfpaths.ps1`. `rep` and `show` are Python and run on either OS, as `python agent-scripts/rep`.
