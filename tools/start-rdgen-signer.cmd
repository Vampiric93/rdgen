@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-windows-signing-agent.ps1" -InstallDirectory "%~dp0."
if errorlevel 1 pause
