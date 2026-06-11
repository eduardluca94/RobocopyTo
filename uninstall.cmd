@echo off
rem RobocopyTo uninstaller shim: runs uninstall.ps1 past the execution policy
rem (process-scoped bypass), removing the app and the certificate trust.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -RemoveTrust -Pause %*
