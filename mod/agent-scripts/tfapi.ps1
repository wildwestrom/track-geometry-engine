# Windows counterpart of tfapi: search TF3's Teal API definitions (api\tealdef and base\tealdef
# in the game install), case-sensitive regex, paths relative to the install; first 60 lines.
#   tfapi.ps1 PATTERN [-A N] [-B N] [-I]     e.g. tfapi.ps1 'record WindowAPI' -A 5
# -A/-B lines of context after/before (like grep), -I ignore case.
param([Parameter(Mandatory = $true, Position = 0)][string]$Pattern,
	[int]$A = 0, [int]$B = 0, [switch]$I, [string]$SteamId = "75515556")
. (Join-Path (Split-Path $PSScriptRoot) "tfpaths.ps1") -SteamId $SteamId
if (-not $TfGame) { [Console]::Error.WriteLine("tfapi: Transport Fever 3 not found in any Steam library"); exit 1 }
$files = Get-ChildItem -Recurse -File -Filter *.tl -Path (Join-Path $TfGame "api\tealdef"), (Join-Path $TfGame "base\tealdef")
$cut = { param($s) if ($s.Length -gt 300) { $s.Substring(0, 300) } else { $s } }
$(foreach ($m in Select-String -Path $files.FullName -Pattern $Pattern -CaseSensitive:(-not $I) -Context $B, $A) {
	$rel = $m.Path.Substring($TfGame.Length + 1) -replace '\\', '/'
	$k = $m.LineNumber - $m.Context.PreContext.Count
	foreach ($c in $m.Context.PreContext) { & $cut "${rel}-${k}-$c"; $k++ }
	& $cut "${rel}:$($m.LineNumber):$($m.Line)"
	$k = $m.LineNumber + 1
	foreach ($c in $m.Context.PostContext) { & $cut "${rel}-${k}-$c"; $k++ }
}) | Select-Object -First 60
