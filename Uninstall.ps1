# =====================================================================
#  Workday Launcher  ·  卸载
#  移除开机自启、桌面快捷方式，并结束后台进程。文件夹保留（可自行删除）。
# =====================================================================

$ErrorActionPreference = 'Continue'

if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$startup = [Environment]::GetFolderPath('Startup')
if (-not $startup) {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if (-not $appData) { $appData = $env:APPDATA }
    $startup = Join-Path $appData 'Microsoft\Windows\Start Menu\Programs\Startup'
}
$desktop = [Environment]::GetFolderPath('Desktop')

$targets = @(
    (Join-Path $startup 'workday-launcher-daemon.vbs'),
    (Join-Path $startup 'workday-launcher-daemon.lnk'),
    (Join-Path $desktop 'F9开工.lnk'),
    (Join-Path $desktop 'F9开工·设置.lnk'),
    (Join-Path $desktop 'F9开工 · 设置.lnk'),
    # 旧名字（2026-09-24 之前叫「一键开工」）：老机器上升级上来的人也得能卸干净
    (Join-Path $desktop '一键开工.lnk'),
    (Join-Path $desktop '一键开工·设置.lnk'),
    (Join-Path $desktop '一键开工 · 设置.lnk')
)

foreach ($f in $targets) {
    if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        Write-Output ('[OK]   已删除: ' + $f)
    }
}

$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
         Where-Object { $_.CommandLine -and $_.CommandLine -like '*Start-Workday.ps1*' }
if ($procs) {
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Output ('[OK]   已结束后台进程 PID=' + $p.ProcessId)
    }
} else {
    Write-Output '[INFO] 后台进程没在跑'
}

Write-Output ''
Write-Output '卸载完成。程序文件夹还在，不需要的话可以整个删掉：'
Write-Output '（如果桌面/任务栏还留着图标，手动删掉即可）'
Write-Output $ScriptDir
