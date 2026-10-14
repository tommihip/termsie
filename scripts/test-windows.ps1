<#
.SYNOPSIS
    Drives the Windows app headlessly and checks what it does.

.DESCRIPTION
    Every run uses a throwaway XDG_CONFIG_HOME, so the user's real configuration, workspaces,
    session and Credential Manager are never touched (secrets go to a JSON file through
    TERMSIE_SECRETS_FILE). Screenshots and logs land in -Out, for a person to look at when a
    check fails.

        ./scripts/test-windows.ps1 -Exe dist/windows/x64/Termsie/Termsie.exe
#>
param(
    [string]$Exe = "dist/windows/x64/Termsie/Termsie.exe",
    [string]$Out = "test-output"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$script:failures = 0

function Ok($label) { Write-Host "  ok   $label" -ForegroundColor Green }
function Bad($label, $detail) {
    Write-Host "  FAIL $label" -ForegroundColor Red
    if ($detail) { Write-Host "       $detail" }
    $script:failures++
}
function Check($label, [bool]$condition, $detail = $null) { if ($condition) { Ok $label } else { Bad $label $detail } }

function Quote([string]$arg) {
    if ($arg -notmatch '[\s"]') { return $arg }
    return '"' + ($arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# A fresh config folder with an optional config.json, workspaces and secrets.
function New-Fixture([string]$name, [hashtable]$config = @{}, [hashtable]$workspaces = @{}, [hashtable]$secrets = @{}) {
    $fixture = Join-Path $Out "$name-config"
    if (Test-Path $fixture) { Remove-Item -Recurse -Force $fixture }
    $dir = Join-Path $fixture "termsie"
    New-Item -ItemType Directory -Force (Join-Path $dir "workspaces") | Out-Null
    $config | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 (Join-Path $dir "config.json")
    foreach ($ws in $workspaces.Keys) {
        $workspaces[$ws] | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 (Join-Path $dir "workspaces\$ws.json")
    }
    $secrets | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $fixture "secrets.json")
    return $fixture
}

# Runs the app against a fixture and returns its log.
function Invoke-Termsie([string]$name, [string]$fixture, [string[]]$actions, [string[]]$extra = @(), [int]$timeout = 120) {
    $log = Join-Path $Out "$name.log"
    if (Test-Path $log) { Remove-Item $log }
    $env:XDG_CONFIG_HOME = $fixture
    $env:TERMSIE_SECRETS_FILE = Join-Path $fixture "secrets.json"
    $all = @("--actions", ($actions -join ","), "--snapshot", (Join-Path $Out "$name.png"), "--log", $log, "--quit") + $extra
    $line = ($all | ForEach-Object { Quote $_ }) -join " "
    $p = Start-Process -FilePath $Exe -ArgumentList $line -PassThru
    if (-not $p.WaitForExit($timeout * 1000)) {
        $p.Kill()
        Bad "$name finished within $timeout s"
    }
    $text = if (Test-Path $log) { Get-Content -Raw $log } else { "" }
    Set-Content -Path (Join-Path $Out "$name.txt") -Value $text
    return $text
}

# The shells take a few seconds to draw their first prompt on a fresh CI machine.
$settle = @("sleep:6")

Write-Host "`n== a shell runs in a pseudo console and its output is drawn"
$fx = New-Fixture "basic"
$log = Invoke-Termsie "basic" $fx ($settle + @("type:Write-Output ('termsie'+'-ok')\n", "sleep:3", "dumpScreen", "dumpState", "dumpProcess"))
Check "snapshot written" ($log -match "snapshot=ok") $log
Check "PNG exists" (Test-Path (Join-Path $Out "basic.png"))
Check "the shell's output reached the screen" ($log -match "(?m)^termsie-ok\s*$") $log
Check "the default shell is PowerShell" ($log -match "shell=.*(pwsh|powershell)\.exe") $log
Check "the shell is running" ($log -match "process pid=\d+ running=true") $log

Write-Host "`n== terminals open, close into the list, and reopen"
$fx = New-Fixture "lifecycle"
$log = Invoke-Termsie "lifecycle" $fx ($settle + @("newTerminal", "newTerminal", "sleep:3", "dumpTerminals", "closeTerminal:2",
                                                     "dumpTerminals", "openTerminal:2", "sleep:2", "dumpTerminals", "tileGrid", "dumpTerminals"))
$opens = [regex]::Matches($log, "terminal \d id=\S+ open=true")
Check "three terminals were open" ($log -match "terminal 3 id=\S+ open=true") $log
Check "a closed terminal stays in the list" ($log -match "terminal 2 id=\S+ open=false") $log
Check "reopening brings it back" (([regex]::Matches($log, "terminal 2 id=\S+ open=true")).Count -ge 2) $log

Write-Host "`n== a workspace's startup commands run from the PowerShell shim, before the first prompt"
$ws = @{ version = 2; name = "startup"; layout = @{ terminals = @(
    @{ id = "t-startup-1"; name = "first"; startupCommands = @("Write-Output ('start'+'up-ran')"); frame = @(0, 0, 0.5, 1) },
    @{ id = "t-startup-2"; name = "second"; startupCommands = @("Set-Location `$env:TEMP"); frame = @(0.5, 0, 0.5, 1) }
) } }
$fx = New-Fixture "startup" -workspaces @{ startup = $ws }
$log = Invoke-Termsie "startup" $fx (@("openWorkspace:startup", "sleep:10", "dumpText:1", "dumpTerminals"))
Check "the startup command ran" ($log -match "(?m)^startup-ran\s*$") $log
Check "the shell reported its folder (OSC 7)" ($log -match "name=second .*cwd=\S*(Temp|TEMP|tmp)") $log

Write-Host "`n== environment variables and secrets reach the shell, secrets never the files"
$ws = @{ version = 2; name = "envs"; layout = @{
    settings = @{ env = @(@{ name = "WS_VAR"; value = "from-ws" }) };
    terminals = @(@{ id = "t-env-1"; env = @(@{ name = "PLAIN"; value = "p1" }, @{ name = "TOKEN"; secret = $true; secretRef = "s-test-ref" }) })
} }
$fx = New-Fixture "envs" -workspaces @{ envs = $ws } -secrets @{ "s-test-ref" = "hunter2" }
$log = Invoke-Termsie "envs" $fx (@("openWorkspace:envs", "sleep:8", "type:Write-Output (`$env:WS_VAR + '/' + `$env:PLAIN + '/' + `$env:TOKEN)\n", "sleep:3", "dumpScreen", "saveWorkspaceNamed:envs-saved"))
Check "plain, workspace and secret variables are set" ($log -match "(?m)^from-ws/p1/hunter2\s*$") $log
$saved = Get-Content -Raw (Join-Path $fx "termsie\workspaces\envs-saved.json") -ErrorAction SilentlyContinue
Check "the saved workspace holds the reference, not the value" ($saved -and $saved -notmatch "hunter2" -and $saved -match "s-test-ref") $saved

Write-Host "`n== copy tools: last command, its output, everything"
$fx = New-Fixture "copy"
$log = Invoke-Termsie "copy" $fx ($settle + @("type:Write-Output copy-me\n", "sleep:3", "dumpCopyState", "copy:lastCommandOutput", "dumpClipboard",
                                                "copy:lastCommand", "dumpClipboard", "copy:wholeTerminal", "dumpClipboard"))
Check "the shell marks its prompts (OSC 133)" ($log -match "copyState marks=true") $log
Check "last command output includes the output" ($log -match "clipboard=.*copy-me.*copy-me") $log
Check "last command is just the command" ($log -match "(?m)^clipboard=Write-Output copy-me\s*$") $log

Write-Host "`n== kept output survives quitting, and the session comes back"
$fx = New-Fixture "kept"
$null = Invoke-Termsie "kept-1" $fx ($settle + @("type:Write-Output kept-marker\n", "sleep:3", "rename:keeper")) -extra @("--use-session")
$log = Invoke-Termsie "kept-2" $fx (@("sleep:6", "dumpTerminals", "dumpScreen")) -extra @("--use-session")
Check "the session restored the terminal" ($log -match "name=keeper") $log
Check "its output was kept" ($log -match "kept-marker") $log
Check "with a rule saying when it was from" ($log -match "restored from") $log

Write-Host "`n== each terminal keeps its own PowerShell history"
$fx = New-Fixture "history"
$log = Invoke-Termsie "history" $fx ($settle + @("type:Write-Output history-probe\n", "sleep:3", "dumpTerminals"))
$id = [regex]::Match($log, "terminal 1 id=(\S+)").Groups[1].Value
Start-Sleep -Seconds 2
$hist = Join-Path $fx "termsie\panes\$id\ConsoleHost_history.txt"
Check "the command went to this terminal's history file" ((Test-Path $hist) -and ((Get-Content -Raw $hist) -match "history-probe")) $hist

Write-Host "`n== cmd.exe gets its startup commands typed in"
$ws = @{ version = 2; name = "cmd"; layout = @{ terminals = @(@{ id = "t-cmd-1"; startupCommands = @("echo typed-ok") }) } }
$fx = New-Fixture "cmd" -config @{ shell = "C:\Windows\System32\cmd.exe" } -workspaces @{ cmd = $ws }
$log = Invoke-Termsie "cmd" $fx (@("openWorkspace:cmd", "sleep:10", "dumpText:1"))
Check "cmd ran the command" ($log -match "(?m)^typed-ok\s*$") $log

Write-Host "`n== the workspace JSON view applies and refuses"
$good = Join-Path $Out "workspace-good.json"
@'
{ "workspace": { "fontSize": 15, "env": { "A": "1" } },
  "terminals": [ { "name": "alpha" }, { "name": "beta", "startupCommands": ["Write-Output hi"] } ] }
'@ | Set-Content -Encoding utf8 $good
$bad = Join-Path $Out "workspace-bad.json"
'{ "terminals": [ { "startupCommand": "x" } ] }' | Set-Content -Encoding utf8 $bad
$fx = New-Fixture "json"
$log = Invoke-Termsie "json" $fx ($settle + @("applyWorkspaceJSON:$bad", "applyWorkspaceJSON:$good", "sleep:2", "dumpTerminals", "dumpFonts"))
Check "a misspelt key is refused with its name" ($log -match "refused: .*startupCommand") $log
Check "a valid document is applied" ($log -match "applyJSON applied") $log
Check "the terminals it lists exist" ($log -match "name=alpha" -and $log -match "name=beta") $log
Check "the workspace font size applies" ($log -match "size=15") $log

Write-Host "`n== the list gives way as it narrows"
$fx = New-Fixture "sidebar"
$log = Invoke-Termsie "sidebar" $fx ($settle + @("setSidebarWidth:264", "dumpRow:1", "setSidebarWidth:150", "dumpRow:1", "setSidebarWidth:60", "dumpRow:1"))
Check "full width shows a thumbnail" ($log -match "row title=.* thumbnail=104x65") $log
Check "narrower drops the thumbnail" ($log -match "thumbnail=none text=true") $log
Check "narrowest leaves only the number" ($log -match "thumbnail=none text=false") $log

Write-Host "`n== thumbnails cost nothing while a terminal is idle"
$fx = New-Fixture "thumbs"
$log = Invoke-Termsie "thumbs" $fx ($settle + @("dumpThumb:1", "sleep:4", "dumpThumb:1"))
$counts = [regex]::Matches($log, "thumb renders=(\d+)") | ForEach-Object { [int]$_.Groups[1].Value }
Check "an idle terminal's thumbnail is not rebuilt" ($counts.Count -eq 2 -and ($counts[1] - $counts[0]) -le 1) "$counts"

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall checks passed" -ForegroundColor Green
