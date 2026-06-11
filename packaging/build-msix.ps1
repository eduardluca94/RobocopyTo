# build-msix.ps1 - builds the sparse MSIX that puts RobocopyTo in the Windows 11
# top-level context menu. The package holds only the manifest + generated logos;
# the real files stay in %LOCALAPPDATA%\RobocopyTo\app (external content).
#
#   .\build-msix.ps1                      -> unsigned package (register with -Unsigned
#                                            + Developer Mode, or sign later)
#   .\build-msix.ps1 -SelfSign            -> signs with a personal self-signed cert
#                                            (created on first use, kept in CurrentUser\My)
#   .\build-msix.ps1 -PfxPath p.pfx ...   -> signs with a real certificate
#
# Requires makeappx.exe (Windows SDK - ships with VS Build Tools C++ workload).
[CmdletBinding()]
param(
    [string]$Version = '1.0.0.0',
    [string]$Publisher = 'CN=RobocopyTo Open Source',
    [string]$OutDir,        # default: <script dir>\out ($PSScriptRoot is empty in PS 5.1 param defaults)
    [string]$PfxPath,
    [string]$PfxPassword,
    [switch]$SelfSign
)
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }

function Find-RtKitTool([string]$Name) {
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $hit = Get-ChildItem -Path $kits -Directory -Filter '10.*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "x64\$Name" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if (-not $hit) { throw "$Name not found - install the Windows SDK (VS Build Tools C++ workload includes it)." }
    return $hit
}

# Simple generated logo: rounded green square (the dialog's robocopy green) with a
# white double chevron. Drawn at build time so the repo stays text-only.
function New-RtLogoPng([string]$Path, [int]$Size) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $green = [System.Drawing.Color]::FromArgb(255, 6, 176, 37)
    $brush = New-Object System.Drawing.SolidBrush $green
    $m = [int][Math]::Max(1, $Size * 0.05)
    $r = [int][Math]::Max(2, $Size * 0.18)
    $w = $Size - 2 * $m
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc($m, $m, 2 * $r, 2 * $r, 180, 90)
    $gp.AddArc($m + $w - 2 * $r, $m, 2 * $r, 2 * $r, 270, 90)
    $gp.AddArc($m + $w - 2 * $r, $m + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $gp.AddArc($m, $m + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $gp.CloseFigure()
    $g.FillPath($brush, $gp)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single][Math]::Max(2.0, $Size * 0.09))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $cy = [single]($Size * 0.5); $h = [single]($Size * 0.17)
    foreach ($cx in @([single]($Size * 0.45), [single]($Size * 0.68))) {
        $pts = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($cx - $h, $cy - $h),
            [System.Drawing.PointF]::new($cx, $cy),
            [System.Drawing.PointF]::new($cx - $h, $cy + $h)
        )
        $g.DrawLines($pen, $pts)
    }
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$makeappx = Find-RtKitTool 'makeappx.exe'

# stage: stamped manifest + assets
$stage = Join-Path $env:TEMP ('rt-msix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $stage, (Join-Path $stage 'Assets'), $OutDir
try {
    [xml]$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'msix\AppxManifest.xml') -Raw
    $manifest.Package.Identity.Publisher = $Publisher
    $manifest.Package.Identity.Version = $Version
    $manifest.Save((Join-Path $stage 'AppxManifest.xml'))
    New-RtLogoPng (Join-Path $stage 'Assets\Logo50.png') 50
    New-RtLogoPng (Join-Path $stage 'Assets\Logo44.png') 44
    New-RtLogoPng (Join-Path $stage 'Assets\Logo150.png') 150

    $pkg = Join-Path $OutDir 'RobocopyTo-sparse.msix'
    # /nv: the manifest references external content, so package validation must be off
    & $makeappx pack /d $stage /p $pkg /o /nv | ForEach-Object { Write-Verbose $_ }
    if (-not (Test-Path -LiteralPath $pkg)) { throw 'makeappx produced no package.' }

    $signed = $false
    if ($SelfSign) {
        $signtool = Find-RtKitTool 'signtool.exe'
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $_.Subject -eq $Publisher } | Select-Object -First 1
        if (-not $cert) {
            $cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher `
                -KeyUsage DigitalSignature -FriendlyName 'RobocopyTo self-sign' `
                -CertStoreLocation 'Cert:\CurrentUser\My' `
                -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
            Write-Output ("created self-signed certificate " + $cert.Thumbprint)
        }
        & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $pkg | ForEach-Object { Write-Verbose $_ }
        if ($LASTEXITCODE -ne 0) { throw "signtool failed (exit $LASTEXITCODE)" }
        $signed = $true
        Write-Output ("signed with self-signed cert; trust it once (elevated):")
        Write-Output ("  Export-Certificate -Cert Cert:\CurrentUser\My\" + $cert.Thumbprint + " -FilePath rt.cer")
        Write-Output ("  Import-Certificate -FilePath rt.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople")
    } elseif ($PfxPath) {
        $signtool = Find-RtKitTool 'signtool.exe'
        $args = @('sign', '/fd', 'SHA256', '/f', $PfxPath)
        if ($PfxPassword) { $args += @('/p', $PfxPassword) }
        $args += $pkg
        & $signtool $args | ForEach-Object { Write-Verbose $_ }
        if ($LASTEXITCODE -ne 0) { throw "signtool failed (exit $LASTEXITCODE)" }
        $signed = $true
    }

    Write-Output ("OK: " + $pkg + $(if ($signed) { ' (signed)' } else { ' (unsigned)' }))
    if (-not $signed) {
        Write-Output 'register with: packaging\register-msix.ps1 -Unsigned   (needs Developer Mode)'
    } else {
        Write-Output 'register with: packaging\register-msix.ps1'
    }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
