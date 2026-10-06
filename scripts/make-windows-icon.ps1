<#
.SYNOPSIS
    Builds Resources/Windows/Termsie.ico, and the MSIX logo images, from docs/icon.png.

.DESCRIPTION
    The .ico holds PNG-compressed images at every size Explorer, the taskbar and the title bar
    ask for. Run it again after changing the icon; the outputs are committed so a build needs
    nothing but the Swift toolchain.

        ./scripts/make-windows-icon.ps1
#>
param(
    [string]$Source = "docs/icon.png"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
Add-Type -AssemblyName System.Drawing

$image = [System.Drawing.Image]::FromFile((Resolve-Path $Source))

function Get-ScaledPng([int]$size) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($image, 0, 0, $size, $size)
    $g.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    return , $stream.ToArray()
}

# ---- Termsie.ico
$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$images = foreach ($s in $sizes) { , (Get-ScaledPng $s) }
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0)            # reserved
$w.Write([UInt16]1)            # type: icon
$w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([Byte]$dim)       # width (0 means 256)
    $w.Write([Byte]$dim)       # height
    $w.Write([Byte]0)          # palette
    $w.Write([Byte]0)          # reserved
    $w.Write([UInt16]1)        # planes
    $w.Write([UInt16]32)       # bits per pixel
    $w.Write([UInt32]$images[$i].Length)
    $w.Write([UInt32]$offset)
    $offset += $images[$i].Length
}
foreach ($bytes in $images) { $w.Write($bytes) }
$w.Flush()
New-Item -ItemType Directory -Force Resources/Windows | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $root "Resources/Windows/Termsie.ico"), $out.ToArray())

# ---- MSIX logos
New-Item -ItemType Directory -Force Resources/Windows/Assets | Out-Null
$logos = @{ "StoreLogo.png" = 50; "Square44x44Logo.png" = 44; "Square150x150Logo.png" = 150;
            "Square44x44Logo.targetsize-256_altform-unplated.png" = 256 }
foreach ($name in $logos.Keys) {
    [System.IO.File]::WriteAllBytes((Join-Path $root "Resources/Windows/Assets/$name"), (Get-ScaledPng $logos[$name]))
}
# The wide tile is the square icon centred on a transparent 310x150 canvas.
$wide = New-Object System.Drawing.Bitmap 310, 150
$g = [System.Drawing.Graphics]::FromImage($wide)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.Clear([System.Drawing.Color]::Transparent)
$g.DrawImage($image, 95, 15, 120, 120)
$g.Dispose()
$wide.Save((Join-Path $root "Resources/Windows/Assets/Wide310x150Logo.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$wide.Dispose()
$image.Dispose()
Write-Host "Wrote Resources/Windows/Termsie.ico and Resources/Windows/Assets/*.png"
