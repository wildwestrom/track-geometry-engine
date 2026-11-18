# Windows counterpart of sync.sh: mirror the mod into TF3's staging area.
# Usage: powershell -ExecutionPolicy Bypass -File mod\sync.ps1 [-SteamId 75515556]
param([string]$SteamId = "75515556")
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "tfpaths.ps1") -SteamId $SteamId
$src = Join-Path $PSScriptRoot "track_geometry"
$dst = Join-Path $TfLocal "staging_area\track_geometry"
# /MIR = copy + delete extras (like rsync -a --delete)
robocopy $src $dst /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }
$global:LASTEXITCODE = 0
"synced to $dst"
