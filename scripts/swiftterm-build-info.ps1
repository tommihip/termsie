<#
.SYNOPSIS
    Sets the SWIFTTERM_BUILD_* variables from Package.resolved. Dot-source it before `swift build`
    on Windows:  . ./scripts/swiftterm-build-info.ps1

.DESCRIPTION
    SwiftTerm stamps its build with source-control details through a build-tool plugin whose
    generator runs `git`. The plugin starts the generator with an environment holding only these
    four variables, so on Windows the generator has no SystemRoot, Foundation's Process cannot
    initialise Winsock, and the build stops with an illegal-instruction crash. With all four set
    the generator never runs git. The values come from Package.resolved, so they are accurate.

    With -GitHubEnv the variables are also appended to $GITHUB_ENV for later workflow steps.
#>
param([switch]$GitHubEnv)

$resolvedPath = Join-Path (Split-Path -Parent $PSScriptRoot) "Package.resolved"
$resolved = Get-Content -Raw $resolvedPath | ConvertFrom-Json
$pin = $resolved.pins | Where-Object { $_.identity -eq "swiftterm" } | Select-Object -First 1
$values = @{
    SWIFTTERM_BUILD_BRANCH = "release"
    SWIFTTERM_BUILD_TAG    = if ($pin.state.version) { "v$($pin.state.version)" } else { "unknown" }
    SWIFTTERM_BUILD_COMMIT = if ($pin.state.revision) { $pin.state.revision } else { "unknown" }
    SWIFTTERM_BUILD_DIRTY  = "false"
}
foreach ($name in $values.Keys) {
    Set-Item -Path "env:$name" -Value $values[$name]
    if ($GitHubEnv -and $env:GITHUB_ENV) { "$name=$($values[$name])" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV }
}
