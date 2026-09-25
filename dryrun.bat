@echo off
chcp 65001 >nul
echo.
echo   Dry run - show what would be opened, open nothing.
echo   ------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Workday.ps1" -DryRun
echo.
echo   ---- latest log ----
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem '%~dp0logs' -Filter *.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Encoding UTF8 -Tail 40"
echo.
pause
