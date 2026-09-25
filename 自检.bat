@echo off
chcp 65001 >nul
echo.
echo   ===== F9开工 自检 =====
echo.
echo   [1/3] 检查两个脚本有没有语法错误...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile('%~dp0Settings-GUI.ps1',[ref]$t,[ref]$e)|Out-Null;if($e.Count){Write-Host ('  ✗ Settings-GUI.ps1 有语法错误 '+$e.Count+' 处')}else{Write-Host '  ✓ Settings-GUI.ps1 语法正确'}"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile('%~dp0Start-Workday.ps1',[ref]$t,[ref]$e)|Out-Null;if($e.Count){Write-Host ('  ✗ Start-Workday.ps1 有语法错误 '+$e.Count+' 处')}else{Write-Host '  ✓ Start-Workday.ps1 语法正确'}"
echo.
echo   [2/3] 跑设置界面内部自检（不弹窗）...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Settings-GUI.ps1" -SelfTest
echo        完成
echo.
echo   [3/3] 跑启动器自检（不会真的打开软件）...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Start-Workday.ps1" -Check
echo        完成
echo.
echo   ===== 结果 =====
echo.
echo   ---- 设置界面自检 (logs\gui-selftest.txt) ----
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "if(Test-Path '%~dp0logs\gui-selftest.txt'){Get-Content '%~dp0logs\gui-selftest.txt' -Encoding UTF8}"
echo.
echo   ---- 启动器自检 (logs\launcher-*.log 最后 40 行) ----
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem '%~dp0logs' -Filter 'launcher-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1 | ForEach-Object { Get-Content $_.FullName -Encoding UTF8 -Tail 40 }"
echo.
pause
