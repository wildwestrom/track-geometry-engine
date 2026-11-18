# Windows counterpart of ship: run check.ps1 quietly; if it passes, run sync.ps1 (AGENTS.md asks
# for both after every change under track_geometry/). On failure prints the failing lines (tl
# errors, FAIL lines, Lua errors) and the per-test summaries, then exits 1 without syncing.
# Full output is kept in $env:TEMP\tg-check.out for when the summary isn't enough.
#   powershell -ExecutionPolicy Bypass -File mod\agent-scripts\ship.ps1
$mod = Split-Path $PSScriptRoot
$out = Join-Path $env:TEMP "tg-check.out"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $mod "check.ps1") 2>&1 | ForEach-Object { "$_" })
$ok = $LASTEXITCODE -eq 0
[IO.File]::WriteAllLines($out, [string[]]$lines) # UTF-8; 5.1's *> would write UTF-16
if ($ok) {
	$n = @($lines | Where-Object { $_ -match '^ok ' }).Count
	$p = @($lines | Where-Object { $_ -match '^all passed' }).Count
	"check: $n ok, $p test files passed"
	& (Join-Path $mod "sync.ps1")
} else {
	$lines | Where-Object { $_ -match '^FAIL |error|\.tl:\d+:\d+:|^lua: |[0-9]+ failed$|^== ' -and $_ -notmatch '^\s*no file' } |
		Select-Object -First 60
	"check failed; not synced (full output: $out)"
	exit 1
}
