# make-release.ps1 - assembles a distributable bundle in dist\:
#   RobocopyTo.zip            repo-layout payload incl. prebuilt DLLs + sparse package
#   install.ps1               standalone, for the "irm ... | iex" one-liner
#   RobocopyTo-sparse.msix    loose copy for manual registration
#
# Signing the sparse package (so installs can offer the top-level menu with a
# single UAC trust prompt, no Developer Mode):
#   -SelfSign                 sign with the local CN=RobocopyTo Open Source cert
#                             (created on first use) and export RobocopyTo.cer
#   -PfxPath/-PfxPassword     sign with a real certificate (also exports the .cer)
# Unsigned bundles still install; the top-level menu then needs Developer Mode.
#
# Requires VS C++ build tools (DLL) and the Windows SDK (makeappx/signtool).
[CmdletBinding()]
param(
    [string]$Version = '1.0.0.0',
    [string]$OutDir,            # default: <repo>\dist
    [switch]$IncludeArm64,
    [switch]$SelfSign,
    [string]$PfxPath,
    [string]$PfxPassword
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$dist = if ($OutDir) { $OutDir } else { Join-Path $repo 'dist' }
$buildDir = Join-Path $repo 'native\build'

# --- 1. native DLLs (arm64 first so the unsuffixed dll ends up x64 for local use) ---
if ($IncludeArm64) {
    & (Join-Path $repo 'native\build.ps1') -Arch arm64
    Copy-Item (Join-Path $buildDir 'RobocopyToMenu.dll') (Join-Path $buildDir 'RobocopyToMenu-arm64.dll') -Force
}
& (Join-Path $repo 'native\build.ps1')
Copy-Item (Join-Path $buildDir 'RobocopyToMenu.dll') (Join-Path $buildDir 'RobocopyToMenu-x64.dll') -Force

# --- 2. sparse package (+ public cert export when signing) ---
$msixArgs = @{ Version = $Version }
if ($SelfSign) { $msixArgs.SelfSign = $true }
if ($PfxPath) { $msixArgs.PfxPath = $PfxPath; if ($PfxPassword) { $msixArgs.PfxPassword = $PfxPassword } }
& (Join-Path $PSScriptRoot 'build-msix.ps1') @msixArgs

$outDir = Join-Path $PSScriptRoot 'out'
$cerPath = Join-Path $outDir 'RobocopyTo.cer'
Remove-Item $cerPath -Force -ErrorAction SilentlyContinue
if ($SelfSign) {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
        Where-Object { $_.Subject -eq 'CN=RobocopyTo Open Source' } | Select-Object -First 1
    if ($cert) { $null = Export-Certificate -Cert $cert -FilePath $cerPath }
} elseif ($PfxPath) {
    $pfx = if ($PfxPassword) {
        New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 ($PfxPath, $PfxPassword)
    } else {
        New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $PfxPath
    }
    [System.IO.File]::WriteAllBytes($cerPath, $pfx.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
}

# --- 3. stage a clean repo-layout bundle and zip it ---
$stage = Join-Path $env:TEMP ('rt-release-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $stage
try {
    Copy-Item (Join-Path $repo 'src') (Join-Path $stage 'src') -Recurse
    Copy-Item (Join-Path $repo 'tests') (Join-Path $stage 'tests') -Recurse
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $stage 'packaging\msix'), (Join-Path $stage 'packaging\out'), (Join-Path $stage 'native\build')
    foreach ($f in 'register-shell.ps1', 'register-msix.ps1', 'build-msix.ps1', 'make-release.ps1') {
        Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $stage 'packaging') -Force
    }
    Copy-Item (Join-Path $PSScriptRoot 'msix\AppxManifest.xml') (Join-Path $stage 'packaging\msix') -Force
    Copy-Item (Join-Path $outDir 'RobocopyTo-sparse.msix') (Join-Path $stage 'packaging\out') -Force
    if (Test-Path $cerPath) { Copy-Item $cerPath (Join-Path $stage 'packaging\out') -Force }
    foreach ($f in 'RobocopyToMenu.cpp', 'RobocopyToMenu.def', 'build.ps1') {
        Copy-Item (Join-Path $repo "native\$f") (Join-Path $stage 'native') -Force
    }
    Get-ChildItem $buildDir -Filter 'RobocopyToMenu-*.dll' | Copy-Item -Destination (Join-Path $stage 'native\build') -Force
    foreach ($f in 'install.ps1', 'install.cmd', 'uninstall.ps1', 'uninstall.cmd', 'LICENSE') {
        Copy-Item (Join-Path $repo $f) $stage -Force
    }

    Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Force -Path $dist
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath (Join-Path $dist 'RobocopyTo.zip')
    Copy-Item (Join-Path $repo 'install.ps1') $dist -Force
    Copy-Item (Join-Path $outDir 'RobocopyTo-sparse.msix') $dist -Force
    if (Test-Path $cerPath) { Copy-Item $cerPath $dist -Force }
    Get-ChildItem $buildDir -Filter 'RobocopyToMenu-*.dll' | Copy-Item -Destination $dist -Force

    # --- 4. single-file installer: console exe with the bundle embedded ---
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (Test-Path $csc) {
        $setupExe = Join-Path $dist 'RobocopyTo-setup.exe'
        $zipPath = Join-Path $dist 'RobocopyTo.zip'
        & $csc '/nologo', '/target:winexe', '/optimize+', "/out:$setupExe",
            "/resource:$zipPath,RobocopyTo.zip",
            '/reference:System.IO.Compression.dll', '/reference:System.IO.Compression.FileSystem.dll',
            '/reference:System.Windows.Forms.dll',
            (Join-Path $PSScriptRoot 'setup-stub.cs') 2>&1 | ForEach-Object { Write-Verbose $_ }
        if (-not (Test-Path $setupExe)) { Write-Warning 'setup exe build failed (the zip + install.ps1 still work)' }
    }

    Write-Output ("dist ready: " + $dist)
    Get-ChildItem $dist | ForEach-Object { Write-Output ("  " + $_.Name + "  (" + $_.Length + " bytes)") }
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
