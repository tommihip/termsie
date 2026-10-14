<#
.SYNOPSIS
    Builds, signs, packages and (optionally) publishes a Termsie release for Windows.

.DESCRIPTION
    The Windows counterpart of scripts/release.sh. For each architecture it:

      1. builds and stages the app (scripts/build-windows.ps1), with the current ConPTY;
      2. signs every executable and DLL with Authenticode;
      3. packs Termsie-<version>-windows-<arch>.zip, which the in-app updater and winget use,
         and Termsie-<version>-windows-<arch>.msix, signed, for installing as a package;
      4. writes SHA256SUMS-windows.txt;
      5. with -Publish, uploads the files to the GitHub release v<version>, creating it if the
         macOS script has not, and writes winget manifests to dist/windows/winget/.

    Signing (one of):
      -CertificateThumbprint <sha1>   a code-signing certificate in the user's certificate store
      -TrustedSigning <metadata.json> Azure Trusted Signing, with the Microsoft dlib installed
                                      (Microsoft.Trusted.Signing.Client); see the metadata format
                                      at https://learn.microsoft.com/azure/trusted-signing/
      -SkipSign                       unsigned, for a dry run. The in-app updater refuses to
                                      replace a signed copy with an unsigned one, and an unsigned
                                      copy never updates itself.

    Examples:
      ./scripts/release-windows.ps1 -SkipSign                                  # dry run, x64
      ./scripts/release-windows.ps1 -Version 0.9.0 -Arch x64,arm64 -CertificateThumbprint ABC… -Publish

    ARM64 packages must be built on an ARM64 machine, where the toolchain's own runtime is ARM64.
    The release workflow builds each architecture on its own runner and then publishes once with
    -PublishOnly, which uploads the packages already in dist/windows.
#>
param(
    [string]$Version,
    [string[]]$Arch = @("x64"),
    [string]$CertificateThumbprint,
    [string]$TrustedSigning,
    [string]$TrustedSigningDlib,
    [string]$Publisher,
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [string]$Repo = "tommihip/termsie",
    [switch]$SkipBuild,
    [switch]$SkipSign,
    [switch]$SkipMsix,
    [switch]$Publish,
    [switch]$PublishOnly,
    [switch]$Force
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
function Say($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }

$platformFile = "Sources/TermsieCore/Support/Platform.swift"
$current = (Select-String -Path $platformFile -Pattern 'static let version = "([0-9.]+)"').Matches[0].Groups[1].Value
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "-Version must look like 1.2.3" }
    if ($Version -ne $current) {
        Say "Setting version to $Version"
        (Get-Content -Raw $platformFile) -replace 'static let version = "[0-9.]+"', "static let version = `"$Version`"" |
            Set-Content -NoNewline -Encoding utf8 $platformFile
        if (Test-Path "Resources/Info.plist") {
            $plist = Get-Content -Raw "Resources/Info.plist"
            $plist = [regex]::Replace($plist, '(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)', "`${1}$Version`${2}")
            Set-Content -NoNewline -Encoding utf8 "Resources/Info.plist" $plist
        }
    }
} else {
    $Version = $current
}
$tag = "v$Version"
$dist = Join-Path $root "dist\windows"
New-Item -ItemType Directory -Force $dist | Out-Null

if ($PublishOnly) { $Publish = $true; $SkipBuild = $true; $SkipSign = $true }
if (-not $SkipSign -and -not $CertificateThumbprint -and -not $TrustedSigning) {
    throw "Give -CertificateThumbprint or -TrustedSigning to sign, or -SkipSign for an unsigned dry run."
}

if ($Publish) {
    $existing = & gh release view $tag --repo $Repo --json assets --jq '.assets[].name' 2>$null
    if ($LASTEXITCODE -eq 0 -and ($existing -match "windows") -and -not $Force) {
        throw "$tag on $Repo already has Windows files. Release a new version, or add -Force to replace them."
    }
}

function Find-SdkTool([string]$name) {
    $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (-not (Test-Path $kits)) { return $null }
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    Get-ChildItem $kits -Directory | Where-Object { $_.Name -match '^10\.' } | Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "$hostArch\$name" } | Where-Object { Test-Path $_ } | Select-Object -First 1
}

$signtool = Find-SdkTool "signtool.exe"
function Sign-Files([string[]]$files) {
    if ($SkipSign -or -not $files) { return }
    if (-not $signtool) { throw "signtool.exe not found: install the Windows 11 SDK" }
    $common = @("sign", "/fd", "SHA256", "/tr", $TimestampUrl, "/td", "SHA256")
    if ($TrustedSigning) {
        $dlib = if ($TrustedSigningDlib) { $TrustedSigningDlib } else {
            Get-ChildItem "$env:LOCALAPPDATA\Microsoft\MicrosoftTrustedSigningClientTools", "${env:ProgramFiles}\Microsoft\TrustedSigning*" -Recurse -Filter Azure.CodeSigning.Dlib.dll -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $dlib) { throw "Azure.CodeSigning.Dlib.dll not found: pass -TrustedSigningDlib" }
        $common += @("/dlib", $dlib, "/dmdf", (Resolve-Path $TrustedSigning).Path)
    } else {
        $common += @("/sha1", $CertificateThumbprint)
    }
    # signtool takes many files at once; batches keep the command line short.
    for ($i = 0; $i -lt $files.Count; $i += 40) {
        $batch = $files[$i..([Math]::Min($i + 39, $files.Count - 1))]
        & $signtool @common @batch
        if ($LASTEXITCODE -ne 0) { throw "signtool failed" }
    }
}

function Get-Publisher {
    if ($Publisher) { return $Publisher }
    if ($CertificateThumbprint) {
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $CertificateThumbprint } | Select-Object -First 1
        if ($cert) { return $cert.Subject }
    }
    if ($TrustedSigning) { throw "Pass -Publisher with the subject of the Trusted Signing certificate (e.g. ""CN=…"")" }
    return "CN=Termsie Development"
}

$made = @()
if ($PublishOnly) {
    $made = @(Get-ChildItem $dist -File | Where-Object { $_.Name -like "Termsie-$Version-windows-*" } | Select-Object -ExpandProperty FullName)
    if (-not $made) { throw "no packages for $Version in $dist" }
    $Arch = @()
}
foreach ($a in $Arch) {
    if (-not $SkipBuild) {
        & (Join-Path $PSScriptRoot "build-windows.ps1") -Configuration release -Arch $a -Conpty
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "build failed for $a" }
    }
    $stage = Join-Path $dist "$a\Termsie"
    if (-not (Test-Path (Join-Path $stage "Termsie.exe"))) { throw "nothing staged in $stage" }
    if (-not (Test-Path (Join-Path $stage "swiftCore.dll"))) {
        throw "$stage has no Swift runtime; build $a on a machine with the $a Swift runtime installed"
    }

    Say "Signing $a"
    $binaries = Get-ChildItem $stage -Recurse -Include *.exe, *.dll | Select-Object -ExpandProperty FullName
    Sign-Files $binaries

    Say "Packing $a"
    $zip = Join-Path $dist "Termsie-$Version-windows-$a.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path $stage -DestinationPath $zip
    $made += $zip

    if (-not $SkipMsix) {
        $makeappx = Find-SdkTool "makeappx.exe"
        if (-not $makeappx) {
            Write-Warning "makeappx.exe not found: skipping the MSIX package"
        } else {
            $layout = Join-Path $dist "msix-$a"
            if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
            New-Item -ItemType Directory -Force $layout | Out-Null
            Copy-Item $stage (Join-Path $layout "Termsie") -Recurse
            Copy-Item "Resources/Windows/Assets" (Join-Path $layout "Assets") -Recurse
            $four = "$Version.0"
            $msixArch = if ($a -eq "arm64") { "arm64" } else { "x64" }
            (Get-Content -Raw "Resources/Windows/AppxManifest.xml").
                Replace("{VERSION}", $four).Replace("{ARCH}", $msixArch).Replace("{PUBLISHER}", [Security.SecurityElement]::Escape((Get-Publisher))) |
                Set-Content -Encoding utf8 (Join-Path $layout "AppxManifest.xml")
            $msix = Join-Path $dist "Termsie-$Version-windows-$a.msix"
            if (Test-Path $msix) { Remove-Item $msix }
            & $makeappx pack /o /d $layout /p $msix /nv
            if ($LASTEXITCODE -ne 0) { throw "makeappx failed" }
            Sign-Files @($msix)
            $made += $msix
        }
    }
}

Say "Checksums"
$sums = Join-Path $dist "SHA256SUMS-windows.txt"
$made | ForEach-Object { "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 $_).Hash.ToLower(), (Split-Path -Leaf $_) } |
    Set-Content -Encoding ascii $sums
Get-Content $sums

if ($Publish) {
    Say "Publishing to $Repo $tag"
    & gh release view $tag --repo $Repo *> $null
    if ($LASTEXITCODE -ne 0) {
        git tag $tag
        git push origin $tag
        & gh release create $tag --repo $Repo --title "Termsie $Version" --notes-file docs/release-notes.md
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
    }
    & gh release upload $tag --repo $Repo --clobber @($made + $sums)
    if ($LASTEXITCODE -ne 0) { throw "gh release upload failed" }

    Say "winget manifests"
    $wingetDir = Join-Path $dist "winget\$Version"
    New-Item -ItemType Directory -Force $wingetDir | Out-Null
    $installers = foreach ($zip in ($made | Where-Object { $_ -like "*.zip" })) {
        $a = if ($zip -match "arm64") { "arm64" } else { "x64" }
        $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash
@"
  - Architecture: $a
    InstallerUrl: https://github.com/$Repo/releases/download/$tag/$(Split-Path -Leaf $zip)
    InstallerSha256: $hash
"@
    }
    @"
PackageIdentifier: Termsie.Termsie
PackageVersion: $Version
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
  - RelativeFilePath: Termsie\Termsie.exe
    PortableCommandAlias: termsie
MinimumOSVersion: 10.0.18362.0
Installers:
$($installers -join "`n")
ManifestType: installer
ManifestVersion: 1.6.0
"@ | Set-Content -Encoding utf8 (Join-Path $wingetDir "Termsie.Termsie.installer.yaml")
    @"
PackageIdentifier: Termsie.Termsie
PackageVersion: $Version
PackageLocale: en-US
Publisher: Termsie
PublisherUrl: https://termsie.com
PackageName: Termsie
PackageUrl: https://termsie.com
License: Apache-2.0
LicenseUrl: https://github.com/$Repo/blob/main/LICENSE
ShortDescription: One window for everything you're running.
Description: Floating, colour-coded terminals in one window, with a live list of what each one is doing.
Tags:
  - terminal
  - console
  - powershell
ReleaseNotesUrl: https://github.com/$Repo/releases/tag/$tag
ManifestType: defaultLocale
ManifestVersion: 1.6.0
"@ | Set-Content -Encoding utf8 (Join-Path $wingetDir "Termsie.Termsie.locale.en-US.yaml")
    @"
PackageIdentifier: Termsie.Termsie
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
"@ | Set-Content -Encoding utf8 (Join-Path $wingetDir "Termsie.Termsie.yaml")
    Write-Host "Wrote $wingetDir. Submit them with:  wingetcreate submit $wingetDir"
    Say "Done. https://github.com/$Repo/releases/tag/$tag"
}
