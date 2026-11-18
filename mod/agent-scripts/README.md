# agent-scripts

Helpers so the agent runs one command instead of rebuilding the same tool calls. Details are in each script's header comment.

- `rep`: exact-text replacements across files from stdin blocks; writes nothing unless every block matches.
- `show PATTERN FILE...`: matches with line numbers and context, or the whole block with `--block`.
- `ship`: `check.sh` with only the failures shown; runs `sync.sh` if it passes.
- `tflog [ERE...]`: the game log since the last mod load, filtered to the mod's lines.
- `tfapi PATTERN`: grep the game's Teal API definitions.
- `jjctx [N]`: `jj st`, recent log, and diffstat.
