# Windows counterpart of check.sh: type-check the mod's Teal files and run the offline tests.
# The game resolves require("<modId>::/dir/file.script.tl"); tl turns the dots into slashes and
# looks for <include_dir>/<modId>::/dir/file/script/tl.tl. "::" can't be in a Windows filename,
# so .tlpath/ holds copies under "<modId>__/" and tlconfig.lua maps "::" to "__".
# Usage: powershell -ExecutionPolicy Bypass -File mod\check.ps1   (exit 1 on any failure)
$ErrorActionPreference = "Stop"
trap { Write-Error $_ -ErrorAction Continue; Pop-Location; exit 2 }
Push-Location $PSScriptRoot
try {
	$modId = [regex]::Match((Get-Content -Raw track_geometry\mod.json), '"modId":\s*"([^"]*)"').Groups[1].Value
	$content = (Resolve-Path track_geometry\content).Path
	if (Test-Path .tlpath) { Remove-Item -Recurse -Force .tlpath }
	foreach ($f in Get-ChildItem -Recurse -File -Path $content -Filter *.script.tl) {
		$rel = $f.FullName.Substring($content.Length + 1) -replace '\.script\.tl$', ''
		$dst = Join-Path ".tlpath\${modId}__" "$rel\script\tl.tl"
		New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
		Copy-Item $f.FullName $dst
	}
	# luarocks installs tl as a bare Lua script (no .bat), which PowerShell can't start itself.
	$tl = (Get-Command tl -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
	$ErrorActionPreference = "Continue" # tl and lua write to stderr; that's output, not a failure
	[Console]::OutputEncoding = [Text.Encoding]::UTF8 # Lua prints UTF-8 (°, ‰), not the OEM code page
	$status = 0
	foreach ($f in Get-ChildItem -Recurse -File -Path $content -Filter *.tl) {
		$rel = Resolve-Path -Relative $f.FullName
		# "$_" turns stderr's error records back into plain lines
		$out = & lua $tl check $rel 2>&1 | ForEach-Object { "$_" } | Out-String
		if ($LASTEXITCODE -ne 0) { $out.TrimEnd(); $status = 1 }
	}
	foreach ($t in Get-ChildItem test\*_test.lua) {
		"== test/$($t.Name)"
		& lua "test/$($t.Name)" 2>&1 | ForEach-Object { "$_" }
		if ($LASTEXITCODE -ne 0) { $status = 1 }
	}
} finally { Pop-Location }
exit $status
