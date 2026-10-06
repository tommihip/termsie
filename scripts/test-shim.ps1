<#
.SYNOPSIS
    Proves the PowerShell shim leaves the user's environment alone and does its jobs, in both
    PowerShell 7 and Windows PowerShell, before the app is ever launched.

.DESCRIPTION
    The PowerShell counterpart of test-shim.sh. Termsie.exe --emit-shim writes the generated
    script; each available PowerShell then loads it the way a terminal does and the results are
    compared against the same shell without it:

      - it loads under the execution policy as it is (Windows PowerShell defaults to Restricted);
      - the exported environment is identical apart from Termsie's own variables;
      - startup commands run in order, in the global scope, and leave no queue behind;
      - the prompt still shows the user's prompt, and reports the folder (OSC 7) and marks (OSC 133).

        ./scripts/test-shim.ps1 -Exe dist/windows/x64/Termsie/Termsie.exe
#>
param([string]$Exe = "dist/windows/x64/Termsie/Termsie.exe")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$failures = 0
function Check($label, [bool]$ok, $detail = $null) {
    if ($ok) { Write-Host "  ok   $label" -ForegroundColor Green }
    else { Write-Host "  FAIL $label" -ForegroundColor Red; if ($detail) { Write-Host "       $detail" }; $script:failures++ }
}

$dir = Join-Path ([IO.Path]::GetTempPath()) "termsie-shim-$([guid]::NewGuid())"
$p = Start-Process -FilePath (Resolve-Path $Exe).Path -ArgumentList "--emit-shim `"$dir`"" -PassThru -Wait
$script = Join-Path $dir "termsie.ps1"
if (-not (Test-Path $script)) { Write-Host "could not emit the shim"; exit 1 }

$load = ". ([scriptblock]::Create([IO.File]::ReadAllText('$($script.Replace("'", "''"))')))"
$envProbe = 'Get-ChildItem env: | Where-Object { $_.Name -notlike "TERMSIE_*" } | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }'

$shells = @()
foreach ($candidate in @("pwsh.exe", "powershell.exe")) {
    $found = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($found) { $shells += $found.Source }
}
if (-not $shells) { Write-Host "no PowerShell found"; exit 1 }

foreach ($shell in $shells) {
    Write-Host "`n== $(Split-Path -Leaf $shell)"
    $native = & $shell -NoLogo -NoProfile -Command $envProbe
    $shimmed = & $shell -NoLogo -NoProfile -Command "$load; $envProbe"
    Check "loads under the current execution policy" ($LASTEXITCODE -eq 0)
    $diff = Compare-Object $native $shimmed | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
    Check "the environment is unchanged" (-not $diff) ($diff -join "; ")

    $env:TERMSIE_STARTUP_COUNT = "2"
    $env:TERMSIE_STARTUP_1 = "Write-Output ('first'+'-ran')"
    $env:TERMSIE_STARTUP_2 = '$global:termsieProbe = 7'
    $env:TERMSIE_STARTUP_ECHO = "0"
    $env:TERMSIE_MARKS = "1"
    $out = & $shell -NoLogo -NoProfile -Command "$load; ""probe=`$global:termsieProbe""; ""queue=`$([bool]`$env:TERMSIE_STARTUP_1)""; (prompt).Replace([string][char]27, '<ESC>').Replace([string][char]7, '<BEL>')"
    Remove-Item env:TERMSIE_STARTUP_*, env:TERMSIE_MARKS -ErrorAction SilentlyContinue
    $text = $out -join "`n"
    Check "startup commands run" ($text -match "(?m)^first-ran$") $text
    Check "in the global scope" ($text -match "probe=7") $text
    Check "and leave no queue behind" ($text -match "queue=False") $text
    Check "the prompt reports the folder" ($text -match "<ESC>\]7;file://[^<]+<BEL>") $text
    Check "the prompt is marked" ($text -match "<ESC>\]133;A<BEL>.*PS .*> <ESC>\]133;B<BEL>") $text
}

Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "`n$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall checks passed" -ForegroundColor Green
