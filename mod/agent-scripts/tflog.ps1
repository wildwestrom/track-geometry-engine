# Windows counterpart of tflog: read TF3's game log (crash_dump\stdout.txt) for the mod.
#   tflog.ps1 [-All] [-N 40] [REGEX...]
# By default: only lines after the last mod (re)load ("preRunFn: mod loaded" or
# "Reloading Lua StateProvider"), filtered to the mod's tag and error lines, Texture errors
# dropped, cut to 300 chars, last N=40 shown with line numbers.
# Each regex given replaces the default filter (lines matching any of them are kept),
# e.g. tflog.ps1 -N 200 'track_geometry_tool' '\[PerfMon\] v=1'
# -All  search the whole log instead of since the last load.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$All, [int]$N = 40, [string]$SteamId = "75515556",
	[Parameter(ValueFromRemainingArguments = $true)][string[]]$Patterns)
. (Join-Path (Split-Path $PSScriptRoot) "tfpaths.ps1") -SteamId $SteamId
$log = Join-Path $TfLocal "crash_dump\stdout.txt"
if (-not (Test-Path $log)) { [Console]::Error.WriteLine("tflog: no log at $log"); exit 1 }
# The game keeps the log open for writing, so open it shared.
$fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
try { $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Close() }
$lines = $text -split "\r?\n"
$start = 0
if (-not $All) {
	for ($i = $lines.Count - 1; $i -ge 0; $i--) {
		if ($lines[$i] -match 'preRunFn: mod loaded|Reloading Lua StateProvider') { $start = $i; break }
	}
}
$pat = if ($Patterns) { ($Patterns | ForEach-Object { "(?:$_)" }) -join '|' } else { 'track_geometry_tool|[Ee]rror|stack traceback' }
"== $log (from line $($start + 1), modified $((Get-Item $log).LastWriteTime.ToString('HH:mm:ss')))"
$hits = for ($i = $start; $i -lt $lines.Count; $i++) {
	$l = $lines[$i]
	if ($l -cmatch $pat -and $l -notmatch 'Texture error') {
		$s = "$($i + 1):$l"
		if ($s.Length -gt 300) { $s.Substring(0, 300) } else { $s }
	}
}
$hits | Select-Object -Last $N
