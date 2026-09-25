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

# ---------------------------------------------------------------- 桌面图标
$appIco = Join-Path $ScriptDir ('skin_' + $SetSkin + '_app.ico')
$setIco = Join-Path $ScriptDir ('skin_' + $SetSkin + '_setup.ico')
if (-not (Test-Path -LiteralPath $appIco)) { $appIco = Join-Path $ScriptDir 'app.ico' }
if (-not (Test-Path -LiteralPath $setIco)) { $setIco = Join-Path $ScriptDir 'setup.ico' }

$main  = Join-Path $ScriptDir 'Start-Workday.ps1'
$gui   = Join-Path $ScriptDir 'Settings-GUI.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

$desktop   = [Environment]::GetFolderPath('Desktop')
$startMenu = [Environment]::GetFolderPath('Programs')

try {
    $ws = New-Object -ComObject WScript.Shell

    $a = $ws.CreateShortcut((Join-Path $desktop 'F9开工.lnk'))
    $a.TargetPath       = $psExe
    $a.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $main + '" -Run'
    $a.WorkingDirectory = $ScriptDir
    $a.WindowStyle      = 7
    $a.Description      = 'F9开工：双击一次，把常用的软件和网页全部打开'
    $a.IconLocation     = $appIco + ',0'
    $a.Save()

    $b = $ws.CreateShortcut((Join-Path $desktop 'F9开工·设置.lnk'))
    $b.TargetPath       = $psExe
    $b.Arguments        = '-NoProfile -ExecutionPolicy Bypass -File "' + $gui + '"'
    $b.WorkingDirectory = $ScriptDir
    $b.WindowStyle      = 1
    $b.Description      = 'F9开工·设置：想打开什么，在这里打勾、粘贴网址'
    $b.IconLocation     = $setIco + ',0'
    $b.Save()

    Say '[OK] 桌面图标已更新'

    if (Test-Path -LiteralPath $startMenu) {
        $c = $ws.CreateShortcut((Join-Path $startMenu 'F9开工.lnk'))
        $c.TargetPath       = $psExe
        $c.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $main + '" -Run'
        $c.WorkingDirectory = $ScriptDir
        $c.WindowStyle      = 7
        $c.IconLocation     = $appIco + ',0'
        $c.Save()

        $d = $ws.CreateShortcut((Join-Path $startMenu 'F9开工·设置.lnk'))
        $d.TargetPath       = $psExe
        $d.Arguments        = '-NoProfile -ExecutionPolicy Bypass -File "' + $gui + '"'
        $d.WorkingDirectory = $ScriptDir
        $d.WindowStyle      = 1
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
            $_.ProcessId -ne $PID -and $_.CommandLine -and
            $_.CommandLine -like '*Start-Workday.ps1*' -and
            $_.CommandLine -notmatch '\-Run|\-Check|\-DryRun|\-TipTest|-SelfTest'
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
