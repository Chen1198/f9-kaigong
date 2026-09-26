# =====================================================================
#  F9开工 · 换皮肤
#  双击「换皮肤.bat」运行，选一个皮肤即可。
#  会自动改 skin.json、重画桌面图标、重启后台程序。
# =====================================================================

[CmdletBinding()]
param([string]$SetSkin)

$ErrorActionPreference = 'Continue'

if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$SkinPath   = Join-Path $ScriptDir 'skin.json'
$ArtDir     = Join-Path $ScriptDir 'art'
$LogDir     = Join-Path $ScriptDir 'logs'
$Ascii      = New-Object System.Text.ASCIIEncoding

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Say { param([string]$T) Write-Output $T }

# ---------------------------------------------------------------- 读皮肤
function Get-SkinFile {
    if (-not (Test-Path -LiteralPath $SkinPath)) { return $null }
    try {
        return (Get-Content -LiteralPath $SkinPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Say ('[X] skin.json 读不了：' + $_.Exception.Message)
        return $null
    }
}

$all = Get-SkinFile
if (-not $all) {
    Say '找不到皮肤配置文件 skin.json，请确认程序目录完整。'
    Say '按任意键退出...'
    try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 4 }
    exit 1
}

# 可选的皮肤列表
$ids = @()
foreach ($p in $all.skins.PSObject.Properties) {
    if ($p.Name -notlike '_*') { $ids += $p.Name }
}

function Get-Label {
    param([string]$Id)
    $o = $all.skins.PSObject.Properties[$Id]
    if ($o) {
        $lab = $o.Value.PSObject.Properties['label']
        if ($lab -and -not [string]::IsNullOrWhiteSpace([string]$lab.Value)) {
            return [string]$lab.Value
        }
    }
    return $Id
}

$cur = [string]$all.skin

# ---------------------------------------------------------------- 界面
if (-not $SetSkin) {
    Clear-Host
    Say ''
    Say '  ============================================'
    Say '     F9开工 · 换皮肤'
    Say '  ============================================'
    Say ''
    Say ('  当前皮肤：' + (Get-Label $cur))
    Say ''
    Say '  可选皮肤：'
    Say ''
    $i = 1
    foreach ($id in $ids) {
        $mark = '  '
        if ($id -eq $cur) { $mark = ' *' }
        $tip = ''
        try {
            $one = $all.skins.PSObject.Properties[$id].Value
            $d = $one.PSObject.Properties['_说明']
            if ($d -and -not [string]::IsNullOrWhiteSpace([string]$d.Value)) {
                $tip = [string]$d.Value
                # 说明里带「：」时只取冒号后面那半句，读起来短一点
                $ix = $tip.IndexOf([char]0xFF1A)
                if ($ix -ge 0) { $tip = $tip.Substring($ix + 1) }
            }
        } catch { $tip = '' }
        Say ('   ' + $mark + ' [' + $i + ']  ' + (Get-Label $id) + '    ' + $tip)
        $i++
    }
    Say ''
    Say '  输入编号再按回车即可切换（直接回车 = 不改）：'
    Say ''
    $ans = Read-Host '  请选择'

    if ([string]::IsNullOrWhiteSpace($ans)) {
        Say ''
        Say '  没有改动。'
        Start-Sleep -Seconds 1
        exit 0
    }
    $n = 0
    if (-not [int]::TryParse($ans.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $ids.Count) {
        Say ''
        Say '  编号不对，没有改动。'
        Start-Sleep -Seconds 2
        exit 0
    }
    $SetSkin = $ids[$n - 1]
}

if ($ids -notcontains $SetSkin) {
    Say ('没有这个皮肤：' + $SetSkin)
    exit 1
}

# ---------------------------------------------------------------- 写入
$raw = Get-Content -LiteralPath $SkinPath -Raw -Encoding UTF8
# 只替换顶层 "skin": "xxx" 这一行，其他内容原样保留
$new = [System.Text.RegularExpressions.Regex]::Replace(
    $raw,
    '"skin"\s*:\s*"[^"]*"',
    ('"skin": "' + $SetSkin + '"'),
    1)
if ($new -eq $raw -and $raw -notmatch ('"skin"\s*:\s*"' + [regex]::Escape($SetSkin) + '"')) {
    Say '[!] 没能定位到 skin 字段，改用整体重写。'
    $all.skin = $SetSkin
    $new = ($all | ConvertTo-Json -Depth 12)
}
[System.IO.File]::WriteAllText($SkinPath, $new, (New-Object System.Text.UTF8Encoding($false)))

Say ''
Say ('[OK] 皮肤已切换为：' + (Get-Label $SetSkin))

# ---------------------------------------------------------------- 桌面 / 开始菜单图标
# 【2026-09-26 修】桌面那个「F9开工」就是敲木鱼的启动台，所以：
#   ① 目标必须走 run-hub.vbs（等价 -Hub，先弹启动台）；以前写的是 -Run，
#      也就是"跳过启动台直接开工"——换一次皮肤，启动台就没了。
#   ② 图标必须用 hub.ico（那只木鱼）；以前用皮肤那张闪电图，换皮肤就把木鱼盖掉。
#   ③ 不再往桌面建「F9开工·设置」：用户 2026-09-25 要求桌面只留 1 个图标，
#      设置入口只放开始菜单（Install.ps1 的 2h 段负责）。
#   规则要和 Install.ps1 的 2c / 2h 段保持一致，两边一起改。
$hubIco = Join-Path $ScriptDir 'hub.ico'
$appIco = Join-Path $ScriptDir ('skin_' + $SetSkin + '_app.ico')
$setIco = Join-Path $ScriptDir ('skin_' + $SetSkin + '_setup.ico')
if (Test-Path -LiteralPath $hubIco) { $appIco = $hubIco }
elseif (-not (Test-Path -LiteralPath $appIco)) { $appIco = Join-Path $ScriptDir 'app.ico' }
if (-not (Test-Path -LiteralPath $setIco)) { $setIco = Join-Path $ScriptDir 'setup.ico' }

$main   = Join-Path $ScriptDir 'Start-Workday.ps1'
$gui    = Join-Path $ScriptDir 'Settings-GUI.ps1'
$hubVbs = Join-Path $ScriptDir 'run-hub.vbs'
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
$wsExe  = Join-Path $env:SystemRoot 'System32\wscript.exe'
$useVbs = (Test-Path -LiteralPath $hubVbs) -and (Test-Path -LiteralPath $wsExe)

$desktop   = [Environment]::GetFolderPath('Desktop')
$startMenu = [Environment]::GetFolderPath('Programs')

function Set-HubShortcut {
    param($Lnk, [string]$Desc)
    if ($useVbs) {
        $Lnk.TargetPath = $wsExe
        $Lnk.Arguments  = '"' + $hubVbs + '"'
    } else {
        $Lnk.TargetPath = $psExe
        $Lnk.Arguments  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $main + '" -Hub'
    }
    $Lnk.WorkingDirectory = $ScriptDir
    $Lnk.WindowStyle      = 7
    $Lnk.Description      = $Desc
    $Lnk.IconLocation     = $appIco + ',0'
    $Lnk.Save()
}

try {
    $ws = New-Object -ComObject WScript.Shell

    # 桌面：只有这一个图标（敲木鱼的启动台）
    $a = $ws.CreateShortcut((Join-Path $desktop 'F9开工.lnk'))
    Set-HubShortcut $a 'F9开工：双击弹出启动台，敲一下中间那只木鱼就开工'
    Say '[OK] 桌面图标已更新（木鱼启动台）'

    if (Test-Path -LiteralPath $startMenu) {
        $c = $ws.CreateShortcut((Join-Path $startMenu 'F9开工.lnk'))
        Set-HubShortcut $c 'F9开工：弹出启动台，敲一下中间那只木鱼就开工'

        $d = $ws.CreateShortcut((Join-Path $startMenu 'F9开工·设置.lnk'))
        $d.TargetPath       = $psExe
        $d.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $gui + '"'
        $d.WorkingDirectory = $ScriptDir
        $d.WindowStyle      = 7
        $d.Description      = 'F9开工 · 设置：改清单 / 皮肤 / 快捷键 / 收工倒计时'
        $d.IconLocation     = $setIco + ',0'
        $d.Save()
        Say '[OK] 开始菜单图标已更新'
    }
} catch {
    Say ('[!] 图标更新跳过（不影响使用）：' + $_.Exception.Message)
}

# 刷新图标缓存，让新图标立刻显示（个别环境会拦这个命令，失败就算了）
try {
    $ie4u = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
    if (Test-Path -LiteralPath $ie4u) {
        Start-Process -FilePath $ie4u -ArgumentList '-show' -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
} catch { }

# ---------------------------------------------------------------- 重启后台
$killed = 0
try {
    $ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            # 【2026-09-26 修】停止条件必须跟 Settings-GUI.ps1 的 Get-DaemonProcs 完全一致：
            # 只停「常驻待命」那一个（命令行不带任何一次性开关）。
            # 原来这里只排了 -Run/-Check/-DryRun/-TipTest，漏掉 -Hub、-Sequence、-Main 等 ——
            # 结果：正开着启动台、或正在开工（-Sequence 正在一个个开软件）时来换皮肤，
            # 会把那一半活儿硬掐断。这类"判据漏项"以前在后台重启上已经踩过一次。
            $_.ProcessId -ne $PID -and $_.CommandLine -and
            $_.CommandLine -like '*Start-Workday.ps1*' -and
            $_.CommandLine -notmatch '\-(Sequence|Run|Check|DryRun|TipTest|FanTest|Main|SimTrigger|NoTip|ShowTip|Shutdown|QuitTest|QuitShot|Hub|HubShot|Warm|IconsOnly)\b'
        }
    foreach ($p in $ps) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
    }
} catch { }

if ($killed -gt 0) { Say ('[OK] 已停掉旧的后台程序（' + $killed + ' 个），正在用新皮肤重启...') }
else { Say '[OK] 正在启动后台程序...' }

Start-Sleep -Milliseconds 600
try {
    Start-Process -FilePath $psExe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $main
    ) -WindowStyle Hidden
} catch {
    Say ('[!] 后台没起来，双击桌面「F9开工」也能用：' + $_.Exception.Message)
}

Say ''
Say '  换好了。按快捷键试试，或者在桌面双击图标看效果。'
Say ''
Say '  按任意键关闭...'
try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 3 }
