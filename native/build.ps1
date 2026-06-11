# Builds RobocopyToMenu.dll with the MSVC toolchain (any VS edition with C++ tools).
# Output: native\build\RobocopyToMenu.dll  (x64 by default; -Arch arm64 cross-builds)
param([string]$Arch = 'x64')
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found - install Visual Studio Build Tools with the C++ workload.' }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
if (-not $vsPath) { throw 'No Visual Studio installation with C++ tools found.' }

$vcvarsArch = if ($Arch -eq 'arm64') { 'x64_arm64' } else { 'x64' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
$src = Join-Path $PSScriptRoot 'RobocopyToMenu.cpp'
$def = Join-Path $PSScriptRoot 'RobocopyToMenu.def'
$out = Join-Path $PSScriptRoot 'build'
$null = New-Item -ItemType Directory -Force -Path $out

$cmd = "call `"$vcvars`" $vcvarsArch >nul 2>&1 && cl /nologo /LD /MT /O1 /W4 /EHs-c- /GS /DUNICODE /D_UNICODE /utf-8 `"$src`" " +
       "/Fo`"$out\\`" /Fe`"$out\RobocopyToMenu.dll`" " +
       "/link /DEF:`"$def`" /NXCOMPAT /DYNAMICBASE ole32.lib oleaut32.lib shell32.lib user32.lib advapi32.lib shlwapi.lib uuid.lib"
$output = cmd /c $cmd 2>&1
$output | ForEach-Object { Write-Output $_ }
if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }
if (-not (Test-Path "$out\RobocopyToMenu.dll")) { throw 'Build produced no DLL.' }
Write-Output "OK: $out\RobocopyToMenu.dll ($((Get-Item "$out\RobocopyToMenu.dll").Length) bytes)"
