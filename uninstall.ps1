# uninstall.ps1 - removes everything install.ps1 created. Per-user, no admin
# (one UAC prompt only with -RemoveTrust).
# Keeps user data (logs/journals/settings) unless -Purge is given.
[CmdletBinding()]
param(
    [switch]$Purge,        # also delete logs, journals, settings, and any leftover staging
    [switch]$RemoveTrust,  # also remove the RobocopyTo package certificate from TrustedPeople (admin prompt)
    [switch]$Pause,        # keep the console open at the end (Apps & features / Settings button)
    [switch]$Quiet
)
$ErrorActionPreference = 'SilentlyContinue'
$clsid = '{6F1A3B58-2D94-4E1C-9C7A-8B5E0D4F2A17}'
function Say($m) { if (-not $Quiet) { Write-Host $m } }

$appRoot = Join-Path $env:LOCALAPPDATA 'RobocopyTo'
$appDir  = Join-Path $appRoot 'app'

# sparse package first (Win11 top-level menu), if it was registered
Get-AppxPackage -Name 'RobocopyTo' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue

if ($RemoveTrust) {
    Say "Removing the RobocopyTo certificate trust (admin prompt)..."
    $cmd = 'Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object { $_.Subject -eq ''CN=RobocopyTo Open Source'' } | Remove-Item'
    try { Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $cmd } catch { }
}

# shell registration removal: both strategies (whichever was used)
$reg = Join-Path $PSScriptRoot 'packaging\register-shell.ps1'
if (-not (Test-Path $reg)) { $reg = Join-Path $appDir 'packaging\register-shell.ps1' }
if (Test-Path $reg) {
    . $reg
    Unregister-RtComMenu -Clsid $clsid
    Unregister-RtRegistryMenu
} else {
    # fallback hardcoded cleanup if the helper is gone
    foreach ($k in '*','Directory','Directory\Background','Drive') {
        Remove-Item -Path "HKCU:\Software\Classes\$k\shell\RobocopyTo" -Recurse -Force
    }
    Remove-Item -Path "HKCU:\Software\Classes\CLSID\$clsid" -Recurse -Force
    Get-ChildItem 'HKCU:\Software\Classes' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'RobocopyTo.*' } |
        ForEach-Object { Remove-Item $_.PSPath -Recurse -Force }
}
Say "Removed shell menu entries."

# metadata + uninstall entry
Remove-Item -Path 'HKCU:\Software\RobocopyTo' -Recurse -Force
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RobocopyTo' -Recurse -Force

# staging never outlives operations; clear any residue on visible volume roots
foreach ($drv in Get-PSDrive -PSProvider FileSystem) {
    $sr = Join-Path $drv.Root '$RobocopyTo.staging'
    if (Test-Path -LiteralPath $sr) { Remove-Item -LiteralPath $sr -Recurse -Force }
}

# the launcher exe may be loaded; remove the payload but tolerate locks
if (Test-Path $appDir) {
    Remove-Item $appDir -Recurse -Force
    if (Test-Path $appDir) {
        # exe in use: schedule the folder for the next reboot would need admin; instead
        # rename it aside so a reinstall is clean and Explorer drops the handle on restart
        $stale = Join-Path $appRoot ('app.old-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        Rename-Item $appDir $stale -ErrorAction SilentlyContinue
    }
}
Say "Removed program files."

if ($Purge) {
    foreach ($d in 'logs','journal','staging') {
        Remove-Item -Path (Join-Path $appRoot $d) -Recurse -Force
    }
    Remove-Item -Path (Join-Path $appRoot 'settings.json') -Force
    # any same-volume staging roots recorded in journals are best-effort gone with journals
    Say "Purged logs, journals, and settings."
    # if the whole app root is now empty, drop it
    if ((Test-Path $appRoot) -and -not (Get-ChildItem $appRoot -Force)) { Remove-Item $appRoot -Force }
}

try { & "$env:WINDIR\System32\ie4uinit.exe" -show 2>$null } catch { }
Say ""
Say "RobocopyTo uninstalled."
if (-not $Purge) { Say "Your logs, history, and settings are kept in $appRoot (run with -Purge to remove them)." }
if ($Pause -and -not $Quiet) { Read-Host 'Press Enter to close' | Out-Null }
