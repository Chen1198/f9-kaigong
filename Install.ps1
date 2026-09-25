# =====================================================================
#  Workday Launcher  ·  安装
#  1) 开机后自动在后台待命（在启动文件夹写一个 .vbs，不需要管理员权限）
#  2) 桌面放两个图标：
#     ·「F9开工」双击打开控制面板（清单 + 设置都在这一个窗口里）
#       想让它双击就直接开工？在面板里把「双击桌面图标」改成"直接开工"即可
#     ·「F9收工」双击弹出「关机 / 重启 / 睡眠」窗口（带倒计时，点【取消】能停下）
#  3) 立刻把后台程序拉起来，不用重启就能按快捷键
#
#  参数:
#    -IconsOnly  只重建上面那两个图标和它们的启动器；不碰开机自启、也不动后台进程。
#                面板上「在桌面放一个『F9收工』图标」那个按钮走的就是这条路
#                （用户可能正开着软件干活，不能被我们重启后台打断）。
# =====================================================================

param([switch]$IconsOnly)

$ErrorActionPreference = 'Continue'

if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$main    = Join-Path $ScriptDir 'Start-Workday.ps1'
$gui     = Join-Path $ScriptDir 'Settings-GUI.ps1'
$SysRoot = $env:SystemRoot
if (-not $SysRoot) { $SysRoot = 'C:\Windows' }
$psExe   = Join-Path $SysRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

$startup = [Environment]::GetFolderPath('Startup')
if (-not $startup) {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if (-not $appData) { $appData = $env:APPDATA }
    $startup = Join-Path $appData 'Microsoft\Windows\Start Menu\Programs\Startup'
}
$desktop = [Environment]::GetFolderPath('Desktop')

$startupVbs = Join-Path $startup 'workday-launcher-daemon.vbs'
$desktopLnk = Join-Path $desktop 'F9开工.lnk'
$desktopQuitLnk = Join-Path $desktop 'F9收工.lnk'
$appVbs     = Join-Path $ScriptDir 'run-app.vbs'
$quitVbs    = Join-Path $ScriptDir 'run-quit.vbs'
$hubVbs     = Join-Path $ScriptDir 'run-hub.vbs'
$ascii      = New-Object System.Text.ASCIIEncoding

# ---- 桌面图标：跟着当前皮肤走（原来这两行忘了定义，导致装完还是白板图标）----
$appIco  = Join-Path $ScriptDir 'app.ico'
$setIco  = Join-Path $ScriptDir 'setup.ico'
$quitIco = Join-Path $ScriptDir 'quit.ico'
$hubIco  = Join-Path $ScriptDir 'hub.ico'
try {
    $skinFile = Join-Path $ScriptDir 'skin.json'
    if (Test-Path -LiteralPath $skinFile) {
        $skinId = [string](((Get-Content -LiteralPath $skinFile -Raw -Encoding UTF8) | ConvertFrom-Json).skin)
        if (-not [string]::IsNullOrWhiteSpace($skinId)) {
            $a2 = Join-Path $ScriptDir ('skin_' + $skinId + '_app.ico')
            $s2 = Join-Path $ScriptDir ('skin_' + $skinId + '_setup.ico')
            if (Test-Path -LiteralPath $a2) { $appIco = $a2 }
            if (Test-Path -LiteralPath $s2) { $setIco = $s2 }
            $q2 = Join-Path $ScriptDir ('skin_' + $skinId + '_quit.ico')
            if (Test-Path -LiteralPath $q2) { $quitIco = $q2 }
        }
    }
} catch { }

# ---- .vbs 拼装小工具 ----
# ⚠️ VBScript 里字符串内部的引号必须写成两个（""）。只写一个会把字符串提前截断，
#    双击图标就弹「Windows Script Host / 语句未结束 / 800A0401」——这个坑踩过一次，别再改回去。
#    所以下面统一用 $dq 拼，写盘前还做一次引号配对自检。
function New-QuietStarterVbs {
    param([string]$ExePath, [string]$ScriptPath, [string]$ExtraArgs, [string]$Comment1, [string]$Comment2)
    $q  = [char]34
    $dq = $q + $q
    $cmd = $dq + $ExePath + $dq + ' -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $dq + $ScriptPath + $dq
    if (-not [string]::IsNullOrWhiteSpace($ExtraArgs)) { $cmd = $cmd + ' ' + $ExtraArgs }
    $runLine = 'CreateObject("WScript.Shell").Run "' + $cmd + '", 0, False'
    $n = @($runLine.ToCharArray() | Where-Object { $_ -eq $q }).Count
    if ($n % 2 -ne 0) { throw ('生成的 .vbs 引号不成对（' + $n + ' 个），已中止：' + $runLine) }
    return ("'" + $Comment1 + [Environment]::NewLine +
            "'" + $Comment2 + [Environment]::NewLine +
            $runLine + [Environment]::NewLine)
}

# 用 VBScript 引擎亲自验一遍语法：把有副作用的 Run 换成纯赋值。
# 语法对 -> 只是赋个值立刻退出；语法错 -> 编译报错、退出码非 0。
function Test-VbsSyntax {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $cs = Join-Path $SysRoot 'System32\cscript.exe'
        if (-not (Test-Path -LiteralPath $cs)) { return $true }
        $txt   = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::ASCII)
        $probe = $txt.Replace('CreateObject("WScript.Shell").Run ', 'Dim probe : probe = ')
        $probe = $probe -replace '", 0, False', '"'
        $pf = Join-Path $env:TEMP 'workday-launcher-vbscheck.vbs'
        [System.IO.File]::WriteAllText($pf, $probe, (New-Object System.Text.ASCIIEncoding))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $cs
        $psi.Arguments              = '//NoLogo //B "' + $pf + '"'
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardError  = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $null = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
        return ($proc.ExitCode -eq 0)
    } catch { return $true }
}

# ---- 1) 开机自启：在启动文件夹里写一个静默启动器（无窗口，不闪黑框） ----
# -IconsOnly（面板上的"放个收工图标"按钮）只补图标，绝不碰这里。
if ($IconsOnly) {
    Write-Output '[INFO] -IconsOnly：只补图标和启动器，不动开机自启'
} else {
try {
    $vbs = New-QuietStarterVbs -ExePath $psExe -ScriptPath $main -ExtraArgs '' `
              -Comment1 'Workday Launcher - keep waiting in background after logon' `
              -Comment2 'Delete this file to disable auto start'
    [System.IO.File]::WriteAllText($startupVbs, $vbs, $ascii)
    Write-Output ('[OK]   开机后台待命已设置: ' + $startupVbs)
} catch {
    Write-Output ('[FAIL] 设置开机自启失败: ' + $_.Exception.Message)
}
}

# ---- 2) 一个不闪黑框的启动器（.vbs）----
# 直接让快捷方式去拉 powershell.exe 时，屏幕上会先冒出一个黑框。
# 让 wscript 用 0 号窗口模式去拉，就完全不会出现黑框了。
$appVbsOk = $false
try {
    $vbs = New-QuietStarterVbs -ExePath $psExe -ScriptPath $main -ExtraArgs '-Main' `
              -Comment1 'Workday Launcher - open the control panel, no console window' `
              -Comment2 'Do not edit by hand: the doubled quotes are required by VBScript'
    [System.IO.File]::WriteAllText($appVbs, $vbs, $ascii)
    # 写完立刻验语法，过了才算数（不过就退回直接调 powershell，最多闪一下黑框，功能不受影响）
    $appVbsOk = Test-VbsSyntax -Path $appVbs
    if ($appVbsOk) {
        Write-Output ('[OK]   已生成无黑框启动器: ' + $appVbs + '  （语法校验通过）')
    } else {
        Write-Output '[WARN] run-app.vbs 语法校验没过，桌面图标改用直接调用 powershell（会闪一下黑框）'
    }
} catch {
    Write-Output ('[WARN] 生成 .vbs 启动器失败: ' + $_.Exception.Message)
}

# ---- 2b) 桌面快捷方式：只放一个「F9开工」，双击 = 赛博朋克启动台 ----
# 【2026-09-25 改成"二合一"】以前桌面摆两个图标（F9开工 / F9收工），
# 现在合成一个：双击弹出启动台（中间一个大圆环），点一下圆环就开工。
# 收工没有丢 —— 它回到快捷键 Ctrl+Alt+Q（后台注册的全局热键，跟桌面图标无关）。
#
# 目标优先用 wscript 跑 .vbs（零黑框）；wscript 不在就退回直接跑 powershell。
$wscriptExe = Join-Path $SysRoot 'System32\wscript.exe'

$hubVbsOk = $false
try {
    $vbs = New-QuietStarterVbs -ExePath $psExe -ScriptPath $main -ExtraArgs '-Hub' `
              -Comment1 'Workday Launcher - cyber launch pad (click the ring to start the day)' `
              -Comment2 'Do not edit by hand: the doubled quotes are required by VBScript'
    [System.IO.File]::WriteAllText($hubVbs, $vbs, $ascii)
    $hubVbsOk = Test-VbsSyntax -Path $hubVbs
    if ($hubVbsOk) {
        Write-Output ('[OK]   已生成启动台启动器: ' + $hubVbs + '  （语法校验通过）')
    } else {
        Write-Output '[WARN] run-hub.vbs 语法校验没过，桌面图标改用直接调 powershell（会闪一下黑框）'
    }
} catch {
    Write-Output ('[WARN] 生成启动台启动器失败: ' + $_.Exception.Message)
}

$useVbs = $hubVbsOk -and (Test-Path -LiteralPath $wscriptExe)
try {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($desktopLnk)
    if ($useVbs) {
        $lnk.TargetPath = $wscriptExe
        $lnk.Arguments  = '"' + $hubVbs + '"'
    } else {
        $lnk.TargetPath = $psExe
        $lnk.Arguments  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $main + '" -Hub'
    }
    $lnk.WorkingDirectory = $ScriptDir
    $lnk.WindowStyle      = 7
    $lnk.Description      = 'F9开工：双击弹出启动台，点一下中间那个大圆环就开工'
    if (Test-Path -LiteralPath $hubIco) { $lnk.IconLocation = $hubIco + ',0' }
    elseif (Test-Path -LiteralPath $appIco) { $lnk.IconLocation = $appIco + ',0' }
    $lnk.Save()
    Write-Output ('[OK]   桌面已生成「F9开工」图标（' + $(if ($useVbs) { 'wscript 无黑框模式' } else { 'powershell 兜底模式' }) + '）')
} catch {
    Write-Output ('[WARN] 没能在桌面建快捷方式(不影响快捷键使用): ' + $_.Exception.Message)
}

# ---- 2e) 桌上如果还留着老版本建的「F9收工」图标，挪到程序目录备份 ----
# 【为什么撤掉】用户 2026-09-25 要求"只留一键开工这一个功能"，桌面合成一个图标。
# 收工**没有丢** —— 按 Ctrl+Alt+Q 一样弹「关机 / 重启 / 睡眠」窗口（带倒计时），
# 那条路走的是后台注册的全局热键，跟桌面图标没有关系。
# 只挪我们自己建的那个（参数里带本程序路径），绝不动用户其它快捷方式。
foreach ($oldQ in @('F9收工.lnk')) {
    $opq = Join-Path $desktop $oldQ
    if (-not (Test-Path -LiteralPath $opq)) { continue }
    try {
        $wsq5 = New-Object -ComObject WScript.Shell
        $skq5 = $wsq5.CreateShortcut($opq)
        $mineQ = ($skq5.Arguments -and ($skq5.Arguments -like '*run-quit.vbs*' -or $skq5.Arguments -like '*Start-Workday.ps1*'))
        if ($mineQ) {
            $bakq = Join-Path $ScriptDir ('old-shortcut-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.lnk.bak')
            Move-Item -LiteralPath $opq -Destination $bakq -Force
            Write-Output ('[OK]   桌面已合并成一个图标，旧的「F9收工」备份到: ' + $bakq)
            Write-Output '       （收工功能还在，按 Ctrl+Alt+Q 就行）'
        } else {
            Write-Output '[SKIP] 桌面上的 F9收工 不是本程序建的，没动它'
        }
    } catch {
        Write-Output ('[WARN] 处理 F9收工 失败: ' + $_.Exception.Message)
    }
}

# ---- 2c) 老版本会在桌面放第二个「F9开工·设置」图标，挪到程序目录里备份 ----
foreach ($old2 in @('F9开工·设置.lnk', 'F9开工 · 设置.lnk')) {
    $op = Join-Path $desktop $old2
    if (Test-Path -LiteralPath $op) {
        try {
            $ws3 = New-Object -ComObject WScript.Shell
            $sk  = $ws3.CreateShortcut($op)
            # 只动我们自己建的那个（参数里带本程序的 Settings-GUI.ps1）
            if ($sk.Arguments -and $sk.Arguments -like ('*' + $gui + '*')) {
                $bak = Join-Path $ScriptDir ('old-shortcut-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.lnk.bak')
                Move-Item -LiteralPath $op -Destination $bak -Force
                Write-Output ('[OK]   桌面已合并成一个图标，旧的设置图标备份到: ' + $bak)
            } else {
                Write-Output ('[SKIP] 桌面上的 ' + $old2 + ' 不是本程序建的，没动它')
            }
        } catch {
            Write-Output ('[WARN] 处理 ' + $old2 + ' 失败: ' + $_.Exception.Message)
        }
    }
}

# ---- 2d) 名字从「一键开工」改成「F9开工」了：桌面上的旧图标挪到程序目录备份 ----
# 不删，只挪走 —— 万一用户想找回来，备份就在程序目录里。
foreach ($oldMain in @('一键开工.lnk', '一键开工 · 设置.lnk', '一键开工·设置.lnk')) {
    $op = Join-Path $desktop $oldMain
    if (-not (Test-Path -LiteralPath $op)) { continue }
    try {
        $ws4 = New-Object -ComObject WScript.Shell
        $sk4 = $ws4.CreateShortcut($op)
        # 只动我们自己建的（参数里带本程序的 run-app.vbs 或 Start-Workday.ps1）
        $mine = ($sk4.Arguments -and ($sk4.Arguments -like '*run-app.vbs*' -or $sk4.Arguments -like '*Start-Workday.ps1*' -or $sk4.Arguments -like '*Settings-GUI.ps1*'))
        if ($mine) {
            $bak4 = Join-Path $ScriptDir ('old-shortcut-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.lnk.bak')
            Move-Item -LiteralPath $op -Destination $bak4 -Force
            Write-Output ('[OK]   桌面上的旧名字「' + $oldMain + '」已挪走（备份: ' + $bak4 + '）')
        } else {
            Write-Output ('[SKIP] 桌面上的 ' + $oldMain + ' 不是本程序建的，没动它')
        }
    } catch {
        Write-Output ('[WARN] 处理 ' + $oldMain + ' 失败: ' + $_.Exception.Message)
    }
}

# ---- 3) 立刻把后台进程拉起来（顺便处理"程序更新了但后台还是旧代码"的情况）----
# -IconsOnly 时整段跳过：那是面板按钮叫起来的，用户手上多半正开着东西在干活。
if ($IconsOnly) {
    Write-Output '[INFO] -IconsOnly：不动后台进程（桌面上那个「F9开工」图标现在就能用）'
} else {
try {
    $mainTime = (Get-Item -LiteralPath $main).LastWriteTime
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and $_.CommandLine -like '*Start-Workday.ps1*' })

    $stale = @()
    foreach ($e in $existing) {
        $cd = $null
        try { $cd = [datetime]$e.CreationDate } catch { $cd = $null }
        if ($cd -and $cd -lt $mainTime) { $stale += $e }
    }

    if ($existing.Count -eq 0) {
        Start-Process -FilePath $psExe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $main
        ) -WindowStyle Hidden
        Start-Sleep -Seconds 4
        Write-Output '[OK]   后台程序已启动'
    } elseif ($stale.Count -gt 0) {
        # 后台是改代码之前拉起来的，里面的还是旧版本，重启一下
        foreach ($e in $stale) {
            try { Stop-Process -Id $e.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Seconds 1
        Start-Process -FilePath $psExe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $main
        ) -WindowStyle Hidden
        Start-Sleep -Seconds 4
        Write-Output '[OK]   检测到程序更新过，后台已重启（用上最新版本了）'
    } else {
        Write-Output '[OK]   后台程序已经在跑了，无需重复启动'
    }
    Write-Output '[INFO] 现在按一下 F9（或 Ctrl+Alt+W）就能F9开工；Ctrl+Alt+Q 是F9收工'
} catch {
    Write-Output ('[FAIL] 启动后台程序失败: ' + $_.Exception.Message)
}
}

Write-Output ''
Write-Output '安装完成。'
Write-Output '桌面上只留一个「F9开工」：双击弹出启动台，点一下中间那个大圆环就开工。'
Write-Output '想改清单 / 皮肤 / 彩蛋：开始菜单里的「F9开工·设置」（都在那一个窗口里）。'
Write-Output '收工：按 Ctrl+Alt+Q = 关机 / 重启 / 睡眠（带倒计时，随时能取消）。'
Write-Output ('有疑问就双击 check.bat 自检。程序位置: ' + $ScriptDir)
