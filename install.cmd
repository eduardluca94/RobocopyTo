@echo off
rem RobocopyTo installer shim. Browser-downloaded scripts are blocked by
rem PowerShell's execution policy on many systems; this runs install.ps1 with
rem the policy bypassed for this one process only - nothing machine-wide.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
