<#
.SYNOPSIS
    Resize an image and save as 32-bit uncompressed TGA, ready to drop
    into Interface\AddOns\AutoLoot\Media\Background.tga.

.DESCRIPTION
    Loads any common image format (PNG, JPG, JPEG, BMP, GIF, TIFF) and
    rescales to the target dimensions, then writes a TGA file that
    WoW 3.3.5a's texture engine will load directly.

    Defaults to 1024x512 -- a power-of-2 landscape texture that matches
    the AutoLoot settings window aspect ratio (720x520).  Power-of-2 is
    the recommendation because some 3.3.5a clients render non-power-of-2
    textures with visible filtering artifacts.

    No external dependencies: pure PowerShell + .NET System.Drawing.
    The TGA writer is built in -- System.Drawing can't save TGA, so we
    write the 18-byte header and BGRA pixel bytes ourselves.

.PARAMETER InputPath
    Source image path.  If omitted, an Open File dialog appears.

.PARAMETER OutputPath
    Destination .tga path.  Defaults to "<input-basename>.tga" in the
    same folder as the input.

.PARAMETER Width
    Target width in pixels.  Default 1024.

.PARAMETER Height
    Target height in pixels.  Default 512.

.PARAMETER ToAddon
    Switch.  When set, also copies the resulting TGA to:
      Interface\AddOns\AutoLoot\Media\Background.tga
    (resolved relative to this script's location, two folders up).
    Use this for one-step "convert and install".

.EXAMPLE
    .\Resize-Background.ps1
    -- File picker opens, default 1024x512, output beside the source.

.EXAMPLE
    .\Resize-Background.ps1 -InputPath "C:\Pics\Castle.png" -ToAddon
    -- Resizes and drops straight into the AutoLoot Media folder.

.EXAMPLE
    .\Resize-Background.ps1 -InputPath bg.jpg -Width 1024 -Height 1024
    -- Square texture variant.

.NOTES
    Author: Veronica-Vasilieva
    Part of the AutoLoot addon's Tools/ folder.
#>

[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$OutputPath,
    [int]$Width  = 1024,
    [int]$Height = 512,
    [switch]$ToAddon
)

# ---------------------------------------------------------------------------
# 1. Locate input
# ---------------------------------------------------------------------------
if (-not $InputPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|All files|*.*"
    $dlg.Title  = "Select the source image"
    if ($dlg.ShowDialog() -ne 'OK') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }
    $InputPath = $dlg.FileName
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    Write-Error "Input file not found: $InputPath"
    return
}

$InputFull = (Resolve-Path -LiteralPath $InputPath).Path

# ---------------------------------------------------------------------------
# 2. Default output path
# ---------------------------------------------------------------------------
if (-not $OutputPath) {
    $dir  = Split-Path $InputFull -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($InputFull)
    $OutputPath = Join-Path $dir "$base.tga"
}

# ---------------------------------------------------------------------------
# 3. Load + resize via .NET System.Drawing (high-quality bicubic)
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Drawing
Write-Host "Loading: $InputFull" -ForegroundColor Cyan
$src = [System.Drawing.Image]::FromFile($InputFull)
Write-Host ("  Source dimensions: {0}x{1}" -f $src.Width, $src.Height)

$dst = New-Object System.Drawing.Bitmap $Width, $Height
$g   = [System.Drawing.Graphics]::FromImage($dst)
$g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$g.DrawImage($src, 0, 0, $Width, $Height)
$g.Dispose()
$src.Dispose()

Write-Host ("  Resized to:        {0}x{1}" -f $Width, $Height)

# ---------------------------------------------------------------------------
# 4. Write 32-bit uncompressed TGA
#
#    Header (18 bytes):
#      [2]  Image type 2 (uncompressed true-color)
#      [12..13] Width  (little-endian)
#      [14..15] Height (little-endian)
#      [16] Bits per pixel = 32
#      [17] Descriptor   = 0x28
#             bits 0-3: alpha bits = 8
#             bit  5  : origin    = top-left
#    Body: Width * Height pixels, BGRA bytes (System.Drawing native order).
# ---------------------------------------------------------------------------
$header = New-Object byte[] 18
$header[2]  = 2
$header[12] =  $Width  -band 0xFF
$header[13] = ($Width  -shr 8) -band 0xFF
$header[14] =  $Height -band 0xFF
$header[15] = ($Height -shr 8) -band 0xFF
$header[16] = 32
$header[17] = 0x28

# LockBits gives us a contiguous byte buffer in BGRA order (matching TGA).
$rect = New-Object System.Drawing.Rectangle 0, 0, $Width, $Height
$data = $dst.LockBits($rect,
            [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

$rowBytes = $Width * 4
$bytes    = New-Object byte[] ($rowBytes * $Height)

# Row-by-row copy so we ignore any padding (stride - rowBytes) the GDI+
# layer might add for alignment.  Format32bppArgb on multiples-of-4
# widths usually has stride == rowBytes anyway, but we handle the general
# case so unusual dimensions still produce a valid TGA.
for ($y = 0; $y -lt $Height; $y++) {
    $srcPtr = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
    [System.Runtime.InteropServices.Marshal]::Copy(
        $srcPtr, $bytes, $y * $rowBytes, $rowBytes)
}
$dst.UnlockBits($data)
$dst.Dispose()

$fs = [System.IO.File]::Create($OutputPath)
$fs.Write($header, 0, 18)
$fs.Write($bytes,  0, $bytes.Length)
$fs.Close()

$bytesLen = (Get-Item $OutputPath).Length
Write-Host ("Wrote:   {0}" -f $OutputPath) -ForegroundColor Green
Write-Host ("  Size: {0} bytes ({1:N1} KB)" -f $bytesLen, ($bytesLen / 1KB))

# ---------------------------------------------------------------------------
# 5. Optional: copy straight into the addon's Media folder
# ---------------------------------------------------------------------------
if ($ToAddon) {
    $scriptDir = Split-Path $PSCommandPath -Parent
    $addonRoot = Split-Path $scriptDir -Parent     # ...\AutoLoot
    $mediaDir  = Join-Path $addonRoot 'Media'
    $target    = Join-Path $mediaDir 'Background.tga'

    if (-not (Test-Path $mediaDir)) {
        New-Item -ItemType Directory -Path $mediaDir | Out-Null
    }
    Copy-Item -LiteralPath $OutputPath -Destination $target -Force
    Write-Host ""
    Write-Host "Installed -> $target" -ForegroundColor Magenta
    Write-Host "/reload in-game to see the new background." -ForegroundColor Magenta
} else {
    Write-Host ""
    Write-Host "Next step: copy the .tga to" -ForegroundColor Cyan
    Write-Host "  Interface\AddOns\AutoLoot\Media\Background.tga" -ForegroundColor Cyan
    Write-Host "Then /reload in-game.  (Or re-run this script with -ToAddon to install it for you.)"
}
