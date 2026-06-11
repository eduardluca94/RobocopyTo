# register-msix.ps1 - registers (or removes) the sparse package that puts the
# Robocopy flyout in the Windows 11 top-level context menu. Per-user, no admin.
#
#   .\register-msix.ps1                -> register a signed package
#   .\register-msix.ps1 -Unsigned      -> register an unsigned package (Developer Mode)
#   .\register-msix.ps1 -Unregister    -> remove the package (menu falls back to
#                                         "Show more options"; the app keeps working)
[CmdletBinding()]
param(
    [string]$Package,       # default: <script dir>\out\RobocopyTo-sparse.msix
    [switch]$Unsigned,
    [switch]$Unregister
)
$ErrorActionPreference = 'Stop'
if (-not $Package) { $Package = Join-Path $PSScriptRoot 'out\RobocopyTo-sparse.msix' }

if ($Unregister) {
    $existing = Get-AppxPackage -Name 'RobocopyTo' -ErrorAction SilentlyContinue
    if ($existing) { $existing | Remove-AppxPackage; Write-Output 'Sparse package removed.' }
    else { Write-Output 'No RobocopyTo package was registered.' }
    return
}

if (-not (Test-Path -LiteralPath $Package)) {
    throw "Package not found: $Package - run packaging\build-msix.ps1 first."
}

# external content root = the real install
$installDir = (Get-ItemProperty 'HKCU:\Software\RobocopyTo' -ErrorAction SilentlyContinue).InstallDir
if (-not $installDir) { $installDir = Join-Path $env:LOCALAPPDATA 'RobocopyTo\app' }
if (-not (Test-Path -LiteralPath (Join-Path $installDir 'RobocopyToMenu.dll'))) {
    throw "Install dir '$installDir' has no RobocopyToMenu.dll - run install.ps1 first."
}

if ($Unsigned) {
    $dm = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
    if (1 -ne $dm) {
        throw 'Unsigned packages need Developer Mode: Settings > System > For developers > Developer Mode.'
    }
}

# re-register cleanly on upgrade
Get-AppxPackage -Name 'RobocopyTo' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue

if ($Unsigned) {
    Add-AppxPackage -Path $Package -ExternalLocation $installDir -AllowUnsigned
} else {
    Add-AppxPackage -Path $Package -ExternalLocation $installDir
}

Write-Output 'Sparse package registered: Robocopy now appears in the top-level context menu.'
Write-Output 'If the new entry does not show yet, restart Explorer (taskkill /f /im explorer.exe; start explorer).'
