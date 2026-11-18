# Where TF3 lives on Windows; dot-sourced by sync.ps1 and the agent-scripts/*.ps1.
# Sets $TfSteam (Steam install), $TfLocal (userdata\<SteamId>\3493540\local) and $TfGame
# (the game install, found through Steam's library list; $null if not found).
param([string]$SteamId = "75515556")
$TfSteam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
if (-not $TfSteam) { $TfSteam = "C:\Program Files (x86)\Steam" }
$TfSteam = $TfSteam -replace '/', '\'
$TfLocal = Join-Path $TfSteam "userdata\$SteamId\3493540\local"
$TfGame = $null
$libs = @($TfSteam)
$vdf = Join-Path $TfSteam "steamapps\libraryfolders.vdf"
if (Test-Path $vdf) {
	$libs += Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' |
		ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
}
foreach ($l in $libs) {
	$g = Join-Path $l "steamapps\common\Transport Fever 3"
	if (Test-Path $g) { $TfGame = $g; break }
}
