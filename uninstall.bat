@echo off
chcp 65001 >nul
echo.
echo   Workday Launcher - uninstall
echo   ------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
echo.
pause
