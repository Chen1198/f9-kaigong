@echo off
chcp 65001 >nul
echo.
echo   Workday Launcher - install
echo   ------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
echo.
pause
