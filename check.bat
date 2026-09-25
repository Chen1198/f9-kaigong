@echo off
chcp 65001 >nul
echo.
echo   Self check - verify hotkey + config, open nothing
echo   ------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Workday.ps1" -Check
echo.
echo   ---- latest log ----
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem '%~dp0logs' -Filter *.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Encoding UTF8 -Tail 60"
echo.
pause
