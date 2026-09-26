# =====================================================================
#  F9开工 · 设置  (图形界面)
#
#  双击「设置.bat」打开。改动后点右下角「保存并生效」即可，不用重启电脑。
#
#  命令行参数（一般用不到）：
#     -SelfTest   只做内部自检，把结果写到 logs\gui-selftest.txt，不弹窗口
# =====================================================================

[CmdletBinding()]
param([switch]$SelfTest)

if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# ---------------------------------------------------------------- 藏掉自己的黑框
# 双击桌面图标时，Windows 会先弹出一个黑色控制台窗口。
# 参数里的 -WindowStyle Hidden 有时来不及生效（或者快捷方式是旧的、没带这个参数），
# 黑框就留在屏幕上了。这里从脚本内部再兜一次底。
# 只在"被 -File 当独立进程拉起 + 控制台是我们独占"时才藏，
# 免得把 .bat 里那个正在等输出的 cmd 窗口一起藏掉。
function Hide-OwnConsole {
    try {
        if ([string][Environment]::CommandLine -notmatch '\s-File\s') { return $false }
    } catch { return $false }

    try {
        if (-not ('WorkdayConsole' -as [type])) {
            $cs = @'
using System;
using System.Runtime.InteropServices;

public class WorkdayConsole
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("kernel32.dll")]
    public static extern uint GetConsoleProcessList(uint[] list, uint count);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
            Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
        }

        $hwnd = [WorkdayConsole]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }

        $buf = New-Object 'uint[]' 8
        $cnt = [WorkdayConsole]::GetConsoleProcessList($buf, 8)
        if ($cnt -gt 1) { return $false }

        [void][WorkdayConsole]::ShowWindow($hwnd, 0)
        return $true
    } catch {
        return $false
    }
}

[void](Hide-OwnConsole)


# ---------------------------------------------------------------- 兜底报错
trap {
    $msg = ($_ | Out-String)
    try {
        $d = Join-Path $ScriptDir 'logs'
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $f = Join-Path $d 'gui-error.log'
        [System.IO.File]::AppendAllText($f, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + $msg + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    if (-not $SelfTest) {
        try {
            [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
            [System.Windows.Forms.MessageBox]::Show($msg, 'F9开工 · 设置 出错', 'OK', 'Error') | Out-Null
        } catch { }
    }
    exit 1
}

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

$ConfigPath = Join-Path $ScriptDir 'config.json'
$MainScript = Join-Path $ScriptDir 'Start-Workday.ps1'
$SkinPath   = Join-Path $ScriptDir 'skin.json'
$ArtDir     = Join-Path $ScriptDir 'art'
$LogDir     = Join-Path $ScriptDir 'logs'

# 目录一律走系统 API 取，环境变量缺失也不会出错
$AppDataDir = [Environment]::GetFolderPath('ApplicationData')
if (-not $AppDataDir) { $AppDataDir = $env:APPDATA }
$StartupDir = [Environment]::GetFolderPath('Startup')
if (-not $StartupDir) { $StartupDir = Join-Path $AppDataDir 'Microsoft\Windows\Start Menu\Programs\Startup' }
$StartupVbs = Join-Path $StartupDir 'workday-launcher-daemon.vbs'

$SysRoot = $env:SystemRoot
if (-not $SysRoot) { $SysRoot = 'C:\Windows' }
$PSExe = Join-Path $SysRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PSExe)) { $PSExe = 'powershell.exe' }

$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$Ascii      = New-Object System.Text.ASCIIEncoding

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$SelfTestLines = New-Object System.Collections.ArrayList
function Add-St { param([string]$T) [void]$SelfTestLines.Add($T) }

# ---------------------------------------------------------------- 数据
$script:Apps     = New-Object System.Collections.Generic.List[object]
$script:Urls     = New-Object System.Collections.Generic.List[object]
$script:Browsers = [ordered]@{}
$script:Hotkeys  = @('F9', 'Ctrl+Alt+W')
$script:AppDelay = 150
$script:UrlDelay = 120
# 同一个东西不重复打开（默认开）：软件已经在跑就跳过、清单里填重了只开一次。
# 面板上没给开关（用户要的就是"就别重复打开"，多一个勾反而添乱），
# 但要在这里读进来、存回去 —— 不然从面板点一次「保存并生效」就把它冲掉了。
$script:SkipRunning = $true
# 已经在跑的软件：把它的窗口"叫到最前面"（默认开）。
# 只跳过、不做任何动静的话，三个软件都开着时按 F9 屏幕上完全没有变化，
# 用户的结论就是"按了没反应"（2026-09-23 就是这么被投诉的）。
$script:ActivateRunning = $true
$script:Loading  = $false
$script:SwitchSkinBusy = $false   # 防止换皮肤时反复触发下拉框事件
$script:EvtFired = 0
$script:Detected = $null
$script:ShowTip  = $true     # 开工时要不要出右下角那个进度窗
$script:ShowHeart = $false   # 开工时要不要飘一下表情包/皮肤形象（默认关）
$script:IconAction = 'panel' # 双击桌面图标时：panel=弹出启动台 / run=跳过启动台直接开工
# 开工彩蛋：自己设的语音 + 表情包
$script:StickerPath = ''     # 自定义表情包图片路径（留空 = 用皮肤形象图）
$script:SayText     = ''     # 开工念的一句话（TTS）
$script:SoundPath   = ''     # 开工播放的音频文件（wav/mp3…）
$script:VoiceVolume = 80     # 语音音量 0-100
# 语言状态放在最前面：后面 New-UiFont / T 都要用
$script:Lang    = 'zh'       # 界面语言：zh / en
$script:Dict    = @{}        # 中 -> 英 对照表
$script:UiFontNames = @('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI', 'SimSun')

# ---------------------------------------------------------------- 皮肤
$script:SkinAll  = $null   # skin.json 全文
$script:SkinName = 'minimal'
$script:Skin     = $null   # 当前皮肤对象
$script:SkinKeys = @()     # 可选的皮肤 id
$script:SkinPalette = @{}  # 摊平后的配色表（名 -> #RRGGBB）

# 配色变量：必须先在这里声明一次，函数内的 $script: 赋值才会落到脚本作用域
$script:CBg      = $null
$script:CPanel   = $null
$script:CCard    = $null
$script:CBorder  = $null
$script:CHeadBg  = $null
$script:CHeadTx  = $null
$script:CTitle   = $null
$script:CSub     = $null
$script:CText    = $null
$script:CAccent  = $null
$script:CAccentD = $null
$script:CAccentT = $null
$script:CListBg  = $null
$script:CListTx  = $null
$script:CListGd  = $null
$script:CSelBg   = $null
$script:CSelTx   = $null

# 当前配色（Load-Skin 之后由 Apply-SkinColors 填充）
$script:CAccent  = [System.Drawing.Color]::FromArgb(45, 107, 216)
$script:CPanel   = [System.Drawing.Color]::White
$script:CBorder  = [System.Drawing.Color]::FromArgb(216, 222, 232)
$script:CSelBg   = [System.Drawing.Color]::FromArgb(220, 232, 250)
$script:CListBg  = [System.Drawing.Color]::White
$script:CListTx  = [System.Drawing.Color]::FromArgb(31, 42, 55)
$script:CAccentT = [System.Drawing.Color]::White
$script:CAccentD = [System.Drawing.Color]::FromArgb(31, 85, 176)
$script:CBg      = [System.Drawing.Color]::FromArgb(244, 246, 250)
$script:CCard    = [System.Drawing.Color]::White
$script:CHeadBg  = [System.Drawing.Color]::White
$script:CHeadTx  = [System.Drawing.Color]::FromArgb(31, 42, 55)
$script:CTitle   = [System.Drawing.Color]::FromArgb(31, 42, 55)
$script:CSub     = [System.Drawing.Color]::FromArgb(110, 118, 129)
$script:CText    = [System.Drawing.Color]::FromArgb(31, 42, 55)
$script:CListGd  = [System.Drawing.Color]::FromArgb(230, 234, 242)
$script:CSelTx   = [System.Drawing.Color]::FromArgb(18, 54, 95)

function Load-Skin {
    $script:SkinAll  = $null
    $script:SkinKeys = @()
    $script:SkinName = 'minimal'
    $script:Skin     = $null
    if (-not (Test-Path -LiteralPath $SkinPath)) { return }
    try {
        $raw = Get-Content -LiteralPath $SkinPath -Raw -Encoding UTF8
        $all = $raw | ConvertFrom-Json
        $script:SkinAll = $all
        if ($all.skins) {
            foreach ($p in $all.skins.PSObject.Properties) {
                if ($p.Name -notlike '_*') { $script:SkinKeys += $p.Name }
            }
        }
        $n = [string]$all.skin
        $pick = $null
        if (-not [string]::IsNullOrWhiteSpace($n)) {
            $pick = $all.skins.PSObject.Properties[$n]
            if ($pick) { $pick = $pick.Value }
        }
        if (-not $pick -and $script:SkinKeys.Count -gt 0) {
            $n = $script:SkinKeys[0]
            $pick = $all.skins.PSObject.Properties[$n].Value
        }
        if ($pick) {
            $script:SkinName = $n
            $pick | Add-Member -NotePropertyName '_name'  -NotePropertyValue $n -Force
            $lab = $pick.PSObject.Properties['label']
            if ($lab) {
                $pick | Add-Member -NotePropertyName '_label' -NotePropertyValue ([string]$lab.Value) -Force
            }
            $script:Skin = $pick
        }
    } catch {
        $script:Skin = $null
    }
}

# 取色：显式把配色表传进来，彻底避开作用域问题
function Convert-HexToColor {
    param([string]$Hex, [string]$Fallback)
    $s = $Hex
    if ([string]::IsNullOrWhiteSpace($s)) { $s = $Fallback }
    $h = $s.Trim().TrimStart('#')
    if ($h.Length -ne 6) {
        $h = $Fallback.Trim().TrimStart('#')
        if ($h.Length -ne 6) { $h = '1F2A37' }
    }
    $r = 31; $g = 42; $b = 55
    try { $r = [Convert]::ToInt32($h.Substring(0, 2), 16) } catch { }
    try { $g = [Convert]::ToInt32($h.Substring(2, 2), 16) } catch { }
    try { $b = [Convert]::ToInt32($h.Substring(4, 2), 16) } catch { }
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

# 从配色表里取一个键（表不存在或没有该键就用默认值）
function Pick-Hex {
    param($Palette, [string]$Key, [string]$Default)
    $hex = $null
    try {
        if ($Palette) {
            foreach ($k in $Palette.Keys) {
                if ([string]$k -eq $Key) { $hex = [string]$Palette[$k]; break }
            }
        }
    } catch { $hex = $null }
    if ([string]::IsNullOrWhiteSpace($hex)) { return $Default }
    return $hex
}

# ⚠️ 函数名千万不要叫 SC —— PowerShell 内置别名 sc = Set-Content，别名优先级高于函数，
#    结果 SC 'bg' '#fff' 会被当成 Set-Content -Path 'bg' -Value '#fff'，
#    既拿不到颜色，还会在当前目录生成一堆叫 bg/panel/accent 的垃圾文件。
function Skin-Color {
    param([string]$Key, [string]$Fallback)
    $hex = Pick-Hex $script:SkinPalette $Key $Fallback
    return (Convert-HexToColor $hex $Fallback)
}

# 摊平皮肤配色（返回哈希表，不用 $script: 写全局，避免作用域陷阱）
function New-SkinPalette {
    $palette = @{}
    if ($script:Skin) {
        foreach ($p in $script:Skin.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            $v = [string]$p.Value
            if (-not [string]::IsNullOrWhiteSpace($v)) { $palette[$p.Name] = $v }
        }
    }
    # 注意：必须用逗号包一层，否则 PowerShell 会把哈希表展开成数组
    return ,$palette
}

# 重新读 skin.json 并刷新界面配色（换皮肤时用，不用关窗口）
# 注意：这里一律用顶层变量赋值（不用 $script:）——
#       本函数在每个分支里都直接写 $script:XXX 时，PowerShell 5.1 在部分情况下写不进去，
#       结果是颜色变量全变 $null，界面直接报错。用顶层变量最稳。
function Resolve-SkinColors {
    $Bg      = Skin-Color 'bg'          '#F4F6FA'
    $Panel   = Skin-Color 'panel'       '#FFFFFF'
    $Card    = Skin-Color 'card'        '#FFFFFF'
    $Border  = Skin-Color 'border'      '#D8DEE8'
    $HeadBg  = Skin-Color 'headerBg'    '#FFFFFF'
    $HeadTx  = Skin-Color 'headerText'  '#1F2A37'
    $Title   = Skin-Color 'titleText'   '#1F2A37'
    $Sub     = Skin-Color 'subText'     '#6E7681'
    $Text    = Skin-Color 'text'        '#1F2A37'
    $Accent  = Skin-Color 'accent'      '#2D6BD8'
    $AccentD = Skin-Color 'accentDark'  '#1F55B0'
    $AccentT = Skin-Color 'accentText'  '#FFFFFF'
    $ListBg  = Skin-Color 'listBg'      '#FFFFFF'
    $ListTx  = Skin-Color 'listText'    '#1F2A37'
    $ListGd  = Skin-Color 'listGrid'    '#E6EAF2'
    $SelBg   = Skin-Color 'listSelBg'   '#DCE8FA'
    $SelTx   = Skin-Color 'listSelText' '#12365F'

    $script:CBg      = $Bg
    $script:CPanel   = $Panel
    $script:CCard    = $Card
    $script:CBorder  = $Border
    $script:CHeadBg  = $HeadBg
    $script:CHeadTx  = $HeadTx
    $script:CTitle   = $Title
    $script:CSub     = $Sub
    $script:CText    = $Text
    $script:CAccent  = $Accent
    $script:CAccentD = $AccentD
    $script:CAccentT = $AccentT
    $script:CListBg  = $ListBg
    $script:CListTx  = $ListTx
    $script:CListGd  = $ListGd
    $script:CSelBg   = $SelBg
    $script:CSelTx   = $SelTx
}

function Get-SkinArtPath {
    if (-not $script:Skin) { return $null }
    $a = [string]$script:Skin.art
    if ([string]::IsNullOrWhiteSpace($a)) { return $null }
    $f = Join-Path $ArtDir ($a + '.png')
    if (Test-Path -LiteralPath $f) { return $f }
    return $null
}

# 把按钮刷成皮肤风格：主按钮=实心强调色，普通按钮=描边款
function Style-Btn {
    param($Btn, [switch]$Primary)
    $Btn.FlatStyle = 'Flat'
    $Btn.UseVisualStyleBackColor = $false
    $Btn.Cursor = 'Hand'
    $Btn.Font = $script:UiFont
    if ($Primary) {
        $Btn.BackColor = $script:CAccent
        $Btn.ForeColor = $script:CAccentT
        $Btn.FlatAppearance.BorderSize = 0
        $Btn.FlatAppearance.MouseOverBackColor = $script:CAccentD
        $Btn.FlatAppearance.MouseDownBackColor = $script:CAccentD
        $Btn.Font = $script:UiBold
    } else {
        $Btn.BackColor = $script:CPanel
        $Btn.ForeColor = $script:CAccentD
        $Btn.FlatAppearance.BorderSize = 1
        $Btn.FlatAppearance.BorderColor = $script:CBorder
        $Btn.FlatAppearance.MouseOverBackColor = $script:CSelBg
        $Btn.FlatAppearance.MouseDownBackColor = $script:CSelBg
    }
}

# 统一列表控件外观
function Style-List {
    param($Lv)
    $Lv.BackColor   = $script:CListBg
    $Lv.ForeColor   = $script:CListTx
    $Lv.BorderStyle = 'FixedSingle'
    $Lv.OwnerDraw   = $false
    # 用选中色覆盖系统高亮
    $Lv.Add_DrawColumnHeader({ param($s, $e) })
}

Load-Skin

# 注意：这里不用函数，直接在脚本顶层赋值（函数内 $script: 赋值在部分环境下不可靠）
$script:SkinPalette = New-SkinPalette
Resolve-SkinColors

# 调试：把皮肤解析结果写进日志（出问题时一看就知道）
try {
    $dbg = Join-Path $LogDir '_skin-debug.txt'
    $t = @()
    $t += 'SkinName = ' + $script:SkinName
    $t += 'SkinNull = ' + ($null -eq $script:Skin)
    $t += 'PaletteCount = ' + $script:SkinPalette.Count
    $t += 'CBgNull = ' + ($null -eq $script:CBg)
    if ($script:CBg) { $t += 'CBg = ' + $script:CBg.R + ',' + $script:CBg.G + ',' + $script:CBg.B }
    $t += 'CAccent = ' + $(if ($script:CAccent) { $script:CAccent.R.ToString() + ',' + $script:CAccent.G + ',' + $script:CAccent.B } else { 'NULL' })
    [System.IO.File]::WriteAllLines($dbg, $t, (New-Object System.Text.UTF8Encoding($false)))
} catch { }

# ---------------------------------------------------------------- 小工具
function New-UiFont {
    param([double]$Size = 9.5, [switch]$Bold)
    $st = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $st = [System.Drawing.FontStyle]::Bold }
    foreach ($n in $script:UiFontNames) {
        try {
            $fam = New-Object System.Drawing.FontFamily($n)
            return (New-Object System.Drawing.Font($fam, $Size, $st))
        } catch { }
    }
    return (New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericSansSerif, $Size, $st))
}

# ---------------------------------------------------------------- 语言
# 界面文字全都走 T '键' ，换语言时才翻译得动。
# 中文原文同时也是键名（找不到就原样显示），所以不会出现空白字。
function T {
    param([string]$s)
    if ($script:Lang -eq 'zh') { return $s }
    $hit = $null
    foreach ($k in $script:Dict.Keys) { if ([string]$k -eq $s) { $hit = [string]$script:Dict[$k]; break } }
    if ($null -eq $hit) { return $s }
    return $hit
}

function New-DictEn {
    $d = @{}
    # 标题 / 副标题 / 分组
    $d['F9开工 · 设置'] = 'Workday Launcher'
    $d['F9开工'] = 'Workday Launcher'
    $d['F9开工'] = 'Workday Launcher'
    $d['勾上要打开的东西、填好网址，最后点右下角「保存并生效」—— 不用重启电脑，换皮肤也是当场生效。'] =
          'Tick what to open and fill in the URLs, then hit "Save & Apply" at the bottom right. No reboot needed - theme changes apply instantly.'
    $d['皮肤：'] = 'Theme: '
    $d['简约白'] = 'Minimal'
    $d['墨玉黑'] = 'Ink'
    $d['莫兰迪'] = 'Morandi'
    $d['深海靛'] = 'Indigo'
    # 标题里的 ①②③ 不能省，否则和字典键对不上
    $d['① 要打开的软件（勾上的才会打开，从上往下依次启动）'] = '1. Apps to open (ticked ones only, launched top to bottom)'
    $d['② 要打开的网页（勾上的才会打开，按顺序打开）'] = '2. Web pages to open (ticked ones only, in order)'
    $d['已选'] = 'selected:'
    $d['个'] = ''
    $d['③ 其它设置'] = '3. Other settings'
    # 一键收工
    $d['收工快捷键'] = 'Quit hotkey'
    $d['倒计时'] = 'Countdown'
    $d['秒'] = 's'
    $d['（窗口里显示：关机 / 重启 / 睡眠）'] = '(the window shows: Shut down / Restart / Sleep)'
    $d['在桌面放一个「F9收工」图标'] = 'Put a "F9 Finish" icon on the desktop'
    $d['默认 Ctrl+Alt+Q（Q = quit）。按一下会弹出「关机 / 重启 / 睡眠」的窗口，带倒计时可以取消。清空这一格 = 关掉收工功能'] =
          'Default Ctrl+Alt+Q (Q = quit). It pops up a Shut down / Restart / Sleep window with a cancellable countdown. Clear this box to turn the feature off.'
    $d['点了「关机 / 重启 / 睡眠」之后等这么多秒才真的执行；这段时间里点【取消】或按 Esc 就能马上停下'] =
          'How many seconds to wait after you pick Shut down / Restart / Sleep. You can still click Cancel or press Esc during the countdown.'
    $d['在桌面上生成一个「F9收工」的图标，双击它就能弹出收工窗口（跟快捷键是同一个功能，后台没在跑也能用）'] =
          'Put an "F9 Finish" icon on the desktop. Double-click it for the shut-down window (same as the hotkey, and it works even if the background helper is not running).'
    $d['正在生成桌面图标…'] = 'Creating the desktop icon…'
    $d['桌面已经放好「F9收工」图标了，双击就能用（拖到任务栏也行）'] =
          'The "F9 Finish" desktop icon is ready - double-click it (or drag it to the taskbar).'
    $d['生成桌面图标失败：'] = 'Could not create the desktop icon: '

    # 软件分组
    $d['添加软件'] = 'Add app'
    $d['修改'] = 'Edit'
    $d['删除'] = 'Delete'
    $d['上移'] = 'Up'
    $d['下移'] = 'Down'
    $d['软件名称'] = 'Name'
    $d['位置'] = 'Location'
    $d['共 0 个'] = '0 total'

    # 网页分组
    $d['添加'] = 'Add'
    $d['粘贴网址，比如 taobao.com（会自动补 https）'] = 'Paste a URL, e.g. taobao.com (https is added automatically)'
    $d['名称（随便写，方便自己认）'] = 'Label (anything you recognise)'
    $d['给它起个名字（可以留空，不填就用网址当名字）'] =
          'Give it a label (blank = the site name is used)'
    $d['添加到列表'] = 'Add to list'
    $d['打开'] = 'On'
    $d['名称'] = 'Label'
    $d['网址'] = 'URL'
    $d['列：名称'] = 'Label'
    $d['列：网址'] = 'URL'

    # 其它设置
    $d['快捷键'] = 'Hotkey'
    $d['（下面下拉选，也可以自己输入）'] = '(pick below, or type your own)'
    $d['软件间隔'] = 'App gap'
    $d['网页间隔'] = 'Page gap'
    $d['毫秒'] = 'ms'
    $d['界面语言'] = 'Language'
    $d['皮肤'] = 'Theme'
    $d['开机自动在后台待命（推荐勾上）'] = 'Stay in background after logon (recommended)'
    $d['开工时显示进度窗'] = 'Show progress window'
    # 说明文字（鼠标停在上面才出现）
    $d['勾上：按快捷键后右下角出进度窗，进度条一直流动，全部开完几秒后自己收起。不勾：只在后台安静地开，什么都不显示。'] = 'On: a progress window shows at the bottom-right while launching, then closes itself. Off: opens everything silently in the background.'
    $d['开完一个软件、开下一个之前等多久（毫秒）。这个数直接加到总耗时上：3 个软件就有 2 个间隔。默认 150 够稳了；想最快就设 0。'] = 'How long to wait before opening the next app (ms). This adds straight to the total: 3 apps = 2 gaps. 150 is the default; use 0 for the fastest launch.'
    $d['开完一个网页、开下一个之前等多久（毫秒）。网页交给浏览器开，通常更快，默认 120；设 0 就一起发出去。'] = 'How long to wait before opening the next page (ms). Browsers open fast, so 120 is the default; use 0 to fire them together.'
    $d['开工飘一下形象'] = 'Animate on launch'
    $d['打开程序文件夹'] = 'Open folder'
    $d['查看运行记录'] = 'View log'
    $d['卸载'] = 'Uninstall'

    # 底部按钮
    $d['立即开工一次'] = 'Open now'
    $d['试运行检查'] = 'Test run'
    $d['保存并生效'] = 'Save & Apply'

    # 气泡
    $d['只检查不改动：看快捷键能不能用、软件能不能找到，不会真的打开任何东西'] =
          'Check only: verifies the hotkey and that every app can be found. Nothing is actually opened.'
    $d['按一下就能开工。可以填两个，中间用 / 分开（例如 F9 / Ctrl+Alt+W），两个都能用。单独一个 F9 容易被别的软件抢走，建议保留一个组合键。'] =
          'Press once to open everything. You can enter two, separated by "/" (e.g. F9 / Ctrl+Alt+W) - both will work. A bare F9 is easily grabbed by other apps, so keeping a combo key is recommended.'
    $d['立刻按清单把软件和网页打开一遍（就是按快捷键的效果）'] =
          'Open everything in the list right now - same as pressing the hotkey.'
    $d['勾上：每次开机后自动在后台待命，随时可以按快捷键'] =
          'When ticked, the launcher waits quietly in the background after every logon.'
    $d['勾上的才会打开；不想要的点「删除」移出列表'] =
          'Only ticked items open. Use "Delete" to remove an entry.'
    $d['勾上的才会打开；网址要带 http:// 或 https://'] =
          'Only ticked items open. URLs need http:// or https://'
    $d['勾上：开工时屏幕上飘一下当前皮肤的形象图，一秒就过（小彩蛋，默认不勾）'] =
          'When ticked, the current theme character drifts across the screen for a second on launch. Off by default.'
    $d['换界面语言，只是界面文字变了，清单内容不动'] =
          'Switch the interface language. Only labels change - your list is untouched.'
    $d['选一套配色，选完立刻生效，不用点保存也不用重启'] =
          'Pick a colour theme. It applies the moment you choose it - no save, no restart.'

    # 提示条
    $d['后台正在待命 —— 按 '] = 'Waiting in the background - press '
    $d[' 就能开工'] = ' to open everything'
    $d[' 就能开工（按下去右下角会闪一下「开工中」）'] =
          ' to open everything (a small "starting..." hint flashes at the bottom right)'
    $d['后台刚才没在运行，已经自动帮你启动了 —— 现在按 '] =
          'The background process was not running, so it has been started for you. Now press '
    $d['后台没在运行 —— 点「保存并生效」会自动帮你启动'] =
          'Not running - click "Save & Apply" and it will be started for you'
    $d['没找到 config.json（点「保存并生效」会自动生成一份）'] =
          'config.json not found (click "Save & Apply" to create one)'
    $d['config.json 内容有错，已改用默认设置（点「保存并生效」会重新生成）'] =
          'config.json has an error, defaults loaded (Save & Apply rewrites it)'

    # 应用内运行提示
    $d['已保存。'] = 'Saved. '
    $d['已保存，'] = 'Saved. '
    $d['皮肤已换成「'] = 'Theme switched to "'
    $d['」（桌面图标也换了）；'] = '" (desktop icons updated); '
    $d['关掉本窗口重新打开，就能看到新皮肤。'] = 'close and reopen this window to see it.'
    $d['皮肤已换成「'] = 'Skin changed to "'
    $d['」，已经生效了（按 '] = '" - applied instantly (pressing '
    $d[' 开工也是这个风格）'] = ' will use this style too)'
    $d['」，但没写进 skin.json，关掉重开会变回去'] = '" - but skin.json was not written; it will revert after restart'
    $d['换皮肤出错：'] = 'Skin switch failed: '
    $d['」（桌面图标也换了）；'] = '" (desktop icons updated); '
    $d['现在按 '] = 'Now press '
    $d[' 就是新皮肤的进度窗了'] = ' to see the new skin in the progress window'
    $d['皮肤没换成功；'] = 'Theme was not switched; '
    $d['开机自启已打开；'] = 'Auto-start on; '
    $d['开机自启没设置成功；'] = 'Auto-start could not be set; '
    $d['开机自启已关掉；'] = 'Auto-start off; '
    $d['后台已重新启动 —— 现在按 '] = 'Background restarted - now press '
    $d[' 试试'] = ' to try it'
    $d['但后台没启动成功，重启电脑后会自动启动'] =
          'but the background process failed to start; it will start on next logon'
    $d['关掉后开机就不会自动待命了（现在按快捷键还是能用）'] =
          'Once off, it will not wait in the background after logon (the hotkey still works now)'
    $d['不勾选 = 以后开机不再自动待命（改完记得点「保存并生效」）'] =
          'Unticked = no more background waiting after logon (remember to Save & Apply)'
    $d['已添加：'] = 'Added: '
    $d[' —— 别忘了点「保存并生效」'] = ' - remember to click "Save & Apply"'
    $d['先在左边列表里点一下要修改的那一行'] = 'Click the row you want to edit first'
    $d['已修改 —— 别忘了点「保存并生效」'] = 'Updated - remember to click "Save & Apply"'
    $d['先在左边列表里点一下要删除的那一行'] = 'Click the row you want to delete first'
    $d['已从清单里删除 —— 别忘了点「保存并生效」'] = 'Removed from the list - remember to click "Save & Apply"'
    $d['先点一下要移动的那一行'] = 'Click the row you want to move first'
    $d['先把网址粘贴到上面那个框里'] = 'Paste a URL into the box above first'
    $d['这个网址已经在列表里了：'] = 'That URL is already in the list: '
    $d['已添加网页：'] = 'Added page: '
    $d[' —— 别忘了点「保存并生效」'] = ' - remember to click "Save & Apply"'
    $d['先点一下要删除的那一行'] = 'Click the row you want to delete first'
    $d['已删除 —— 别忘了点「保存并生效」'] = 'Removed - remember to click "Save & Apply"'
    $d['正在检查，请稍等几秒...'] = 'Checking, one moment...'
    $d['检查时出错了：'] = 'Check failed: '
    $d['没有拿到检查结果。请点「查看运行记录」看看日志。'] =
          'No result came back. Click "View log" to see what happened.'
    $d['【怎么看】'] = 'How to read this:'
    $d['快捷键那一行写「✓ 快捷键可用」= 能用；'] = 'A "✓ hotkey available" line means it works;'
    $d['写「✗ ...被别的程序占用」= 换一个快捷键（在下面「快捷键」框里改）；'] =
          '"✗ ... taken by another program" means pick a different one in the Hotkey box;'
    $d['每一行「软件: 名称 -> 路径」= 找到了；写「跳过软件(没找到)」= 这个要重新填路径。'] =
          'Each "软件: name -> path" line means the app was found; "skipped (not found)" means re-enter its path.'
    $d['试运行检查结果（没有真的打开任何东西）'] = 'Test run result (nothing was actually opened)'
    $d['正在按清单打开...'] = 'Opening your list...'
    $d['已经按界面上的清单打开了 —— 看看屏幕上有没有'] =
          'Done - everything in the list has been launched'
    $d['打开失败：'] = 'Failed to open: '
    $d['检查完成（已顺手把界面上的清单保存好，但没有真的打开任何东西）'] =
          'Check finished. Your list was saved, but nothing was opened.'
    $d['请先选中一个网页'] = 'Please select a web page first'
    $d['请先选中一个软件'] = 'Please select an app first'
    $d['确定要卸载吗？'] = 'Uninstall now?'
    $d['F9开工 · 卸载'] = 'Workday Launcher - Uninstall'
    $d['（开工时不显示进度窗，只安静地打开东西）'] = ' (no progress window - it just opens things quietly)'
    $d['开工时右下角会出进度窗，进度条一直流动到全部开完'] = 'A progress window will appear at the bottom-right while launching'
    $d['开工时不显示进度窗，只在后台安静地打开东西（改完记得点「保存并生效」）'] =
          'No progress window - it just opens things quietly (remember to Save & Apply)'
    $d['已经卸载了。程序文件夹还在，不需要的话可以直接删掉：'] =
          'Uninstalled. The program folder is kept in case you need it: '
    $d['双击桌面图标'] = 'Double-click the desktop icon'
    $d['打开启动台'] = 'Open the launch pad'
    $d['直接开工'] = 'Start right away'
    $d['双击桌面上「F9开工」图标时干什么：弹出启动台（点中间木鱼才开工），还是跳过启动台直接开工。改完点「保存并生效」'] =
          'What the desktop "Workday Launcher" icon does: show the launch pad (click the wooden fish to start), or skip the launch pad and start straight away. Click "Save & Apply" to take effect.'
    $d['勾上要打开的东西、填好网址，点右下角「保存并生效」。要马上开工就点【立即开工一次】，或者直接按快捷键 —— 换皮肤也是当场生效。'] =
          'Tick what to open and fill in the URLs, then hit "Save & Apply". To start now, click "Start now" - or just press your hotkey. Skin changes apply instantly too.'
    $d['保存失败：'] = 'Save failed: '

    # ---------------- ④ 开工彩蛋 ----------------
    $d['↘ 想开工时飘表情包 / 放语音，在下面「④ 开工彩蛋」里设'] =
          'v  To float a sticker or play a sound on launch, set it in "4. Launch extras" below'
    $d['④ 开工彩蛋（可选）：开工时飘自己的表情包 / 放自己的语音'] =
          '4. Launch extras (optional): float your own sticker / play your own voice'
    $d['④ 开工彩蛋（可选）'] = '4. Launch extras (optional)'
    $d['开工时飘一下表情包'] = 'Float a sticker on launch'
    $d['选图片…'] = 'Pick image...'
    $d['用皮肤形象'] = 'Use theme art'
    $d['说一句话'] = 'Say a line'
    $d['音量'] = 'Volume'
    $d['清空'] = 'Clear text'
    $d['放音频'] = 'Play audio'
    $d['选音频文件…'] = 'Pick audio...'
    $d['清除'] = 'Remove'
    $d['试听一下'] = 'Preview it'
    $d['（没选：飘图时用当前皮肤的形象图）'] = '(none: the current theme art will float instead)'
    $d['（没选音频：就念上面那句话）'] = '(none: it will speak the line above instead)'
    $d['当前：'] = 'Current: '
    $d['挑一张图片当开工表情包'] = 'Pick an image to float on launch'
    $d['图片'] = 'Images'
    $d['音频'] = 'Audio'
    $d['所有文件'] = 'All files'
    $d['表情包已选好：'] = 'Sticker selected: '
    $d[' —— 点「试听一下」看看效果'] = ' - hit "Preview it" to see how it looks'
    $d['选图片出错：'] = 'Could not pick the image: '
    $d['已经改回用当前皮肤的形象图了（记得点「保存并生效」）'] =
          'Back to the current theme art (remember to Save & Apply)'
    $d['那句话已清空（记得点「保存并生效」）'] = 'The line is cleared (remember to Save & Apply)'
    $d['选一段音频当开工音'] = 'Pick an audio file to play on launch'
    $d['音频已选好：'] = 'Audio selected: '
    $d[' —— 点「试听一下」听听'] = ' - hit "Preview it" to listen'
    $d['选音频出错：'] = 'Could not pick the audio: '
    $d['音频已清除，改回用「说一句话」（记得点「保存并生效」）'] =
          'Audio removed - it will speak the line again (remember to Save & Apply)'
    $d['什么都还没设 —— 先勾上「开工时飘一下表情包」，或者写一句话 / 选段音频'] =
          'Nothing set yet - tick "Float a sticker on launch", or type a line / pick an audio file first'
    $d['正在试：飘表情包 + 放语音（不会打开任何软件。设置已顺手保存）'] =
          'Previewing: floating the sticker and playing the sound (no apps are opened. Your settings were saved)'
    $d['试听失败：'] = 'Preview failed: '

    # 开工彩蛋的提示气泡
    $d['勾上：开工时屏幕上飘一下表情包（没选图就用当前皮肤的形象图），一秒多就过。默认不勾，不打扰。'] =
          'When ticked, your sticker floats across the screen on launch (or the theme art if you picked none). It lasts about a second. Off by default.'
    $d['挑一张自己的图当表情包：png / jpg / bmp / gif 都行（gif 只会动第一帧）'] =
          'Pick your own image: png / jpg / bmp / gif all work (a gif will only show its first frame)'
    $d['清掉自己选的图，飘图时改回用当前皮肤的形象图'] =
          'Clear your image and fall back to the current theme art'
    $d['打一句话，开工时让电脑自己念出来。中文也能念，不用装任何软件'] =
          'Type a line and Windows will read it out on launch. Chinese works too, nothing to install'
    $d['清空这句话（清空后就不念了）'] = 'Clear the line (it will not be spoken)'
    $d['选一段自己的音频当开工音：wav / mp3 / wma / m4a。选了就优先放它，不再念上面那句话'] =
          'Pick your own audio file: wav / mp3 / wma / m4a. It takes priority over the spoken line'
    $d['清掉音频文件，改回用上面那句话'] = 'Remove the audio file and speak the line instead'
    $d['语音音量 0-100。音频文件走系统音量，这个只管"念一句话"'] =
          'Voice volume 0-100. Audio files use the system volume; this only applies to the spoken line'
    $d['马上试一下：飘一次表情包 + 放一次语音（不会打开任何软件。会顺手把当前设置保存下来）'] =
          'Preview now: float the sticker once and play the sound once (no apps are opened. Your settings get saved along the way)'
    return $d
}

# ★ 必须在这里真正调用一次，字典才会装进 $script:Dict
#   （之前漏了这一步，导致切英文只是字号变了、文字没翻译）
$script:Dict = New-DictEn

function Esc {
    param([string]$s)
    if ($null -eq $s) { return '' }
    $t = [string]$s
    $t = $t -replace "[`r`n`t]", ' '
    $t = $t -replace '\\', '\\'
    $t = $t -replace '"', '\"'
    return $t
}

function Get-LogPath { return (Join-Path $LogDir ('launcher-' + (Get-Date -Format 'yyyy-MM') + '.log')) }

# 从 JSON 对象里安全读一个开关（缺字段/null/"false"/0 都算关）
function Read-Bool {
    param($Obj, [string]$Key, [bool]$Default = $true)
    if (-not $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Key]
    if (-not $p) { return $Default }
    $v = $p.Value
    if ($null -eq $v) { return $Default }
    if ($v -is [bool]) { return [bool]$v }
    $s = ([string]$v).Trim().ToLowerInvariant()
    if ($s -eq 'false' -or $s -eq '0' -or $s -eq 'no' -or $s -eq 'off') { return $false }
    return $true
}

# 从 JSON 对象里安全读一个字符串
function Read-Str {
    param($Obj, [string]$Key, [string]$Default = '')
    if (-not $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Key]
    if (-not $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    $s = [string]$p.Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    return $s.Trim()
}

# ---------------------------------------------------------------- 读配置
function Load-Config {
    $script:Apps.Clear()
    $script:Urls.Clear()
    $script:Browsers = [ordered]@{}
    $script:Hotkeys  = @('F9', 'Ctrl+Alt+W')
    # 收工快捷键：默认 Ctrl+Alt+Q（Q = quit）。
    # ⚠️ 这里跟开工键的规矩不一样：开工键写空会退回 F9，而收工键【写空 = 关掉收工功能】。
    # 所以默认值只能是"字段不存在"时才用，不能靠 Read-Str（它把空串也当没写）。
    $script:QuitHotkey  = 'Ctrl+Alt+Q'
    $script:QuitSeconds = 60
    $script:QuitActions = @('shutdown', 'restart', 'sleep')
    $script:AppDelay = 150
    $script:UrlDelay = 120
    $script:SkipRunning = $true
    $script:ActivateRunning = $true
    $script:ShowTip  = $true
    $script:ShowHeart = $false
    $script:IconAction = 'panel'
    $script:StickerPath = ''
    $script:SayText     = ''
    $script:SoundPath   = ''
    $script:VoiceVolume = 80
    $script:Lang     = 'zh'

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return '没找到 config.json（点「保存并生效」会自动生成一份）' }

    $cfg = $null
    try { $cfg = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json }
    catch { return 'config.json 内容有错，已改用默认设置（点「保存并生效」会重新生成）' }

    if ($cfg.PSObject.Properties['hotkeys']) { $script:Hotkeys = @($cfg.hotkeys | ForEach-Object { [string]$_ }) }
    # 收工快捷键：字段"在"就用它的值，哪怕是空串（空串是"关掉这个功能"的意思）
    if ($cfg.PSObject.Properties['shutdownHotkey']) {
        $script:QuitHotkey = [string]$cfg.shutdownHotkey
    }
    if ($cfg.PSObject.Properties['shutdownSeconds']) {
        try { $script:QuitSeconds = [int]$cfg.shutdownSeconds } catch { }
    }
    if ($cfg.PSObject.Properties['shutdownActions']) {
        $qa = @()
        foreach ($qv in @($cfg.shutdownActions)) {
            $qs = ([string]$qv).Trim().ToLowerInvariant()
            if ((@('shutdown', 'restart', 'sleep') -contains $qs) -and -not ($qa -contains $qs)) { $qa += $qs }
        }
        # 写错单词就当没写（给全三个），总比弹一个空窗口强
        if ($qa.Count -gt 0) { $script:QuitActions = $qa }
    }
    if ($cfg.PSObject.Properties['delayAfterAppMs']) { $script:AppDelay = [int]$cfg.delayAfterAppMs }
    if ($cfg.PSObject.Properties['delayAfterUrlMs']) { $script:UrlDelay = [int]$cfg.delayAfterUrlMs }
    $script:SkipRunning = Read-Bool $cfg 'skipIfRunning' $true
    $script:ActivateRunning = Read-Bool $cfg 'activateIfRunning' $true
    $script:ShowTip = Read-Bool $cfg 'showTipAfterRun' $true
    $script:ShowHeart = Read-Bool $cfg 'showHeartOnRun' $false
    $ia = Read-Str $cfg 'iconAction' 'panel'
    if ($ia -ieq 'run') { $script:IconAction = 'run' } else { $script:IconAction = 'panel' }
    $script:StickerPath = Read-Str $cfg 'stickerPath' ''
    $script:SayText     = Read-Str $cfg 'sayText' ''
    $script:SoundPath   = Read-Str $cfg 'soundPath' ''
    $script:VoiceVolume = [int](Read-Str $cfg 'voiceVolume' '80')
    if ($script:VoiceVolume -lt 0)   { $script:VoiceVolume = 0 }
    if ($script:VoiceVolume -gt 100) { $script:VoiceVolume = 100 }
    $lg = Read-Str $cfg 'lang' 'zh'
    if ($lg -ieq 'en') { $script:Lang = 'en' } else { $script:Lang = 'zh' }

    foreach ($a in @($cfg.apps)) {
        if ($null -eq $a) { continue }
        $n = ''; $p = ''
        if ($a.PSObject.Properties['name'] -and $a.name) { $n = [string]$a.name }
        if ($a.PSObject.Properties['path'] -and $a.path) { $p = [string]$a.path }
        if (-not $n -and -not $p) { continue }
        if (-not $n) { $n = $p }
        $en = $true
        if ($a.PSObject.Properties['enabled']) { $en = [bool]$a.enabled }
        $script:Apps.Add([pscustomobject]@{ Name = $n; Path = $p; Enabled = $en })
    }

    foreach ($u in @($cfg.urls)) {
        if ($null -eq $u) { continue }
        $n = ''; $v = ''
        if ($u.PSObject.Properties['name'] -and $u.name) { $n = [string]$u.name }
        if ($u.PSObject.Properties['url'] -and $u.url) { $v = [string]$u.url }
        elseif ($u.PSObject.Properties['path'] -and $u.path) { $v = [string]$u.path }
        if (-not $v) { continue }
        if (-not $n) { $n = $v }
        $en = $true
        if ($u.PSObject.Properties['enabled']) { $en = [bool]$u.enabled }
        $script:Urls.Add([pscustomobject]@{ Name = $n; Url = $v; Enabled = $en })
    }

    if ($cfg.PSObject.Properties['browsers'] -and $cfg.browsers) {
        foreach ($p in $cfg.browsers.PSObject.Properties) { $script:Browsers[$p.Name] = [string]$p.Value }
    }
    return ''
}

# ---------------------------------------------------------------- 写配置
function Build-ConfigText {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('  "_说明": "这个文件由「F9开工 · 设置」自动生成，建议用图形界面改，手改容易出错。",')
    [void]$sb.AppendLine('')

    $hk = @()
    foreach ($h in $script:Hotkeys) { $hk += ('"' + (Esc $h) + '"') }
    if ($hk.Count -eq 0) { $hk += '"F9"' }
    [void]$sb.AppendLine('  "hotkeys": [' + ($hk -join ', ') + '],')
    [void]$sb.AppendLine('')
    # 收工快捷键。【写空 = 关掉收工功能】这一点要在说明里写清楚，
    # 不然用户看到面板里空格是空的、以为坏了。
    [void]$sb.AppendLine('  "_说明_shutdownHotkey": "收工快捷键：按一下弹出「关机 / 重启 / 睡眠」的窗口，带倒计时、随时能取消。留空字符串 = 关掉收工功能（想用默认的 Ctrl+Alt+Q 就把这一行删掉，别写空）",')
    [void]$sb.AppendLine('  "shutdownHotkey": "' + (Esc $script:QuitHotkey) + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_shutdownSeconds": "收工倒计时秒数（5-600）：点了「关机 / 重启 / 睡眠」之后等这么多秒才真的执行，这段时间里点【取消】或按 Esc 就能马上停下",')
    [void]$sb.AppendLine('  "shutdownSeconds": ' + [int]$script:QuitSeconds + ',')
    [void]$sb.AppendLine('')
    $qa = @()
    foreach ($qc in @($script:QuitActions)) { $qa += ('"' + (Esc ([string]$qc)) + '"') }
    if ($qa.Count -eq 0) { $qa = @('"shutdown"', '"restart"', '"sleep"') }
    [void]$sb.AppendLine('  "_说明_shutdownActions": "收工窗口里显示哪几个按钮，从 shutdown(关机) / restart(重启) / sleep(睡眠) 里挑。默认三个都显示",')
    [void]$sb.AppendLine('  "shutdownActions": [' + ($qa -join ', ') + '],')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "delayAfterAppMs": ' + ([int]$script:AppDelay) + ',')
    [void]$sb.AppendLine('  "delayAfterUrlMs": ' + ([int]$script:UrlDelay) + ',')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_skipIfRunning": "true = 同一个东西不重复打开：软件已经在运行就跳过（不开第二个），清单里填重了也只开一次。改成 false 就会每次都硬开一遍",')
    [void]$sb.AppendLine('  "skipIfRunning": ' + $(if ($script:SkipRunning) { 'true' } else { 'false' }) + ',')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_activateIfRunning": "true = 软件已经在运行时，不再开第二个，而是把它已经开着的窗口叫到最前面（这样按了快捷键屏幕上一定有反应）。改成 false 就只跳过、不叫窗口",')
    [void]$sb.AppendLine('  "activateIfRunning": ' + $(if ($script:ActivateRunning) { 'true' } else { 'false' }) + ',')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_showTipAfterRun": "false = 开工时不显示右下角那个进度窗，只在后台默默干活（进度窗会一直流动到全部开完，然后自己收起）",')
    [void]$sb.AppendLine('  "showTipAfterRun": ' + $(if ($script:ShowTip) { 'true' } else { 'false' }) + ',')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_showHeartOnRun": "true = 开工时屏幕上飘一下表情包（默认 false，不打扰）",')
    [void]$sb.AppendLine('  "showHeartOnRun": ' + $(if ($script:ShowHeart) { 'true' } else { 'false' }) + ',')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_stickerPath": "自定义表情包图片（png/jpg/bmp/gif。留空 = 用当前皮肤的形象图）",')
    [void]$sb.AppendLine('  "stickerPath": "' + (Esc $script:StickerPath) + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_sayText": "开工时让系统语音念这句话（不用装任何软件）。留空 = 不念",')
    [void]$sb.AppendLine('  "sayText": "' + (Esc $script:SayText) + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_soundPath": "开工时播放的音频文件（wav/mp3/wma/m4a）。填了就优先放它，不再念上面那句",')
    [void]$sb.AppendLine('  "soundPath": "' + (Esc $script:SoundPath) + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_voiceVolume": "语音音量 0-100（音频文件走系统音量，这里只管系统语音）",')
    [void]$sb.AppendLine('  "voiceVolume": ' + [int]$script:VoiceVolume + ',')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_lang": "界面语言：zh=中文 / en=English，只影响界面文字，不影响清单",')
    [void]$sb.AppendLine('  "lang": "' + $script:Lang + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  "_说明_iconAction": "双击桌面「F9开工」图标时的动作：panel=弹出启动台，点木鱼才开工（推荐）/ run=跳过启动台直接开工",')
    [void]$sb.AppendLine('  "iconAction": "' + $script:IconAction + '",')
    [void]$sb.AppendLine('')

    # ---- 软件 ----
    $rows = @()
    foreach ($a in $script:Apps) {
        $o = '    { "name": "' + (Esc $a.Name) + '", "path": "' + (Esc $a.Path) + '"'
        if (-not $a.Enabled) { $o += ', "enabled": false' }
        $o += ' }'
        $rows += $o
    }
    if ($rows.Count -eq 0) {
        [void]$sb.AppendLine('  "apps": [],')
    } else {
        [void]$sb.AppendLine('  "apps": [')
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $sep = ','
            if ($i -eq $rows.Count - 1) { $sep = '' }
            [void]$sb.AppendLine($rows[$i] + $sep)
        }
        [void]$sb.AppendLine('  ],')
    }
    [void]$sb.AppendLine('')

    # ---- 网页 ----
    $rows = @()
    foreach ($u in $script:Urls) {
        $o = '    { "name": "' + (Esc $u.Name) + '", "url": "' + (Esc $u.Url) + '", "browser": "default"'
        if (-not $u.Enabled) { $o += ', "enabled": false' }
        $o += ' }'
        $rows += $o
    }
    if ($rows.Count -eq 0) {
        [void]$sb.AppendLine('  "urls": [],')
    } else {
        [void]$sb.AppendLine('  "urls": [')
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $sep = ','
            if ($i -eq $rows.Count - 1) { $sep = '' }
            [void]$sb.AppendLine($rows[$i] + $sep)
        }
        [void]$sb.AppendLine('  ],')
    }
    [void]$sb.AppendLine('')

    # ---- 浏览器 ----
    if ($script:Browsers.Count -eq 0) {
        [void]$sb.AppendLine('  "browsers": {}')
    } else {
        [void]$sb.AppendLine('  "browsers": {')
        $keys = @($script:Browsers.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $sep = ','
            if ($i -eq $keys.Count - 1) { $sep = '' }
            [void]$sb.AppendLine('    "' + (Esc $keys[$i]) + '": "' + (Esc ([string]$script:Browsers[$keys[$i]])) + '"' + $sep)
        }
        [void]$sb.AppendLine('  }')
    }

    [void]$sb.AppendLine('}')
    return $sb.ToString()
}

function Save-Config {
    $text = Build-ConfigText
    [System.IO.File]::WriteAllText($ConfigPath, $text, $Utf8NoBom)
}

# 把界面上选的皮肤写回 skin.json（只改 skin 这一行，其他原样保留）
function Save-Skin {
    param([string]$SkinId)
    if ([string]::IsNullOrWhiteSpace($SkinId)) { return $false }
    if (-not (Test-Path -LiteralPath $SkinPath)) { return $false }
    if ($script:SkinKeys -notcontains $SkinId) { return $false }
    if ($SkinId -eq $script:SkinName) { return $false }
    try {
        $raw = Get-Content -LiteralPath $SkinPath -Raw -Encoding UTF8
        $new = [System.Text.RegularExpressions.Regex]::Replace(
            $raw, '"skin"\s*:\s*"[^"]*"', ('"skin": "' + $SkinId + '"'), 1)
        [System.IO.File]::WriteAllText($SkinPath, $new, $Utf8NoBom)
        return $true
    } catch { return $false }
}

# 换桌面/开始菜单图标（换皮肤时顺手做）
function Update-ShortcutIcons {
    param([string]$SkinId)
    # 【2026-09-26 修】桌面上那个「F9开工」是敲木鱼的启动台，图标必须用 hub.ico（木鱼）。
    # 原来这里一律用 skin_<id>_app.ico（一张闪电图），所以只要保存一次皮肤，
    # 桌面上那只木鱼就被盖回闪电 —— 用户看到的现象就是"图标还是旧的"。
    # 规则与 Install.ps1 的 2c / 2h 段一致：有 hub.ico 就用它，没有才回落到皮肤图标。
    $appIco = Join-Path $ScriptDir ('skin_' + $SkinId + '_app.ico')
    $setIco = Join-Path $ScriptDir ('skin_' + $SkinId + '_setup.ico')
    $hubIco = Join-Path $ScriptDir 'hub.ico'
    if (Test-Path -LiteralPath $hubIco) { $appIco = $hubIco }
    elseif (-not (Test-Path -LiteralPath $appIco)) { $appIco = Join-Path $ScriptDir 'app.ico' }
    if (-not (Test-Path -LiteralPath $setIco)) { $setIco = Join-Path $ScriptDir 'setup.ico' }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $sm      = [Environment]::GetFolderPath('Programs')
    try {
        $ws = New-Object -ComObject WScript.Shell
        foreach ($d in @($desktop, $sm)) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            $p1 = Join-Path $d 'F9开工.lnk'
            if (Test-Path -LiteralPath $p1) {
                $s = $ws.CreateShortcut($p1)
                $s.IconLocation = $appIco + ',0'
                $s.Save()
            }
            $p2 = Join-Path $d 'F9开工·设置.lnk'
            if (Test-Path -LiteralPath $p2) {
                $s = $ws.CreateShortcut($p2)
                $s.IconLocation = $setIco + ',0'
                $s.Save()
            }
        }
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- 后台进程
# 只找「常驻待命」那个进程。
# 注意要排掉带参数的临时进程（-Run / -Sequence / -Check 这些），
# 它们干完活就自己退了 —— 尤其是 -Sequence（正在开软件的那次），
# 要是被当成后台给停掉，用户刚要打开的东西就半路断了。
function Get-DaemonProcs {
    $r = @()
    try {
        $r = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
               Where-Object {
                   $_.CommandLine -and
                   $_.CommandLine -like '*Start-Workday.ps1*' -and
                   $_.CommandLine -notmatch '\-(Sequence|Run|Check|DryRun|TipTest|FanTest|Main|SimTrigger|NoTip|ShowTip|Shutdown|QuitTest|QuitShot)\b'
               })
    } catch { }
    return $r
}

# 后台在不在？问那个互斥体最快（几毫秒），比查进程列表快得多。
$script:DaemonMutexName = 'Local\WorkdayLauncherDaemon'
function Test-DaemonAlive {
    $m = $null
    try {
        $m = [System.Threading.Mutex]::OpenExisting($script:DaemonMutexName)
        return $true
    } catch [System.UnauthorizedAccessException] {
        return $true      # 打不开但不等于不存在（权限问题），当成在跑
    } catch {
        return $false
    } finally {
        if ($m) { try { $m.Dispose() } catch { } }
    }
}

# 后台没在跑就拉起来，然后等它把快捷键注册好（最多等 ~1.5 秒）。
# 面板打开时用：这样一进来就能显示准确的"后台正在待命"，
# 而不是让用户干看着一句"没在运行"还要自己想办法。
function Ensure-DaemonForPanel {
    if (Test-DaemonAlive) { return $true }
    [void](Start-Daemon)
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-DaemonAlive) { return $true }
    }
    return $false
}

function Stop-Daemon {
    $n = 0
    foreach ($p in @(Get-DaemonProcs)) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $n++ } catch { }
    }
    if ($n -gt 0) { Start-Sleep -Milliseconds 800 }
    return $n
}

function Start-Daemon {
    try {
        Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $MainScript) -WindowStyle Hidden
        Start-Sleep -Milliseconds 1200
        return $true
    } catch { return $false }
}

# ---- 开机自启：在启动文件夹放一个静默 vbs ----
function Enable-AutoStart {
    try {
        # ⚠️ VBScript 里字符串内部的引号必须写成两个（""），
        #    只写一个会把字符串截断，开机时会弹「语句未结束 / 800A0401」。
        $q       = [char]34
        $dq      = $q + $q
        $cmd     = $dq + $PSExe + $dq + ' -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $dq + $MainScript + $dq
        $runLine = 'CreateObject("WScript.Shell").Run "' + $cmd + '", 0, False'
        if (@($runLine.ToCharArray() | Where-Object { $_ -eq $q }).Count % 2 -ne 0) { return $false }
        $vbs     = "' Workday Launcher - keep waiting in background after logon" + [Environment]::NewLine +
                   "' Delete this file to disable auto start" + [Environment]::NewLine +
                   $runLine + [Environment]::NewLine
        [System.IO.File]::WriteAllText($StartupVbs, $vbs, $Ascii)
        return $true
    } catch { return $false }
}

function Disable-AutoStart {
    try {
        if (Test-Path -LiteralPath $StartupVbs) { Remove-Item -LiteralPath $StartupVbs -Force -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- 扫描本机软件
function Get-InstalledApps {
    $res = @{}
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if (-not $programData) { $programData = $env:ProgramData }
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if (-not $appData) { $appData = $env:APPDATA }
    $menus = @()
    if ($programData) { $menus += (Join-Path $programData 'Microsoft\Windows\Start Menu\Programs') }
    if ($appData)     { $menus += (Join-Path $appData     'Microsoft\Windows\Start Menu\Programs') }
    $bad = '卸载|uninstall|帮助|help|readme|说明|手册|release ?notes|更新|update|documentation|官网|website|网址|license|许可|repair|修复|setup|安装程序|windows 管理工具|administrative tools'
    foreach ($m in $menus) {
        if (-not (Test-Path -LiteralPath $m)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $m -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)) {
            if ($f.FullName -like '*\Startup\*') { continue }
            $n = $f.BaseName
            if ($n -match $bad) { continue }
            if (-not $res.ContainsKey($n)) { $res[$n] = $f.FullName }
        }
    }
    return $res
}

function Resolve-LnkTarget {
    param([string]$LnkPath)
    try {
        $sh = New-Object -ComObject WScript.Shell
        $t = $sh.CreateShortcut($LnkPath).TargetPath
        if ($t) { return $t }
    } catch { }
    return $LnkPath
}

# ---------------------------------------------------------------- 通用弹窗
function Show-TextDialog {
    param([string]$Title, [string]$Text, [int]$W = 700, [int]$H = 480)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.ClientSize = New-Object System.Drawing.Size($W, $H)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-UiFont 9.5

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(14, 14)
    $tb.Size = New-Object System.Drawing.Size(($W - 28), ($H - 76))
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Both'
    $tb.WordWrap = $false
    $tb.BackColor = [System.Drawing.Color]::White
    $tb.Font = New-UiFont 9.5
    $tb.Text = $Text
    $dlg.Controls.Add($tb)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = '知道了'
    $btn.Size = New-Object System.Drawing.Size(110, 34)
    $btn.Location = New-Object System.Drawing.Point((($W - 110) / 2), ($H - 52))
    $btn.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btn)
    $dlg.AcceptButton = $btn

    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}

# ---------------------------------------------------------------- 添加/修改软件
function Show-AppDialog {
    param($Existing)

    $dlg = New-Object System.Windows.Forms.Form
    if ($Existing) { $dlg.Text = '修改软件' } else { $dlg.Text = '添加软件' }
    $dlg.ClientSize = New-Object System.Drawing.Size(566, 452)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-UiFont 9.5

    # ---- 已安装列表 ----
    $grpPick = New-Object System.Windows.Forms.GroupBox
    $grpPick.Text = '从这台电脑上已经装好的程序里挑一个'
    $grpPick.Location = New-Object System.Drawing.Point(14, 12)
    $grpPick.Size = New-Object System.Drawing.Size(538, 238)
    $grpPick.Font = New-UiFont 9.5
    $dlg.Controls.Add($grpPick)

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = '搜索'
    $lblSearch.Location = New-Object System.Drawing.Point(14, 28)
    $lblSearch.Size = New-Object System.Drawing.Size(40, 22)
    $grpPick.Controls.Add($lblSearch)

    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Location = New-Object System.Drawing.Point(56, 25)
    $txtFilter.Size = New-Object System.Drawing.Size(466, 26)
    $txtFilter.Font = New-UiFont 9.5
    $grpPick.Controls.Add($txtFilter)

    $lbApps = New-Object System.Windows.Forms.ListBox
    $lbApps.Location = New-Object System.Drawing.Point(14, 58)
    $lbApps.Size = New-Object System.Drawing.Size(508, 164)
    $lbApps.Font = New-UiFont 9.5
    $lbApps.IntegralHeight = $false
    $grpPick.Controls.Add($lbApps)

    # ---- 手动填写 ----
    $grpManual = New-Object System.Windows.Forms.GroupBox
    $grpManual.Text = '也可以自己填（只知道名字也行，程序会自己去开始菜单找）'
    $grpManual.Location = New-Object System.Drawing.Point(14, 262)
    $grpManual.Size = New-Object System.Drawing.Size(538, 126)
    $grpManual.Font = New-UiFont 9.5
    $dlg.Controls.Add($grpManual)

    $lblP = New-Object System.Windows.Forms.Label
    $lblP.Text = '程序名或路径'
    $lblP.Location = New-Object System.Drawing.Point(14, 28)
    $lblP.Size = New-Object System.Drawing.Size(96, 22)
    $grpManual.Controls.Add($lblP)

    $txtManual = New-Object System.Windows.Forms.TextBox
    $txtManual.Location = New-Object System.Drawing.Point(112, 25)
    $txtManual.Size = New-Object System.Drawing.Size(288, 26)
    $txtManual.Font = New-UiFont 9.5
    $grpManual.Controls.Add($txtManual)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '浏览...'
    $btnBrowse.Location = New-Object System.Drawing.Point(408, 24)
    $btnBrowse.Size = New-Object System.Drawing.Size(112, 28)
    $grpManual.Controls.Add($btnBrowse)

    $lblN = New-Object System.Windows.Forms.Label
    $lblN.Text = '显示名称'
    $lblN.Location = New-Object System.Drawing.Point(14, 74)
    $lblN.Size = New-Object System.Drawing.Size(96, 22)
    $grpManual.Controls.Add($lblN)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Location = New-Object System.Drawing.Point(112, 71)
    $txtName.Size = New-Object System.Drawing.Size(408, 26)
    $txtName.Font = New-UiFont 9.5
    $grpManual.Controls.Add($txtName)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = '确定'
    $btnOK.Location = New-Object System.Drawing.Point(340, 404)
    $btnOK.Size = New-Object System.Drawing.Size(100, 34)
    $btnOK.DialogResult = 'OK'
    $dlg.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(452, 404)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 34)
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)
    $dlg.AcceptButton = $btnOK
    $dlg.CancelButton = $btnCancel

    # ---- 填数据 ----
    if (-not $script:Detected) { $script:Detected = Get-InstalledApps }
    $usedNames = @()
    foreach ($a in $script:Apps) { $usedNames += $a.Name }

    $all = @()
    foreach ($k in @($script:Detected.Keys | Sort-Object)) {
        if ($Existing -and $k -eq $Existing.Name) { continue }
        if ($usedNames -contains $k) { continue }
        $all += $k
    }

    $fill = {
        $kw = $txtFilter.Text.Trim()
        $lbApps.BeginUpdate()
        $lbApps.Items.Clear()
        foreach ($n in $all) {
            if ($kw -eq '' -or $n -like ('*' + $kw + '*')) { [void]$lbApps.Items.Add($n) }
        }
        $lbApps.EndUpdate()
    }
    & $fill

    $txtFilter.Add_TextChanged($fill)

    $lbApps.Add_SelectedIndexChanged({
        if ($lbApps.SelectedIndex -lt 0) { return }
        $n = [string]$lbApps.SelectedItem
        $lnk = [string]$script:Detected[$n]
        $txtName.Text = $n
        $txtManual.Text = (Resolve-LnkTarget $lnk)
    })
    $lbApps.Add_DoubleClick({
        if ($lbApps.SelectedIndex -ge 0) { $dlg.DialogResult = 'OK' }
    })

    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = '程序 (*.exe;*.lnk;*.bat)|*.exe;*.lnk;*.bat|所有文件 (*.*)|*.*'
        $ofd.Title = '选择要打开的软件'
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtManual.Text = $ofd.FileName
            if ($txtName.Text.Trim() -eq '') {
                $txtName.Text = [System.IO.Path]::GetFileNameWithoutExtension($ofd.FileName)
            }
        }
    })

    if ($Existing) {
        $txtManual.Text = [string]$Existing.Path
        $txtName.Text = [string]$Existing.Name
    }

    if ($dlg.ShowDialog() -eq 'OK') {
        $path = $txtManual.Text.Trim()
        $name = $txtName.Text.Trim()
        if ($name -eq '' -and $path -ne '') {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
        }
        if ($path -eq '' -and $name -eq '') {
            [void][System.Windows.Forms.MessageBox]::Show('你还什么都没填。请从上面的列表里选一个，或者手动填上程序名/路径。', 'F9开工 · 设置')
        } else {
            if ($Existing) {
                $Existing.Name = $name
                $Existing.Path = $path
                $script:AppDialogResult = $Existing
            } else {
                $script:AppDialogResult = [pscustomobject]@{ Name = $name; Path = $path; Enabled = $true }
            }
        }
    } else {
        $script:AppDialogResult = $null
    }
    $dlg.Dispose()
}

# ---------------------------------------------------------------- 界面
$script:UiFont  = New-UiFont 9.5
$script:UiBold  = New-UiFont 9.5 -Bold

$cBg      = $script:CBg
$cPanel   = $script:CPanel
$cCard    = $script:CCard
$cBorder  = $script:CBorder
$cHeadBg  = $script:CHeadBg
$cHeadTx  = $script:CHeadTx
$cTitle   = $script:CTitle
$cSub     = $script:CSub
$cText    = $script:CText
$cAccent  = $script:CAccent
$cAccentD = $script:CAccentD
$cAccentT = $script:CAccentT
$cListBg  = $script:CListBg
$cListTx  = $script:CListTx
$cListGd  = $script:CListGd
$cSelBg   = $script:CSelBg
$cSelTx   = $script:CSelTx
$script:CAccent = $cAccent

$form = New-Object System.Windows.Forms.Form
$form.Text = 'F9开工'
$script:DesignW = 992
# 676 -> 712：③ 多了一行收工设置、④ 跟着下移 35 像素。
# 内容底边从 606 变成 641，711 才装得下（面板内容区永远可滚动，
# 小屏（1366x768）上就是多一条很短的滚动条，不会切掉任何按钮）。
$script:DesignH = 712
$script:BarH    = 62
# 客户区高度按“屏幕可用高度”算出来再定。
# 1366x768 这种小屏，写死高度会把底部那排按钮顶到屏幕外面去。
$waH = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
$script:FormH = $script:DesignH
if (($waH - 46) -lt $script:FormH) { $script:FormH = $waH - 46 }
if ($script:FormH -lt 520) { $script:FormH = 520 }
$script:BarY = $script:FormH - 46
$form.ClientSize = New-Object System.Drawing.Size($script:DesignW, $script:FormH)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = $script:UiFont
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = $cBg

# 内容区（标题头 + 四个分组）装进一个可滚动面板，底部的状态字和三个按钮固定在最下面。
# 这样不管屏幕多小，按钮都不会被切掉。
$panelContent = New-Object System.Windows.Forms.Panel
$panelContent.Location   = New-Object System.Drawing.Point(0, 0)
$panelContent.Size       = New-Object System.Drawing.Size($script:DesignW, ($script:FormH - $script:BarH))
$panelContent.BackColor  = $cBg
$panelContent.AutoScroll = $true
$form.Controls.Add($panelContent)

# 顶部色带 + 标题区
$hdr = New-Object System.Windows.Forms.Panel
$hdr.Location  = New-Object System.Drawing.Point(0, 0)
$hdr.Size      = New-Object System.Drawing.Size(992, 60)
$hdr.BackColor = $cHeadBg
$panelContent.Controls.Add($hdr)

$stripTop = New-Object System.Windows.Forms.Panel
$stripTop.Location  = New-Object System.Drawing.Point(0, 0)
$stripTop.Size      = New-Object System.Drawing.Size(992, 5)
$stripTop.BackColor = $cAccent
$hdr.Controls.Add($stripTop)

# 皮肤形象（有图就显示）
$skinArt = Get-SkinArtPath
if ($skinArt) {
    try {
        $imgArt = [System.Drawing.Image]::FromFile($skinArt)
        $picArt = New-Object System.Windows.Forms.PictureBox
        $picArt.Image     = $imgArt
        $picArt.SizeMode  = 'Zoom'
        $picArt.BackColor = $cHeadBg
        $picArt.Location  = New-Object System.Drawing.Point(18, 12)
        $picArt.Size      = New-Object System.Drawing.Size(44, 44)
        $hdr.Controls.Add($picArt)
    } catch { }
}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'F9开工'
$lblTitle.Location = New-Object System.Drawing.Point(74, 14)
$lblTitle.Size = New-Object System.Drawing.Size(500, 30)
$lblTitle.Font = (New-UiFont 15 -Bold)
$lblTitle.ForeColor = $cTitle
$lblTitle.BackColor = [System.Drawing.Color]::Transparent
$hdr.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '勾上要打开的东西、填好网址，点右下角「保存并生效」。要马上开工就点【立即开工一次】，或者直接按快捷键 —— 换皮肤也是当场生效。'
$lblSub.Location = New-Object System.Drawing.Point(76, 42)
$lblSub.Size = New-Object System.Drawing.Size(900, 20)
$lblSub.ForeColor = $cSub
$lblSub.BackColor = [System.Drawing.Color]::Transparent
$hdr.Controls.Add($lblSub)

# 皮肤名字小标签（右上角）
$lblSkinTag = New-Object System.Windows.Forms.Label
$lblSkinTag.Text = '皮肤：' + $(if ($script:Skin -and $script:Skin._label) { $script:Skin._label } else { '经典蓝' })
$lblSkinTag.TextAlign = 'MiddleRight'
$lblSkinTag.Location = New-Object System.Drawing.Point(796, 18)
$lblSkinTag.Size = New-Object System.Drawing.Size(180, 22)
$lblSkinTag.ForeColor = $cAccentD
$lblSkinTag.Font = (New-UiFont 9 -Bold)
$lblSkinTag.BackColor = [System.Drawing.Color]::Transparent
$hdr.Controls.Add($lblSkinTag)

$stripBot = New-Object System.Windows.Forms.Panel
$stripBot.Location  = New-Object System.Drawing.Point(0, 59)
$stripBot.Size      = New-Object System.Drawing.Size(992, 1)
$stripBot.BackColor = $cBorder
$hdr.Controls.Add($stripBot)

# ---------------- 软件 ----------------
$grpApps = New-Object System.Windows.Forms.GroupBox
$grpApps.Text = '① 要打开的软件（勾上的才会打开，从上往下依次启动）'
$grpApps.Location = New-Object System.Drawing.Point(18, 70)
$grpApps.Size = New-Object System.Drawing.Size(452, 280)
$grpApps.ForeColor = $cHeadTx
$grpApps.BackColor = $cBg
$panelContent.Controls.Add($grpApps)

$lvApps = New-Object System.Windows.Forms.ListView
$lvApps.Location = New-Object System.Drawing.Point(12, 46)
$lvApps.Size = New-Object System.Drawing.Size(428, 190)
$lvApps.View = 'Details'
$lvApps.CheckBoxes = $true
$lvApps.FullRowSelect = $true
$lvApps.GridLines = $true
$lvApps.MultiSelect = $true
$lvApps.HideSelection = $false
$lvApps.HeaderStyle = 'None'
$lvApps.Font = $script:UiFont
$lvApps.BackColor = $cListBg
$lvApps.ForeColor = $cListTx
$lvApps.GridLines = $true
[void]$lvApps.Columns.Add('打开', 48)
[void]$lvApps.Columns.Add('软件名称', 130)
[void]$lvApps.Columns.Add('位置', 228)
$grpApps.Controls.Add($lvApps)

$btnAddApp = New-Object System.Windows.Forms.Button
$btnAddApp.Text = '添加软件'
$btnAddApp.Location = New-Object System.Drawing.Point(12, 244)
$btnAddApp.Size = New-Object System.Drawing.Size(104, 30)
$grpApps.Controls.Add($btnAddApp)

$btnEditApp = New-Object System.Windows.Forms.Button
$btnEditApp.Text = '修改'
$btnEditApp.Location = New-Object System.Drawing.Point(122, 244)
$btnEditApp.Size = New-Object System.Drawing.Size(86, 30)
$grpApps.Controls.Add($btnEditApp)

$btnDelApp = New-Object System.Windows.Forms.Button
$btnDelApp.Text = '删除'
$btnDelApp.Location = New-Object System.Drawing.Point(214, 244)
$btnDelApp.Size = New-Object System.Drawing.Size(86, 30)
$grpApps.Controls.Add($btnDelApp)

$btnUpApp = New-Object System.Windows.Forms.Button
$btnUpApp.Text = '上移'
$btnUpApp.Location = New-Object System.Drawing.Point(306, 244)
$btnUpApp.Size = New-Object System.Drawing.Size(64, 30)
$grpApps.Controls.Add($btnUpApp)

$btnDownApp = New-Object System.Windows.Forms.Button
$btnDownApp.Text = '下移'
$btnDownApp.Location = New-Object System.Drawing.Point(376, 244)
$btnDownApp.Size = New-Object System.Drawing.Size(64, 30)
$grpApps.Controls.Add($btnDownApp)

# ---------------- 网页 ----------------
$grpUrls = New-Object System.Windows.Forms.GroupBox
$grpUrls.Text = '② 要打开的网页'
$grpUrls.Location = New-Object System.Drawing.Point(486, 70)
$grpUrls.Size = New-Object System.Drawing.Size(472, 280)
$panelContent.Controls.Add($grpUrls)

$lblU1 = New-Object System.Windows.Forms.Label
$lblU1.Text = '粘贴网址，比如 taobao.com（会自动补 https）'
# 【高度只能给 18，别改回 20】说明文字正好压在下面那个输入框的头顶上。
# Label 虽然没有边框、文字也不撑开控件，但它的**矩形**是实的，会用自己那块背景
# 把压在下面的东西盖掉 —— 高 20、起点 y=24 时正好吃掉输入框(y=42)最上面那条边框，
# 屏幕上看起来就是"输入框缺了一条边"（用户 2026-09-23 截图圈的就是这里）。
# 18 高 + y 上移 1 像素：既盖不到输入框，文字也还完整。
$lblU1.Location = New-Object System.Drawing.Point(12, 23)
$lblU1.Size = New-Object System.Drawing.Size(448, 18)
$grpUrls.Controls.Add($lblU1)

$txtNewUrl = New-Object System.Windows.Forms.TextBox
$txtNewUrl.Location = New-Object System.Drawing.Point(12, 42)
$txtNewUrl.Size = New-Object System.Drawing.Size(448, 24)
$txtNewUrl.Font = $script:UiFont
$grpUrls.Controls.Add($txtNewUrl)

$lblU2 = New-Object System.Windows.Forms.Label
$lblU2.Text = '给它起个名字（可以留空，不填就用网址当名字）'
$lblU2.Location = New-Object System.Drawing.Point(12, 67)
# 宽度只到「添加到列表」按钮之前，绝不让标签的框盖到按钮上
# 【高度只能给 18，别改回 20】同上：20 高会盖掉下面输入框(y=86)最上面那条边框。
$lblU2.Size = New-Object System.Drawing.Size(296, 18)
$grpUrls.Controls.Add($lblU2)

$txtNewName = New-Object System.Windows.Forms.TextBox
$txtNewName.Location = New-Object System.Drawing.Point(12, 86)
$txtNewName.Size = New-Object System.Drawing.Size(290, 24)
$txtNewName.Font = $script:UiFont
$grpUrls.Controls.Add($txtNewName)

$btnAddUrl = New-Object System.Windows.Forms.Button
$btnAddUrl.Text = '添加到列表'
$btnAddUrl.Location = New-Object System.Drawing.Point(310, 85)
$btnAddUrl.Size = New-Object System.Drawing.Size(150, 26)
$grpUrls.Controls.Add($btnAddUrl)

$lvUrls = New-Object System.Windows.Forms.ListView
$lvUrls.Location = New-Object System.Drawing.Point(12, 138)
$lvUrls.Size = New-Object System.Drawing.Size(448, 98)
$lvUrls.View = 'Details'
$lvUrls.CheckBoxes = $true
$lvUrls.FullRowSelect = $true
$lvUrls.GridLines = $true
$lvUrls.MultiSelect = $true
$lvUrls.HideSelection = $false
$lvUrls.HeaderStyle = 'None'
$lvUrls.Font = $script:UiFont
[void]$lvUrls.Columns.Add('打开', 48)
[void]$lvUrls.Columns.Add('名称', 130)
[void]$lvUrls.Columns.Add('网址', 250)
$grpUrls.Controls.Add($lvUrls)

# ---- 自建列表头 ----
# 系统不给改 ListView 列头的配色（右侧那块空白区更会留一条洗不掉的白带），
# 所以干脆不用系统列头：拿 Label 拼一条出来，颜色完全跟着皮肤走。
function New-ListHeaderBar {
    param([int]$X, [int]$Y, [int]$W, [int[]]$ColW, [string[]]$ColText, [string]$Name)

    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Location  = New-Object System.Drawing.Point($X, $Y)
    $pnl.Size      = New-Object System.Drawing.Size($W, 22)
    $pnl.Name      = $Name
    $pnl.BackColor = $script:CListGd

    $lx = 0
    for ($i = 0; $i -lt $ColW.Count; $i++) {
        $lb = New-Object System.Windows.Forms.Label
        $lb.Name      = ($Name + '_c' + $i)
        $lb.Text      = [string]$ColText[$i]
        $lb.Location  = New-Object System.Drawing.Point(($lx + 8), 2)
        $lb.Size      = New-Object System.Drawing.Size(($ColW[$i] - 4), 18)
        $lb.TextAlign = 'MiddleLeft'
        $lb.AutoSize  = $false
        $lb.BackColor = [System.Drawing.Color]::Transparent
        $lb.ForeColor = $script:CListTx
        $lb.Font      = $script:UiFont
        [void]$pnl.Controls.Add($lb)
        $lx += $ColW[$i]
    }

    # 底下压一条细线，看起来像正经列头
    $line = New-Object System.Windows.Forms.Panel
    $line.Location  = New-Object System.Drawing.Point(0, 21)
    $line.Size      = New-Object System.Drawing.Size($W, 1)
    $line.BackColor = $script:CBorder
    [void]$pnl.Controls.Add($line)

    return $pnl
}

function Get-HeadLabel {
    param($Bar, [int]$Index)
    if (-not $Bar) { return $null }
    $hit = $Bar.Controls.Find(($Bar.Name + '_c' + $Index), $false)
    if ($hit -and $hit.Count -gt 0) { return $hit[0] }
    return $null
}

# 换皮肤后把列头重刷一遍（Paint-Control 会顺手把 Label 刷成正文色，这里再压回来）
function Apply-ListHeader {
    foreach ($bar in @($hdrApps, $hdrUrls)) {
        if (-not $bar) { continue }
        $bar.BackColor = $script:CListGd
        foreach ($c in $bar.Controls) {
            if ($c -is [System.Windows.Forms.Label]) {
                $c.ForeColor = $script:CListTx
                $c.BackColor = [System.Drawing.Color]::Transparent
            } else {
                $c.BackColor = $script:CBorder
            }
        }
    }
}

$hdrApps = New-ListHeaderBar -X 12 -Y 24 -W 428 -ColW @(48, 130, 228) -ColText @('打开', '软件名称', '位置') -Name 'hdrApps'
$grpApps.Controls.Add($hdrApps)

$hdrUrls = New-ListHeaderBar -X 12 -Y 116 -W 448 -ColW @(48, 130, 250) -ColText @('打开', '名称', '网址') -Name 'hdrUrls'
$grpUrls.Controls.Add($hdrUrls)

$btnDelUrl = New-Object System.Windows.Forms.Button
$btnDelUrl.Text = '删除'
$btnDelUrl.Location = New-Object System.Drawing.Point(12, 244)
$btnDelUrl.Size = New-Object System.Drawing.Size(86, 30)
$grpUrls.Controls.Add($btnDelUrl)

$btnUpUrl = New-Object System.Windows.Forms.Button
$btnUpUrl.Text = '上移'
$btnUpUrl.Location = New-Object System.Drawing.Point(104, 244)
$btnUpUrl.Size = New-Object System.Drawing.Size(64, 30)
$grpUrls.Controls.Add($btnUpUrl)

$btnDownUrl = New-Object System.Windows.Forms.Button
$btnDownUrl.Text = '下移'
$btnDownUrl.Location = New-Object System.Drawing.Point(174, 244)
$btnDownUrl.Size = New-Object System.Drawing.Size(64, 30)
$grpUrls.Controls.Add($btnDownUrl)

# ---------------- 其它 ----------------
$grpOther = New-Object System.Windows.Forms.GroupBox
$grpOther.Text = '③ 其它设置'
$grpOther.Location = New-Object System.Drawing.Point(18, 356)
# 高度 118 -> 152：加了第 4 行「一键收工」（原来只有 3 行）
$grpOther.Size = New-Object System.Drawing.Size(940, 152)
$panelContent.Controls.Add($grpOther)

$lblHot = New-Object System.Windows.Forms.Label
$lblHot.Text = '快捷键'
$lblHot.Location = New-Object System.Drawing.Point(14, 25)
$lblHot.Size = New-Object System.Drawing.Size(58, 22)
$grpOther.Controls.Add($lblHot)

$cmbHotkey = New-Object System.Windows.Forms.ComboBox
$cmbHotkey.Location = New-Object System.Drawing.Point(80, 22)
$cmbHotkey.Size = New-Object System.Drawing.Size(150, 26)
$cmbHotkey.DropDownStyle = 'DropDown'
$cmbHotkey.Font = $script:UiFont
# 一格可以写多个快捷键（用 / 分开），两个都能用。
# 单键（F9）容易被别的软件抢走、也容易误触，所以组合键和"两个都留"都放进选项里。
[void]$cmbHotkey.Items.AddRange(@('F9', 'Ctrl+Alt+W', 'F9 / Ctrl+Alt+W', 'F8', 'F10', 'F11', 'F12', 'Ctrl+Alt+S', 'Ctrl+Alt+K', 'Ctrl+Shift+F9'))
$grpOther.Controls.Add($cmbHotkey)

$lblHotTip = New-Object System.Windows.Forms.Label
$lblHotTip.Text = '（下面下拉选，也可以自己输入）'
$lblHotTip.Location = New-Object System.Drawing.Point(244, 25)
$lblHotTip.Size = New-Object System.Drawing.Size(226, 22)
$lblHotTip.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$grpOther.Controls.Add($lblHotTip)

$lblA = New-Object System.Windows.Forms.Label
$lblA.Text = '软件间隔'
$lblA.Location = New-Object System.Drawing.Point(504, 25)
$lblA.Size = New-Object System.Drawing.Size(72, 22)
$grpOther.Controls.Add($lblA)

$numA = New-Object System.Windows.Forms.NumericUpDown
$numA.Location = New-Object System.Drawing.Point(584, 22)
$numA.Size = New-Object System.Drawing.Size(64, 26)
$numA.Minimum = 0
$numA.Maximum = 20000
$numA.Increment = 50
$numA.ThousandsSeparator = $false
$numA.Font = $script:UiFont
$grpOther.Controls.Add($numA)

$lblA2 = New-Object System.Windows.Forms.Label
$lblA2.Text = '毫秒'
$lblA2.Location = New-Object System.Drawing.Point(656, 25)
$lblA2.Size = New-Object System.Drawing.Size(38, 22)
$grpOther.Controls.Add($lblA2)

$lblU = New-Object System.Windows.Forms.Label
$lblU.Text = '网页间隔'
$lblU.Location = New-Object System.Drawing.Point(728, 25)
$lblU.Size = New-Object System.Drawing.Size(72, 22)
$grpOther.Controls.Add($lblU)

$numU = New-Object System.Windows.Forms.NumericUpDown
$numU.Location = New-Object System.Drawing.Point(808, 22)
$numU.Size = New-Object System.Drawing.Size(64, 26)
$numU.Minimum = 0
$numU.Maximum = 20000
$numU.Increment = 50
$numU.Font = $script:UiFont
$grpOther.Controls.Add($numU)

$lblU2b = New-Object System.Windows.Forms.Label
$lblU2b.Text = '毫秒'
$lblU2b.Location = New-Object System.Drawing.Point(880, 25)
$lblU2b.Size = New-Object System.Drawing.Size(38, 22)
$grpOther.Controls.Add($lblU2b)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '开机自动在后台待命（推荐勾上）'
$chkAuto.Location = New-Object System.Drawing.Point(14, 55)
$chkAuto.Size = New-Object System.Drawing.Size(300, 26)
$grpOther.Controls.Add($chkAuto)

# ---- 开工时右下角显示进度窗（不勾就只在后台默默干活）----
$chkTip = New-Object System.Windows.Forms.CheckBox
$chkTip.Text = '开工时显示进度窗'
$chkTip.Location = New-Object System.Drawing.Point(336, 55)
$chkTip.Size = New-Object System.Drawing.Size(140, 26)
$grpOther.Controls.Add($chkTip)

# ---- 开工时飘不飘表情包、放不放语音，都在下面的「④ 开工彩蛋」里设 ----
$lblIconAct = New-Object System.Windows.Forms.Label
$lblIconAct.Text = '双击桌面图标'
$lblIconAct.Location = New-Object System.Drawing.Point(512, 58)
$lblIconAct.Size = New-Object System.Drawing.Size(104, 22)   # 窄一点，别盖住右边的下拉框
$lblIconAct.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$grpOther.Controls.Add($lblIconAct)

$cmbIconAct = New-Object System.Windows.Forms.ComboBox
$cmbIconAct.DropDownStyle = 'DropDownList'
[void]$cmbIconAct.Items.Add('打开启动台')
[void]$cmbIconAct.Items.Add('直接开工')
$cmbIconAct.SelectedIndex = 0
$cmbIconAct.Location = New-Object System.Drawing.Point(624, 54)
$cmbIconAct.Size = New-Object System.Drawing.Size(150, 26)
$cmbIconAct.FlatStyle = 'Flat'
$grpOther.Controls.Add($cmbIconAct)

# ---- 界面语言 ----
$lblLang = New-Object System.Windows.Forms.Label
$lblLang.Text = '界面语言'
$lblLang.Location = New-Object System.Drawing.Point(14, 89)
$lblLang.Size = New-Object System.Drawing.Size(64, 22)
$grpOther.Controls.Add($lblLang)

$cmbLang = New-Object System.Windows.Forms.ComboBox
$cmbLang.Location = New-Object System.Drawing.Point(84, 86)
$cmbLang.Size = New-Object System.Drawing.Size(150, 26)
$cmbLang.DropDownStyle = 'DropDownList'
$cmbLang.Font = $script:UiFont
[void]$cmbLang.Items.Add('简体中文')
[void]$cmbLang.Items.Add('English')
$cmbLang.SelectedIndex = 0
$grpOther.Controls.Add($cmbLang)

# ---- 皮肤（换配色 + 形象 + 桌面图标）----
$lblSkin = New-Object System.Windows.Forms.Label
$lblSkin.Text = '皮肤'
$lblSkin.Location = New-Object System.Drawing.Point(256, 89)
$lblSkin.Size = New-Object System.Drawing.Size(38, 22)
$grpOther.Controls.Add($lblSkin)

$cmbSkin = New-Object System.Windows.Forms.ComboBox
$cmbSkin.Location = New-Object System.Drawing.Point(300, 86)
$cmbSkin.Size = New-Object System.Drawing.Size(160, 26)
$cmbSkin.DropDownStyle = 'DropDownList'
$cmbSkin.Font = $script:UiFont
# 显示名字跟着界面语言走（英文界面显示英文名）
$script:SkinLabelsZh = @{}
$script:SkinLabelsEn = @{}
# 英文名直接从 skin.json 的 labelEn 读 —— 以后加皮肤只改 json，不用动代码
foreach ($k in $script:SkinKeys) {
    try {
        $o = $script:SkinAll.skins.PSObject.Properties[$k]
        if ($o) {
            $le = $o.Value.PSObject.Properties['labelEn']
            if ($le -and -not [string]::IsNullOrWhiteSpace([string]$le.Value)) {
                $script:SkinLabelsEn[$k] = [string]$le.Value
            }
        }
    } catch { }
}
foreach ($k in $script:SkinKeys) {
    $lab = $k
    try {
        $o = $script:SkinAll.skins.PSObject.Properties[$k]
        if ($o) {
            $lb = $o.Value.PSObject.Properties['label']
            if ($lb -and -not [string]::IsNullOrWhiteSpace([string]$lb.Value)) { $lab = [string]$lb.Value }
        }
    } catch { }
    $script:SkinLabelsZh[$k] = $lab
    $show = $lab
    if ($script:Lang -eq 'en' -and $script:SkinLabelsEn.ContainsKey($k)) { $show = $script:SkinLabelsEn[$k] }
    [void]$cmbSkin.Items.Add($show)
}
if ($script:Skin -and $script:Skin._label) {
    $ix = $cmbSkin.Items.IndexOf([string]$script:Skin._label)
    if ($ix -lt 0 -and $script:Lang -eq 'en' -and $script:SkinLabelsEn.ContainsKey($script:SkinName)) {
        $ix = $cmbSkin.Items.IndexOf([string]$script:SkinLabelsEn[$script:SkinName])
    }
    if ($ix -ge 0) { $cmbSkin.SelectedIndex = $ix }
} elseif ($cmbSkin.Items.Count -gt 0) {
    $cmbSkin.SelectedIndex = 0
}
$grpOther.Controls.Add($cmbSkin)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = '打开程序文件夹'
$btnFolder.Location = New-Object System.Drawing.Point(486, 85)
$btnFolder.Size = New-Object System.Drawing.Size(148, 28)
$grpOther.Controls.Add($btnFolder)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = '查看运行记录'
$btnLogs.Location = New-Object System.Drawing.Point(646, 85)
$btnLogs.Size = New-Object System.Drawing.Size(148, 28)
$grpOther.Controls.Add($btnLogs)

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = '卸载'
$btnUninstall.Location = New-Object System.Drawing.Point(842, 85)
$btnUninstall.Size = New-Object System.Drawing.Size(76, 28)
$grpOther.Controls.Add($btnUninstall)

# ---- 第 4 行：一键收工（关机 / 重启 / 睡眠）----
# 收工是"按一下就关机"，误触代价最大，所以这里只放三样：
# 快捷键、倒计时秒数、以及"在桌面放个收工图标"。
# 三个动作按钮不给开关 —— 用户明确说了三个都要，多一个勾选框只是添乱。
$lblQuit = New-Object System.Windows.Forms.Label
$lblQuit.Text = '收工快捷键'
$lblQuit.Location = New-Object System.Drawing.Point(14, 120)
$lblQuit.Size = New-Object System.Drawing.Size(88, 18)   # 高 18：Label 矩形是实的，高了会压掉下一条边
$grpOther.Controls.Add($lblQuit)

$cmbQuitHotkey = New-Object System.Windows.Forms.ComboBox
$cmbQuitHotkey.Location = New-Object System.Drawing.Point(106, 116)
$cmbQuitHotkey.Size = New-Object System.Drawing.Size(142, 26)
$cmbQuitHotkey.DropDownStyle = 'DropDown'
$cmbQuitHotkey.Font = $script:UiFont
[void]$cmbQuitHotkey.Items.AddRange(@('Ctrl+Alt+Q', 'Ctrl+Alt+E', 'Ctrl+Shift+Q', 'Ctrl+Alt+9', 'Ctrl+Alt+F9'))
$grpOther.Controls.Add($cmbQuitHotkey)

$lblQuitSec = New-Object System.Windows.Forms.Label
$lblQuitSec.Text = '倒计时'
$lblQuitSec.Location = New-Object System.Drawing.Point(256, 120)
$lblQuitSec.Size = New-Object System.Drawing.Size(48, 18)
$grpOther.Controls.Add($lblQuitSec)

$numQuitSec = New-Object System.Windows.Forms.NumericUpDown
$numQuitSec.Location = New-Object System.Drawing.Point(308, 116)
$numQuitSec.Size = New-Object System.Drawing.Size(64, 26)
$numQuitSec.Minimum = 5
$numQuitSec.Maximum = 600
$numQuitSec.Increment = 10
$numQuitSec.Font = $script:UiFont
$grpOther.Controls.Add($numQuitSec)

$lblQuitSecU = New-Object System.Windows.Forms.Label
$lblQuitSecU.Text = '秒'
$lblQuitSecU.Location = New-Object System.Drawing.Point(378, 120)
$lblQuitSecU.Size = New-Object System.Drawing.Size(24, 18)
$grpOther.Controls.Add($lblQuitSecU)

$lblQuitTip = New-Object System.Windows.Forms.Label
$lblQuitTip.Text = '（窗口里显示：关机 / 重启 / 睡眠）'
$lblQuitTip.Location = New-Object System.Drawing.Point(412, 120)
$lblQuitTip.Size = New-Object System.Drawing.Size(232, 18)
$lblQuitTip.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$grpOther.Controls.Add($lblQuitTip)

$btnQuitIcon = New-Object System.Windows.Forms.Button
$btnQuitIcon.Text = '在桌面放一个「F9收工」图标'
$btnQuitIcon.Location = New-Object System.Drawing.Point(656, 115)
$btnQuitIcon.Size = New-Object System.Drawing.Size(268, 28)
$grpOther.Controls.Add($btnQuitIcon)

# ---- 一键收工：在桌面生成「F9收工」图标 ----
# 这里【复用 Install.ps1 里那套已经验过的 .vbs 生成逻辑】（引号配对自检 + cscript 真编译），
# 不另写一份 —— 那是踩过「语句未结束 / 800A0401」的那个坑。
$btnQuitIcon.Add_Click({
    Set-Status (T '正在生成桌面图标…') 0
    [System.Windows.Forms.Application]::DoEvents()
    $ins = Join-Path $ScriptDir 'Install.ps1'
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'F9收工.lnk'
    $err = ''
    try {
        if (-not (Test-Path -LiteralPath $ins)) { throw '找不到 Install.ps1' }
        # 【必须带 -WithQuitIcon】Install.ps1 里原本**没有**任何创建「F9收工」图标的代码
        # （2e 那段只会把已有的挪走），所以这个按钮以前点了必然失败，面板上弹的还是
        # 「生成桌面图标失败：」后面空白一片 —— 用户完全看不懂。现在把参数接上。
        $out = & $ins -IconsOnly -WithQuitIcon 2>&1
        $bad = @($out | Where-Object { ([string]$_) -like '*[FAIL]*' })
        if ($bad.Count -gt 0) { $err = [string]$bad[0] }
    } catch { $err = $_.Exception.Message }
    if ((Test-Path -LiteralPath $lnk) -and $err -eq '') {
        Set-Status (T '桌面已经放好「F9收工」图标了，双击就能用（拖到任务栏也行）') 0
    } else {
        Set-Status ((T '生成桌面图标失败：') + $err) 1
    }
})

# ================================================================ ④ 开工彩蛋
# 这个分组就是"让自己的开工有点人味儿"：飘自己选的表情包、播自己录的语音
$grpFun = New-Object System.Windows.Forms.GroupBox
$grpFun.Text = '④ 开工彩蛋（可选）：开工时飘自己的表情包 / 放自己的语音'
$grpFun.Location = New-Object System.Drawing.Point(18, 517)
$grpFun.Size = New-Object System.Drawing.Size(940, 124)
$panelContent.Controls.Add($grpFun)

# ---- 第 1 行：飘表情包 ----
$chkSticker = New-Object System.Windows.Forms.CheckBox
$chkSticker.Text = '开工时飘一下表情包'
$chkSticker.Location = New-Object System.Drawing.Point(14, 24)
$chkSticker.Size = New-Object System.Drawing.Size(196, 26)
$grpFun.Controls.Add($chkSticker)

$btnPickSticker = New-Object System.Windows.Forms.Button
$btnPickSticker.Text = '选图片…'
$btnPickSticker.Location = New-Object System.Drawing.Point(214, 21)
$btnPickSticker.Size = New-Object System.Drawing.Size(100, 28)
$grpFun.Controls.Add($btnPickSticker)

$lblStickerName = New-Object System.Windows.Forms.Label
$lblStickerName.Location = New-Object System.Drawing.Point(322, 25)
$lblStickerName.Size = New-Object System.Drawing.Size(470, 22)
$lblStickerName.AutoEllipsis = $true
$grpFun.Controls.Add($lblStickerName)

$btnStickerDefault = New-Object System.Windows.Forms.Button
$btnStickerDefault.Text = '用皮肤形象'
$btnStickerDefault.Location = New-Object System.Drawing.Point(810, 21)
$btnStickerDefault.Size = New-Object System.Drawing.Size(108, 28)
$grpFun.Controls.Add($btnStickerDefault)

# ---- 第 2 行：让系统语音念一句话（免安装，最省事）----
$lblSay = New-Object System.Windows.Forms.Label
$lblSay.Text = '说一句话'
$lblSay.Location = New-Object System.Drawing.Point(14, 58)
$lblSay.Size = New-Object System.Drawing.Size(70, 22)
$grpFun.Controls.Add($lblSay)

$txtSay = New-Object System.Windows.Forms.TextBox
$txtSay.Location = New-Object System.Drawing.Point(88, 55)
$txtSay.Size = New-Object System.Drawing.Size(500, 26)
$txtSay.Font = $script:UiFont
$grpFun.Controls.Add($txtSay)

$lblVol = New-Object System.Windows.Forms.Label
$lblVol.Text = '音量'
$lblVol.Location = New-Object System.Drawing.Point(610, 58)
$lblVol.Size = New-Object System.Drawing.Size(40, 22)
$grpFun.Controls.Add($lblVol)

$numVol = New-Object System.Windows.Forms.NumericUpDown
$numVol.Location = New-Object System.Drawing.Point(654, 55)
$numVol.Size = New-Object System.Drawing.Size(62, 26)
$numVol.Minimum = 0
$numVol.Maximum = 100
$numVol.Increment = 5
$numVol.Font = $script:UiFont
$grpFun.Controls.Add($numVol)

$lblVolUnit = New-Object System.Windows.Forms.Label
$lblVolUnit.Text = '%'
$lblVolUnit.Location = New-Object System.Drawing.Point(722, 58)
$lblVolUnit.Size = New-Object System.Drawing.Size(20, 22)
$grpFun.Controls.Add($lblVolUnit)

$btnSayClear = New-Object System.Windows.Forms.Button
$btnSayClear.Text = '清空'
$btnSayClear.Location = New-Object System.Drawing.Point(810, 54)
$btnSayClear.Size = New-Object System.Drawing.Size(108, 28)
$grpFun.Controls.Add($btnSayClear)

# ---- 第 3 行：或者放一段自己的音频（优先级比上面那句话高）----
$lblSound = New-Object System.Windows.Forms.Label
$lblSound.Text = '放音频'
$lblSound.Location = New-Object System.Drawing.Point(14, 92)
$lblSound.Size = New-Object System.Drawing.Size(70, 22)
$grpFun.Controls.Add($lblSound)

$btnPickSound = New-Object System.Windows.Forms.Button
$btnPickSound.Text = '选音频文件…'
$btnPickSound.Location = New-Object System.Drawing.Point(88, 89)
$btnPickSound.Size = New-Object System.Drawing.Size(120, 28)
$grpFun.Controls.Add($btnPickSound)

$lblSoundName = New-Object System.Windows.Forms.Label
$lblSoundName.Location = New-Object System.Drawing.Point(216, 93)
$lblSoundName.Size = New-Object System.Drawing.Size(470, 22)
$lblSoundName.AutoEllipsis = $true
$grpFun.Controls.Add($lblSoundName)

$btnSoundClear = New-Object System.Windows.Forms.Button
$btnSoundClear.Text = '清除'
$btnSoundClear.Location = New-Object System.Drawing.Point(694, 89)
$btnSoundClear.Size = New-Object System.Drawing.Size(108, 28)
$grpFun.Controls.Add($btnSoundClear)

$btnFanTest = New-Object System.Windows.Forms.Button
$btnFanTest.Text = '试听一下'
$btnFanTest.Location = New-Object System.Drawing.Point(810, 89)
$btnFanTest.Size = New-Object System.Drawing.Size(108, 28)
$grpFun.Controls.Add($btnFanTest)

# 把"当前选了哪个文件"显示出来（长路径只留文件名，免得把行挤爆）
function Refresh-FanLabels {
    if ($lblStickerName) {
        if ($script:StickerPath) {
            $lblStickerName.Text = (T '当前：') + [System.IO.Path]::GetFileName($script:StickerPath)
        } else {
            $lblStickerName.Text = (T '（没选：飘图时用当前皮肤的形象图）')
        }
    }
    if ($lblSoundName) {
        if ($script:SoundPath) {
            $lblSoundName.Text = (T '当前：') + [System.IO.Path]::GetFileName($script:SoundPath)
        } else {
            $lblSoundName.Text = (T '（没选音频：就念上面那句话）')
        }
    }
}

# ---------------- 底部 ----------------
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(18, ($script:BarY + 2))
$lblStatus.Size = New-Object System.Drawing.Size(540, 40)
$lblStatus.Font = $script:UiFont
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(40, 90, 170)
$form.Controls.Add($lblStatus)

$btnRunNow = New-Object System.Windows.Forms.Button
$btnRunNow.Text = '立即开工一次'
$btnRunNow.Location = New-Object System.Drawing.Point(574, ($script:BarY - 2))
$btnRunNow.Size = New-Object System.Drawing.Size(124, 36)
$form.Controls.Add($btnRunNow)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = '试运行检查'
$btnCheck.Location = New-Object System.Drawing.Point(710, ($script:BarY - 2))
$btnCheck.Size = New-Object System.Drawing.Size(102, 36)
$form.Controls.Add($btnCheck)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = '保存并生效'
$btnSave.Location = New-Object System.Drawing.Point(824, ($script:BarY - 2))
$btnSave.Size = New-Object System.Drawing.Size(150, 36)
$btnSave.Font = $script:UiBold
$form.Controls.Add($btnSave)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($btnCheck, '只检查不改动：看快捷键能不能用、软件能不能找到，不会真的打开任何东西')
$tip.SetToolTip($btnRunNow, '立刻按清单把软件和网页打开一遍（就是按快捷键的效果）')
$tip.SetToolTip($cmbHotkey, '按一下就能开工。可以填两个，中间用 / 分开（例如 F9 / Ctrl+Alt+W），两个都能用。单独一个 F9 容易被别的软件抢走，建议保留一个组合键。')
$tip.SetToolTip($cmbQuitHotkey, '默认 Ctrl+Alt+Q（Q = quit）。按一下会弹出「关机 / 重启 / 睡眠」的窗口，带倒计时可以取消。清空这一格 = 关掉收工功能')
$tip.SetToolTip($numQuitSec, '点了「关机 / 重启 / 睡眠」之后等这么多秒才真的执行；这段时间里点【取消】或按 Esc 就能马上停下')
$tip.SetToolTip($btnQuitIcon, '在桌面上生成一个「F9收工」的图标，双击它就能弹出收工窗口（跟快捷键是同一个功能，后台没在跑也能用）')
$tip.SetToolTip($chkAuto, '勾上：每次开机后自动在后台待命，随时可以按快捷键')
$tip.SetToolTip($chkTip, '勾上：按快捷键后右下角出进度窗，进度条一直流动，全部开完几秒后自己收起。不勾：只在后台安静地开，什么都不显示。')
$tip.SetToolTip($chkSticker, '勾上：开工时屏幕上飘一下表情包（没选图就用当前皮肤的形象图），一秒多就过。默认不勾，不打扰。')
$tip.SetToolTip($cmbLang, '换界面语言，只是界面文字变了，清单内容不动')
# 【这个数直接决定"感觉快不快"】开 N 个软件就有 N-1 个间隔，全都加在总时长上。
$tip.SetToolTip($numA, '开完一个软件、开下一个之前等多久（毫秒）。这个数直接加到总耗时上：3 个软件就有 2 个间隔。默认 150 够稳了；想最快就设 0。')
$tip.SetToolTip($numU, '开完一个网页、开下一个之前等多久（毫秒）。网页交给浏览器开，通常更快，默认 120；设 0 就一起发出去。')
$tip.SetToolTip($cmbIconAct, '双击桌面上「F9开工」图标时干什么：弹出启动台（点中间木鱼才开工），还是跳过启动台直接开工。改完点「保存并生效」')
$tip.SetToolTip($lvApps, '勾上的才会打开；不想要的点「删除」移出列表')
$tip.SetToolTip($lvUrls, '勾上的才会打开；网址要带 http:// 或 https://')
# 开工彩蛋
$tip.SetToolTip($btnPickSticker, '挑一张自己的图当表情包：png / jpg / bmp / gif 都行（gif 只会动第一帧）')
$tip.SetToolTip($btnStickerDefault, '清掉自己选的图，飘图时改回用当前皮肤的形象图')
$tip.SetToolTip($txtSay, '打一句话，开工时让电脑自己念出来。中文也能念，不用装任何软件')
$tip.SetToolTip($btnSayClear, '清空这句话（清空后就不念了）')
$tip.SetToolTip($btnPickSound, '选一段自己的音频当开工音：wav / mp3 / wma / m4a。选了就优先放它，不再念上面那句话')
$tip.SetToolTip($btnSoundClear, '清掉音频文件，改回用上面那句话')
$tip.SetToolTip($numVol, '语音音量 0-100。音频文件走系统音量，这个只管"念一句话"')
$tip.SetToolTip($btnFanTest, '马上试一下：飘一次表情包 + 放一次语音（不会打开任何软件。会顺手把当前设置保存下来）')

# ---------------------------------------------------------------- 统一刷皮肤
# 主按钮（实心强调色）：名字里带"保存/添加/确定"的
$script:PrimaryBtns = @($btnSave, $btnAddUrl, $btnAddApp, $btnRunNow)

function Paint-Control {
    param($Ctl)

    if ($Ctl -is [System.Windows.Forms.Form]) {
        $Ctl.BackColor = $script:CBg
        $Ctl.ForeColor = $script:CText
    }
    elseif ($Ctl -is [System.Windows.Forms.GroupBox]) {
        $Ctl.BackColor = $script:CBg
        $Ctl.ForeColor = $script:CHeadTx
    }
    elseif ($Ctl -is [System.Windows.Forms.Button]) {
        $isPrimary = $false
        foreach ($b in $script:PrimaryBtns) { if ([object]::ReferenceEquals($b, $Ctl)) { $isPrimary = $true } }
        Style-Btn $Ctl -Primary:$isPrimary
    }
    elseif ($Ctl -is [System.Windows.Forms.ListView]) {
        $Ctl.BackColor = $script:CListBg
        $Ctl.ForeColor = $script:CListTx
        $Ctl.BorderStyle = 'FixedSingle'
    }
    elseif ($Ctl -is [System.Windows.Forms.TextBox]) {
        $Ctl.BackColor = $script:CCard
        $Ctl.ForeColor = $script:CText
        $Ctl.BorderStyle = 'FixedSingle'
    }
    elseif ($Ctl -is [System.Windows.Forms.ComboBox]) {
        # FlatStyle 必须设成 Flat，否则深色皮肤下输入框底色会被系统忽略
        $Ctl.FlatStyle = 'Flat'
        $Ctl.BackColor = $script:CCard
        $Ctl.ForeColor = $script:CText
    }
    elseif ($Ctl -is [System.Windows.Forms.NumericUpDown]) {
        $Ctl.BackColor = $script:CCard
        $Ctl.ForeColor = $script:CText
        $Ctl.BorderStyle = 'FixedSingle'
    }
    elseif ($Ctl -is [System.Windows.Forms.CheckBox]) {
        $Ctl.BackColor = [System.Drawing.Color]::Transparent
        $Ctl.ForeColor = $script:CText
    }
    elseif ($Ctl -is [System.Windows.Forms.Panel]) {
        # 顶部色带/分隔线由外面单独设色，这里不动
    }
    elseif ($Ctl -is [System.Windows.Forms.Label]) {
        $Ctl.BackColor = [System.Drawing.Color]::Transparent
        # 状态栏文字颜色由 Set-Status 动态控制
        if (-not [object]::ReferenceEquals($Ctl, $lblStatus)) {
            $Ctl.ForeColor = $script:CText
        }
    }

    foreach ($child in @($Ctl.Controls)) { Paint-Control $child }
}

# 把所有按钮的字体/配色按当前皮肤重刷一遍（换语言换字体后调用）
function Style-AllBtns {
    Paint-Control $form
    $lblSub.ForeColor     = $script:CSub
    $lblSkinTag.ForeColor = $script:CAccentD
    $lblTitle.ForeColor   = $script:CTitle
    $lblHotTip.ForeColor  = $script:CSub
    $lblStatus.ForeColor  = $script:CAccent
}

function Apply-SkinToUi {
    Paint-Control $form
    # 局部微调（分组框上的小字、说明文字用次要色）
    $lblSub.ForeColor      = $script:CSub
    $lblSkinTag.ForeColor  = $script:CAccentD
    $lblTitle.ForeColor    = $script:CTitle
    $lblHotTip.ForeColor   = $script:CSub
    $stripTop.BackColor    = $script:CAccent
    $stripBot.BackColor    = $script:CBorder
    $hdr.BackColor         = $script:CHeadBg
    # 状态栏保持强调色
    $lblStatus.ForeColor   = $script:CAccent
    # 列头是自己拼的，换皮肤后要重刷一次颜色
    Apply-ListHeader
}

Apply-SkinToUi

# ---------------------------------------------------------------- 换语言
# 把界面上每一句中文都过一遍 T() ：中文界面原样不动，英文界面换成英文。
# 找不到译文的句子会保留中文，所以不会出现空白。
function Apply-Lang {
    # 标题、副标题
    $form.Text     = (T 'F9开工')
    $lblTitle.Text = (T 'F9开工')
    $lblSub.Text   = (T '勾上要打开的东西、填好网址，最后点右下角「保存并生效」—— 不用重启电脑，换皮肤也是当场生效。')

    # 分组标题（Update-Counter 会带"已选 N 个"）
    $grpApps.Text  = (T $script:TxAppsTitle)
    $grpUrls.Text  = (T $script:TxUrlsTitle)
    $grpOther.Text = (T '③ 其它设置')

    # 软件区
    $h = Get-HeadLabel $hdrApps 0; if ($h) { $h.Text = (T '打开') }
    $h = Get-HeadLabel $hdrApps 1; if ($h) { $h.Text = (T '软件名称') }
    $h = Get-HeadLabel $hdrApps 2; if ($h) { $h.Text = (T '位置') }
    $btnAddApp.Text  = (T '添加软件')
    $btnEditApp.Text = (T '修改')
    $btnDelApp.Text  = (T '删除')
    $btnUpApp.Text   = (T '上移')
    $btnDownApp.Text = (T '下移')

    # 网页区
    if ($lblU1) { $lblU1.Text = (T '粘贴网址，比如 taobao.com（会自动补 https）') }
    if ($lblU2) { $lblU2.Text = (T '给它起个名字（可以留空，不填就用网址当名字）') }
    $btnAddUrl.Text = (T '添加到列表')
    $h = Get-HeadLabel $hdrUrls 0; if ($h) { $h.Text = (T '打开') }
    $h = Get-HeadLabel $hdrUrls 1; if ($h) { $h.Text = (T '名称') }
    $h = Get-HeadLabel $hdrUrls 2; if ($h) { $h.Text = (T '网址') }
    $btnDelUrl.Text  = (T '删除')
    $btnUpUrl.Text   = (T '上移')
    $btnDownUrl.Text = (T '下移')

    # 其它设置
    $lblHot.Text     = (T '快捷键')
    $lblHotTip.Text  = (T '（下面下拉选，也可以自己输入）')
    $lblA.Text       = (T '软件间隔')
    $lblA2.Text      = (T '毫秒')
    $lblU.Text       = (T '网页间隔')
    $lblU2b.Text     = (T '毫秒')
    $chkAuto.Text    = (T '开机自动在后台待命（推荐勾上）')
    $chkTip.Text     = (T '开工时显示进度窗')
    $chkSticker.Text = (T '开工时飘一下表情包')
    $lblLang.Text    = (T '界面语言')
    $lblSkin.Text    = (T '皮肤')
    if ($lblQuit)      { $lblQuit.Text      = (T '收工快捷键') }
    if ($lblQuitSec)   { $lblQuitSec.Text   = (T '倒计时') }
    if ($lblQuitSecU)  { $lblQuitSecU.Text  = (T '秒') }
    if ($lblQuitTip)   { $lblQuitTip.Text   = (T '（窗口里显示：关机 / 重启 / 睡眠）') }
    if ($btnQuitIcon)  { $btnQuitIcon.Text  = (T '在桌面放一个「F9收工」图标') }
    $btnFolder.Text    = (T '打开程序文件夹')
    $btnLogs.Text      = (T '查看运行记录')
    $btnUninstall.Text = (T '卸载')
    if ($lblIconAct) { $lblIconAct.Text = (T '双击桌面图标') }
    if ($cmbIconAct) {
        # 下拉框里的项目也要跟着语言走，选中的那一项不能丢
        $keepIdx = $cmbIconAct.SelectedIndex
        if ($keepIdx -lt 0) { $keepIdx = $(if ($script:IconAction -eq 'run') { 1 } else { 0 }) }
        $cmbIconAct.Items.Clear()
        [void]$cmbIconAct.Items.Add((T '打开启动台'))
        [void]$cmbIconAct.Items.Add((T '直接开工'))
        $cmbIconAct.SelectedIndex = $keepIdx
    }

    # ④ 开工彩蛋
    $grpFun.Text          = (T '④ 开工彩蛋（可选）：开工时飘自己的表情包 / 放自己的语音')
    $btnPickSticker.Text  = (T '选图片…')
    $btnStickerDefault.Text = (T '用皮肤形象')
    $lblSay.Text          = (T '说一句话')
    $lblVol.Text          = (T '音量')
    $btnSayClear.Text     = (T '清空')
    $lblSound.Text        = (T '放音频')
    $btnPickSound.Text    = (T '选音频文件…')
    $btnSoundClear.Text   = (T '清除')
    $btnFanTest.Text      = (T '试听一下')
    try { Refresh-FanLabels } catch { }

    # 底部按钮
    $btnRunNow.Text = (T '立即开工一次')
    $btnCheck.Text  = (T '试运行检查')
    $btnSave.Text   = (T '保存并生效')

    # 皮肤下拉框的名字也跟着换，右上角小标签同步
    try { Sync-SkinComboItems } catch { }
    $lblSkinTag.Text = (T '皮肤：') + [string]$cmbSkin.Text

    # 提示气泡
    $tip.SetToolTip($btnCheck, (T '只检查不改动：看快捷键能不能用、软件能不能找到，不会真的打开任何东西'))
    $tip.SetToolTip($btnRunNow, (T '立刻按清单把软件和网页打开一遍（就是按快捷键的效果）'))
    $tip.SetToolTip($cmbHotkey, (T '按一下就能开工。可以填两个，中间用 / 分开（例如 F9 / Ctrl+Alt+W），两个都能用。单独一个 F9 容易被别的软件抢走，建议保留一个组合键。'))
    $tip.SetToolTip($cmbQuitHotkey, (T '默认 Ctrl+Alt+Q（Q = quit）。按一下会弹出「关机 / 重启 / 睡眠」的窗口，带倒计时可以取消。清空这一格 = 关掉收工功能'))
    $tip.SetToolTip($numQuitSec, (T '点了「关机 / 重启 / 睡眠」之后等这么多秒才真的执行；这段时间里点【取消】或按 Esc 就能马上停下'))
    $tip.SetToolTip($btnQuitIcon, (T '在桌面上生成一个「F9收工」的图标，双击它就能弹出收工窗口（跟快捷键是同一个功能，后台没在跑也能用）'))
    $tip.SetToolTip($chkAuto, (T '勾上：每次开机后自动在后台待命，随时可以按快捷键'))
    $tip.SetToolTip($chkTip, (T '勾上：按快捷键后右下角出进度窗，进度条一直流动，全部开完几秒后自己收起。不勾：只在后台安静地开，什么都不显示。'))
    $tip.SetToolTip($numA, (T '开完一个软件、开下一个之前等多久（毫秒）。这个数直接加到总耗时上：3 个软件就有 2 个间隔。默认 150 够稳了；想最快就设 0。'))
    $tip.SetToolTip($numU, (T '开完一个网页、开下一个之前等多久（毫秒）。网页交给浏览器开，通常更快，默认 120；设 0 就一起发出去。'))
    $tip.SetToolTip($chkSticker, (T '勾上：开工时屏幕上飘一下表情包（没选图就用当前皮肤的形象图），一秒多就过。默认不勾，不打扰。'))
    $tip.SetToolTip($cmbLang, (T '换界面语言，只是界面文字变了，清单内容不动'))
    $tip.SetToolTip($cmbIconAct, (T '双击桌面上「F9开工」图标时干什么：弹出启动台（点中间木鱼才开工），还是跳过启动台直接开工。改完点「保存并生效」'))
    $tip.SetToolTip($cmbSkin, (T '选一套配色，选完立刻生效，不用点保存也不用重启'))
    $tip.SetToolTip($lvApps, (T '勾上的才会打开；不想要的点「删除」移出列表'))
    $tip.SetToolTip($lvUrls, (T '勾上的才会打开；网址要带 http:// 或 https://'))
    # 开工彩蛋
    $tip.SetToolTip($btnPickSticker, (T '挑一张自己的图当表情包：png / jpg / bmp / gif 都行（gif 只会动第一帧）'))
    $tip.SetToolTip($btnStickerDefault, (T '清掉自己选的图，飘图时改回用当前皮肤的形象图'))
    $tip.SetToolTip($txtSay, (T '打一句话，开工时让电脑自己念出来。中文也能念，不用装任何软件'))
    $tip.SetToolTip($btnSayClear, (T '清空这句话（清空后就不念了）'))
    $tip.SetToolTip($btnPickSound, (T '选一段自己的音频当开工音：wav / mp3 / wma / m4a。选了就优先放它，不再念上面那句话'))
    $tip.SetToolTip($btnSoundClear, (T '清掉音频文件，改回用上面那句话'))
    $tip.SetToolTip($numVol, (T '语音音量 0-100。音频文件走系统音量，这个只管"念一句话"'))
    $tip.SetToolTip($btnFanTest, (T '马上试一下：飘一次表情包 + 放一次语音（不会打开任何软件。会顺手把当前设置保存下来）'))

    # 字体：英文界面优先 Segoe UI，中文界面优先雅黑
    if ($script:Lang -eq 'en') { $script:UiFontNames = @('Segoe UI', 'Microsoft YaHei UI', 'Microsoft YaHei', 'SimSun') }
    else                       { $script:UiFontNames = @('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI', 'SimSun') }
    $script:UiFont = New-UiFont 9.5
    $script:UiBold = New-UiFont 9.5 -Bold
    $form.Font     = $script:UiFont
    try { Style-AllBtns } catch { }
    try { Apply-SkinToUi } catch { }
    Update-Counter
}

# 按语言重建皮肤下拉框的显示文字（选中项保持不变）
function Sync-SkinComboItems {
    if (-not $cmbSkin) { return }
    $want = $script:SkinName
    $old  = $cmbSkin.SelectedIndex
    $cmbSkin.Items.Clear()
    foreach ($k in $script:SkinKeys) {
        $show = [string]$script:SkinLabelsZh[$k]
        if ($script:Lang -eq 'en' -and $script:SkinLabelsEn.ContainsKey($k)) { $show = [string]$script:SkinLabelsEn[$k] }
        [void]$cmbSkin.Items.Add($show)
    }
    $ix = @($script:SkinKeys).IndexOf($want)
    if ($ix -lt 0) { $ix = $old }
    if ($ix -lt 0 -or $ix -ge $cmbSkin.Items.Count) { $ix = 0 }
    if ($cmbSkin.Items.Count -gt 0) { $cmbSkin.SelectedIndex = $ix }
}

# 把界面选的皮肤名映射回皮肤 id（中英文名字都认）
function Get-SkinIdFromLabel {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($k in $script:SkinKeys) {
        if ($k -eq $Text) { return $k }
        if ([string]$script:SkinLabelsZh[$k] -eq $Text) { return $k }
        if ($script:SkinLabelsEn.ContainsKey($k) -and [string]$script:SkinLabelsEn[$k] -eq $Text) { return $k }
    }
    return $null
}

# 立即换皮肤：重载 skin.json -> 重算配色 -> 刷界面 -> 写盘 + 换桌面图标
# 不用关窗口、不用重启，选完下拉框马上见效
function Switch-SkinLive {
    param([string]$SkinId)
    if ([string]::IsNullOrWhiteSpace($SkinId)) { return $false }
    if ($script:SkinKeys -notcontains $SkinId) { return $false }
    if ($SkinId -eq $script:SkinName) { return $false }

    # 1) 先写 skin.json，再从盘上重新读回来（保证界面和文件一致）
    $wrote = $false
    try {
        $job = [System.Text.RegularExpressions.MatchEvaluator]{
            param($m) '"skin": "' + $SkinId + '"'
        }
        $raw = Get-Content -LiteralPath $SkinPath -Raw -Encoding UTF8
        $new = [System.Text.RegularExpressions.Regex]::Replace($raw, '"skin"\s*:\s*"[^"]*"', $job, 1)
        [System.IO.File]::WriteAllText($SkinPath, $new, $Utf8NoBom)
        $wrote = $true
    } catch { $wrote = $false }

    # 2) 重载 + 重算配色
    Load-Skin
    $script:SkinPalette = New-SkinPalette
    Resolve-SkinColors

    # 3) 界面整体重刷（含自建列头、勾选框、按钮描边）
    try { Style-AllBtns } catch { }
    try { Apply-SkinToUi } catch { }
    try { if ($script:Skin -and $script:Skin._label) { $lblSkinTag.Text = (T '皮肤：') + [string]$script:Skin._label } } catch { }
    try { $form.Refresh() } catch { }

    # 4) 顺手换桌面/开始菜单图标
    if ($wrote) { [void](Update-ShortcutIcons $SkinId) }
    return $wrote
}

# 下拉框一改就立刻换（不用等「保存并生效」）
$cmbSkin.Add_SelectedIndexChanged({
    if ($script:Loading) { return }
    if ($script:SwitchSkinBusy) { return }
    $id = Get-SkinIdFromLabel ([string]$cmbSkin.Text)
    if (-not $id -or $id -eq $script:SkinName) { return }
    $script:SwitchSkinBusy = $true
    try {
        $old = 'Default'
        try { $old = $form.Cursor } catch { }
        try { $form.Cursor = 'WaitCursor' } catch { }
        $ok = Switch-SkinLive $id
        try { $form.Cursor = $old } catch { }
        $nm = [string]$cmbSkin.Text
        if ($ok) {
            Set-Status ((T '皮肤已换成「') + $nm + (T '」，已经生效了（按 ') + $cmbHotkey.Text + (T ' 开工也是这个风格）')) 2
        } else {
            Set-Status ((T '皮肤已换成「') + $nm + (T '」，但没写进 skin.json，关掉重开会变回去')) 1
        }
    } catch {
        Set-Status ((T '换皮肤出错：') + $_.Exception.Message) 1
    } finally {
        $script:SwitchSkinBusy = $false
    }
})

$cmbLang.Add_SelectedIndexChanged({
    if ($script:Loading) { return }
    $newLang = 'zh'
    if ($cmbLang.SelectedIndex -eq 1) { $newLang = 'en' }
    if ($newLang -eq $script:Lang) { return }
    $script:Lang = $newLang
    Apply-Lang
    if ($script:Lang -eq 'en') {
        Set-Status 'Language switched to English. Click "Save & Apply" to keep it.' 2
    } else {
        Set-Status '界面语言已换成简体中文。点「保存并生效」就会记住。' 2
    }
})

# ---------------------------------------------------------------- 那条多余的横向滚动条
# 【坑，2026-09-25 修】内容区 $panelContent 是 AutoScroll 的。纵向滚动条一冒出来
# （内容比可视区高时必然出现，用户那台 1366×768 的小屏就一定会），可视宽度就从 992
# 变成 992-17=975；而标题区 $hdr 是按整窗宽 992 硬编码的 —— 超出 17 像素，
# AutoScroll 于是又给你补一条横向滚动条。跑起来不报错、功能也不坏，就是底部多一条
# 多余的横条，而且【只有截图才看得出来】（原来那个"重叠自检"查的是控件互相压，
# 管不到"内容比可视区宽"）。修法：布局定下来之后，把标题区对齐实际可视宽度。
$script:PanelScroll = $panelContent
$script:PanelHeader = $hdr
function Fit-HeaderWidth {
    try {
        $w = [int]$script:PanelScroll.ClientSize.Width
        if ($w -gt 60 -and $script:PanelHeader.Width -ne $w) {
            $script:PanelHeader.Width = $w
            $script:PanelScroll.PerformLayout()
        }
    } catch { }
}

# 打开后自己跳到最前面（避免窗口被别的程序挡在后面 / 最小化着打开）
$form.Add_Shown({
    # 必须在 Show 之后、布局定下来之后再做，否则拿到的可视宽度还是不含滚动条的旧值
    Fit-HeaderWidth
    try {
        $form.WindowState  = [System.Windows.Forms.FormWindowState]::Normal
        $form.ShowInTaskbar = $true
        $form.Activate()
        $form.BringToFront()
    } catch { }
    Fit-HeaderWidth
})

# 窗口大小变了（插拔显示器、改了缩放）可视宽度也会变，跟着重算一次
$form.Add_Resize({ Fit-HeaderWidth })

# ---------------------------------------------------------------- 刷新界面
# 界面上的中文原文集中在这里，换语言时逐条翻译（找不到译文就保留中文）
# 用 [char]0x2460 之类拼标题，避免出现"改了源串却忘了改译文"的漏网之鱼
$script:TxAppsTitle = '① 要打开的软件（勾上的才会打开，从上往下依次启动）'
$script:TxUrlsTitle = '② 要打开的网页（勾上的才会打开，按顺序打开）'

function Update-Counter {
    $a = 0; foreach ($x in $script:Apps) { if ($x.Enabled) { $a++ } }
    $u = 0; foreach ($x in $script:Urls) { if ($x.Enabled) { $u++ } }
    $grpApps.Text = (T $script:TxAppsTitle) + ' — ' + (T '已选') + ' ' + $a + ' ' + (T '个')
    $grpUrls.Text = (T $script:TxUrlsTitle) + ' — ' + (T '已选') + ' ' + $u + ' ' + (T '个')
}

function Refresh-AppList {
    $script:Loading = $true
    $lvApps.BeginUpdate()
    $lvApps.Items.Clear()
    foreach ($it in $script:Apps) {
        $lvi = New-Object System.Windows.Forms.ListViewItem('')
        [void]$lvi.SubItems.Add([string]$it.Name)
        [void]$lvi.SubItems.Add([string]$it.Path)
        $lvi.Checked = [bool]$it.Enabled
        $lvi.Tag = $it
        [void]$lvApps.Items.Add($lvi)
    }
    $lvApps.EndUpdate()
    $script:Loading = $false
    Update-Counter
}

function Refresh-UrlList {
    $script:Loading = $true
    $lvUrls.BeginUpdate()
    $lvUrls.Items.Clear()
    foreach ($it in $script:Urls) {
        $lvi = New-Object System.Windows.Forms.ListViewItem('')
        [void]$lvi.SubItems.Add([string]$it.Name)
        [void]$lvi.SubItems.Add([string]$it.Url)
        $lvi.Checked = [bool]$it.Enabled
        $lvi.Tag = $it
        [void]$lvUrls.Items.Add($lvi)
    }
    $lvUrls.EndUpdate()
    $script:Loading = $false
    Update-Counter
}

# 「快捷键」框里的一行字 -> 快捷键数组。
# 允许一格写多个，用 / 或 、 分开（下拉框里给的是 'F9 / Ctrl+Alt+W'）。
function Split-HotKeyText {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if ($t -eq '') { return @('F9') }
    $parts = @($t -split '\s*[/、,;]\s*|\s+和\s*|\s+and\s+' |
               Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
               ForEach-Object { $_.Trim() })
    if ($parts.Count -eq 0) { return @('F9') }
    return $parts
}

function Load-Ui {
    $warn = Load-Config
    Refresh-AppList
    Refresh-UrlList

    # 多个快捷键就并排显示，例如 'F9 / Ctrl+Alt+W'（也正是下拉框里的写法）
    $cmbHotkey.Text = 'F9'
    if ($script:Hotkeys.Count -gt 0) { $cmbHotkey.Text = ($script:Hotkeys -join ' / ') }
    # 收工设置。数字要先夹到控件允许的范围里，不然 Value 一赋值就抛异常。
    if ($cmbQuitHotkey) { $cmbQuitHotkey.Text = [string]$script:QuitHotkey }
    if ($numQuitSec) {
        $qs = [int]$script:QuitSeconds
        if ($qs -lt [int]$numQuitSec.Minimum) { $qs = [int]$numQuitSec.Minimum }
        if ($qs -gt [int]$numQuitSec.Maximum) { $qs = [int]$numQuitSec.Maximum }
        $numQuitSec.Value = [decimal]$qs
    }
    $numA.Value = [decimal]$script:AppDelay
    $numU.Value = [decimal]$script:UrlDelay
    $chkAuto.Checked = (Test-Path -LiteralPath $StartupVbs)
    $chkTip.Checked  = [bool]$script:ShowTip
    if ($chkSticker) { $chkSticker.Checked = [bool]$script:ShowHeart }
    if ($cmbLang) { $cmbLang.SelectedIndex = $(if ($script:Lang -eq 'en') { 1 } else { 0 }) }
    if ($cmbIconAct) { $cmbIconAct.SelectedIndex = $(if ($script:IconAction -eq 'run') { 1 } else { 0 }) }
    # 开工彩蛋
    if ($txtSay) { $txtSay.Text = [string]$script:SayText }
    if ($numVol) { $numVol.Value = [decimal]$script:VoiceVolume }
    Refresh-FanLabels

    if ($warn -ne '') {
        Set-Status $warn 1
    } else {
        # 后台没在跑就当场拉起来：用户双击图标打开这个面板，
        # 一进来就看到"后台正在待命"，而不是看到一句自己不知道怎么办的报错
        $alive = Test-DaemonAlive
        $weStarted = $false
        # 自检(-SelfTest)是无头跑的，绝不能顺手把后台进程拉起来 —— 那会污染自检结果
        if (-not $alive -and -not $SelfTest) {
            $alive = Ensure-DaemonForPanel
            $weStarted = $true
        }
        $hkText = $cmbHotkey.Text
        if ($alive) {
            if ($weStarted) {
                Set-Status (T '后台刚才没在运行，已经自动帮你启动了 —— 现在按 ' + $hkText + (T ' 就能开工')) 2
            } else {
                Set-Status (T '后台正在待命 —— 按 ' + $hkText + (T ' 就能开工（按下去右下角会闪一下「开工中」）')) 0
            }
        } else {
            Set-Status (T '后台没在运行 —— 点「保存并生效」会自动帮你启动') 1
        }
    }
}

function Set-Status {
    param([string]$Text, [int]$Kind = 0)
    $lblStatus.Text = $Text
    if ($Kind -eq 1) {
        $lblStatus.ForeColor = Convert-HexToColor (Pick-Hex $script:SkinPalette 'warn' '#C25A14') '#C25A14'
    } elseif ($Kind -eq 2) {
        $lblStatus.ForeColor = Convert-HexToColor (Pick-Hex $script:SkinPalette 'ok' '#1E8A50') '#1E8A50'
    } else {
        $lblStatus.ForeColor = $script:CAccent
    }
    $lblStatus.Refresh()
}

# 按位置把列表上的勾选状态同步进数据（顺序一致，不依赖事件参数）
function Sync-CheckState {
    $n = [Math]::Min($lvApps.Items.Count, $script:Apps.Count)
    for ($i = 0; $i -lt $n; $i++) { ($script:Apps)[$i].Enabled = $lvApps.Items[$i].Checked }
    $n = [Math]::Min($lvUrls.Items.Count, $script:Urls.Count)
    for ($i = 0; $i -lt $n; $i++) { ($script:Urls)[$i].Enabled = $lvUrls.Items[$i].Checked }
}

# 把界面上的内容收进数据模型并写盘（勾选状态直接读列表，双保险）
function Apply-UiToModel {
    param([switch]$NoWrite)
    Sync-CheckState

    $script:Hotkeys  = @(Split-HotKeyText $cmbHotkey.Text)
    # 收工快捷键：【刻意不做 Trim 以外的任何加工】—— 空字符串是有意义的
    # （= 关掉收工功能），不能像开工键那样"空了就退回默认"。
    if ($cmbQuitHotkey) { $script:QuitHotkey = ([string]$cmbQuitHotkey.Text).Trim() }
    if ($numQuitSec)     { $script:QuitSeconds = [int]$numQuitSec.Value }
    $script:AppDelay = [int]$numA.Value
    $script:UrlDelay = [int]$numU.Value
    $script:ShowTip  = [bool]$chkTip.Checked
    $script:ShowHeart = [bool]$chkSticker.Checked
    if ($cmbIconAct) { $script:IconAction = $(if ($cmbIconAct.SelectedIndex -eq 1) { 'run' } else { 'panel' }) }
    # 开工彩蛋（控件都在就收，万一某个没建出来也不报错）
    if ($txtSay)         { $script:SayText     = [string]$txtSay.Text }
    if ($numVol)         { $script:VoiceVolume = [int]$numVol.Value }

    # 语言：0=中文 1=English
    $script:Lang = 'zh'
    if ($cmbLang -and $cmbLang.SelectedIndex -eq 1) { $script:Lang = 'en' }

    if (-not $NoWrite) { Save-Config }
}

# ---------------------------------------------------------------- 事件
$lvApps.Add_ItemChecked({
    $script:EvtFired++
    if ($script:Loading) { return }
    Sync-CheckState
    Update-Counter
})
$lvUrls.Add_ItemChecked({
    $script:EvtFired++
    if ($script:Loading) { return }
    Sync-CheckState
    Update-Counter
})

$btnAddApp.Add_Click({
    $script:AppDialogResult = $null
    Show-AppDialog -Existing $null
    if ($script:AppDialogResult) {
        $script:Apps.Add($script:AppDialogResult)
        Refresh-AppList
        $lvApps.Items[$lvApps.Items.Count - 1].Selected = $true
        $lvApps.EnsureVisible($lvApps.Items.Count - 1)
        Set-Status ((T '已添加：') + $script:AppDialogResult.Name + (T ' —— 别忘了点「保存并生效」')) 2
    }
})

function Edit-SelectedApp {
    if ($lvApps.SelectedIndices.Count -eq 0) {
        Set-Status (T '先在左边列表里点一下要修改的那一行') 1
        return
    }
    $i = $lvApps.SelectedIndices[0]
    $cur = ($script:Apps)[$i]
    $script:AppDialogResult = $null
    Show-AppDialog -Existing $cur
    if ($script:AppDialogResult) {
        Refresh-AppList
        Set-Status (T '已修改 —— 别忘了点「保存并生效」') 2
    }
}
$btnEditApp.Add_Click({ Edit-SelectedApp })
$lvApps.Add_DoubleClick({ Edit-SelectedApp })

$btnDelApp.Add_Click({
    if ($lvApps.SelectedIndices.Count -eq 0) {
        Set-Status (T '先在左边列表里点一下要删除的那一行') 1
        return
    }
    $idx = @($lvApps.SelectedIndices | ForEach-Object { [int]$_ } | Sort-Object -Descending)
    foreach ($i in $idx) { $script:Apps.RemoveAt($i) }
    Refresh-AppList
    Set-Status (T '已从清单里删除 —— 别忘了点「保存并生效」') 2
})

function Move-AppItem {
    param([int]$Dir)
    if ($lvApps.SelectedIndices.Count -eq 0) { Set-Status (T '先点一下要移动的那一行') 1; return }
    $i = $lvApps.SelectedIndices[0]
    $j = $i + $Dir
    if ($j -lt 0 -or $j -ge $script:Apps.Count) { return }
    $tmp = ($script:Apps)[$i]
    ($script:Apps)[$i] = ($script:Apps)[$j]
    ($script:Apps)[$j] = $tmp
    Refresh-AppList
    $lvApps.Items[$j].Selected = $true
    $lvApps.Items[$j].Focused = $true
    $lvApps.EnsureVisible($j)
}
$btnUpApp.Add_Click({ Move-AppItem -1 })
$btnDownApp.Add_Click({ Move-AppItem 1 })

$btnAddUrl.Add_Click({
    $v = $txtNewUrl.Text.Trim()
    if ($v -eq '') { Set-Status (T '先把网址粘贴到上面那个框里') 1; return }
    if ($v -notmatch '^[a-zA-Z]+://') { $v = 'https://' + $v }
    $n = $txtNewName.Text.Trim()
    if ($n -eq '') {
        try { $n = ([Uri]$v).Host } catch { $n = $v }
    }
    foreach ($x in $script:Urls) {
        if ($x.Url -ieq $v) { Set-Status ((T '这个网址已经在列表里了：') + $n) 1; return }
    }
    $script:Urls.Add([pscustomobject]@{ Name = $n; Url = $v; Enabled = $true })
    $txtNewUrl.Text = ''
    $txtNewName.Text = ''
    Refresh-UrlList
    $lvUrls.Items[$lvUrls.Items.Count - 1].Selected = $true
    $lvUrls.EnsureVisible($lvUrls.Items.Count - 1)
    Set-Status ((T '已添加网页：') + $n + (T ' —— 别忘了点「保存并生效」')) 2
})

$btnDelUrl.Add_Click({
    if ($lvUrls.SelectedIndices.Count -eq 0) { Set-Status (T '先点一下要删除的那一行') 1; return }
    $idx = @($lvUrls.SelectedIndices | ForEach-Object { [int]$_ } | Sort-Object -Descending)
    foreach ($i in $idx) { $script:Urls.RemoveAt($i) }
    Refresh-UrlList
    Set-Status (T '已删除 —— 别忘了点「保存并生效」') 2
})

function Move-UrlItem {
    param([int]$Dir)
    if ($lvUrls.SelectedIndices.Count -eq 0) { Set-Status (T '先点一下要移动的那一行') 1; return }
    $i = $lvUrls.SelectedIndices[0]
    $j = $i + $Dir
    if ($j -lt 0 -or $j -ge $script:Urls.Count) { return }
    $tmp = ($script:Urls)[$i]
    ($script:Urls)[$i] = ($script:Urls)[$j]
    ($script:Urls)[$j] = $tmp
    Refresh-UrlList
    $lvUrls.Items[$j].Selected = $true
    $lvUrls.Items[$j].Focused = $true
    $lvUrls.EnsureVisible($j)
}
$btnUpUrl.Add_Click({ Move-UrlItem -1 })
$btnDownUrl.Add_Click({ Move-UrlItem 1 })

$btnFolder.Add_Click({
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList $ScriptDir } catch { }
})

$btnLogs.Add_Click({
    $log = Get-LogPath
    if (-not (Test-Path -LiteralPath $log)) {
        Show-TextDialog -Title '运行记录' -Text '还没有运行记录。' -W 620 -H 300
        return
    }
    $all = @(Get-Content -LiteralPath $log -Encoding UTF8)
    $take = 120
    if ($all.Count -le $take) { $lines = $all } else { $lines = $all[($all.Count - $take)..($all.Count - 1)] }
    Show-TextDialog -Title '运行记录（最近的部分）' -Text ($lines -join "`r`n") -W 820 -H 520
})

$btnCheck.Add_Click({
    $old = $form.Cursor
    $form.Cursor = 'WaitCursor'
    Set-Status (T '正在检查，请稍等几秒...') 0
    try { Apply-UiToModel } catch { }
    $log = Get-LogPath
    $before = 0
    if (Test-Path -LiteralPath $log) { $before = @(Get-Content -LiteralPath $log -Encoding UTF8).Count }

    $wasRunning = ((Get-DaemonProcs).Count -gt 0)
    if ($wasRunning) { [void](Stop-Daemon) }
    $text = ''
    try {
        Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $MainScript, '-Check') -WindowStyle Hidden -Wait | Out-Null
        if (Test-Path -LiteralPath $log) {
            $all = @(Get-Content -LiteralPath $log -Encoding UTF8)
            if ($all.Count -gt $before) { $text = ($all[$before..($all.Count - 1)] -join "`r`n") }
        }
    } catch {
        $text = (T '检查时出错了：') + $_.Exception.Message
    } finally {
        if ($wasRunning) { [void](Start-Daemon) }
    }

    if ($text.Trim() -eq '') { $text = (T '没有拿到检查结果。请点「查看运行记录」看看日志。') }
    $text = $text + "`r`n`r`n" + (T '【怎么看】') + "`r`n" +
            '  · ' + (T '快捷键那一行写「✓ 快捷键可用」= 能用；') + "`r`n" +
            '  · ' + (T '写「✗ ...被别的程序占用」= 换一个快捷键（在下面「快捷键」框里改）；') + "`r`n" +
            '  · ' + (T '每一行「软件: 名称 -> 路径」= 找到了；写「跳过软件(没找到)」= 这个要重新填路径。')

    $form.Cursor = $old
    Set-Status (T '检查完成（已顺手把界面上的清单保存好，但没有真的打开任何东西）') 2
    Show-TextDialog -Title (T '试运行检查结果（没有真的打开任何东西）') -Text $text -W 860 -H 540
})

$btnRunNow.Add_Click({
    $form.Cursor = 'WaitCursor'
    Set-Status (T '正在按清单打开...') 0
    try { Apply-UiToModel } catch { }
    try {
        Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $MainScript, '-Run') -WindowStyle Hidden | Out-Null
        Set-Status (T '已经按界面上的清单打开了 —— 看看屏幕上有没有') 2
    } catch {
        Set-Status ((T '打开失败：') + $_.Exception.Message) 1
    }
    $form.Cursor = 'Default'
})

$btnSave.Add_Click({
    # 1) 收集界面上的值并写盘
    try {
        Apply-UiToModel
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show((T '保存失败：') + $_.Exception.Message, (T 'F9开工 · 设置'))
        return
    }
    $hkParts = @(Split-HotKeyText $cmbHotkey.Text)
    $hk = ($hkParts -join ' / ')

    # 2) 皮肤：选下拉框时已经当场换过了，这里只兜底一次
    #    界面文字可能已经是英文了，所以中英文名字都要认
    $skinMsg = ''
    $skinChanged = $false
    try {
        $sel = [string]$cmbSkin.Text
        $wantId = $null
        foreach ($k in $script:SkinKeys) {
            $lab = [string]$script:SkinLabelsZh[$k]
            if ($lab -eq $sel -or $k -eq $sel) { $wantId = $k; break }
            if ($script:SkinLabelsEn.ContainsKey($k) -and [string]$script:SkinLabelsEn[$k] -eq $sel) { $wantId = $k; break }
        }
        if ($wantId -and $wantId -ne $script:SkinName) {
            if (Switch-SkinLive $wantId) {
                $skinMsg = (T '皮肤已换成「') + $sel + (T '」（桌面图标也换了）；')
                $skinChanged = $true
            } else {
                $skinMsg = (T '皮肤没换成功；')
            }
        }
    } catch { $skinMsg = '' }

    # 3) 开机自启
    $autoMsg = ''
    if ($chkAuto.Checked) {
        if (Enable-AutoStart) { $autoMsg = (T '开机自启已打开；') } else { $autoMsg = (T '开机自启没设置成功；') }
    } else {
        [void](Disable-AutoStart)
        $autoMsg = (T '开机自启已关掉；')
    }

    # 4) 重启后台，让快捷键立刻生效
    $form.Cursor = 'WaitCursor'
    $n = Stop-Daemon
    $ok = Start-Daemon
    $form.Cursor = 'Default'

    # 关了提示弹窗时顺带说一句，免得用户以为坏了
    $tipMsg = ''
    if (-not $chkTip.Checked) { $tipMsg = (T '（开工时不显示进度窗，只安静地打开东西）') }

    if ($skinChanged) {
        Set-Status ((T '已保存。') + $skinMsg + (T '现在按 ') + $hk + (T ' 就是新皮肤的进度窗了')) 2
    } elseif ($ok) {
        Set-Status ((T '已保存，') + $autoMsg + (T '后台已重新启动 —— 现在按 ') + $hk + (T ' 试试') + $tipMsg) 2
    } else {
        Set-Status ((T '已保存，') + $autoMsg + (T '但后台没启动成功，重启电脑后会自动启动')) 1
    }
})

$chkTip.Add_CheckedChanged({
    if ($chkTip.Checked) { Set-Status (T '开工时右下角会出进度窗，进度条一直流动到全部开完') 0 }
    else { Set-Status (T '开工时不显示进度窗，只在后台安静地打开东西（改完记得点「保存并生效」）') 1 }
})

$chkAuto.Add_CheckedChanged({
    if ($chkAuto.Checked) { Set-Status (T '关掉后开机就不会自动待命了（现在按快捷键还是能用）') 0 }
    else { Set-Status '不勾选 = 以后开机不再自动待命（改完记得点「保存并生效」）' 1 }
})

# ---------------------------------------------------------------- ④ 开工彩蛋
# 选表情包图片
$btnPickSticker.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = (T '挑一张图片当开工表情包')
        $dlg.Filter = (T '图片') + '|*.png;*.jpg;*.jpeg;*.bmp;*.gif|' + (T '所有文件') + '|*.*'
        if ($script:StickerPath -and (Test-Path -LiteralPath $script:StickerPath)) {
            $dlg.InitialDirectory = Split-Path -Parent $script:StickerPath
        }
        if ($dlg.ShowDialog() -eq 'OK') {
            $script:StickerPath = $dlg.FileName
            Refresh-FanLabels
            if (-not $chkSticker.Checked) { $chkSticker.Checked = $true }
            Set-Status ((T '表情包已选好：') + [System.IO.Path]::GetFileName($dlg.FileName) + (T ' —— 点「试听一下」看看效果')) 2
        }
    } catch {
        Set-Status ((T '选图片出错：') + $_.Exception.Message) 1
    }
})

# 清掉自定义表情包，改回皮肤形象
$btnStickerDefault.Add_Click({
    $script:StickerPath = ''
    Refresh-FanLabels
    Set-Status (T '已经改回用当前皮肤的形象图了（记得点「保存并生效」）') 2
})

# 清空"说一句话"
$btnSayClear.Add_Click({
    $txtSay.Text = ''
    Apply-UiToModel
    Set-Status (T '那句话已清空（记得点「保存并生效」）') 2
})

# 选音频文件
$btnPickSound.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = (T '选一段音频当开工音')
        $dlg.Filter = (T '音频') + '|*.wav;*.mp3;*.wma;*.m4a|' + (T '所有文件') + '|*.*'
        if ($script:SoundPath -and (Test-Path -LiteralPath $script:SoundPath)) {
            $dlg.InitialDirectory = Split-Path -Parent $script:SoundPath
        }
        if ($dlg.ShowDialog() -eq 'OK') {
            $script:SoundPath = $dlg.FileName
            Refresh-FanLabels
            Set-Status ((T '音频已选好：') + [System.IO.Path]::GetFileName($dlg.FileName) + (T ' —— 点「试听一下」听听')) 2
        }
    } catch {
        Set-Status ((T '选音频出错：') + $_.Exception.Message) 1
    }
})

# 清掉音频
$btnSoundClear.Add_Click({
    $script:SoundPath = ''
    Refresh-FanLabels
    Set-Status (T '音频已清除，改回用「说一句话」（记得点「保存并生效」）') 2
})

# 试听：先存盘再让启动器演一遍，用户改完马上能听到/看到
$btnFanTest.Add_Click({
    if (-not $chkSticker.Checked -and -not $txtSay.Text.Trim() -and -not $script:SoundPath) {
        Set-Status (T '什么都还没设 —— 先勾上「开工时飘一下表情包」，或者写一句话 / 选段音频') 1
        return
    }
    try {
        # 注意：这里会顺手把设置写盘，不然启动器读到的还是旧配置，试听就没效果
        Apply-UiToModel
        Set-Status (T '正在试：飘表情包 + 放语音（不会打开任何软件。设置已顺手保存）') 0
        $form.Cursor = 'WaitCursor'
        Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $MainScript, '-FanTest') -WindowStyle Hidden | Out-Null
        $form.Cursor = 'Default'
    } catch {
        $form.Cursor = 'Default'
        Set-Status ((T '试听失败：') + $_.Exception.Message) 1
    }
})

$btnUninstall.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "确定要卸载吗？`r`n`r`n· 取消开机自动待命`r`n· 删掉桌面图标`r`n· 结束后台程序`r`n`r`n程序文件夹会保留，方便以后再用。",
        'F9开工 · 卸载', 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        try {
            & $PSExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Uninstall.ps1') | Out-Null
        } catch { }
        [void][System.Windows.Forms.MessageBox]::Show((T '已经卸载了。程序文件夹还在，不需要的话可以直接删掉：') + "`r`n" + $ScriptDir, (T 'F9开工 · 设置'))
        $form.Close()
    }
})

# ---------------------------------------------------------------- 启动
Load-Ui

if ($SelfTest) {
    Add-St '===== F9开工 · 设置 —— 内部自检 ====='
    # ---------------- 皮肤 ----------------
    Add-St ('皮肤: ' + $script:SkinName + ' / ' + $(if ($script:Skin -and $script:Skin._label) { $script:Skin._label } else { '(无)' }))
    Add-St ('皮肤可选: ' + ($script:SkinKeys -join ', '))
    Add-St ('皮肤下拉框项目: ' + (@($cmbSkin.Items) -join ' / ') + '  当前选中=' + [string]$cmbSkin.Text)
    Add-St ('皮肤形象图: ' + $(if (Get-SkinArtPath) { '有' } else { '无' }))
    Add-St ('窗口背景色: ' + $form.BackColor.R + ',' + $form.BackColor.G + ',' + $form.BackColor.B)
    Add-St ('强调色: ' + $script:CAccent.R + ',' + $script:CAccent.G + ',' + $script:CAccent.B)
    Add-St ('保存按钮底色: ' + $btnSave.BackColor.R + ',' + $btnSave.BackColor.G + ',' + $btnSave.BackColor.B + ' 样式=' + $btnSave.FlatStyle)
    Add-St ('列表底色: ' + $lvApps.BackColor.R + ',' + $lvApps.BackColor.G + ',' + $lvApps.BackColor.B)
    Add-St ('标题文字色: ' + $lblTitle.ForeColor.R + ',' + $lblTitle.ForeColor.G + ',' + $lblTitle.ForeColor.B)
    $hds = @()
    for ($i = 0; $i -lt 3; $i++) { $x = Get-HeadLabel $hdrApps $i; if ($x) { $hds += $x.Text } else { $hds += '?' } }
    Add-St ('列头(软件): ' + ($hds -join ' | '))
    $hds = @()
    for ($i = 0; $i -lt 3; $i++) { $x = Get-HeadLabel $hdrUrls $i; if ($x) { $hds += $x.Text } else { $hds += '?' } }
    Add-St ('列头(网页): ' + ($hds -join ' | '))
    Add-St ('列头底色: ' + $hdrApps.BackColor.R + ',' + $hdrApps.BackColor.G + ',' + $hdrApps.BackColor.B + ' / 字色: ' + $hdrApps.Controls[0].ForeColor.R + ',' + $hdrApps.Controls[0].ForeColor.G + ',' + $hdrApps.Controls[0].ForeColor.B)
    Add-St ('界面字体: ' + $form.Font.Name + ' ' + $form.Font.Size)
    Add-St ('窗口尺寸: ' + $form.ClientSize.Width + ' x ' + $form.ClientSize.Height)
    Add-St ('控件总数: ' + $form.Controls.Count)
    Add-St ('软件清单行数: ' + $lvApps.Items.Count)
    Add-St ('网页清单行数: ' + $lvUrls.Items.Count)
    # ---------------- 快捷键与后台 ----------------
    Add-St ('快捷键框项目: ' + (@($cmbHotkey.Items) -join ' / '))
    Add-St ('快捷键框内容: ' + $cmbHotkey.Text)
    Add-St ('拆出来的快捷键: ' + (@(Split-HotKeyText $cmbHotkey.Text) -join ' + '))
    Add-St ('后台待命进程在跑吗: ' + $(if (Test-DaemonAlive) { '✓ 在跑（快捷键可以用）' } else { '✗ 没在跑' }))
    Add-St ('认出的常驻进程数: ' + (@(Get-DaemonProcs).Count) + ' （这个数应该和上面一致，0 就是没在跑）')
    Add-St ('开工间隔: 软件 ' + $script:AppDelay + ' ms / 网页 ' + $script:UrlDelay + ' ms')
    Add-St ('界面上显示的间隔: ' + $numA.Value + ' / ' + $numU.Value)
    Add-St ('开机自启勾选状态: ' + $chkAuto.Checked)
    # ---------------- 一键收工 ----------------
    Add-St ''
    Add-St '----- 功能：一键收工（关机 / 重启 / 睡眠）-----'
    Add-St ('收工快捷键框内容: "' + [string]$cmbQuitHotkey.Text + '"   （空 = 关掉收工功能）')
    Add-St ('收工倒计时: ' + $numQuitSec.Value + ' 秒')
    Add-St ('收工窗口里显示的动作: ' + (@($script:QuitActions) -join ' / '))
    try {
        $svQ = [string]$cmbQuitHotkey.Text
        $svS = $numQuitSec.Value
        $cmbQuitHotkey.Text = 'Ctrl+Alt+Q'
        $numQuitSec.Value = [decimal]45
        Apply-UiToModel -NoWrite
        $q1 = (($script:QuitHotkey -eq 'Ctrl+Alt+Q') -and ([int]$script:QuitSeconds -eq 45))
        $cmbQuitHotkey.Text = ''
        Apply-UiToModel -NoWrite
        $q2 = ($script:QuitHotkey -eq '')
        $cmbQuitHotkey.Text = $svQ
        $numQuitSec.Value = $svS
        Apply-UiToModel -NoWrite
        Add-St ('收工设置 改得动: ' + $q1 + ' / 清空=关掉收工: ' + $q2)
    } catch {
        Add-St ('收工设置自检出错: ' + $_.Exception.Message)
    }
    # 面板里放这个按钮到底有没有用？看桌面上那个图标在不在
    $quitLnkChk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'F9收工.lnk'
    Add-St ('桌面「F9收工」图标: ' + $(if (Test-Path -LiteralPath $quitLnkChk) { '在' } else { '不在（点面板上的按钮可以生成）' }))

    # ---------------- 新功能 1：不弹窗（后台默默干活）----------------
    Add-St ''
    Add-St '----- 功能：开工时不显示进度窗 -----'
    Add-St ('"开工时显示进度窗" 勾选状态: ' + $chkTip.Checked + '  (= 按快捷键后右下角要不要出进度窗)')
    Add-St ('读到的 showTipAfterRun: ' + $script:ShowTip)
    try {
        $saved = $chkTip.Checked
        $chkTip.Checked = $false
        [System.Windows.Forms.Application]::DoEvents()
        Apply-UiToModel -NoWrite
        $tipOffOk = (-not $script:ShowTip)
        $chkTip.Checked = $true
        [System.Windows.Forms.Application]::DoEvents()
        Apply-UiToModel -NoWrite
        $tipOnOk = ($script:ShowTip)
        $chkTip.Checked = $saved
        [System.Windows.Forms.Application]::DoEvents()
        Apply-UiToModel -NoWrite
        Add-St ('取消勾选 -> showTipAfterRun=False: ' + $tipOffOk)
        Add-St ('勾回来 -> showTipAfterRun=True: ' + $tipOnOk)
    } catch {
        Add-St ('不弹窗开关测试出错: ' + $_.Exception.Message)
    }

    # 顺带验证"开工飘一下形象"开关
    if ($chkSticker) {
        try {
            $saveH = $chkSticker.Checked
            $chkSticker.Checked = $true
            [System.Windows.Forms.Application]::DoEvents()
            Apply-UiToModel -NoWrite
            $heartOnOk = ($script:ShowHeart)
            $chkSticker.Checked = $false
            [System.Windows.Forms.Application]::DoEvents()
            Apply-UiToModel -NoWrite
            $heartOffOk = (-not $script:ShowHeart)
            $chkSticker.Checked = $saveH
            [System.Windows.Forms.Application]::DoEvents()
            Apply-UiToModel -NoWrite
            Add-St ('开工飘形象开关: 勾上->True=' + $heartOnOk + '  取消->False=' + $heartOffOk)
        } catch {
            Add-St ('开工飘形象开关测试出错: ' + $_.Exception.Message)
        }
    }

    # ---------------- 功能：开工彩蛋（表情包 + 语音） ----------------
    Add-St ''
    Add-St '----- 功能：开工彩蛋（飘表情包 / 放语音）-----'
    Add-St ('飘表情包开关: ' + $chkSticker.Checked)
    Add-St ('自定义表情包: ' + $(if ($script:StickerPath) { $script:StickerPath } else { '(没选，用皮肤形象)' }))
    if ($lblStickerName) { Add-St ('  界面显示: ' + $lblStickerName.Text) }
    Add-St ('说一句话: ' + $(if ($script:SayText) { $script:SayText } else { '(空)' }))
    Add-St ('音频文件: ' + $(if ($script:SoundPath) { $script:SoundPath } else { '(没选)' }))
    if ($lblSoundName) { Add-St ('  界面显示: ' + $lblSoundName.Text) }
    Add-St ('语音音量: ' + $script:VoiceVolume)

    # 试着读一张真图片 + 走一遍"选图/清除"的界面动作
    try {
        $artChk = Get-SkinArtPath
        if ($artChk) {
            $script:StickerPath = $artChk
            Refresh-FanLabels
            $nameShown = $lblStickerName.Text
            $script:StickerPath = ''
            Refresh-FanLabels
            $noneShown = $lblStickerName.Text
            Add-St ('选中图片时显示: ' + $nameShown)
            Add-St ('清掉图片后显示: ' + $noneShown)
            Add-St ('清除后确实为空: ' + ($script:StickerPath -eq ''))
        } else {
            Add-St '没有可用的皮肤形象图，跳过选图往返测试'
        }
    } catch {
        Add-St ('表情包往返测试出错: ' + $_.Exception.Message)
    }

    # 音量输入框边界
    try {
        $saveV = $numVol.Value
        $numVol.Value = 0
        Apply-UiToModel -NoWrite
        $volMin = ($script:VoiceVolume -eq 0)
        $numVol.Value = 100
        Apply-UiToModel -NoWrite
        $volMax = ($script:VoiceVolume -eq 100)
        $numVol.Value = $saveV
        Apply-UiToModel -NoWrite
        Add-St ('音量上下限: 0->' + $volMin + '  100->' + $volMax)
    } catch {
        Add-St ('音量测试出错: ' + $_.Exception.Message)
    }

    # 这句话、音频要能正确写进 config.json
    try {
        $bakSay = $script:SayText
        $bakSnd = $script:SoundPath
        $bakVol = $script:VoiceVolume
        $script:SayText = '开工啦，今天也要加油'
        $script:SoundPath = 'C:\test\hello.mp3'
        $script:VoiceVolume = 66
        $j = Build-ConfigText
        $okSay = ($j -like '*"sayText": "开工啦，今天也要加油"*')
        # 注意：写进 JSON 时反斜杠会被转义成两个，所以这里要按转义后的样子比对
        $okSnd = ($j -like '*"soundPath": "C:\\test\\hello.mp3"*')
        $okVol = ($j -like '*"voiceVolume": 66*')
        $parsed = $null
        try { $parsed = ($j | ConvertFrom-Json) } catch { }
        $jsonOk = ($null -ne $parsed)
        # 回读一遍，确认落盘的就是我们设的值
        $readBack = ''
        if ($parsed) { $readBack = [string]$parsed.soundPath }
        Add-St ('sayText 写进配置: ' + $okSay + '  soundPath: ' + $okSnd + '  voiceVolume: ' + $okVol)
        Add-St ('  soundPath 回读一致: ' + ($readBack -eq 'C:\test\hello.mp3') + ' -> ' + $readBack)
        Add-St ('带彩蛋字段的 JSON 仍能解析: ' + $jsonOk)
        $script:SayText = $bakSay
        $script:SoundPath = $bakSnd
        $script:VoiceVolume = $bakVol
    } catch {
        Add-St ('彩蛋配置写入测试出错: ' + $_.Exception.Message)
    }

    # 双击桌面图标的行为：写进配置 + 下拉框往返
    try {
        $bakAct = $script:IconAction
        $script:IconAction = 'run'
        $j2 = Build-ConfigText
        $okAct = ($j2 -like '*"iconAction": "run"*')
        $script:IconAction = 'panel'
        $j3 = Build-ConfigText
        $okAct2 = ($j3 -like '*"iconAction": "panel"*')
        Add-St ('桌面图标动作写进配置: run=' + $okAct + '  panel=' + $okAct2)
        Add-St ('下拉框项目: ' + (@($cmbIconAct.Items) -join ' / '))

        # 通过下拉框改一遍，看模型有没有跟着变
        $cmbIconAct.SelectedIndex = 1
        Apply-UiToModel
        $viaUi = $script:IconAction
        $cmbIconAct.SelectedIndex = 0
        Apply-UiToModel
        $viaUi2 = $script:IconAction
        Add-St ('下拉框选"直接开工"-> ' + $viaUi + '  选"打开启动台"-> ' + $viaUi2)
        $script:IconAction = $bakAct
        Load-Ui
    } catch {
        Add-St ('桌面图标动作测试出错: ' + $_.Exception.Message)
    }

    # 新增的界面文字在英文界面下真的会变英文（不是留着中文）
    try {
        $zhWas = $script:Lang
        $script:Lang = 'en'
        $pairs = @(
            @('开工时飘一下表情包', 'Float a sticker on launch'),
            @('试听一下', 'Preview it'),
            @('说一句话', 'Say a line'),
            @('选图片…', 'Pick image...')
        )
        $miss = @()
        foreach ($pr in $pairs) {
            if ((T $pr[0]) -ne $pr[1]) { $miss += $pr[0] }
        }
        $script:Lang = $zhWas
        Add-St ('开工彩蛋文案有英文: ' + $(if ($miss.Count -eq 0) { 'True' } else { 'False -> 缺: ' + ($miss -join ' / ') }))
    } catch {
        Add-St ('彩蛋文案翻译测试出错: ' + $_.Exception.Message)
    }

    # 反斜杠、引号这类字符不能在 JSON 里写坏
    try {
        $bakSay = $script:SayText
        $script:SayText = '带"引号"和\反斜杠'
        $j2 = Build-ConfigText
        $ok2 = 'NO'
        try { $null = ($j2 | ConvertFrom-Json); $ok2 = 'YES' } catch { }
        $script:SayText = $bakSay
        Add-St ('特殊字符(引号/反斜杠)的 JSON 仍能解析: ' + $ok2)
    } catch {
        Add-St ('特殊字符测试出错: ' + $_.Exception.Message)
    }

    # ---------------- 功能：点下拉框立刻换皮肤（不关窗口） ----------------
    Add-St ''
    Add-St '----- 功能：切换皮肤立刻生效 -----'
    try {
        $origId  = $script:SkinName
        $origIx  = $cmbSkin.SelectedIndex
        $bgBefore = '' + $form.BackColor.R + ',' + $form.BackColor.G + ',' + $form.BackColor.B
        $acBefore = '' + $script:CAccent.R + ',' + $script:CAccent.G + ',' + $script:CAccent.B

        # 找一个和当前不一样的皮肤，用"改下拉框"的方式切换（= 用户点下拉框）
        $targetIx = -1
        for ($i = 0; $i -lt $cmbSkin.Items.Count; $i++) {
            if ($i -ne $origIx) { $targetIx = $i; break }
        }
        if ($targetIx -ge 0) {
            $cmbSkin.SelectedIndex = $targetIx
            [System.Windows.Forms.Application]::DoEvents()
            $newId    = $script:SkinName
            $bgAfter  = '' + $form.BackColor.R + ',' + $form.BackColor.G + ',' + $form.BackColor.B
            $acAfter  = '' + $script:CAccent.R + ',' + $script:CAccent.G + ',' + $script:CAccent.B
            $lvAfter  = '' + $lvApps.BackColor.R + ',' + $lvApps.BackColor.G + ',' + $lvApps.BackColor.B
            $tagAfter = [string]$lblSkinTag.Text

            # skin.json 里那行是不是也写进去了（关掉重开不会变回去）
            $fileNow = ''
            try {
                $rawNow = Get-Content -LiteralPath $SkinPath -Raw -Encoding UTF8
                $m = [regex]::Match($rawNow, '"skin"\s*:\s*"([^"]*)"')
                if ($m.Success) { $fileNow = $m.Groups[1].Value }
            } catch { }

            Add-St ('切换前皮肤: ' + $origId + '  底=' + $bgBefore + '  强调=' + $acBefore)
            Add-St ('切换后皮肤: ' + $newId + '  底=' + $bgAfter + '  强调=' + $acAfter)
            Add-St ('窗口底色当场变了: ' + ($bgAfter -ne $bgBefore))
            Add-St ('强调色当场变了: ' + ($acAfter -ne $acBefore))
            Add-St ('列表底色也已重刷: ' + $lvAfter)
            Add-St ('右上角皮肤标签: ' + $tagAfter)
            Add-St ('skin.json 已写入: ' + $fileNow + '  == 选中: ' + ($fileNow -eq $newId))
            Add-St ('状态栏提示: ' + $lblStatus.Text)

            # 切回去
            $cmbSkin.SelectedIndex = $origIx
            [System.Windows.Forms.Application]::DoEvents()
            Add-St ('切回原皮肤: ' + $script:SkinName + '  底=' + $form.BackColor.R + ',' + $form.BackColor.G + ',' + $form.BackColor.B)
            Add-St ('切回成功: ' + ($script:SkinName -eq $origId))
        } else {
            Add-St '只有一个皮肤可选，跳过'
        }
    } catch {
        Add-St ('换皮肤测试出错: ' + $_.Exception.Message)
    }

    # ---------------- 新功能 2：切换语言 ----------------
    Add-St ''
    Add-St '----- 功能：切换界面语言 -----'
    Add-St ('当前语言: ' + $script:Lang)
    Add-St ('语言下拉框: ' + (@($cmbLang.Items) -join ' / ') + '  当前选中=' + [string]$cmbLang.Text)
    Add-St ('字典条数: ' + $script:Dict.Count)
    try {
        $zhTitle = $lblTitle.Text
        $zhGrp   = $grpOther.Text
        $zhSave  = $btnSave.Text
        $zhSub   = $lblSub.Text

        $cmbLang.SelectedIndex = 1     # 切到 English
        [System.Windows.Forms.Application]::DoEvents()
        $enTitle = $lblTitle.Text
        $enGrp   = $grpOther.Text
        $enSave  = $btnSave.Text
        $enSub   = $lblSub.Text
        $enFont  = $form.Font.Name
        $enSkin  = [string]$cmbSkin.Text

        $cmbLang.SelectedIndex = 0     # 切回中文
        [System.Windows.Forms.Application]::DoEvents()
        $backTitle = $lblTitle.Text
        $backSkin  = [string]$cmbSkin.Text

        Add-St ('中文标题: ' + $zhTitle)
        Add-St ('英文标题: ' + $enTitle)
        Add-St ('中文③其它设置: ' + $zhGrp)
        Add-St ('英文 3.Other: ' + $enGrp)
        Add-St ('中文保存按钮: ' + $zhSave)
        Add-St ('英文保存按钮: ' + $enSave)
        Add-St ('副标题有翻译(不是中文原文): ' + ($enSub -ne $zhSub) + ' -> ' + $enSub.Substring(0, [Math]::Min(70, $enSub.Length)))
        Add-St ('英文界面字体: ' + $enFont)
        Add-St ('英文界面皮肤名: ' + $enSkin + ' / 切回中文后: ' + $backSkin)
        Add-St ('切回中文标题复位: ' + ($backTitle -eq $zhTitle))
        Add-St ('换语言不影响清单: 软件 ' + $script:Apps.Count + ' 条 / 网页 ' + $script:Urls.Count + ' 条')
    } catch {
        Add-St ('切换语言测试出错: ' + $_.Exception.Message)
    }

    Add-St ''
    Add-St ('启动文件夹 vbs 存在: ' + (Test-Path -LiteralPath $StartupVbs))
    Add-St ('状态栏文字: ' + $lblStatus.Text)
    Add-St ('本机扫描到的程序数: ' + (Get-InstalledApps).Count)
    Add-St ''
    Add-St '----- 生成的 config.json 预览（不会真的覆盖你的配置）-----'
    $preview = Build-ConfigText
    Add-St $preview
    Add-St '----- 预览结束 -----'
    $okJson = 'NO'
    try { $null = ($preview | ConvertFrom-Json); $okJson = 'YES' } catch { $okJson = 'NO :: ' + $_.Exception.Message }
    Add-St ('生成的 JSON 能被正确解析: ' + $okJson)
    Add-St ('提示气泡组件: ' + $tip.GetType().Name)

    # ---- 模拟点击，验证按钮背后的逻辑真的生效 ----
    try {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()

        $n0 = $script:Urls.Count
        $txtNewUrl.Text = 'example.com'
        $txtNewName.Text = '测试网页'
        $btnAddUrl.PerformClick()
        $addOk = ($script:Urls.Count -eq $n0 + 1)
        $urlFix = $false
        if ($addOk) { $urlFix = (($script:Urls)[$script:Urls.Count - 1].Url -eq 'https://example.com') }

        $lvUrls.Items[$lvUrls.Items.Count - 1].Selected = $true
        $btnDelUrl.PerformClick()
        $delOk = ($script:Urls.Count - $n0 -eq 0)

        $lvApps.Items[0].Checked = $false
        [System.Windows.Forms.Application]::DoEvents()
        $chkEvt = (($script:Apps)[0].Enabled -eq $false)
        ($script:Apps)[0].Enabled = $true
        Apply-UiToModel -NoWrite
        $chkSync = (($script:Apps)[0].Enabled -eq $false)
        $lvApps.Items[0].Checked = $true
        [System.Windows.Forms.Application]::DoEvents()
        Apply-UiToModel -NoWrite
        $chkBack = (($script:Apps)[0].Enabled -eq $true)

        $name0 = ($script:Apps)[0].Name
        $lvApps.Items[1].Selected = $true
        $btnUpApp.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $moveOk = (($script:Apps)[0].Name -ne $name0)
        $lvApps.Items[0].Selected = $true
        $btnDownApp.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $moveBack = (($script:Apps)[0].Name -eq $name0)

        # 可选：把界面离线渲染成图片（设了环境变量 LAUNCHER_SHOT 才跑，平时完全不受影响）
        # 只做离屏渲染，绝不截屏（截屏会拍到用户桌面上的其它窗口）
        $shotDir = [string]$env:LAUNCHER_SHOT
        if (-not [string]::IsNullOrWhiteSpace($shotDir)) {
            try {
                if (-not (Test-Path -LiteralPath $shotDir)) {
                    New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
                }
                [void]$form.Handle
                $bw = [int]$form.Width
                $bh = [int]$form.Height
                $bmp = New-Object System.Drawing.Bitmap($bw, $bh)
                $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bw, $bh)))
                $sp = Join-Path $shotDir ($script:SkinName + '.png')
                $bmp.Save($sp, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                Add-St ('界面截图: ' + $sp)

                # A/B 对照：临时把两个下拉框改成 DropDown 再拍一张。
                # 离线渲染（DrawToBitmap）拍不出 DropDownList 的选中文字，
                # 用这张对照图就能确认"文字本身是有的，只是渲染路径拍不到"。
                try {
                    $cmbLang.DropDownStyle = 'DropDown'
                    $cmbSkin.DropDownStyle = 'DropDown'
                    for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents() }
                    $bmpX = New-Object System.Drawing.Bitmap($bw, $bh)
                    $form.DrawToBitmap($bmpX, (New-Object System.Drawing.Rectangle(0, 0, $bw, $bh)))
                    $spX = Join-Path $shotDir ($script:SkinName + '-combo.png')
                    $bmpX.Save($spX, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmpX.Dispose()
                    Add-St ('下拉框对照图: ' + $spX)
                } catch {
                    Add-St ('下拉框对照图失败: ' + $_.Exception.Message)
                } finally {
                    $cmbLang.DropDownStyle = 'DropDownList'
                    $cmbSkin.DropDownStyle = 'DropDownList'
                    for ($i = 0; $i -lt 4; $i++) { [System.Windows.Forms.Application]::DoEvents() }
                }

            } catch {
                Add-St ('界面截图失败: ' + $_.Exception.Message)
            }
        }

        $form.Hide()

        Add-St ('模拟点击: 添加网页=' + $addOk + '  自动补https=' + $urlFix + '  删除=' + $delOk)
        Add-St ('勾选状态: 事件回调生效=' + $chkEvt + '  保存前同步生效=' + $chkSync + '  勾回来=' + $chkBack)
        Add-St ('排序: 上移=' + $moveOk + '  下移复位=' + $moveBack)
        Add-St ('勾选事件累计触发次数: ' + $script:EvtFired)
    } catch {
        Add-St ('模拟点击测试出错: ' + $_.Exception.Message)
    }

    # ---- 布局重叠自检（2026-09-23 加）----
    # Label 虽然没有边框，但它的矩形是实的：它压住谁，谁就缺一块 ——
    # 最典型的就是"说明文字盖掉了下面输入框最上面那条边框"（用户截图圈的就是这里）。
    # 这里把「标签 vs 输入类控件」的重叠全扫一遍，有一处就报一处。
    try {
        $overlap = @()
        foreach ($g in @($grpApps, $grpUrls, $grpFun, $grpOther)) {
            if (-not $g) { continue }
            $labs = @($g.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] })
            $inps = @($g.Controls | Where-Object {
                ($_ -is [System.Windows.Forms.TextBox])      -or
                ($_ -is [System.Windows.Forms.NumericUpDown]) -or
                ($_ -is [System.Windows.Forms.ComboBox])      -or
                ($_ -is [System.Windows.Forms.Button])        -or
                ($_ -is [System.Windows.Forms.ListView])
            })
            foreach ($l in $labs) {
                if ([string]::IsNullOrEmpty($l.Text)) { continue }
                foreach ($c in $inps) {
                    $r = [System.Drawing.Rectangle]::Intersect($l.Bounds, $c.Bounds)
                    if ($r.Width -gt 0 -and $r.Height -gt 0) {
                        $t = [string]$l.Text
                        if ($t.Length -gt 12) { $t = $t.Substring(0, 12) + '…' }
                        $overlap += ($g.Text + ' 里「' + $t + '」压住 ' + $c.GetType().Name +
                                     '（压在 ' + $r.Width + '×' + $r.Height + ' 像素）')
                    }
                }
            }
        }
        if ($overlap.Count -eq 0) {
            Add-St '布局重叠自检: 没有标签压住输入框/按钮 OK'
        } else {
            foreach ($o in $overlap) { Add-St ('布局重叠自检: 【缺陷】' + $o) }
        }
    } catch {
        Add-St ('布局重叠自检出错: ' + $_.Exception.Message)
    }

    # ---- 横向滚动条自检（2026-09-25 加）----
    # 跟上面的"重叠检查"是两件事：那个查"控件互相压"，这个查"整块内容比可视区宽"。
    # 这个只能靠自动查 —— 界面上不会报错，只是底部多一条多余的横条。
    try {
        Fit-HeaderWidth
        [System.Windows.Forms.Application]::DoEvents()
        Fit-HeaderWidth
        $hVis = $false
        try { $hVis = [bool]$script:PanelScroll.HorizontalScroll.Visible } catch { }
        $cw = [int]$script:PanelScroll.ClientSize.Width
        $hw = [int]$script:PanelHeader.Width
        if ($hVis) {
            Add-St ('横向滚动条自检: 【缺陷】内容比可视区宽（可视 ' + $cw + 'px，标题区 ' + $hw +
                    'px）—— 底部会多出一条多余的横条')
        } else {
            Add-St ('横向滚动条自检: 没有多余的横条 OK（可视 ' + $cw + 'px，标题区 ' + $hw + 'px）')
        }
    } catch {
        Add-St ('横向滚动条自检出错: ' + $_.Exception.Message)
    }

    [System.IO.File]::WriteAllLines((Join-Path $LogDir 'gui-selftest.txt'), $SelfTestLines.ToArray(), (New-Object System.Text.UTF8Encoding($true)))
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
