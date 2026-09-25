@echo off
rem ===================================================================
rem  One-click Workday Launcher - Settings (graphical)
rem  Double-click this file to open the settings window.
rem ===================================================================
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Settings-GUI.ps1"
exit /b 0
