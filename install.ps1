# install.ps1 - per-user installer for RobocopyTo. No admin required; one optional
# UAC prompt only if you opt into the Windows 11 top-level menu (certificate trust).
#
# Ways to run it:
#   from a clone or an extracted release zip:   .\install.ps1
#   straight from the web (latest release):
#     irm https://github.com/eduardluca94/RobocopyTo/releases/latest/download/install.ps1 | iex
#
# What it does (all under HKCU + %LOCALAPPDATA%, nothing machine-wide unless you
# opt into the certificate trust):
#   1. copies the payload (src module) to %LOCALAPPDATA%\RobocopyTo\app
#   2. compiles the windowless launcher + interop with the in-box csc.exe
#   3. registers the shell menu - the native IExplorerCommand DLL when one is
#      present (prebuilt in releases) or buildable, else a registry-verb fallback
#   4. writes an "Apps & features" uninstall entry
#   5. OPTIONAL (asks first): registers the sparse package so Robocopy appears in
#      the Windows 11 top-level context menu. With a signed package this trusts
#      the RobocopyTo certificate in LocalMachine\TrustedPeople (single UAC
#      prompt); with an unsigned one it needs Developer Mode.
#
# Re-running is safe (idempotent): it overwrites the payload and re-registers.
[CmdletBinding()]
param(
    [switch]$NoDll,             # skip the native DLL, force the registry-verb fallback
    [switch]$TopLevelMenu,      # register the Win11 top-level menu without asking
    [switch]$SkipTopLevelMenu,  # never touch the top-level menu / certificates
    [switch]$Quiet,
    [string]$Repo = 'eduardluca94/RobocopyTo'   # only used by the web bootstrap
)
$ErrorActionPreference = 'Stop'
function Say($m) { if (-not $Quiet) { Write-Host $m } }

# --- bootstrap: no payload next to this script ("irm | iex", or the loose copy in
# --- a release folder) -> use a sibling RobocopyTo.zip, else download the release
$repo = $PSScriptRoot
if (-not $repo -or -not (Test-Path (Join-Path $repo 'src\RobocopyTo.Launch.ps1'))) {
    $tmp = Join-Path $env:TEMP ('robocopyto-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path $tmp
    $zip = Join-Path $tmp 'RobocopyTo.zip'
    $localZip = if ($repo) { Join-Path $repo 'RobocopyTo.zip' } else { $null }
    if ($localZip -and (Test-Path -LiteralPath $localZip)) {
        Say "Using the bundle next to this script: $localZip"
        Copy-Item -LiteralPath $localZip $zip
    } else {
        $zipUrl = "https://github.com/$Repo/releases/latest/download/RobocopyTo.zip"
        Say "Downloading $zipUrl"
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
        } catch {
            # releases 404 briefly while their assets are being swapped; one
            # patient retry rides out the window
            Say "  download failed ($($_.Exception.Message.Trim())) - retrying in 10s..."
            Start-Sleep -Seconds 10
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
        }
    }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $inner = Join-Path $tmp 'install.ps1'
    if (-not (Test-Path $inner)) { throw 'The release zip did not contain install.ps1.' }
    & $inner @PSBoundParameters
    return
}

$clsid = '{6F1A3B58-2D94-4E1C-9C7A-8B5E0D4F2A17}'
$appRoot = Join-Path $env:LOCALAPPDATA 'RobocopyTo'
$appDir  = Join-Path $appRoot 'app'          # payload (module + launcher + dll)
Say "Installing RobocopyTo to $appDir"

# --- 1. copy payload ---
# sweep aside-renamed payloads from earlier upgrades (their handles are long gone)
Get-ChildItem $appRoot -Directory -Filter 'app.old-*' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $appDir) {
    try { Remove-Item $appDir -Recurse -Force -ErrorAction Stop }
    catch {
        # Explorer may still hold the old menu DLL: shove the dir aside; the handle
        # drops with Explorer and the sweep above removes it on the next install
        Rename-Item $appDir (Join-Path $appRoot ('app.old-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    }
}
$null = New-Item -ItemType Directory -Force -Path $appDir
Copy-Item (Join-Path $repo 'src\*') -Destination $appDir -Recurse -Force
$launchScript = Join-Path $appDir 'RobocopyTo.Launch.ps1'
if (-not (Test-Path $launchScript)) { throw "Payload copy failed: $launchScript missing." }

# --- 2. compile the launcher exe with the in-box C# compiler ---
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'C# compiler (csc.exe) not found - .NET Framework 4.x is required.' }
$launcherExe = Join-Path $appDir 'RobocopyTo.exe'
$cscArgs = @(
    '/nologo', '/target:winexe', '/optimize+', "/out:$launcherExe",
    '/reference:System.Windows.Forms.dll',
    (Join-Path $appDir 'launcher\Launcher.cs')
)
& $csc $cscArgs 2>&1 | ForEach-Object { Write-Verbose $_ }
if (-not (Test-Path $launcherExe)) { throw 'Launcher compilation failed.' }
Say "  compiled RobocopyTo.exe"

# precompile the interop layer too: Add-Type's per-launch csc spawn is the single
# biggest avoidable chunk of menu-click -> dialog latency
$interopDll = Join-Path $appDir 'RobocopyTo.Native.dll'
$cscArgs2 = @(
    '/nologo', '/target:library', '/optimize+', "/out:$interopDll",
    '/reference:System.dll', '/reference:System.Core.dll',
    (Join-Path $appDir 'Interop.cs')
)
& $csc $cscArgs2 2>&1 | ForEach-Object { Write-Verbose $_ }
if (-not (Test-Path $interopDll)) { throw 'Interop compilation failed.' }
Say "  compiled RobocopyTo.Native.dll"

# --- write install metadata the DLL reads (InstallDir, last-op marker home) ---
$swKey = 'HKCU:\Software\RobocopyTo'
$null = New-Item -Path $swKey -Force
Set-ItemProperty -Path $swKey -Name 'InstallDir' -Value $appDir
Set-ItemProperty -Path $swKey -Name 'Version' -Value '1.0.0'
# the menu is text-only: drop icon refs an earlier version may have written
foreach ($n in @('IconRoot', 'Icon.copyto', 'Icon.mirrorto', 'Icon.moveto', 'Icon.paste', 'Icon.settings')) {
    Remove-ItemProperty -Path $swKey -Name $n -ErrorAction SilentlyContinue
}

# --- 3. shell integration ---
. (Join-Path $repo 'packaging\register-shell.ps1')

$dll = Join-Path $appDir 'RobocopyToMenu.dll'
$useDll = $false
if (-not $NoDll) {
    if (-not (Test-Path $dll)) {
        # releases ship per-arch DLLs; a repo build leaves an unsuffixed one;
        # last resort: build it here if VS C++ tools are available
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        $prebuilt = @(
            (Join-Path $repo "native\build\RobocopyToMenu-$arch.dll"),
            (Join-Path $repo 'native\build\RobocopyToMenu.dll')
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($prebuilt) {
            Copy-Item $prebuilt $dll -Force
        } else {
            try {
                Say "  building native menu DLL..."
                & (Join-Path $repo 'native\build.ps1') | ForEach-Object { Write-Verbose $_ }
                $built = Join-Path $repo 'native\build\RobocopyToMenu.dll'
                if (Test-Path $built) { Copy-Item $built $dll -Force }
            } catch { Write-Verbose "DLL build skipped: $_" }
        }
    }
    $useDll = Test-Path $dll
}

if ($useDll) {
    Register-RtComMenu -Dll $dll -Clsid $clsid
    Say "  registered native menu (live Robopaste/Undo states)"
} else {
    Register-RtRegistryMenu -LauncherExe $launcherExe
    Say "  registered classic menu (registry verbs)"
}

# --- 4. uninstall entry in Apps & features ---
$arp = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RobocopyTo'
$null = New-Item -Path $arp -Force
$uninstallCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($appDir)\uninstall.ps1`" -RemoveTrust -Pause"
Copy-Item (Join-Path $repo 'uninstall.ps1') (Join-Path $appDir 'uninstall.ps1') -Force
Set-ItemProperty -Path $arp -Name 'DisplayName' -Value 'RobocopyTo'
Set-ItemProperty -Path $arp -Name 'DisplayVersion' -Value '1.0.0'
Set-ItemProperty -Path $arp -Name 'Publisher' -Value 'RobocopyTo contributors'
Set-ItemProperty -Path $arp -Name 'DisplayIcon' -Value $launcherExe
Set-ItemProperty -Path $arp -Name 'UninstallString' -Value $uninstallCmd
Set-ItemProperty -Path $arp -Name 'NoModify' -Value 1 -Type DWord
Set-ItemProperty -Path $arp -Name 'NoRepair' -Value 1 -Type DWord
Set-ItemProperty -Path $arp -Name 'InstallLocation' -Value $appDir

# --- 5. optional: Windows 11 top-level context menu (sparse package) ---
$msix = Join-Path $repo 'packaging\out\RobocopyTo-sparse.msix'
$cer  = Join-Path $repo 'packaging\out\RobocopyTo.cer'
$topLevelDone = $false
if (-not $SkipTopLevelMenu -and (Test-Path $msix)) {
    $wantTop = [bool]$TopLevelMenu
    if (-not $wantTop -and -not $Quiet -and [Environment]::UserInteractive) {
        $ans = Read-Host 'Also add Robocopy to the Windows 11 top-level right-click menu? [Y/n]'
        $wantTop = ($ans -eq '' -or $ans -match '^[Yy]')
    }
    if ($wantTop) {
        try {
            if (Test-Path $cer) {
                # trust the package certificate once (the single admin prompt)
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cer
                $trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
                           Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
                if (-not $trusted) {
                    Say "  trusting the RobocopyTo package certificate (admin prompt)..."
                    Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                        "Import-Certificate -FilePath `"$cer`" -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null"
                    )
                    $trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
                               Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
                    if (-not $trusted) { throw 'the certificate was not trusted (prompt declined?)' }
                }
            }
            & (Join-Path $repo 'packaging\register-msix.ps1') -Package $msix | ForEach-Object { Say "  $_" }
            $topLevelDone = $true
        } catch {
            # unsigned package (or trust declined): Developer Mode is the fallback
            $devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
            if (1 -eq $devMode) {
                try {
                    & (Join-Path $repo 'packaging\register-msix.ps1') -Package $msix -Unsigned | ForEach-Object { Say "  $_" }
                    $topLevelDone = $true
                } catch { }
            }
            if (-not $topLevelDone) {
                Say ("  top-level menu skipped: " + $_.Exception.Message)
                Say "  (everything else works; rerun install.ps1 -TopLevelMenu to retry)"
            }
        }
    }
} elseif (-not $SkipTopLevelMenu -and -not (Test-Path $msix)) {
    Say "  (no sparse package in this source - the top-level Win11 menu needs a release zip"
    Say "   or packaging\build-msix.ps1; the classic menu works either way)"
}

# nudge Explorer to reload context-menu handlers
try { & "$env:WINDIR\System32\ie4uinit.exe" -show 2>$null } catch { }

Say ""
Say "RobocopyTo installed."
Say "Right-click any file, folder, drive, or folder background -> Robocopy."
if (-not $useDll) {
    Say "(Classic menu mode: Robopaste is always shown; it reports if the clipboard has no files.)"
}
if ($topLevelDone) {
    Say "Top-level Windows 11 menu is on (restart Explorer if it does not show up yet)."
} elseif (Get-AppxPackage -Name 'RobocopyTo' -ErrorAction SilentlyContinue) {
    Say "Top-level Windows 11 menu was already on and stays on."
} else {
    Say "On Windows 11 the entry is under 'Show more options' (Shift+F10)."
}
