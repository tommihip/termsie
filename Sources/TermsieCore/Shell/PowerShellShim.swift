import Foundation

/// The PowerShell counterpart of the zsh shim: one generated script that gives a terminal its own
/// history, runs its startup commands before the first prompt, reports the working folder, and
/// marks prompts and commands with OSC 133 for the copy tools.
///
/// PowerShell is started with `-NoExit -Command`, so the user's profile has already run when this
/// does, exactly as the user's own zsh files have run when the zsh shim's own part does. It is
/// loaded through a script block rather than dot-sourced as a file because Windows PowerShell's
/// default execution policy refuses every script file, and a terminal must never fail to start
/// over a policy the user did not choose.
///
/// Written for Windows PowerShell 5.1 as well as PowerShell 7: no `??`, no ternary, no `&&`.
extension ShimScripts {
    public static let powerShellFileName = "termsie.ps1"

    public static let powerShell = #"""
    # Termsie shell integration - generated, do not edit. Regenerated when Termsie updates.
    # PowerShell runs this right after your profile, so everything your profile set up still applies.
    if ($global:__TermsieShimLoaded) { return }
    $global:__TermsieShimLoaded = $true
    $global:__TermsieRan = $false

    # ------------------------------------------------------------------ history
    # PSReadLine reads its history file the first time it draws a prompt, which has not happened
    # yet, so pointing it at this terminal's own file now isolates it from the very first command.
    if ($env:TERMSIE_HISTFILE -and (Get-Module -Name PSReadLine)) {
        try {
            $global:__TermsieGlobalHistory = (Get-PSReadLineOption).HistorySavePath
            if (Test-Path -LiteralPath $env:TERMSIE_HISTFILE) {
                $global:__TermsieHistoryStart = @(Get-Content -LiteralPath $env:TERMSIE_HISTFILE).Count
            } else {
                $global:__TermsieHistoryStart = 0
            }
            Set-PSReadLineOption -HistorySavePath $env:TERMSIE_HISTFILE
        } catch { }
    }

    # Commands this terminal ran go into your normal history too when it exits, so isolation does
    # not mean losing them. Only this session's lines are appended.
    if ($env:TERMSIE_HISTORY_MERGE -eq '1' -and $global:__TermsieGlobalHistory -and $env:TERMSIE_HISTFILE -and
        ($global:__TermsieGlobalHistory -ne $env:TERMSIE_HISTFILE)) {
        $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            try {
                if (Test-Path -LiteralPath $env:TERMSIE_HISTFILE) {
                    $lines = @(Get-Content -LiteralPath $env:TERMSIE_HISTFILE)
                    if ($lines.Count -gt $global:__TermsieHistoryStart) {
                        $new = $lines[$global:__TermsieHistoryStart..($lines.Count - 1)]
                        Add-Content -LiteralPath $global:__TermsieGlobalHistory -Value $new
                    }
                }
            } catch { }
        }
    }

    # -------------------------------------------------------- prompt and marks
    # The working folder is reported on every prompt (OSC 7), because PowerShell's `cd` never
    # changes the process's own directory and there is no other way to see it from outside.
    # OSC 133 marks where each prompt, the command typed at it, and its output begin.
    $global:__TermsieUserPrompt = $function:prompt
    function global:prompt {
        $ok = $?
        $native = $global:LASTEXITCODE
        $esc = [char]27
        $bel = [char]7
        $out = ''
        if ($env:TERMSIE_MARKS -eq '1' -and $global:__TermsieRan) {
            $code = 0
            if (-not $ok) { $code = 1; if ($native) { $code = $native } }
            $out += "$esc]133;D;$code$bel"
            $global:__TermsieRan = $false
        }
        $loc = $executionContext.SessionState.Path.CurrentLocation
        if ($loc.Provider.Name -eq 'FileSystem') {
            $parts = $loc.ProviderPath.Split([char[]]@([char]92, [char]47)) | ForEach-Object { [Uri]::EscapeDataString($_) }
            $out += "$esc]7;file://$env:COMPUTERNAME/$($parts -join '/')$bel"
        }
        if ($env:TERMSIE_MARKS -eq '1') { $out += "$esc]133;A$bel" }
        $text = ''
        if ($global:__TermsieUserPrompt) { $text = (& $global:__TermsieUserPrompt) -join '' }
        if (-not $text) { $text = "PS $($loc.Path)> " }
        $global:LASTEXITCODE = $native
        if ($env:TERMSIE_MARKS -eq '1') { return $out + $text + "$esc]133;B$bel" }
        return $out + $text
    }

    # C goes out when a command line is accepted, so everything after it is that command's output.
    # Only when Enter still does what PSReadLine does by default: a binding the user made stays.
    if ($env:TERMSIE_MARKS -eq '1' -and (Get-Module -Name PSReadLine)) {
        try {
            $enter = Get-PSReadLineKeyHandler -Chord Enter -ErrorAction Stop | Select-Object -First 1
            if (-not $enter -or $enter.Function -eq 'AcceptLine') {
                Set-PSReadLineKeyHandler -Chord Enter -ScriptBlock {
                    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
                    $global:__TermsieRan = $true
                    [Console]::Write("$([char]27)]133;C$([char]7)")
                }
            }
        } catch { }
    }

    # --------------------------------------------------------- startup commands
    # Taken out of the environment first, so the commands themselves never see the queue.
    $__termsieCount = 0
    [void][int]::TryParse("$env:TERMSIE_STARTUP_COUNT", [ref]$__termsieCount)
    $__termsieCommands = @()
    for ($__termsieIndex = 1; $__termsieIndex -le $__termsieCount; $__termsieIndex++) {
        $__termsieName = "TERMSIE_STARTUP_$__termsieIndex"
        $__termsieCommands += , [Environment]::GetEnvironmentVariable($__termsieName)
        [Environment]::SetEnvironmentVariable($__termsieName, $null)
    }
    [Environment]::SetEnvironmentVariable('TERMSIE_STARTUP_COUNT', $null)
    # Strictly one after another: each returns before the next starts, so a command never
    # receives input meant for the one after it. Ctrl+C stops the rest, as it does under zsh.
    foreach ($__termsieCommand in $__termsieCommands) {
        if (-not $__termsieCommand) { continue }
        if ($env:TERMSIE_STARTUP_ECHO -ne '0') { Write-Host "> $__termsieCommand" -ForegroundColor DarkGray }
        if ($env:TERMSIE_STARTUP_RECORD -ne '0' -and (Get-Module -Name PSReadLine)) {
            try { [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($__termsieCommand) } catch { }
        }
        try { Invoke-Expression $__termsieCommand } catch { Write-Error $_ }
    }
    Remove-Variable -Name __termsieCount, __termsieCommands, __termsieIndex, __termsieName, __termsieCommand -ErrorAction SilentlyContinue
    """#

    /// The arguments that load the shim. `-NoExit` keeps the shell interactive afterwards; the
    /// script path is quoted for PowerShell's single-quoted string rules.
    public static func powerShellArguments(scriptPath: String, userArgs: [String]) -> [String] {
        let quoted = scriptPath.replacingOccurrences(of: "'", with: "''")
        var args = userArgs
        let lowered = Set(userArgs.map { $0.lowercased() })
        if !lowered.contains("-nologo") { args.append("-NoLogo") }
        if !lowered.contains("-noexit") { args.append("-NoExit") }
        args.append("-Command")
        args.append(". ([scriptblock]::Create([IO.File]::ReadAllText('\(quoted)')))")
        return args
    }
}
