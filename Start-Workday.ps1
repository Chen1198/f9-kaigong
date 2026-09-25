# =====================================================================
#  Workday Launcher  ·  F9开工
#  按一下快捷键 -> 自动打开 config.json 里写好的软件和网页
#
#  用法:
#    不加参数      后台常驻，等待快捷键（开机自启用这个，不要手动双击）
#    -Run          立刻开工一次然后退出（桌面快捷方式用这个）
#    -Run -NoTip   立刻开工一次，且进度窗只闪一下就走（不留完成清单）
#    -Sequence     内部用：「干一次开工」然后退出，由外面的进程拉着跑（面板的
#                  「立即开工一次」走这条路）。后台常驻进程收到快捷键时是
#                  【自己】跑 Invoke-Launch —— 起子进程要等 2~8 秒的冷启动，
#                  那才是以前"按下去半天没动静"的真正原因。
#    -DryRun       只写日志、不真的打开，用来检查配置对不对
#    -Check        自检：查快捷键、查软件路径、查皮肤和语音设置，什么都不打开
#    -SimTrigger   模拟按一次快捷键（不真的按键），并报出"处理这次按键花了多少毫秒"。
#                  想知道"按下去到底卡不卡"就跑它
#    -TipTest      只演一遍右下角进度窗（看皮肤/排版效果用）
#    -FanTest      只演一遍开工彩蛋（飘表情包 + 播语音），不打开软件
#    -Main         桌面图标用这个：按 config.json 里的 iconAction 决定
#                  是打开控制面板，还是直接开工
#    -Shutdown     弹「收工」窗口（关机 / 重启 / 睡眠，带倒计时）。
#                  桌面上的「F9收工」图标双击走这条路
#    -QuitTest     只演一遍收工窗口看看长相，绝不真的关机
#    -QuitShot D   把收工窗口离屏渲染成两张预览图放到目录 D，然后退出
# =====================================================================

[CmdletBinding()]
param(
    [switch]$Run,
    [switch]$DryRun,
    [switch]$Check,
    [switch]$TipTest,
    [switch]$FanTest,
    [switch]$Main,
    [switch]$NoTip,
    [switch]$Sequence,
    [switch]$ShowTip,
    [switch]$SimTrigger,
    [switch]$Shutdown,
    [switch]$QuitTest,
    [string]$QuitShot = '',
    [string]$Trigger = ''
)

$ErrorActionPreference = 'Continue'

if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$ConfigPath = Join-Path $ScriptDir 'config.json'
$SkinPath   = Join-Path $ScriptDir 'skin.json'
$ArtDir     = Join-Path $ScriptDir 'art'
$LogDir     = Join-Path $ScriptDir 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile   = Join-Path $LogDir ('launcher-' + (Get-Date -Format 'yyyy-MM') + '.log')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 日志每行前面挂个身份牌：后台进程写「[后台]」，干活的子进程写「[开工]」，
# 混在一起也一眼看得出谁是谁。
$script:LogTag = ''

# ---------------------------------------------------------------- 藏掉自己的黑框
# 快捷方式直接拉 powershell.exe 跑 .ps1 时，屏幕上会先冒出一个黑色控制台窗口。
# 参数里的 -WindowStyle Hidden 有时来不及生效（或者快捷方式是旧的、根本没带这个参数），
# 黑框就留在那儿了。这里干脆从脚本内部把它藏掉。
#
# 但要注意：如果是 .bat 拉起来的，那个黑框里还有 cmd 在等我们打印结果，
# 这种情况绝对不能藏。判断条件两条：
#   1) 我们是被 -File 当独立进程拉起来的（不是用户在自己窗口里 & 调用）
#   2) 这个控制台是我们独占的（GetConsoleProcessList 里只有自己）
function Hide-OwnConsole {
    # 【重要，动之前先看这段】内部调用一律直接跳过。
    #
    # 下面那段 Add-Type 是"现场编译 C#"：它会去起一个 csc.exe，实测在用户这台
    # 机器上要吃掉 2~7 秒（杀毒软件每次都要扫一遍新生成的 exe）。而这条路径
    # 每次开工都会被走一遍 —— 表现就是「按了快捷键，要等好几秒才见软件开」。
    #
    # 关键是：这些内部调用本来就没有黑框要藏 ——
    #   · -Sequence   由后台用 CreateNoWindow + -WindowStyle Hidden 拉起
    #   · -Check / -DryRun / -TipTest / -FanTest / -SimTrigger  同样是隐藏启动
    # 真正需要"藏黑框"的只有一种情况：用户双击快捷方式、控制台是我们独占的。
    # 那种情况走的是 -Main / -Run，会老老实实执行下面的逻辑。
    if ($Sequence -or $Check -or $DryRun -or $SimTrigger -or $TipTest -or $FanTest) { return $false }

    # 先做最便宜的判断，省掉一次 Add-Type 编译
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

        [void][WorkdayConsole]::ShowWindow($hwnd, 0)      # 0 = SW_HIDE
        return $true
    } catch {
        return $false
    }
}

# 越早藏越好：放在所有其它代码之前
[void](Hide-OwnConsole)


function Get-LauncherSkin {
    if (-not (Test-Path -LiteralPath $SkinPath)) { return $null }
    try {
        $raw  = Get-Content -LiteralPath $SkinPath -Raw -Encoding UTF8
        $all  = $raw | ConvertFrom-Json
        $name = [string]$all.skin
        $one  = $null
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $p = $all.skins.PSObject.Properties[$name]
            if ($p) { $one = $p.Value }
        }
        if (-not $one) {
            $name = 'minimal'
            $p = $all.skins.PSObject.Properties['minimal']
            if ($p) { $one = $p.Value }
        }
        if (-not $one) { return $null }
        $one | Add-Member -NotePropertyName '_name' -NotePropertyValue $name -Force
        return $one
    } catch {
        Write-Log ('皮肤文件读不了，先用默认外观: ' + $_.Exception.Message)
        return $null
    }
}

function ConvertTo-SkinColor {
    param([string]$Hex, [string]$Fallback)
    if ([string]::IsNullOrWhiteSpace($Hex)) { $Hex = $Fallback }
    try {
        $h = $Hex.Trim().TrimStart('#')
        if ($h.Length -ne 6) { $h = $Fallback.TrimStart('#') }
        return [System.Drawing.Color]::FromArgb(
            [Convert]::ToInt32($h.Substring(0, 2), 16),
            [Convert]::ToInt32($h.Substring(2, 2), 16),
            [Convert]::ToInt32($h.Substring(4, 2), 16))
    } catch {
        return [System.Drawing.Color]::FromArgb(31, 42, 55)
    }
}

# 日志：整个程序可能有多个进程同时在写同一个文件（后台 + 干活的子进程），
# 所以写失败不是"出错"，只是恰好撞上了，等一下重试就行 —— 别丢日志。
function Write-Log {
    param([string]$Message, [string]$Tag = '')
    if ([string]::IsNullOrEmpty($Tag)) { $Tag = $script:LogTag }
    # 带毫秒：排查"到底慢在哪一步"的时候，秒级精度根本不够看
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '  ' + $Tag + $Message
    for ($try = 0; $try -lt 8; $try++) {
        try {
            $fs = [System.IO.File]::Open($LogFile, 'Append', 'Write', 'Read')
            try {
                $bytes = $Utf8NoBom.GetBytes($line + [Environment]::NewLine)
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Close() }
            return
        } catch {
            Start-Sleep -Milliseconds (15 * ($try + 1))
        }
    }
}

# 配置缓存：一次开工里要读好几遍 config.json（找软件路径、看开关、看皮肤…），
# 每次按键都重新解析一遍纯属浪费 —— 但用户改了配置要立刻生效，
# 所以用「文件最后写入时间」判断，文件一动就重新读。
$script:CfgCache     = $null
$script:CfgCacheTime = [datetime]::MinValue

function Get-LauncherConfig {
    param([switch]$NoCache)
    if (-not [System.IO.File]::Exists($ConfigPath)) {
        Write-Log ('ERROR 找不到配置文件: ' + $ConfigPath)
        return $null
    }
    try {
        # 【为什么用 File::* 而不是 Test-Path / Get-Item / Get-Content】
        # 这三个是 PowerShell 的 cmdlet，每次调用都要过一遍参数绑定 + 提供程序层，
        # 在"按下按键到窗口亮出来"这条路径上实测能吃掉几十毫秒。
        # File::* 是纯 .NET 静态调用，同一个操作只要几微秒。
        # 用 Utc 版本比较，免得夏令时/时区变化让缓存判等失败。
        $mtime = [System.IO.File]::GetLastWriteTimeUtc($ConfigPath)
        if (-not $NoCache -and $script:CfgCache -and $mtime -eq $script:CfgCacheTime) {
            return $script:CfgCache
        }
        $raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        $script:CfgCache     = $obj
        $script:CfgCacheTime = $mtime
        return $obj
    } catch {
        Write-Log ('ERROR 配置文件格式有问题(少括号/逗号?): ' + $_.Exception.Message)
        return $null
    }
}

# ---------------------------------------------------------------- 找软件
function Resolve-AppPath {
    param($Item)

    $cands = @()
    if ($Item.path) { $cands += ([string]$Item.path) }
    if ($Item.name) { $cands += ([string]$Item.name) }

    # 1) 直接当路径试
    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($c.Trim())
        if (Test-Path -LiteralPath $expanded) { return $expanded }
    }

    # 2) 去开始菜单里按名字找
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if (-not $programData) { $programData = $env:ProgramData }
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if (-not $appData) { $appData = $env:APPDATA }
    $startMenus = @()
    if ($programData) { $startMenus += (Join-Path $programData 'Microsoft\Windows\Start Menu\Programs') }
    if ($appData)     { $startMenus += (Join-Path $appData     'Microsoft\Windows\Start Menu\Programs') }
    $needles = @()
    foreach ($c in $cands) {
        if (-not [string]::IsNullOrWhiteSpace($c)) {
            $needles += ($c.Trim() -replace '\.lnk$', '')
        }
    }

    foreach ($sm in $startMenus) {
        if (-not (Test-Path -LiteralPath $sm)) { continue }
        $lnks = @(Get-ChildItem -LiteralPath $sm -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)
        foreach ($n in $needles) {
            $hit = $lnks | Where-Object { $_.BaseName -ieq $n } | Select-Object -First 1
            if (-not $hit) {
                $hit = $lnks | Where-Object { $_.BaseName -like ($n + '*') } | Select-Object -First 1
            }
            if ($hit) {
                try {
                    $sh = New-Object -ComObject WScript.Shell
                    $target = $sh.CreateShortcut($hit.FullName).TargetPath
                    if ($target -and (Test-Path -LiteralPath $target)) { return $target }
                } catch { }
            }
        }
    }
    return $null
}

function Resolve-BrowserPath {
    param($Cfg, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    if ($Key -ieq 'default') { return $null }
    if (-not $Cfg.browsers) { return $null }
    $prop = $Cfg.browsers.PSObject.Properties[$Key]
    if (-not $prop -or -not $prop.Value) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables([string]$prop.Value)
    if (Test-Path -LiteralPath $expanded) { return $expanded }
    return $null
}

# ---------------------------------------------------------------- 起进程
# 用 .NET 的 ProcessStartInfo 直接起，不走 Start-Process 这个 cmdlet ——
# cmdlet 要过一遍参数绑定、输出流、错误流，实测 60~100 毫秒；
# 这个只要 4~20 毫秒。一次开工要起 3~5 个，省下来的就是"按下去多久见动静"。
function Start-ProcessFast {
    param([string]$Path = '', [string]$Url = '', [string]$Browser = '')
    if ($Url -and $Browser) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $Browser
        $psi.Arguments = $Url
        $psi.UseShellExecute = $false
        [void][System.Diagnostics.Process]::Start($psi)
        return
    }
    if ($Url) {
        # 交给系统默认浏览器打开，这种必须走 ShellExecute（要对 URL 协议做关联解析）
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Url
        $psi.UseShellExecute = $true
        [void][System.Diagnostics.Process]::Start($psi)
        return
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.UseShellExecute = $false
    # 工作目录设成软件自己所在的文件夹：跟双击图标启动时一致，
    # 有些软件（尤其绿色版）靠这个找自己的配置和资源。
    try { $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Path) } catch { }
    # 【为什么把进程对象还回去】调用方要靠它的 Id 去盯着"这个软件的窗口到底出来了没有"
    # —— 用户抱怨的"进度条 3 秒跑完了，应用半分钟才出来"就是缺了这一步（以前 [void] 丢掉了）。
    try {
        return [System.Diagnostics.Process]::Start($psi)
    } catch {
        # 极少数软件用 CreateProcess 起不来（需要管理员权限、或者本身只是个壳），
        # 这种情况退回 Start-Process —— 它走 ShellExecute，能弹 UAC。
        return (Start-Process -FilePath $Path -PassThru -ErrorAction Stop)
    }
}

# ---------------------------------------------------------------- 「已经在跑就别再开一个」
# 用户 2026-09-23 明确要求：同一个东西不能重复打开。
# 重复有三种来源，这里一次全堵住：
#   ① 清单里本来就填了两遍（同一个 exe / 同一个网址）→ 排清单时去重
#   ② 软件已经开着（微信这会儿就开着），再按一次又起一个进程 → 开之前先看进程表
#   ③ 手抖连按、两个快捷键一起按 → Invoke-TriggerAction 里的时间闸 + LaunchBusy
#
# 判断"在不在跑"用 exe 的文件名（去掉扩展名）去比进程名：
# 对绝大多数软件成立（WeChat.exe ↔ 进程 WeChat）。万一某个软件的进程名和 exe 名
# 对不上，最坏结果只是它没被跳过、照常打开 —— 不影响开工。
#
# 【别改成"先把全部 329 个进程列成一个哈希表"】那样要在脚本引擎里循环 329 次
# （取值 + ToLower + try/catch），实测 120 毫秒起步、冷的时候 600 毫秒；
# 而 `GetProcessesByName` 是在原生代码里过滤的，一次只要 10~40 毫秒。
# 而且它每次都是新的 —— 不需要缓存，也就没有"缓存太旧、把刚开过的又开一遍"的坑。
function Test-AppAlreadyRunning {
    param([string]$Exe)
    if ([string]::IsNullOrWhiteSpace($Exe)) { return $false }
    $base = ''
    try { $base = [System.IO.Path]::GetFileNameWithoutExtension($Exe) } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($base)) { return $false }
    $procs = $null
    try { $procs = [System.Diagnostics.Process]::GetProcessesByName($base) } catch { return $false }
    if (-not $procs) { return $false }
    $any = ($procs.Count -gt 0)
    # 每个 Process 对象都要 Dispose，不然会漏句柄（这是用了好几年的老坑）
    foreach ($p in $procs) { try { $p.Dispose() } catch { } }
    return $any
}

# 一行文字按界面语言二选一。
# 不把两种语言拼在一起，是因为中英文语序不一样，硬拼出来两边都不像人话。
function TP {
    param([string]$Zh, [string]$En)
    if ($script:TipLang -eq 'en') { return $En }
    return $Zh
}

# ---------------------------------------------------------------- 开工
function Invoke-Launch {
    # -Warm：预热专用。和 -IsDryRun 一起用，走完"排清单"这条路（把函数体编译好、
    # 把 Resolve-AppPath 热起来），但**一条日志都不写**、什么也不打开，
    # 免得每次后台启动都往日志里灌一堆"[试运行] 软件: xx"让人以为真去试了一遍。
    param([switch]$IsDryRun, [switch]$ShowTip, [switch]$NoProgress, [switch]$Warm, $Cfg)

    # 调用方通常已经读过配置了（它得先知道 showTipAfterRun 才能决定传不传 $ShowTip），
    # 那就直接复用，别再读一遍 —— 读一次 config.json 要几十毫秒，
    # 而这段时间正好卡在"按下按键"和"窗口亮出来"中间，是最不该花的钱。
    $cfg = $Cfg
    if (-not $cfg) { $cfg = Get-LauncherConfig }
    if (-not $cfg) { return }

    # 每开完一个要小等一下，让系统把上一个真正拉起来（不然一口气全点出去
    # 容易互相抢焦点）。等一下是放在"开下一个之前"，不是"开完这个之后"：
    # 第一个软件零延迟（按完马上有动静），最后一个也不用白等收尾。
    # 【别调大】这两个数直接乘进总时长：3 个软件就是 2 个间隔，
    # 400 毫秒的间隔白白吃掉 0.8 秒 —— 用户抱怨的"慢"有一大半是它。
    # 150 毫秒足够让 Windows 把上一个进程登记好，又几乎感觉不到。
    # 0 = 一口气全点出去（机器快、又不怕抢焦点的话可以这么设）。
    $appDelay = 150
    if ($cfg.PSObject.Properties['delayAfterAppMs']) { $appDelay = [int]$cfg.delayAfterAppMs }
    $urlDelay = 120
    if ($cfg.PSObject.Properties['delayAfterUrlMs']) { $urlDelay = [int]$cfg.delayAfterUrlMs }

    # 「等窗口出来」最多等多久。30 秒是给这台 2012 年双核留的余量：
    # 微信在内存吃紧的时候冷启动实测要 20~25 秒。到点还没出来就不再等了，
    # 照实写成"还没看到窗口"，绝不让条子永远转下去。
    # （别调小：调小了就等于回到"条子跑完了但东西还没出来"那个老毛病。）
    $appWaitMs = 30000

    # ---- 重复打开的三道闸（用户 2026-09-23 明确要求"不能重复打开同一个"）----
    # ① 清单里去重（下面 $seen）：配置里填重了也只开一次
    # ② 已经在跑的软件跳过（$skipRunning）：微信本来就开着，再按不该冒出第二个
    # ③ 手抖连按：Invoke-TriggerAction 的时间闸 + LaunchBusy
    # 想把"已经在跑也照样再点一遍"要回来（比如想把最小化的窗口重新拉起来），
    # 把 config.json 里的 skipIfRunning 改成 false 就行。
    $skipRunning = Test-ConfigSwitch -Cfg $cfg -Key 'skipIfRunning' -Default $true
    # 跳过的同时把窗口叫到前台（默认开）。关掉它的唯一理由是"不想让它抢焦点"，
    # 但关掉之后按 F9 会变成"什么都看不见"，用户已经因此报过一次"按了没反应"。
    $activateRunning = Test-ConfigSwitch -Cfg $cfg -Key 'activateIfRunning' -Default $true
    # 【血的教训 2026-09-25】上面这两行必须是"两行赋值"，不能只留一行 ——
    # 我加 activateRunning 时把 skipRunning 那行**覆盖**掉了，于是"不重复打开"这道闸
    # 直接失效（$skipRunning = $null = 假），一按 F9 就把 WorkBuddy / cc-switch 又开了一遍。
    # 所以自检里加了断言：这两个键都必须被读到、且默认值都必须是 $true。

    $tag = ''
    if ($Warm) { $tag = '[预热] ' }
    elseif ($IsDryRun) { $tag = '[试运行] ' }

    # ---- 第一步：先把进度窗亮出来 ----
    # 【为什么它排在"排清单"前面】按下去到窗口出现，这段时间就是用户感觉到的"响应速度"。
    # 排清单要读一遍配置、挨个查软件路径、再写几条日志，实测 200 多毫秒；
    # 让它排在窗口前面，那 200 多毫秒就白白变成"按下去没动静"（以前就是这样）。
    # 所以先把窗亮出来（这时候还不知道一共几项，就写"准备中"），排完清单立刻把总数补上。
    #
    # 【谁来门这个窗，别搞错】就是 config 里的 showTipAfterRun（= 进来的参数 $ShowTip）：
    #   · 勾上（true） → 窗一路流动到开完，最后把开了哪几项列出来
    #   · 不勾（false）→ **整个窗都不出现**，后台安静地开（-NoTip / 字面板的"不弹提示"也走这条）
    # ⚠️ $ShowTip 这个 switch 的默认值是 $false —— 所以**每个调用点都必须显式传它**，
    #    漏了就会表现为"进度窗怎么不出来了"（以前这里只认 $NoProgress，于是面板上
    #    取消勾选「开工时显示进度窗」根本不管用，窗照样弹 —— 已验证并修掉）。
    $isEn = ($script:TipLang -eq 'en')
    $useProgress = $false
    if ($ShowTip -and -not $NoProgress) {
        try { $useProgress = [Environment]::UserInteractive } catch { $useProgress = $false }
    }
    if ($useProgress) {
        $t = '⚡ F9开工'
        $s = '准备中…'
        if ($isEn) { $t = '⚡ Starting workday'; $s = 'Getting ready…' }
        $useProgress = Show-Progress -Title $t -SubText $s -Foot ''
    }

    # ---- 第二步：把这次要开的东西排成一个清单 ----
    # 先排再开有三个好处：
    #   1) 进度条的分母（一共几项）提前就确定了，不会开着开着总数才变
    #   2) "没找到"的软件在这一步就挑出来，能一次性告诉用户
    #   3) 真正开软件的那一段代码很短，出错的面也小
    $plan    = @()
    $missing = @()
    # 去重用：同一个 exe / 同一个网址在清单里出现两次，只留第一次（用户明确要求不重复打开）
    $seen    = @{}

    foreach ($a in @($cfg.apps)) {
        if ($null -eq $a) { continue }
        # 在设置工具里取消了打勾（enabled=false）就跳过，不删配置
        $prop = $a.PSObject.Properties['enabled']
        if ($prop -and ($a.enabled -eq $false -or [string]$a.enabled -ieq 'false')) {
            Write-Log ($tag + '跳过(已取消勾选): ' + $a.name)
            continue
        }
        $exe = Resolve-AppPath $a
        if (-not $exe) {
            Write-Log ($tag + '跳过软件(没找到): ' + $a.name)
            $missing += ('软件：' + $a.name)
            continue
        }
        $key = 'a|' + ([string]$exe).Trim().ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            Write-Log ($tag + '跳过软件(清单里重复了，只开一次): ' + $a.name + '  ->  ' + $exe)
            continue
        }
        $seen[$key] = $true
        $plan += [pscustomobject]@{ Kind = 'app'; Name = [string]$a.name; Exe = $exe; Url = '' }
    }

    foreach ($u in @($cfg.urls)) {
        if ($null -eq $u) { continue }
        $propU = $u.PSObject.Properties['enabled']
        if ($propU -and ($u.enabled -eq $false -or [string]$u.enabled -ieq 'false')) {
            Write-Log ($tag + '跳过(已取消勾选): ' + $u.name)
            continue
        }
        $url = $null
        if ($u.url)  { $url = [string]$u.url }
        elseif ($u.path) { $url = [string]$u.path }
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        # 名字留空就用网址当名字（设置界面里也是这么提示的）
        $uname = [string]$u.name
        if ([string]::IsNullOrWhiteSpace($uname)) { $uname = $url }

        # 网址去重：只有结尾多个斜杠、大小写不一样，都算同一个地址
        $ukey = 'u|' + $url.Trim().TrimEnd('/').ToLowerInvariant()
        if ($seen.ContainsKey($ukey)) {
            Write-Log ($tag + '跳过网页(清单里重复了，只开一次): ' + $uname + '  ->  ' + $url)
            continue
        }
        $seen[$ukey] = $true

        $browser = ''
        if ($u.browser) { $browser = [string](Resolve-BrowserPath -Cfg $cfg -Key ([string]$u.browser)) }

        $plan += [pscustomobject]@{ Kind = 'url'; Name = $uname; Exe = $browser; Url = $url }
    }

    if ($IsDryRun) {
        if (-not $Warm) {
            Write-Log ($tag + '--- 开工序列 开始 ---')
            foreach ($it in $plan) {
                if ($it.Kind -eq 'url') {
                    $who = '系统默认浏览器'
                    if ($it.Exe) { $who = $it.Exe }
                    Write-Log ($tag + '网页: ' + $it.Name + '  ->  ' + $it.Url + '   (' + $who + ')')
                } else {
                    Write-Log ($tag + '软件: ' + $it.Name + '  ->  ' + $it.Exe)
                }
            }
            foreach ($m in $missing) { Write-Log ($tag + '没找到: ' + $m) }
            Write-Log ($tag + '--- 开工序列 结束 ---')
        }
        # 【别忘】试运行也把窗亮出来了（上面第一步），这里得收掉，
        # 不然那个窗会一直贴在右下角不消失（它的自动收起是靠后面的收尾流程开的）。
        if ($useProgress) { Hide-Progress }
        return
    }

    # 进程查询走原生过滤、每次都是新的，所以这里不用预热、也不缓存
    # （缓存会有"太旧了、把刚开过的又开一遍"的坑）。

    $total = @($plan).Count
    $done  = 0
    $opened  = @()
    # 已经在跑、被跳过的（用户要求"不重复打开"，跳过的要告诉他，不然他会以为漏开了）
    $already = @()
    # 其中"确实被摆到用户眼前"的条数（叫到前台 / 本来就在最前）——用来在收尾时给一句准话
    $brought = 0
    # 清单里"第一个被叫到前面的"软件的 exe（收尾前再叫它一次，让它最终在最上层）
    $firstBrought = ''
    # 这次真正启动出去的软件（记它的进程 Id，用来等"窗口真的出现"）
    $launched = @()
    $swAll = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Log ('--- ' + $tag + '开工序列 开始（共 ' + $total + ' 项）---')

    # 清单排好了，把"一共几项"和第一项的进展补到窗上（窗早就亮了，只是还没信息）
    if ($useProgress) {
        $st = $(if ($isEn) { 'Starting…' } else { '开始…' })
        $ft = $(if ($isEn) { '0 / ' + $total } else { '0 / ' + $total })
        Set-Progress -SubText $st -Foot $ft -Pump
    }

    # ---- 第三步：一项一项开，每开一项把进度条往前推一格 ----
    foreach ($it in $plan) {
        $pos = $done + 1
        if ($useProgress) {
            if ($isEn) {
                $st = 'Opening ' + $it.Name + ' (' + $pos + '/' + $total + ')'
                $ft = 'Done ' + $done + '/' + $total + ' · ' + [math]::Round($swAll.Elapsed.TotalSeconds, 1) + ' s'
            } else {
                $st = '正在打开 ' + $it.Name + '（' + $pos + '/' + $total + '）'
                $ft = '已完成 ' + $done + '/' + $total + ' · ' + [math]::Round($swAll.Elapsed.TotalSeconds, 1) + ' 秒'
            }
            Set-Progress -SubText $st -Foot $ft
        }

        # ---- 已经在跑的就别开第二个（用户明确要求）----
        # 放在"等间隔"之前：跳过的东西不该白等一段。
        if ($skipRunning -and $it.Kind -eq 'app' -and (Test-AppAlreadyRunning -Exe $it.Exe)) {
            # 【这里必须"有动静"】只写一行日志然后 continue，用户那一边是完全静默的：
            # 三个软件都开着的时候，按 F9 屏幕上什么都不会变 —— 用户会认为"程序坏了/没反应"。
            # 所以：不再开第二个进程，但要把已经开着的那个窗口摆到他眼前。
            $act = $null
            if ($activateRunning) {
                try { $act = Show-AppIfRunning -Exe $it.Exe } catch { $act = $null }
            }
            if ($act) {
                $howTxt = ''
                if ($act.How) { $howTxt = '　[叫窗口: ' + $act.How + ']' }
                Write-Log ('已在运行，不开第二个: ' + $it.Name + ' ' + ($act.Zh -replace '[（）]', '') + $howTxt)
                $already += [pscustomobject]@{ Text = ('软件：' + $it.Name); Zh = $act.Zh; En = $act.En }
                if ($act.Code -eq 1 -or $act.Code -eq 2) {
                    $brought++
                    # 记下"第一个被叫到前面的"。等所有软件都叫过一遍之后，再把它叫一次，
                    # 让它最终留在最上面 —— 否则"最后叫的那个"会盖住第一个，
                    # 用户看到的最上层窗口就跟他的清单顺序无关了（随机感）。
                    if (-not $firstBrought) { $firstBrought = [string]$it.Exe }
                }
                if ($useProgress) {
                    if ($act.Code -eq 1 -or $act.Code -eq 2) {
                        $st2 = $(if ($isEn) { 'Already running - brought to front: ' + $it.Name + ' (' + $pos + '/' + $total + ')' }
                                 else        { '已在运行，已叫到最前面：' + $it.Name + '（' + $pos + '/' + $total + '）' })
                    } else {
                        $st2 = $(if ($isEn) { 'Already running (in the tray): ' + $it.Name + ' (' + $pos + '/' + $total + ')' }
                                 else        { '已在运行（在后台托盘里）：' + $it.Name + '（' + $pos + '/' + $total + '）' })
                    }
                    Set-Progress -SubText $st2 -Foot $('已完成 ' + $done + '/' + $total) -Pump
                }
            } else {
                Write-Log ('跳过软件(已经在运行，不再开第二个): ' + $it.Name)
                $already += [pscustomobject]@{ Text = ('软件：' + $it.Name); Zh = ''; En = '' }
            }
            $done++
            if ($useProgress) { Set-Progress -Pct ($done / [double]([Math]::Max(1, $total))) -Pump }
            continue
        }

        if ($done -gt 0) {
            $gap = $appDelay
            if ($it.Kind -eq 'url') { $gap = $urlDelay }
            # 等待期间也让条子继续流动（直接 Start-Sleep 会把动画整段冻住，看着像死机）
            $swGap = [System.Diagnostics.Stopwatch]::StartNew()
            if ($useProgress) { Wait-WithPump -Milliseconds $gap } else { Start-Sleep -Milliseconds $gap }
            $swGap.Stop()
            # 这里要求"实际 ≈ 设定"。实际比设定大出一截，就说明泵消息那步在拖时间
            Write-Log ('  等 ' + $gap + ' ms（实际 ' + [int]$swGap.Elapsed.TotalMilliseconds + ' ms）')
        }

        $short = $(if ($it.Kind -eq 'url') { '网页' } else { '软件' })
        $swOne = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $newProc = $null
            if ($it.Kind -eq 'url') { $newProc = Start-ProcessFast -Url $it.Url -Browser ([string]$it.Exe) }
            else                    { $newProc = Start-ProcessFast -Path $it.Exe }
            $swOne.Stop()
            Write-Log ('打开' + $short + ': ' + $it.Name + '（用时 ' + [int]$swOne.Elapsed.TotalMilliseconds + ' ms）')
            $opened += ($short + '：' + $it.Name)
            # 记下刚起来的进程 Id，等会儿要盯着它的窗口出没出来。
            # 【只管软件，不管网页】网页是"在已有浏览器里开个标签"，不存在"窗口还没出来"这回事。
            if ($it.Kind -eq 'app' -and $newProc -is [System.Diagnostics.Process]) {
                $pidNew = -1
                try { $pidNew = $newProc.Id } catch { }
                if ($pidNew -gt 0) {
                    $launched += [pscustomobject]@{ Name = [string]$it.Name; Pid = $pidNew; Ready = $false; Ms = -1 }
                }
                try { $newProc.Dispose() } catch { }   # 只要 Id，句柄别占着
            }
        } catch {
            $swOne.Stop()
            Write-Log ('打开' + $short + '失败: ' + $it.Name + ' :: ' + $_.Exception.Message)
            $missing += ($short + '：' + $it.Name)
        }

        $done++
        if ($useProgress) { Set-Progress -Pct ($done / [double]([Math]::Max(1, $total))) -Pump }
    }

    # 最后把清单里第一个"已经在跑的"再叫一次，让它留在最上面（见 $firstBrought 处的说明）
    if ($brought -gt 0 -and $firstBrought) {
        try {
            $null = Show-AppIfRunning -Exe $firstBrought
            Write-Log ('再次把清单第 1 个叫到最前面: ' + [System.IO.Path]::GetFileNameWithoutExtension($firstBrought))
        } catch { }
    }

    $swAll.Stop()
    $secs = [math]::Round($swAll.Elapsed.TotalSeconds, 1)
    Write-Log ('--- ' + $tag + '开工序列 结束（用时 ' + $secs + ' 秒）---')

    # ---- 第四步：彩蛋（语音）----
    # 放在开完之后，是因为用户想听的是"开好了"。用的是异步播放/异步朗读，不会卡住后台。
    try { Invoke-LauncherVoice } catch { Write-Log ('开工语音异常: ' + $_.Exception.Message) }

    # ---- 第五步：进度窗收尾 ----
    if ($useProgress) {
        if ($opened.Count -eq 0 -and $missing.Count -eq 0) {
            $head = $(if ($isEn) { '✓ Workday started (the list is empty)' } else { '✓ 开工完成（清单里还没有东西）' })
        } elseif ($missing.Count -gt 0) {
            $head = $(if ($isEn) { '✓ Workday started - ' + $missing.Count + ' item(s) not found' }
                      else         { '✓ 开工完成，有 ' + $missing.Count + ' 项没找到' })
        } elseif ($already.Count -gt 0) {
            # 【这条分支是用户最容易误解的一条】"已打开 0 项"读起来像"什么都没干"。
            # 所以把它写成"你要的东西已经在眼前了"，而不是"打开了 0 个"。
            if ($isEn) {
                if ($opened.Count -eq 0) {
                    if ($brought -gt 0) { $head = '✓ All set - ' + $already.Count + ' already running, brought to the front' }
                    else                { $head = '✓ All set - ' + $already.Count + ' already running (nothing to open)' }
                } else {
                    $head = '✓ Workday started - ' + $opened.Count + ' opened, ' + $already.Count + ' already running (' + $brought + ' brought to the front)'
                }
            } else {
                if ($opened.Count -eq 0) {
                    if ($brought -gt 0) { $head = '✓ 全都已经在跑了，已经帮你摆到最前面' }
                    else                { $head = '✓ 要用的' + $already.Count + ' 个都已经在跑了，没有需要新开的' }
                } else {
                    $head = '✓ 开工完成：新开 ' + $opened.Count + ' 项，' + $already.Count + ' 项本来就在跑（' + $brought + ' 项已摆到最前面）'
                }
            }
        } else {
            $head = $(if ($isEn) { '✓ Workday started - ' + $opened.Count + ' item(s) opened' }
                      else         { '✓ 开工完成，已打开 ' + $opened.Count + ' 项' })
        }

        $lines = @()
        if ($ShowTip) {
            foreach ($o in $opened)  { $lines += ('✓ ' + $o) }
            # 已经在跑的单独列出来：不写出来用户会以为"我勾了它怎么没开"。
            # 条目自己带后缀（"已叫到最前面"/"在托盘里"）时就不再叠加默认后缀，
            # 否则会变成"（…）（…）"两个括号叠在一起。
            $sfx = $(if ($isEn) { ' (already running - skipped)' } else { '（本来就在运行，没重复开）' })
            foreach ($g in $already) {
                if ($isEn) { $lines += ('· ' + $g.Text + $(if ($g.En) { $g.En } else { $sfx })) }
                else       { $lines += ('· ' + $g.Text + $(if ($g.Zh) { $g.Zh } else { $sfx })) }
            }
            foreach ($m in $missing) { $lines += ('✗ ' + $m) }
            # 清单是空的（用户还没配）也要说一句，不然看着像"开了个空窗"
            if ($lines.Count -eq 0) {
                $lines += $(if ($isEn) { '  Nothing in the list yet - open Settings to tick some items' }
                            else        { '  清单里还没有东西，先打开「F9开工 · 设置」打勾吧' })
            }
        }

        $foot = $(if ($isEn) { 'This window closes itself in 3 seconds' } else { '这个窗 3 秒后自动收起' })
        $hold = 3000
        if (-not $ShowTip) {
            $foot = $(if ($isEn) { 'Done - closing' } else { '就开这些，收起' })
            $hold = 1200
        }

        $subDone = $(if ($isEn) { 'Total ' + $secs + ' s' } else { '共用 ' + $secs + ' 秒' })

        # ---- 关键一步：等软件真的出现在屏幕上，再把条子收掉 ----
        # 以前这里直接 Complete-Progress，于是"条子跑满"只代表"启动调用发出去了"，
        # 而微信的窗口可能还要 20 多秒才出来 —— 用户看到的就是"条子跑完了但什么都没发生"。
        # 现在把"还没看到窗口"的那几个记下来，交给窗口自己的定时器继续盯（不占住后台）。
        $waitItems = @($launched | Where-Object { $_.Pid -gt 0 })
        if ($waitItems.Count -gt 0) {
            # 探测组件先在**开始等之前**备好：等的时候（每 0.25 秒一次）就不该再花这个钱，
            # 更不能出现"组件拿不到 → 每次都判断不了 → 白等 30 秒"（第一版踩过）。
            $null = Initialize-AppWinProbe
            $script:PWait = @{
                Items    = $waitItems
                Started  = Get-Date
                Deadline = (Get-Date).AddMilliseconds($appWaitMs)   # 到点就不等了，绝不无限转
                IsEn     = $isEn
                Head     = $head
                Lines    = $lines
                Foot     = $foot
                Hold     = $hold
            }
            # 条子停在九成、继续流动：表示"还没完，但已经开了"
            # （别拉到 100%：拉满就是"完成"，那正是我们要改掉的谎话）
            $script:PTgt  = 0.92
            $script:PHide = [datetime]::MaxValue    # 别让定时器按旧时间把它收掉
            $stWait = $(if ($isEn) { 'Waiting for them to appear…' } else { '等它们真的出现在屏幕上…' })
            Set-Progress -SubText $stWait -Foot '' -Pump
            Write-Log ('等窗口出现（最多 ' + [int]($appWaitMs / 1000) + ' 秒）: ' +
                       ((@($waitItems | ForEach-Object { $_.Name })) -join '、'))

            if ($Sequence) {
                # 子进程没有消息循环：我们陪着泵消息，把"等窗口"这件事跑完（上限再留 6 秒余量）
                $swSeq = [System.Diagnostics.Stopwatch]::StartNew()
                while ($script:PWait -and $swSeq.Elapsed.TotalMilliseconds -lt ($appWaitMs + 6000)) {
                    Wait-WithPump -Milliseconds 120
                }
                Wait-WithPump -Milliseconds $hold
                Hide-Progress
                Write-Log '进度窗已收起'
            }
            # 常驻后台自己有消息循环：到点由定时器收尾（Update-AppWait），这里直接返回。
            # 【千万别在这里等】一等，这段时间后台就听不见快捷键了
            # （实测"处理一次按键"会从几十毫秒涨到 7 秒）。
        } else {
            Complete-Progress -Title $head -SubText $subDone -Lines $lines -Foot $foot -HoldMs $hold

            # 收尾方式分两种，不能混：
            if ($Sequence) {
                # 子进程没有消息循环，窗口要靠我们"陪着泵消息"才不会刚显示就消失
                Wait-WithPump -Milliseconds $hold
                Hide-Progress
                Write-Log '进度窗已收起'
            } else {
                # 常驻后台自己有消息循环，到点由定时器把窗收掉。
            }
        }
    }
}
# ---------------------------------------------------------------- 快捷键表
$script:VKMap = @{
    'F1'=0x70; 'F2'=0x71; 'F3'=0x72; 'F4'=0x73; 'F5'=0x74; 'F6'=0x75;
    'F7'=0x76; 'F8'=0x77; 'F9'=0x78; 'F10'=0x79; 'F11'=0x7A; 'F12'=0x7B;
    'SCROLLLOCK'=0x91; 'PAUSE'=0x13; 'BREAK'=0x13; 'INSERT'=0x2D; 'DELETE'=0x2E;
    'END'=0x23; 'HOME'=0x24; 'PAGEUP'=0x21; 'PAGEDOWN'=0x22; 'SPACE'=0x20;
    'TAB'=0x09; 'ENTER'=0x0D; 'BACKQUOTE'=0xC0;
    'NUMPAD0'=0x60; 'NUMPAD1'=0x61; 'NUMPAD2'=0x62; 'NUMPAD3'=0x63; 'NUMPAD4'=0x64;
    'NUMPAD5'=0x65; 'NUMPAD6'=0x66; 'NUMPAD7'=0x67; 'NUMPAD8'=0x68; 'NUMPAD9'=0x69
}

function ConvertTo-HotKeyDef {
    param([string]$Text)
    $mods = 0
    $vk   = -1
    foreach ($p in @($Text -split '\+')) {
        $t = $p.Trim().ToUpperInvariant()
        if ($t -eq '') { continue }
        if     ($t -eq 'CTRL' -or $t -eq 'CONTROL') { $mods = $mods -bor 0x0002 }
        elseif ($t -eq 'ALT')                        { $mods = $mods -bor 0x0001 }
        elseif ($t -eq 'SHIFT')                      { $mods = $mods -bor 0x0004 }
        elseif ($t -eq 'WIN' -or $t -eq 'WINDOWS')   { $mods = $mods -bor 0x0008 }
        elseif ($t.Length -eq 1 -and $t -ge 'A' -and $t -le 'Z') { $vk = [int][char]$t }
        elseif ($t.Length -eq 1 -and $t -ge '0' -and $t -le '9') { $vk = [int][char]$t }
        elseif ($script:VKMap.ContainsKey($t))       { $vk = [int]$script:VKMap[$t] }
    }
    if ($vk -lt 0) { return $null }
    return @{ Text = $Text.Trim(); Mods = $mods; Vk = $vk }
}

# 一格写成多个也认： "F9 / Ctrl+Alt+W"、"F9、Ctrl+Alt+W"、"F9 和 Ctrl+Alt+W"
# （开工键和收工键用的是同一套写法，所以抽出来共用）
function Split-HotKeyCells {
    param($Cells)
    $out = @()
    foreach ($h in @($Cells)) {
        $parts = @([string]$h -split '\s*[/、,;]\s*|\s+和\s*|\s+and\s+' |
                   Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($p in $parts) {
            $d = ConvertTo-HotKeyDef $p
            if (-not $d) { Write-Log ('快捷键写法看不懂，已忽略: ' + $p); continue }
            $out += $d
        }
    }
    return $out
}

# 收工快捷键：读 config.json 的 shutdownHotkey（默认 Ctrl+Alt+Q）。
# ⚠️ 【写空字符串 = 把收工功能关掉】。想用默认值就把整行删掉，别写 ""。
# 这条规矩跟开工键那边不一样（那边写空会退回 F9），所以面板里也写得明明白白。
function Get-QuitHotKeyDefs {
    $cfg = Get-LauncherConfig
    $t   = $null
    if ($cfg) {
        $p = $cfg.PSObject.Properties['shutdownHotkey']
        if ($p) { $t = [string]$p.Value }
    }
    if ($null -eq $t) { $t = 'Ctrl+Alt+Q' }               # 没写 -> 用默认
    if ([string]::IsNullOrWhiteSpace($t)) { return @() }   # 写了空 -> 关掉
    $out = @()
    foreach ($d in @(Split-HotKeyCells @($t))) {
        $d.Kind = 'quit'
        $d.Text = [string]$d.Text
        $out += $d
    }
    return $out
}

function Get-HotKeyDefs {
    $cfg  = Get-LauncherConfig
    $list = @()
    if ($cfg -and $cfg.hotkeys) { $list = @($cfg.hotkeys) }
    if ($list.Count -eq 0) { $list = @('F9', 'Ctrl+Alt+W') }

    $defs = @()
    $seen = @{}
    # 【顺序有意义】开工键全部排在前面。按键回调只拿得到一个序号，
    # 而 -SimTrigger 固定拿 #1 当样本 —— 那必须是一个"开工"键。
    foreach ($d in @(Split-HotKeyCells $list)) {
        $key = [string]$d.Mods + ':' + [string]$d.Vk
        if ($seen.ContainsKey($key)) { continue }     # 同一个键写了两次，只留一个
        $seen[$key] = $true
        $d.Kind = 'launch'
        $defs += $d
    }
    if ($defs.Count -eq 0) {
        $d1 = ConvertTo-HotKeyDef 'F9';         $d1.Kind = 'launch'; $defs += $d1
        $d2 = ConvertTo-HotKeyDef 'Ctrl+Alt+W'; $d2.Kind = 'launch'; $defs += $d2
    }
    # 收工键排在后面。跟开工键撞了的话开工优先（同一个键注册两次，第二次必然失败，
    # 与其让它静默失败，不如在这里就丢掉）
    foreach ($d in @(Get-QuitHotKeyDefs)) {
        $key = [string]$d.Mods + ':' + [string]$d.Vk
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $defs += $d
    }
    return $defs
}

# ---------------------------------------------------------------- 编译缓存
# Add-Type 不是"加载"，是"现场起一个 csc.exe 把 C# 编译成程序集" ——
# 在这台机器上实测要 2~7 秒（杀毒软件对每一个新生成的 exe 都要完整扫一遍）。
# 而"读一个已经编好的 dll"只要十几毫秒。
# 所以：编译一次 → 落盘 → 以后每次直接读。
#
# 缓存文件名里带着源码的哈希：代码一改哈希就变，自动换新的，
# 绝不会出现"改了代码还在跑旧行为"这种最恶心的问题。
$script:TypeCacheDir = Join-Path $ScriptDir 'cache'

function Get-TypeCacheKey {
    param([string]$Source)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Source))
        $sha.Dispose()
        $hex = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 8; $i++) { [void]$hex.Append($bytes[$i].ToString('x2')) }
        return $hex.ToString()
    } catch { return 'nohash' }
}

function Add-CachedType {
    param([string]$TypeName, [string]$Source, [string[]]$Refs = @())

    if ($TypeName -as [type]) { return $true }        # 本进程里早就有了

    # 缓存路径：算不出来（极端情况）就当成"没有缓存"，走后面的兜底
    $dll = $null
    try {
        if (-not (Test-Path -LiteralPath $script:TypeCacheDir)) {
            New-Item -ItemType Directory -Path $script:TypeCacheDir -Force | Out-Null
        }
        $dll = Join-Path $script:TypeCacheDir ($TypeName + '-' + (Get-TypeCacheKey $Source) + '.dll')
    } catch { $dll = $null }

    # ---- 1) 有缓存：直接读，快路径 ----
    if ($dll -and (Test-Path -LiteralPath $dll)) {
        try {
            [void][System.Reflection.Assembly]::LoadFrom($dll)
            if ($TypeName -as [type]) { return $true }
        } catch { }
    }

    # ---- 2) 没缓存：编译一份落盘，给以后所有进程用 ----
    if ($dll) {
        if (Test-Path -LiteralPath $dll) {
            # 缓存文件在、但读不出来（被打断/损坏）。别去覆盖它，
            # 换个名字再编一个就行 —— 删除文件在这里是没必要冒的风险。
            $dll = $dll -replace '\.dll$', ('.r' + (Get-Random -Minimum 1000 -Maximum 9999) + '.dll')
        }
        try {
            if ($Refs.Count -gt 0) {
                Add-Type -TypeDefinition $Source -Language CSharp -OutputAssembly $dll `
                         -ReferencedAssemblies $Refs -WarningAction SilentlyContinue -ErrorAction Stop
            } else {
                Add-Type -TypeDefinition $Source -Language CSharp -OutputAssembly $dll `
                         -WarningAction SilentlyContinue -ErrorAction Stop
            }
            [void][System.Reflection.Assembly]::LoadFrom($dll)
            if ($TypeName -as [type]) { return $true }
        } catch { }
    }

    # ---- 3) 兜底：缓存目录写不进去（只读安装、杀毒拦截）就在内存里编 ----
    # 慢是慢点，但功能一定还在，绝不会因为"缓存不了"就整个程序不能用。
    try {
        if ($Refs.Count -gt 0) {
            Add-Type -TypeDefinition $Source -Language CSharp -ReferencedAssemblies $Refs `
                     -WarningAction SilentlyContinue -ErrorAction Stop
        } else {
            Add-Type -TypeDefinition $Source -Language CSharp `
                     -WarningAction SilentlyContinue -ErrorAction Stop
        }
        return (($TypeName -as [type]) -ne $null)
    } catch {
        Write-Log ('ERROR 内部组件编译失败: ' + $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------- 内部组件
function Initialize-HotKeyHost {
    if ('HotKeyHost' -as [type]) { return $true }
    $csSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class HotKeyHost
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint   message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint   time;
        public int    ptX;
        public int    ptY;
    }

    public static Action<int> OnTrigger;

    public static List<int> Register(int[] modifiers, int[] vks)
    {
        List<int> ok = new List<int>();
        for (int i = 0; i < vks.Length; i++)
        {
            bool r = RegisterHotKey(IntPtr.Zero, i + 1, (uint)modifiers[i] | 0x4000u, (uint)vks[i]);
            if (r) { ok.Add(i + 1); }
        }
        return ok;
    }

    public static void UnregisterAll(int count)
    {
        for (int i = 1; i <= count; i++) { UnregisterHotKey(IntPtr.Zero, i); }
    }

    public static void Loop()
    {
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
        {
            if (msg.message == 0x0312)
            {
                // 0x0312 = WM_HOTKEY，有人按了快捷键
                if (OnTrigger != null)
                {
                    try { OnTrigger(msg.wParam.ToInt32()); } catch { }
                }
            }
            // 【必须】把消息派发出去。
            // 以前这里只捡 WM_HOTKEY、其它消息一律丢掉，所以在这个循环里
            // 创建的窗口永远不重绘、定时器永远不响 —— 右下角那个进度窗
            // 就是靠这里的定时器推动高光流动、到点自己收起的，少了这行它会一直贴在屏幕上。
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }
}
'@
    return (Add-CachedType -TypeName 'HotKeyHost' -Source $csSource)
}

# ---------------------------------------------------------------- 窗口探测 + 把窗口叫到前台
# 两件事都在这里：
#   ① "这个进程在屏幕上有没有可见的窗口？" —— 判断启动出去的软件到底出来了没有
#      （用户抱怨的"条子跑完了但应用半分钟才出来"就是缺这个判据）
#   ② "它已经开着，那就把它的窗口叫到最前面" —— 见下面 Activate 的说明。
#
# 【为什么要 ②（2026-09-23 用户的"没反应"就是它）】
# 加了"已经在运行就跳过"之后，用户按 F9：三个软件全在跑 → 全跳过 → 屏幕上什么都没有，
# 只有右下角一个小条自己亮一下又收掉。用户的感受就是"按了没反应"，
# 而在这之前（没有跳过逻辑时）F9 会把微信重新拉起来、窗口弹到眼前，是有反应的。
# 所以"跳过"不能只是"什么都不做"，必须是"把已经开着的那个摆到你面前"。
function Initialize-AppWinProbe {
    if ('AppWinProbe' -as [type]) { return $true }
    $csSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class AppWinProbe {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
    // 【坑，2026-09-25 踩过】GetCurrentThreadId 在 kernel32.dll 里，不是 user32.dll！
    // 写成 user32 编译能过、调用就抛 EntryPointNotFoundException，
    // 被上层 catch 吞掉之后表现为"每个软件都叫不动"（返回 3），极难看出来。
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    // 备用手段：比 SetForegroundWindow 更"横"，从后台进程抢前台几乎必成
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool fAltTab);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

    public struct RECT { public int L, T, R, B; }

    const int GWL_EXSTYLE      = -20;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_NOACTIVATE = 0x08000000;
    const int SW_RESTORE       = 9;
    const int SW_SHOW          = 5;
    // "像窗口的窗口"的最小尺寸：过滤掉托盘程序那种 16x16 的隐藏消息窗
    const int MIN_W = 120;
    const int MIN_H = 80;

    // 是不是一个"真的在屏幕上、能给人看的"主窗口：
    // 可见 + 顶层（不是别人的子窗）+ 不是工具窗/不接受激活（托盘那种）+ 有标题 + 够大
    static bool IsRealWin(IntPtr h) {
        if (!IsWindowVisible(h)) return false;
        if (GetParent(h) != IntPtr.Zero) return false;
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) != 0) return false;
        if ((ex & WS_EX_NOACTIVATE) != 0) return false;
        if (GetWindowTextLength(h) <= 0) return false;
        RECT r;
        GetWindowRect(h, out r);
        if ((r.R - r.L) < MIN_W || (r.B - r.T) < MIN_H) return false;
        return true;
    }

    // 有没有"真的窗口"（不是随便一个小窗算数）
    public static bool HasVisible(uint pid) {
        bool found = false;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p == pid && IsRealWin(h)) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // 随便什么可见窗口的数量（调试/自检用）
    public static int CountVisible(uint pid) {
        int n = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) n++;
            return true;
        }, IntPtr.Zero);
        return n;
    }

    // 挑一个"最像主窗口"的：有多个窗口时选面积最大的那个
    static IntPtr Pick(uint pid) {
        IntPtr best = IntPtr.Zero;
        long bestArea = -1;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            if (!IsRealWin(h)) return true;
            RECT r;
            GetWindowRect(h, out r);
            long area = (long)(r.R - r.L) * (long)(r.B - r.T);
            if (area > bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    public static string LastHow = "";   // 最后那一次是靠哪一招成功的（写进日志，方便以后排查）

    // 把这个进程的窗口叫到最前面。
    // 返回值：0=没有能叫的窗口（托盘程序/藏在后台） 1=它本来就在最前面
    //        2=已经叫到前面 3=有窗口但怎么都叫不动
    //
    // 【为什么要四级递进】Windows 有一条"前台锁"：不是当前前台的进程调用
    // SetForegroundWindow 往往被直接忽略（连返回值都不一定准）。而不同软件、
    // 不同时候能生效的招数不一样（实测同一台机器上微信一次就成，
    // WorkBuddy/cc-switch 得靠后面的招）。所以：**每一招之后都真去核对
    // "前台窗口是不是它了"**，不成就换下一招；而不是只看 API 返回 true 就以为成了。
    public static int Activate(uint pid) {
        LastHow = "";
        IntPtr h = Pick(pid);
        if (h == IntPtr.Zero) return 0;

        if (IsIconic(h)) ShowWindow(h, SW_RESTORE);   // 最小化了先还原，不然叫上来还是个"条"
        else             ShowWindow(h, SW_SHOW);

        if (GetForegroundWindow() == h) { LastHow = "本来就在最前面"; return 1; }

        // ① 直接叫
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (GetForegroundWindow() == h) { LastHow = "直接叫"; return 2; }

        // ② 把自己的输入队列临时接到"当前前台"那个线程上，前台锁就放行了
        IntPtr fg = GetForegroundWindow();
        uint fgT = 0;
        uint myT = GetCurrentThreadId();
        if (fg != IntPtr.Zero) GetWindowThreadProcessId(fg, out fgT);
        if (fgT != 0 && fgT != myT) {
            if (AttachThreadInput(myT, fgT, true)) {
                BringWindowToTop(h);
                SetForegroundWindow(h);
                AttachThreadInput(myT, fgT, false);
                if (GetForegroundWindow() == h) { LastHow = "接线程"; return 2; }
            }
        }

        // ③ 假装按一下 Alt（系统把"用户刚按过键"当解锁前台锁的信号），再叫
        keybd_event(0x12, 0, 0, IntPtr.Zero);      // VK_MENU 按下
        SetForegroundWindow(h);
        keybd_event(0x12, 0, 2, IntPtr.Zero);      // 松开
        if (GetForegroundWindow() == h) { LastHow = "Alt解锁"; return 2; }

        // ④ 最后一招：SwitchToThisWindow（没有返回值，只能靠核对）
        SwitchToThisWindow(h, true);
        if (GetForegroundWindow() == h) { LastHow = "SwitchToThisWindow"; return 2; }

        LastHow = "四招都没成";
        return 3;
    }
}
'@
    return (Add-CachedType -TypeName 'AppWinProbe' -Source $csSource)
}

# "已经在运行"的软件：尽量把它摆到用户眼前，别只是静默跳过。
# 返回一个对象：Code（0/1/2/3，见 C# 里 Activate 的注释）+ Zh/En（界面上那一句）
function Show-AppIfRunning {
    param([string]$Exe)
    $code = -1
    $tried = $false
    try {
        if (-not ('AppWinProbe' -as [type])) { $null = Initialize-AppWinProbe }
        $base = ''
        try { $base = [System.IO.Path]::GetFileNameWithoutExtension($Exe) } catch { }
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $procs = @([System.Diagnostics.Process]::GetProcessesByName($base))
            $script:ActHow = ''
            # 【别写成"最后一个结果说了算"】同一个软件往往有一堆同名进程
            # （WorkBuddy 就有 16 个），有窗口的只是其中一个。
            # 挨个试、取"最好"的那个结果：叫到前面 > 本来就在前 > 叫不动 > 没有窗口。
            $rank = @{ 2 = 4; 1 = 3; 3 = 2; 0 = 1 }
            $best = -1
            foreach ($p in $procs) {
                $id = 0
                try { $id = $p.Id } catch { }
                if ($id -le 0) { continue }
                $tried = $true
                $c = 3
                try { $c = [AppWinProbe]::Activate([uint32]$id) } catch { $c = 3 }
                if ($best -lt 0 -or $rank[$c] -gt $rank[$best]) {
                    $best = $c
                    try { $script:ActHow = [string][AppWinProbe]::LastHow } catch { $script:ActHow = '' }
                }
                if ($best -eq 2) { break }   # 已经叫到最前面了，不用再试别的
            }
            if ($best -ge 0) { $code = $best }
            foreach ($p in $procs) { try { $p.Dispose() } catch { } }
        }
    } catch { $code = 3 }
    if (-not $tried) { $code = 3 }
    if ($code -lt 0) { $code = 3 }

    $how = ''
    try { $how = [string]$script:ActHow } catch { $how = '' }
    switch ($code) {
        1 { return [pscustomobject]@{ Code = 1; How = $how; Zh = '（本来就在运行，窗口已经在最前面）';       En = ' (already running - it was already in front)' } }
        2 { return [pscustomobject]@{ Code = 2; How = $how; Zh = '（本来就在运行，已把它叫到最前面）';       En = ' (already running - brought to the front)' } }
        0 { return [pscustomobject]@{ Code = 0; How = $how; Zh = '（在后台跑着，没有窗口可叫；没重复开）';   En = ' (running in the tray - no window to show)' } }
        default { return [pscustomobject]@{ Code = 3; How = $how; Zh = '（本来就在运行，没重复开）';          En = ' (already running - skipped)' } }
    }
}

# ---------------------------------------------------------------- 开工进度窗（右下角）
# 按一下快捷键，右下角立刻出现一个带「流动进度条」的小窗，一路报进度；
# 全部开完变成「✓ 开工完成」并列出开了哪些，过几秒自己收起。
#
# 为什么必须"立刻出现"：开软件本身要时间（微信冷启动几百毫秒到几秒都有），
# 中间屏幕上要是没动静，用户就会以为"按了没反应"，然后连按好几下。
#
# 为什么窗口是"提前造好"的：PowerShell 现建窗口 + 现造字体，第一次要 130~250 毫秒，
# 反馈就不"即时"了。所以后台刚启动时就把窗口造好、藏起来，
# 按键时只剩一次 Show()（实测 15~40 毫秒）。
#
# 为什么用 NoFocusForm：它是 C# 写的一个窗口，带 WS_EX_NOACTIVATE ——
# 弹出来绝不抢焦点、不进 Alt+Tab、不闪任务栏，不会打断你正在打的字。
# 这段 C# 只在需要时编译一次，之后走 cache 目录里的 dll（见 Add-CachedType）。
function Initialize-HintUi {
    if ('NoFocusForm' -as [type]) { return $true }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        Write-Log ('进度窗不可用（不影响开工）: ' + $_.Exception.Message)
        return $false
    }
    $uiSrc = @'
using System;
using System.Drawing;
using System.Windows.Forms;

// 一个永远不会抢焦点的窗口：Show 出来也不激活，不进 Alt+Tab，不闪任务栏
public class NoFocusForm : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW
            return cp;
        }
    }
}
'@
    $ok = Add-CachedType -TypeName 'NoFocusForm' -Source $uiSrc `
                         -Refs @('System.Windows.Forms', 'System.Drawing')
    if (-not $ok) {
        Write-Log '进度窗不可用（不影响开工本身，只是少了右下角那个进度提示）'
    }
    return $ok
}

# 进度窗的"控件袋"：造一次，之后一直复用。
# 用哈希表装，是因为下面那几个动画回调（Timer / Paint）跟外面是各自的作用域，
# 只有 $script: 里的东西它们才看得见 —— 用一个袋子最省事。
$script:PUi     = $null                  # 控件袋，$null = 还没造
$script:PFlow   = 0.0                    # 条子上那道高光的相位 0~1
$script:PFill   = 0.0                    # 平滑之后的填充比例（不是目标值，是"当前值"）
$script:PTgt    = 0.0                    # 目标填充比例
$script:PHide   = [datetime]::MaxValue   # 到这个时刻自动收起
$script:PHeart  = -1                     # 形象图飞入的帧计数，-1 = 不动画
$script:PFail   = 0                      # 显示失败的次数（只报前两次，免得刷屏）

# 条子上的"流动"高光是怎么做出来的，先把坑说清楚。
#
# 第一版是自绘（在 Panel 的 Paint 事件里用脚本画）：用 SetClip(圆角路径)
# 加 LinearGradientBrush 画那道流光。好看是好看，但 GDI+ 里这两个操作都极贵，
# 而且 Paint 回调每帧都要进一次脚本引擎 —— 实测一次重绘能卡到一秒以上。
# 后果就是"每个软件之间要等 2.8 秒"（设定值明明只有 400 毫秒）。
#
# 现在改成：一个圆角轨道 Panel + 一个填充 Panel + 一个高光 Panel，全是纯 Panel，
# 每帧只改两个数字（填充的宽度、高光的位置），没有任何自绘代码，
# 重绘全交给系统去做，开销可以忽略。
#
# 高光 Panel 挂在"填充 Panel"里面当子控件 —— 一旦跑到填充范围之外，
# 系统会自动把它裁掉，不需要我们做任何裁剪判断。

function Sync-BarVisual {
    $u = $script:PUi
    if (-not $u) { return }
    try {
        $full = [int]$u.Bar.Width
        $fw = [int]($full * $script:PFill)
        if ($fw -gt $full) { $fw = $full }
        if ($fw -lt 0) { $fw = 0 }
        $u.BarFill.Width = $fw
        # 高光在填充里左右滑；跑到填充外面，系统会自动裁掉，不用我们判断
        $shw = [int]$u.BarSheen.Width
        $u.BarSheen.Left = [int](-$shw + ($fw + $shw) * $script:PFlow)
    } catch { }
}

function Initialize-ProgressUi {
    if ($script:PUi) { return $true }
    if (-not (Initialize-HintUi)) { return $false }
    try {
        # 颜色全部跟着皮肤走，换了皮肤进度窗也一起换
        $sk = Get-LauncherSkin
        $cCard  = ConvertTo-SkinColor ($sk.card)     '#FFFFFF'
        $cText  = ConvertTo-SkinColor ($sk.text)     '#1F2A37'
        $cSub   = ConvertTo-SkinColor ($sk.subText)  '#6E7681'
        $cAcc   = ConvertTo-SkinColor ($sk.accent)   '#2D6BD8'
        $cTrack = ConvertTo-SkinColor ($sk.border)   '#D8DEE8'

        $W = 348
        $f = New-Object NoFocusForm
        $f.FormBorderStyle = 'None'
        $f.ShowInTaskbar   = $false
        $f.TopMost         = $true
        $f.StartPosition   = 'Manual'
        $f.BackColor       = $cCard
        $f.ClientSize      = New-Object System.Drawing.Size($W, 104)

        # 顶上一条皮肤色条，跟面板里的标题条保持同一种长相
        $acc = New-Object System.Windows.Forms.Panel
        $acc.BackColor = $cAcc
        $acc.Location  = New-Object System.Drawing.Point(0, 0)
        $acc.Size      = New-Object System.Drawing.Size($W, 4)
        $f.Controls.Add($acc)

        $fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
        $fontBody  = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
        $fontFoot  = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)

        $title = New-Object System.Windows.Forms.Label
        $title.Font      = $fontTitle
        $title.ForeColor = $cText
        $title.BackColor = [System.Drawing.Color]::Transparent
        $title.Text      = '⚡ F9开工'
        $f.Controls.Add($title)

        $sub = New-Object System.Windows.Forms.Label
        $sub.Font      = $fontBody
        $sub.ForeColor = $cSub
        $sub.BackColor = [System.Drawing.Color]::Transparent
        $sub.Text      = '准备中…'
        $f.Controls.Add($sub)

        $body = New-Object System.Windows.Forms.Label
        $body.Font      = $fontBody
        $body.ForeColor = $cText
        $body.BackColor = [System.Drawing.Color]::Transparent
        $body.Text      = ''
        $body.Visible   = $false
        $f.Controls.Add($body)

        # 进度条 = 三个纯 Panel 套娃：
        #   轨道 bar（圆角） ← 填充 fill ← 高光 sheen
        # 高光是填充的子控件，跑到填充外面会被系统自动裁掉，不用我们判断。
        $bar = New-Object System.Windows.Forms.Panel
        $bar.BackColor = $cTrack
        $f.Controls.Add($bar)

        $barFill = New-Object System.Windows.Forms.Panel
        $barFill.BackColor = $cAcc
        $barFill.Location  = New-Object System.Drawing.Point(0, 0)
        $barFill.Size      = New-Object System.Drawing.Size(0, 10)
        $bar.Controls.Add($barFill)

        # 高光颜色：把主题色往白（深底）或往黑（浅底）拉一把，做成"亮一道"的效果
        $lumA = (0.299 * $cAcc.R) + (0.587 * $cAcc.G) + (0.114 * $cAcc.B)
        $mix  = 0.45
        if ($lumA -gt 140) {
            $cSheen = [System.Drawing.Color]::FromArgb(
                [int]($cAcc.R * (1 - $mix)), [int]($cAcc.G * (1 - $mix)), [int]($cAcc.B * (1 - $mix)))
        } else {
            $cSheen = [System.Drawing.Color]::FromArgb(
                [int]($cAcc.R + (255 - $cAcc.R) * $mix),
                [int]($cAcc.G + (255 - $cAcc.G) * $mix),
                [int]($cAcc.B + (255 - $cAcc.B) * $mix))
        }
        $barSheen = New-Object System.Windows.Forms.Panel
        $barSheen.BackColor = $cSheen
        $barSheen.Location  = New-Object System.Drawing.Point(-30, 0)
        $barSheen.Size      = New-Object System.Drawing.Size(30, 10)
        $barFill.Controls.Add($barSheen)

        # 圆角：用 Region 给轨道塑个形，只做这一次（不是每帧），很便宜。
        # 子控件会被父控件的 Region 裁掉，所以填充也跟着是圆头的。
        try {
            $barW = $W - 28            # 跟 Update-ProgressLayout 里给条子的宽度保持一致
            $rp = New-Object System.Drawing.Drawing2D.GraphicsPath
            $rp.AddArc(0, 0, 10, 10, 90, 180)
            $rp.AddArc(($barW - 10), 0, 10, 10, 270, 180)
            $rp.CloseFigure()
            $bar.Region = New-Object System.Drawing.Region($rp)
            $rp.Dispose()
        } catch { }

        $foot = New-Object System.Windows.Forms.Label
        $foot.Font      = $fontFoot
        $foot.ForeColor = $cSub
        $foot.BackColor = [System.Drawing.Color]::Transparent
        $foot.Text      = ''
        $f.Controls.Add($foot)

        # 形象图（有就显示在左上角）。皮肤里没配图就整块不要，
        # 文字会自动往左挪，不会留一块空白。
        $pic = $null
        try {
            $img = Get-StickerImage (Get-LauncherConfig)
            if ($img) {
                $pic = New-Object System.Windows.Forms.PictureBox
                $pic.Image     = $img
                $pic.SizeMode  = 'Zoom'
                $pic.BackColor = $cCard
                $pic.Size      = New-Object System.Drawing.Size(36, 36)
                $pic.Visible   = $false
                $f.Controls.Add($pic)
            }
        } catch { $pic = $null }

        # 40 毫秒一跳：既推动那道流动的高光，也把填充比例平滑地拉向目标值。
        # 【注意】回调里改的变量必须写 $script: —— 回调有自己的作用域，
        # 写成 $x++ 只会动到它自己的局部变量，外面看着永远不动。
        $tickSrc = @'
try {
    $u = $script:PUi
    if (-not $u) { return }
    $script:PFlow = $script:PFlow + 0.030
    if ($script:PFlow -gt 1.0) { $script:PFlow = 0.0 }
    $d = $script:PTgt - $script:PFill
    if ([Math]::Abs($d) -lt 0.004) { $script:PFill = $script:PTgt }
    else { $script:PFill = $script:PFill + $d * 0.20 }
    # 形象图从窗口上沿"飞"进自己的位置（只在开场做一遍）
    if ($script:PHeart -ge 0 -and $u.Pic) {
        $script:PHeart = $script:PHeart + 1
        $n = 14
        if ($script:PHeart -ge $n) { $script:PHeart = -1; $u.Pic.Top = 10 }
        else {
            $t2 = $script:PHeart / [double]$n
            $e2 = 1 - [Math]::Pow(1 - $t2, 3)
            $u.Pic.Top = [int](-44 + (10 - (-44)) * $e2)
        }
    }
    Sync-BarVisual
    # 启动出去的软件，窗口出来了没有？出来了才收尾（自带降频，每帧不干活）
    if ($script:PWait) { Update-AppWait }
    if ((Get-Date) -ge $script:PHide) { Hide-Progress }
} catch { }
'@
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 40
        $timer.Add_Tick([scriptblock]::Create($tickSrc))

        $bag = @{
            Form     = $f
            Accent   = $acc
            Title    = $title
            Sub      = $sub
            Body     = $body
            Bar      = $bar
            BarFill  = $barFill
            BarSheen = $barSheen
            Foot     = $foot
            Pic      = $pic
            # 【坑】窗口还没 Show 出来的时候，Control.Visible 一律返回 false
            # （WinForms 的规矩：只要有一个父控件不可见，它就报 false）。
            # 布局是"显示之前"算的，那时候问 Pic.Visible 永远是 false ——
            # 结果就是"有形象图"和"没形象图"两套左边距算错一套。
            # 所以自己记一个标记，不问 Visible。下面统一用 PicOn。
            PicOn    = ($null -ne $pic)
            # 清单那一行在不在，同理自己记一个标记（窗口没 Show 时 Visible 不可信）
            BodyOn   = $false
            # 屏幕工作区缓存，第一次要用的时候才去读（见 Get-WorkArea）
            WA       = $null
            Timer    = $timer
            Font     = @{ Title = $fontTitle; Body = $fontBody; Foot = $fontFoot }
            ColText  = $cText
            Width    = $W
        }
        $script:PUi = $bag
        Sync-BarVisual

        # 【再预热一遍】把"亮窗"那条路上剩下的活先空跑掉。
        # 排版 / 贴右下角 / 带清单的排版 这几件事只在按键时才跑，第一次跑要现 JIT、
        # 现读屏幕工作区，实测第一次按键会多吃 200~600 毫秒 —— 那正是用户抱怨的"卡一下"。
        # 这里趁窗口还没 Show（屏幕上什么都看不见）把它们各干一遍，首按键就是热的。
        $script:PFill  = 0.0
        $script:PTgt   = 0.0
        $script:PHeart = -1
        $u2 = $script:PUi
        $u2.WA = $null                 # 逼它当场读一次屏幕，把枚举显示输出那笔钱付掉
        Update-ProgressLayout          # 开工态（没清单）排一遍
        Move-ProgressToCorner
        Sync-BarVisual
        $body.Visible  = $true         # 完成态（带清单）也排一遍，两条路的代码都要热
        $u2.BodyOn     = $true
        $body.Text     = '预热'
        $body.Height   = 22
        Update-ProgressLayout
        Move-ProgressToCorner
        $body.Visible  = $false
        $u2.BodyOn     = $false
        $body.Text     = ''
        Update-ProgressLayout

        # 然后把句柄造出来、把第一次绘制也做掉（这两步加起来约 200 毫秒），
        # 这样用户第一次按键时看到的就是"立刻"出来，不会卡一下。
        # 窗口摆到屏幕外面 (-4000,-4000) 再 Show：控件才会真正布局和绘制，
        # 而因为位置在屏幕外，用户完全看不见。
        $f.Location = [System.Drawing.Point]::new(-4000, -4000)
        $null = $f.Handle
        $f.Show()
        $f.Refresh()
        $f.Hide()
        return $true
    } catch {
        $script:PUi = $null
        Write-Log ('进度窗准备失败（不影响开工）: ' + $_.Exception.Message)
        return $false
    }
}

# 按窗口里到底有哪几行，重新排一遍坐标。
# 因为"完成"之后要插进一列清单，窗口得跟着长高；而窗口是贴右下角的，
# 长高之后必须重新贴一次，不然下沿就跑到屏幕外面去了。
function Update-ProgressLayout {
    $u = $script:PUi
    if (-not $u) { return }
    $W    = $u.Width
    $left = 14
    if ($u.Pic -and $u.PicOn) {
        $u.Pic.Left = 14        # 左边距跟其它控件对齐（Top 由"飞入"动画自己管，这里不许动）
        $left = 58              # 有形象图，文字给它让位
    }

    # 【性能】坐标一律用 SetBounds(x,y,w,h) 一把设完，别 Location / Size 各设一次：
    #   · Location + Size 各来一发 New-Object Point/Size ≈ 每个控件 11 毫秒
    #   · 换成 SetBounds 只要 ~0.5 毫秒，而且一次调用只触发一次布局
    # 整轮 8 个控件从 ~40 毫秒压到 ~4 毫秒 —— 按键那一下的手感就是靠这些抠出来的。
    $y = 10
    $u.Title.SetBounds($left, $y, ($W - $left - 14), 20)
    $y += 22

    $u.Sub.SetBounds($left, $y, ($W - $left - 14), 18)
    $y += 22

    if ($u.BodyOn) {
        # 【别删这行】清单也要摆位置。忘了设的话它默认待在 (0,0)，
        # 会正好压在标题和形象图上 —— 渲染出来是一团糊。
        # （判断用 BodyOn 而不是 Body.Visible：窗口没 Show 的时候 Visible 一律报 false，
        #   照它算会把"有清单"当成"没清单"，跟当年 Pic.Visible 那个坑是同一个。）
        $u.Body.SetBounds(14, $y, ($W - 28), $u.Body.Height)
        $y += $u.Body.Height + 4
    }

    $u.Bar.SetBounds(14, $y, ($W - 28), 10)
    $y += 18

    $u.Foot.SetBounds(14, $y, ($W - 28), 16)
    $y += 24

    if ($u.Form.ClientSize.Height -ne $y) {
        $u.Form.ClientSize = [System.Drawing.Size]::new($W, $y)
    }
}

# 屏幕工作区（屏幕里去掉任务栏之后那块）读一次就存起来。
# 【省时间】Screen.PrimaryScreen 第一次问要去枚举显示输出，实测 20~40 毫秒 ——
# 而这正是"按下去"那一下最不该花的时间。缓存在 Hide-Progress 里作废，
# 于是每次开工只重新问一次（热的时候 1 毫秒出头），改了分辨率/拖了任务栏也能跟上。
function Get-WorkArea {
    $u = $script:PUi
    if (-not $u) { return [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
    if ($null -eq $u.WA) { $u.WA = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
    return $u.WA
}

function Move-ProgressToCorner {
    $u = $script:PUi
    if (-not $u) { return }
    $wa = Get-WorkArea
    # 【性能】别写 New-Object System.Drawing.Point(...)：那句话要过一遍 cmdlet 管道，
    # 实测 11~14 毫秒；[Point]::new() 是 1 毫秒出头的直接构造。按键路上每一毫秒都算。
    $u.Form.Location = [System.Drawing.Point]::new(
        ([Math]::Max(0, $wa.Right  - $u.Form.Width  - 24)),
        ([Math]::Max(0, $wa.Bottom - $u.Form.Height - 24)))
}

# 把进度窗亮出来。按键后走的就是这里，所以要尽量少干活（十几毫秒）。
function Show-Progress {
    # -Warm：只走"改字/排版/挪位置"这些计算，**不真的 Show 出来**，也不写计时日志。
    # 后台刚起来时用它把这条路上的函数先编译好（PowerShell 第一次调用某个函数
    # 才编译它的函数体，冷的时候这一下要几十上百毫秒 —— 正好落在用户按键那一下）。
    param([string]$Title = '⚡ F9开工', [string]$SubText = '准备中…', [string]$Foot = '', [switch]$Warm)
    try {
        if (-not $script:PUi) {
            if (-not (Initialize-ProgressUi)) { return $false }
        }
        $u = $script:PUi
        # 这里故意不写 SuspendLayout/ResumeLayout：控件都是绝对定位，
        # 没有布局引擎要算，那对调用只是白白多跑一遍整窗重排（实测白花几十到几百毫秒）。
        $swL = [System.Diagnostics.Stopwatch]::StartNew()
        $u.Title.Text      = $Title
        $u.Title.ForeColor = $u.ColText
        $u.Sub.Text        = $SubText
        $u.Sub.Visible     = $true
        $u.Body.Text       = ''
        $u.Body.Visible    = $false
        $u.BodyOn          = $false      # 布局看标记，不看 Visible（窗口没 Show 时 Visible 不可信）
        $u.Foot.Text       = $Foot
        $mTxt = [int]$swL.Elapsed.TotalMilliseconds
        $swL.Restart()
        $script:PFill = 0.0
        $script:PTgt  = 0.0
        $script:PHide = [datetime]::MaxValue
        # 新的一次开工：把上一轮"还在等窗口"的残留清掉（万一是异常退出没收干净）
        $script:PWait       = $null
        $script:AppWaitTick = 0
        # 形象图从窗口上沿飞进来（"开工飘表情包"那个开关控制）
        $heartOn = $false
        try { $heartOn = Test-ConfigSwitch -Cfg (Get-LauncherConfig) -Key 'showHeartOnRun' -Default $false } catch { }
        $mCfg = [int]$swL.Elapsed.TotalMilliseconds
        $swL.Restart()
        if ($u.Pic) {
            $u.Pic.Visible = $true
            $u.PicOn      = $true
            $u.Pic.Top     = 10
            $script:PHeart = -1
            if ($heartOn) { $u.Pic.Top = -44; $script:PHeart = 0 }
        }
        $mPic = [int]$swL.Elapsed.TotalMilliseconds
        $swL.Restart()
        Update-ProgressLayout
        $mLayout = [int]$swL.Elapsed.TotalMilliseconds
        $swL.Restart()
        Move-ProgressToCorner
        $mMove = [int]$swL.Elapsed.TotalMilliseconds
        # 预热模式到此为止：上面的计算都做过了（该编译的也编译了），
        # 但不 Show、不开计时器、不写日志 —— 用户看不到任何东西。
        if ($Warm) { return $true }
        $swL.Restart()
        $u.Form.Show()          # ShowWithoutActivation 已覆盖，不会抢焦点
        $mShow = [int]$swL.Elapsed.TotalMilliseconds
        $swL.Restart()
        $u.Form.Refresh()
        if (-not $u.Timer.Enabled) { $u.Timer.Start() }
        $mRef = [int]$swL.Elapsed.TotalMilliseconds
        # 「按下→出窗」= 用户真正感觉到的那一下。拆成"按键到进开工"(热键层读配置)
        # 和"进开工到窗口亮起"(下面这几段)，哪一段变胖了都一眼看得出来。
        $mPressBefore = -1
        if ($script:SwPress) { $mPressBefore = [int]$script:SwPress.ElapsedMilliseconds }
        Write-Log ('进度窗细分: 改字 ' + $mTxt + ' / 读配置 ' + $mCfg + ' / 形象图 ' + $mPic +
                   ' / 排版 ' + $mLayout + ' / 挪位置 ' + $mMove + ' / Show ' + $mShow + ' / Refresh ' + $mRef + ' ms' +
                   '  ＝本次共 ' + ([int]$mTxt + [int]$mCfg + [int]$mPic + [int]$mLayout + [int]$mMove + [int]$mShow + [int]$mRef) + ' ms' +
                   '（按键→出窗 ' + $mPressBefore + ' ms，其中热键层 ' + $script:PressCfgMs + ' ms）')
        $script:SwPress = $null
        return $true
    } catch {
        $script:PFail++
        if ($script:PFail -le 2) { Write-Log ('进度窗显示失败（不影响开工）: ' + $_.Exception.Message) }
        return $false
    }
}

# 更新进度。Pct 传 -1 表示"只改文字、不动条子"。
# -Pump 会顺手泵一次消息：开软件的过程中没有消息循环，
# 不泵的话条子就要等到开完才动一下（那个"动"才是用户想看的）。
function Set-Progress {
    param([double]$Pct = -1, [string]$SubText, [string]$Foot, [switch]$Pump)
    try {
        $u = $script:PUi
        if (-not $u) { return }
        if ($Pct -ge 0) { $script:PTgt = [Math]::Max(0.0, [Math]::Min(1.0, $Pct)) }
        if ($PSBoundParameters.ContainsKey('SubText')) { $u.Sub.Text  = $SubText }
        if ($PSBoundParameters.ContainsKey('Foot'))    { $u.Foot.Text = $Foot }
        Sync-BarVisual
        if ($Pump) {
            [System.Windows.Forms.Application]::DoEvents()
            # DoEvents 会把消息泵里的东西都跑一遍，包括"到点自己收起"那件事；
            # 所以要顺手把计时推一下，条子才来得及走到"平滑后"的位置
            $d = $script:PTgt - $script:PFill
            if ([Math]::Abs($d) -lt 0.004) { $script:PFill = $script:PTgt }
            else { $script:PFill = $script:PFill + $d * 0.20 }
            Sync-BarVisual
            [System.Windows.Forms.Application]::DoEvents()
        }
    } catch { }
}

# 干完了：条子拉满，写结论，顺手把清单列出来，然后到点自己收起。
function Complete-Progress {
    param([string]$Title, [string]$SubText, [string]$Foot = '', [string[]]$Lines = @(), [int]$HoldMs = 3000)
    try {
        $u = $script:PUi
        if (-not $u) { return }
        $script:PTgt  = 1.0
        if (-not [string]::IsNullOrEmpty($Title)) { $u.Title.Text = $Title }
        # 收尾时那句"正在打开 xxx"已经是过去式了，必须换掉 ——
        # 画面上留着"正在打开"，用户会以为还没开完。
        if ($PSBoundParameters.ContainsKey('SubText')) { $u.Sub.Text = $SubText }
        $list = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($list.Count -gt 7) {
            $list = @(@($list)[0..5]) + ('…… 还有 ' + (@($Lines).Count - 6) + ' 项')
        }
        if ($list.Count -gt 0) {
            $u.Body.Text    = ($list -join [Environment]::NewLine)
            $u.Body.Height  = ($list.Count * 18 + 4)
            $u.Body.Visible = $true
            $u.BodyOn       = $true
        } else {
            $u.Body.Visible = $false
            $u.BodyOn       = $false
        }
        $u.Foot.Text = $Foot
        Update-ProgressLayout
        # 【别删这行】清单插进来之后窗口会长高十几到几十像素。窗口是按"下沿贴屏幕底"
        # 摆的，长高之后不重新贴一次，下沿就直接跑到屏幕外面去了 ——
        # 实测：进行中 348x96 摆在下沿 704，切成"完成+清单"变 348x158，
        # 位置还留在 608 的话下沿就是 766，超出 728 的工作区，清单末几行和页脚全被切掉。
        Move-ProgressToCorner
        Sync-BarVisual
        $u.Form.Refresh()
        $script:PHide = (Get-Date).AddMilliseconds($HoldMs)
        if (-not $u.Timer.Enabled) { $u.Timer.Start() }
    } catch { }
}

# ---------------------------------------------------------------- 等软件真的出来
# 【为什么要这一步】以前"开好一个软件"的定义是"Process.Start 返回了"，而它几十毫秒就返回，
# 于是进度条 0.5 秒跑满、再停 3 秒收起 —— 可微信在这台机器上冷启动要 20 多秒。
# 用户看到的就是"条子跑完了，然后干等半分钟"，会以为程序坏了。
# 现在：条子一直流到窗口真的出现在屏幕上为止，"跑完"就等于"东西真的在你眼前了"。
#
# 【为什么不在这里当场死等】当场等会把后台占住几十秒（听不见快捷键、也泵不了消息）。
# 所以只把"还没起来的"记下来，交给进度窗自己的定时器（40ms 一跳）慢慢看，
# 消息照泵、条子照流、按键照样响应。
#
# 【为什么最后才等】开软件那一段必须是"一口气全点出去"：三个软件并行启动，
# 总耗时约等于最慢的那一个（实测 25 秒）。要是开一个等一个，就变成 25+25+25 了。
$script:PWait = $null        # 正在等的那批：Items / Deadline / Started / IsEn / Head / Lines / Foot / Hold
$script:AppWaitTick = 0

function Update-AppWait {
    $w = $script:PWait
    if (-not $w) { return }

    # 【必须先确认探测组件能用 —— 第一版就是在这里栽的】
    # 这个原生组件原来只在"后台常驻"启动时预编译过；别的入口（面板「立即开工一次」
    # 走的 -Sequence、试运行）从没初始化它，于是 [AppWinProbe] 每次都抛
    # "找不到类型"，又被下面的 catch 吞掉，永远返回 false ——
    # 结果：明明 0.6 秒就弹出来的记事本，条子却傻等了整整 30 秒。
    # 教训：**探测失败要当成"判断不了、立刻收尾"**，绝不能当成"它还没出来"。
    $probeOk = $true
    if (-not ('AppWinProbe' -as [type])) { $null = Initialize-AppWinProbe }
    if (-not ('AppWinProbe' -as [type])) {
        $probeOk = $false
        if (-not $w.Warned) {
            $w.Warned = $true
            Write-Log '窗口探测组件不可用 —— 这次不等窗口，按老方式直接收尾（不影响开工）'
        }
        foreach ($it in @($w.Items)) { $it.Ready = $true; $it.Ms = -2 }
    }

    # 降频：定时器 40ms 一跳，每 6 跳（约 0.25 秒）才真去枚举一次顶层窗口。
    # 这台是 2012 年的双核，枚举窗口这种活不能每帧做。
    # （探测组件不可用时不降频：要立刻走到下面的收尾，别再多等 0.25 秒）
    if ($probeOk) {
        $script:AppWaitTick = $script:AppWaitTick + 1
        if (($script:AppWaitTick % 6) -ne 0) { return }
    }

    $items = @($w.Items)
    $left  = 0
    foreach ($it in $items) {
        if ($it.Ready) { continue }
        if ($it.Pid -le 0) { $it.Ready = $true; continue }
        # 进程没了也算起来过：有些软件只是个"壳"，把界面交给别的进程去做（也可能开完就退）
        $alive = $false
        try { $alive = ($null -ne (Get-Process -Id $it.Pid -ErrorAction SilentlyContinue)) } catch { }
        if (-not $alive) { $it.Ready = $true; continue }
        $has = $false
        try { $has = [AppWinProbe]::HasVisible([uint32]$it.Pid) } catch { }
        if ($has) {
            $it.Ready = $true
            $it.Ms = [int]((Get-Date) - $w.Started).TotalMilliseconds
        } else { $left++ }
    }

    $over = ((Get-Date) -ge $w.Deadline)
    if ($left -gt 0 -and -not $over) {
        # 还在等：把"谁还没起来、已经等了多久"写在窗上 —— 等待本身要看得见。
        # 用户抱怨的正是"看不见的等待"，所以宁可啰嗦一点也要把秒数报出来。
        $names = @($items | Where-Object { -not $_.Ready } | ForEach-Object { $_.Name })
        $e = [math]::Round(((Get-Date) - $w.Started).TotalMilliseconds / 1000.0, 1)
        if ($w.IsEn) { Set-Progress -SubText ('Waiting for ' + ($names -join ', ') + '… ' + $e + ' s') }
        else         { Set-Progress -SubText ('正在启动 ' + ($names -join '、') + '…（已等 ' + $e + ' 秒）') }
        return
    }

    # ---- 到齐了（或者到点了）：真正收尾 ----
    $script:PWait       = $null
    $script:AppWaitTick = 0
    $waited = [math]::Round(((Get-Date) - $w.Started).TotalMilliseconds / 1000.0, 1)

    # 每个软件"从按下到窗口真的出现"用了多久 —— 这个数才是用户感觉到的速度。
    # 以后再说"慢"，看这一行就知道慢在哪个软件、是不是它自己的冷启动。
    foreach ($it in $items) {
        $t = '没等到窗口（到点了，或它本来就不弹窗，比如托盘程序）'
        if ($it.Ms -ge 0) { $t = $it.Ms.ToString() + ' ms' }
        elseif ($it.Ms -eq -2) { $t = '没做判断（探测组件不可用）' }
        Write-Log ('窗口出现: ' + $it.Name + ' -> ' + $t)
    }

    $head = $w.Head
    $notUp = @($items | Where-Object { -not $_.Ready })
    if ($notUp.Count -gt 0) {
        if ($w.IsEn) { $head = '✓ Workday started - ' + $notUp.Count + ' still loading' }
        else         { $head = '✓ 开工完成（有 ' + $notUp.Count + ' 项还没看到窗口）' }
    }
    $sub = $(if ($w.IsEn) { 'Ready in ' + $waited + ' s' } else { '到全部就绪用了 ' + $waited + ' 秒' })

    # 特别慢的单独点出来 —— 用户最想知道"我这台机器到底慢在哪"，
    # 顺手也把责任说清楚：这是那个软件自己启动慢，不是启动器在偷懒。
    $lines = @($w.Lines)
    $slow  = @($items | Where-Object { $_.Ms -ge 5000 } | Sort-Object Ms -Descending)
    foreach ($s in $slow) {
        $sec = [math]::Round($s.Ms / 1000.0, 1)
        if ($w.IsEn) { $lines += ('· ' + $s.Name + ': ' + $sec + ' s to appear (its own cold start)') }
        else         { $lines += ('· ' + $s.Name + ' 的窗口 ' + $sec + ' 秒才出来（它自己启动慢）') }
    }

    Complete-Progress -Title $head -SubText $sub -Lines $lines -Foot $w.Foot -HoldMs $w.Hold
}

function Hide-Progress {
    try {
        $u = $script:PUi
        if (-not $u) { return }
        $u.Timer.Stop()
        $u.Form.Hide()
        $script:PHide  = [datetime]::MaxValue
        $script:PFill  = 0.0
        $script:PTgt   = 0.0
        $script:PHeart = -1
        # 窗收掉了，"还在等窗口"这件事也就作废了 —— 不清的话它会跟着下一次开工乱跑
        $script:PWait       = $null
        $script:AppWaitTick = 0
        # 顺手把屏幕工作区缓存作废：下次开工重新读一次（1 毫秒出头）。
        # 用户中途改了分辨率、把任务栏换个边，下一按就自动跟上了，不会永远贴着老位置。
        $u.WA = $null
    } catch { }
}

# 等待，但不把消息泵停掉 —— 条子在这段时间里照样流动。
# （直接 Start-Sleep 的话，动画会整段卡住，看着像死机。）
function Wait-WithPump {
    param([int]$Milliseconds)
    if ($Milliseconds -le 0) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $it = 0
    while ($sw.Elapsed.TotalMilliseconds -lt $Milliseconds) {
        $swd = [System.Diagnostics.Stopwatch]::StartNew()
        try { [System.Windows.Forms.Application]::DoEvents() } catch { }
        $swd.Stop()
        # 单次泵消息不该慢。一旦有慢的，说明窗口里又混进了"每帧跑脚本"的绘制代码
        #（自绘进度条那次就是这么被发现的：一次重绘卡一秒多）。
        # 阈值给 150 是留了余量：窗口第一次画出来那一下本来就要几十毫秒，属于正常。
        if ($swd.Elapsed.TotalMilliseconds -gt 150) {
            Write-Log ('    [慢] 第' + $it + '次泵消息花了 ' + [int]$swd.Elapsed.TotalMilliseconds + ' ms，检查进度窗里是不是有自绘代码')
        }
        $it++
        Start-Sleep -Milliseconds 10
    }
}

# 开发验收用：把进度窗当前的样子渲染成一张图（只看程序自己的窗口，绝不截用户桌面）。
# 做法是先把窗口挪到屏幕外再 Show()：只有这样子控件才会真正布局、绘制的内容才画得出来；
# 而因为位置在屏幕外，用户完全看不到。
# 把某个窗口"按它自己真实的画法"渲染一遍，抓成位图。
#
# 【为什么不用 Control.DrawToBitmap】它是让每个子控件分别响应 WM_PRINT，
# 实测画 Panel 会画成一块近黑色（文字正常、颜色全错）—— 拿它出的预览图会骗自己：
# 进度条明明是蓝底浅灰轨道，图上却是一条黑杠。PrintWindow 是让整个窗口重绘一次，
# 画出来的和屏幕上看到的一致。
# 只渲染指定窗口自己，**不碰桌面**（不是截屏，是让窗口自己画到我们的画布上）。
function Get-WindowShot {
    param([IntPtr]$Hwnd, [int]$W, [int]$H)
    if (-not ('WinShot' -as [type])) {
        Add-Type -Name 'WinShot' -Namespace 'Launcher' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool PrintWindow(System.IntPtr hwnd, System.IntPtr hdcBlt, uint nFlags);
'@ -ErrorAction Stop
    }
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    try {
        # 2 = PW_RENDERFULLCONTENT：不加这个，有些控件会渲染成空白
        [void][Launcher.WinShot]::PrintWindow($Hwnd, $hdc, 2)
    } finally {
        $g.ReleaseHdc($hdc)
        $g.Dispose()
    }
    return $bmp
}

function Save-ProgressShot {
    param([string]$Path, [double]$ForceFill = -1)
    try {
        $u = $script:PUi
        if (-not $u) { return $false }
        if ($ForceFill -ge 0) {
            # 【两个都要设】只改 PFill 的话，40 毫秒后的那一跳会把它又拉回 PTgt（=0），
            # 截图出来条子几乎是空的 —— 验收图就会骗自己。
            $script:PFill = [Math]::Max(0.0, [Math]::Min(1.0, $ForceFill))
            $script:PTgt  = $script:PFill
            Sync-BarVisual
        }
        $u.Form.Location = New-Object System.Drawing.Point(-4000, -4000)
        $u.Form.Show()
        for ($i = 0; $i -lt 8; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
        }
        $tw = [int]$u.Form.Width
        $th = [int]$u.Form.Height
        # 先试 PrintWindow（颜色真实）；拿不到句柄/失败才退回 DrawToBitmap（颜色会偏，但至少能看布局）
        $bmp = $null
        try {
            if ($u.Form.Handle -ne [IntPtr]::Zero) {
                $bmp = Get-WindowShot -Hwnd $u.Form.Handle -W $tw -H $th
            }
        } catch {
            Write-Log ('PrintWindow 抓图失败，退回 DrawToBitmap: ' + $_.Exception.Message)
        }
        if (-not $bmp) {
            $bmp = New-Object System.Drawing.Bitmap($tw, $th)
            $u.Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $tw, $th)))
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        # 顺手把每个控件的实际位置记一行：布局错位的时候，看这一行就知道是谁跑到哪去了
        try {
            $dbg = @()
            foreach ($c in $u.Form.Controls) {
                $dbg += ($c.GetType().Name + ' ' + $c.Location.X + ',' + $c.Location.Y + ' ' +
                         $c.Width + 'x' + $c.Height + $(if ($c.Visible) { ' V' } else { ' H' }))
            }
            Write-Log ('进度窗控件: ' + ($dbg -join ' | '))
            Write-Log ('进度窗缩放: 模式=' + $u.Form.AutoScaleMode +
                       ' 设计=' + $u.Form.AutoScaleDimensions.Width + 'x' + $u.Form.AutoScaleDimensions.Height +
                       ' 当前=' + $u.Form.CurrentAutoScaleDimensions.Width + 'x' + $u.Form.CurrentAutoScaleDimensions.Height)
        } catch { }
        Write-Log ('进度窗截图: ' + $Path + ' 尺寸 ' + $tw + 'x' + $th)
        return $true
    } catch {
        Write-Log ('进度窗截图失败: ' + $_.Exception.Message)
        return $false
    }
}

function Get-PlainHotKeyList {
    param($Defs)
    $out = @()
    foreach ($d in $Defs) { $out += [string]$d.Text }
    return $out
}

# 跟上面那个一一对应，取的是 'launch' / 'quit'。
# -SimTrigger 里要先把这张表填好，不然模拟按键会被当成开工。
function Get-HotKeyKindList {
    param($Defs)
    $out = @()
    foreach ($d in $Defs) { $out += [string]$d.Kind }
    return $out
}

# ---------------------------------------------------------------- 后台有没有在跑
# 后台进程启动时会一直占着一个叫 WorkdayLauncherDaemon 的互斥体，进程一死就自动放开。
# 所以"能不能打开这个互斥体"就等于"后台在不在"。
# 用互斥体探测而不是去查进程列表：查进程要 200~500 毫秒，这个只要几毫秒 ——
# 它会被用在每次双击图标的时候，快一点不亏。
$script:DaemonMutexName = 'Local\WorkdayLauncherDaemon'

function Test-DaemonRunning {
    $m = $null
    try {
        $m = [System.Threading.Mutex]::OpenExisting($script:DaemonMutexName)
        return $true
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    } catch [System.UnauthorizedAccessException] {
        return $true      # 打不开但不等于不存在（权限问题），当成在跑
    } catch {
        return $false
    } finally {
        if ($m) { try { $m.Dispose() } catch { } }   # 只关句柄，绝不动互斥体本身
    }
}

function Get-LauncherPsExe {
    $p = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $p)) { $p = 'powershell.exe' }
    return $p
}

# 静默拉起一个后台进程（不经过 cmd，所以不可能闪黑框）。
# 用 ProcessStartInfo 而不是 Start-Process：CreateNoWindow 更可靠。
function Start-DaemonQuiet {
    param([switch]$WaitReady)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = (Get-LauncherPsExe)
        $psi.Arguments       = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                               (Join-Path $ScriptDir 'Start-Workday.ps1') + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.WorkingDirectory = $ScriptDir
        [void][System.Diagnostics.Process]::Start($psi)
        if ($WaitReady) {
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Milliseconds 100
                if (Test-DaemonRunning) { return $true }
            }
        }
        return $true
    } catch {
        Write-Log ('拉起后台失败: ' + $_.Exception.Message)
        return $false
    }
}

# 不管从哪个入口进来（双击图标 / 面板 / 开工一次），只要发现后台没在跑就顺手把它拉起来。
# 为什么需要：开机自启只认"真正登录"这一个时机，如果只是解锁屏幕（或后台被误关了），
# 后台就一直是死的 —— 表现出来就是"快捷键按了没反应"。
function Ensure-Daemon {
    if (Test-DaemonRunning) { return $true }
    Write-Log '发现后台没在跑，顺手拉起来'
    return (Start-DaemonQuiet)
}

# 后台刚起来时先把"贵"的东西都加载好。
# 不然第一次按键要现场加载 WinForms、造窗口造字体，加起来能拖到一秒多 ——
# 用户会觉得"第一次按特别慢"。
function Warm-UpDaemon {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void](Initialize-HotKeyHost)

    # 【重要，别删】把 PowerShell 自己的模块先叫醒。
    # Get-Content / ConvertFrom-Json / Get-Item / Get-Date 这些是"按需加载"的，
    # 第一次用会现场去加载模块 —— 实测能吃掉 150~450 毫秒。放在这里做，
    # 用户永远感觉不到；要是等第一次按快捷键才做，那一下就会明显卡顿。
    foreach ($m in @('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility',
                     'Microsoft.PowerShell.Security')) {
        try { Import-Module $m -ErrorAction SilentlyContinue } catch { }
    }
    $null = Get-Date
    $null = Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
    $null = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $null = (Get-LauncherConfig)          # 顺手把配置解析一次，缓存也就热了
    $null = [System.DateTime]::Now
    try { $null = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea } catch { }

    # 界面上要用的语言先定下来（"开工完成，已打开 3 项"这种文案要靠它选中文还是英文）
    try { $script:TipLang = Get-LauncherLang } catch { $script:TipLang = 'zh' }

    # 彩蛋要用的组件也先加载：Add-Type 一个程序集要几百毫秒，
    # 等"开工完成要说那句话"的时候才现加载，语音就会晚半秒才响。
    # 只加载用户真的配了的那个 —— 没配就不花这个钱。
    try {
        $cfgW = Get-LauncherConfig
        $sndW = ''
        try { $sndW = [string](Get-ConfigText $cfgW 'soundPath') } catch { $sndW = '' }
        if ($sndW) {
            $extW = ''
            try { $extW = [System.IO.Path]::GetExtension($sndW).ToLowerInvariant() } catch { }
            # mp3/wma/m4a 走 WPF 的播放器；wav 用系统自带 SoundPlayer，不用加载东西
            if ($extW -and $extW -ne '.wav') {
                try { Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue } catch { }
            }
        } else {
            $sayW = ''
            try { $sayW = [string](Get-ConfigText $cfgW 'sayText') } catch { $sayW = '' }
            if ($sayW) { try { Add-Type -AssemblyName System.Speech -ErrorAction SilentlyContinue } catch { } }
        }
    } catch { }

    $hintOk = Initialize-ProgressUi

    # 窗口探测组件先编好/加载好（有缓存就是读一个 dll，几毫秒）。
    # 等第一次按快捷键才现编，那几十上百毫秒正好砸在用户唯一能感觉到的那一下。
    try { $null = Initialize-AppWinProbe } catch { }
    # 顺手把原生调用也 JIT 一遍（拿自己当靶子，必定有进程）
    try { $null = [AppWinProbe]::HasVisible([uint32]$PID) } catch { }

    # ---- 把"按下按键 → 亮出进度窗 → 开软件"这条路上的函数先摸一遍 ----
    # 【为什么必须做这一步】PowerShell 是**第一次调用某个函数时才编译它的函数体**。
    # 实测（真实按键）：冷态第一次"按下 → 出窗"要 338 毫秒，紧接着第二次只要 23 毫秒 ——
    # 差的那 300 多毫秒几乎全是编译开销，而且正好砸在用户唯一能感觉到的那一下，
    # 还是"开机后第一次按快捷键"这一次（用户一定会拿它来判断快不快）。
    # 所以趁后台刚起来、用户还没按键，把它们都空跑一遍：
    #   · -Warm 模式不 Show 窗、不写日志、不开任何软件；
    #   · 走的是和真开工**完全相同的代码路径**（排清单 + Resolve-AppPath + 进度窗排版），
    #     所以预热的就是真正要用的那些代码，不会"热了别的、冷的还是冷的"。
    try {
        $warmCfg = Get-LauncherConfig
        if ($warmCfg) {
            Invoke-Launch -IsDryRun -NoProgress -Warm -Cfg $warmCfg
            $null = Show-Progress -Warm -Title '⚡ F9开工' -SubText '准备中…' -Foot ''
            Set-Progress -SubText '正在打开' -Foot ''
            Set-Progress -Pct 0.5
            Complete-Progress -Title '✓ 开工完成' -SubText '预热' -Foot '' -Lines @('✓ 预热')
            Wait-WithPump -Milliseconds 1
            # "等窗口出现"这条路的函数也空跑一次（PWait 为空时它立刻返回，什么也不做）
            $script:PWait = $null
            Update-AppWait
            Hide-Progress
        }
    } catch {
        Write-Log ('预热（按键路径）没走完，不影响开工: ' + $_.Exception.Message)
    }

    # 顺手把"判断软件在不在跑"这条路径热一下（第一次走要 JIT + 原生快照，
    # 实测第一次 300~400 毫秒、之后 10~40 毫秒）。放在预热里付掉，用户感觉不到。
    # 拿 powershell.exe 当靶子：它必定在跑，函数里的 Dispose 也会一并走到。
    try { $null = Test-AppAlreadyRunning -Exe 'powershell.exe' } catch { }
    # 收工窗口也先造一遍（十几个控件 + 读皮肤，实测一两百毫秒）。
    # 它不在"开机后第一次按"的热路径上（没人一开机就关机），
    # 但顺手预热了，第一次按收工键就不用等这一下。
    try { Show-ShutdownUi -Warm } catch { }
    $sw.Stop()
    Write-Log ('预热完成，用时 ' + [int]$sw.Elapsed.TotalMilliseconds + ' ms（右下角进度窗: ' +
               $(if ($hintOk) { '好了' } else { '没做出来，不影响开工' }) + '）')
}

# ---------------------------------------------------------------- 按了一次快捷键
# 刚按过就别再开工：手抖连按两下、或者两个快捷键一起按，不该把同一批软件开两遍
$script:LastTriggerAt   = [datetime]::MinValue
$script:TriggerMinGapMs = 1500
# 注册快捷键时填进来，按键时拿它显示"按的是哪个键"（内容是快捷键的显示名）
$script:HotKeyNames     = @()
# 跟 HotKeyNames 一一对应，内容是 'launch' 或 'quit'。
# 按键回调只拿得到一个序号（#1、#2…），要靠这张表才知道该开软件还是弹收工窗。
$script:HotKeyKinds     = @()
# 正在开工的标记。开工过程中会 DoEvents 泵消息，泵进来的按键回调有可能重入 ——
# 不拦住的话同一批软件会被开两遍（还会多弹一个进度窗盖在上面）。
$script:LaunchBusy      = $false

# =====================================================================
#  一键收工：关机 / 重启 / 睡眠
# =====================================================================
# 用户 2026-09-24 要的：按一个快捷键（默认 Ctrl+Alt+Q）弹一个小窗口，
# 里面三个按钮【关机】【重启】【睡眠】。点了不会立刻执行 ——
# 先倒数（默认 60 秒，面板里能改），这段时间里点【取消】或按 Esc 就能停下。
#
# 为什么一定要留那 60 秒：手滑点到「关机」的代价太大（正在写的东西直接没了）。
# 给一段"后悔时间"，比弹一个"你确定吗？"的对话框有用得多 ——
# 后者只会被条件反射地点掉。
#
# 窗口做成"两页"，两页都提前造好、靠 Visible 切换：
#   A 选动作  →  点某个按钮  →  B 倒数  →  数到 0 才真的执行
# 现场新建控件在那一下会明显卡一下，还容易错位，所以两页一起造。
$script:QuitState = 'pick'   # pick=在选动作 / count=正在倒数 / done=走人
$script:QuitAct   = ''       # shutdown / restart / sleep
$script:QuitBusy  = $false   # 窗口开着的时候再按快捷键，不叠第二个窗口
$script:QuitLeft  = -1       # 当前显示的是第几秒（变了才去改文字）
$script:QuitEnd   = [datetime]::Now
$script:QUi       = $null    # 控件袋（事件回调跟外面作用域不同，必须走 $script:）

# 收工窗口里显示哪几个动作。config 的 shutdownActions 里写全了就全显示。
# 写错单词就当没写（给全三个），总比弹一个空窗口让人以为坏了强。
function Get-QuitActions {
    $def = @('shutdown', 'restart', 'sleep')
    $cfg = Get-LauncherConfig
    if (-not $cfg) { return $def }
    $p = $cfg.PSObject.Properties['shutdownActions']
    if (-not $p -or $null -eq $p.Value) { return $def }
    $out = @()
    foreach ($v in @($p.Value)) {
        $s = ([string]$v).Trim().ToLowerInvariant()
        if     ($s -eq '关机') { $s = 'shutdown' }
        elseif ($s -eq '重启') { $s = 'restart' }
        elseif ($s -eq '睡眠') { $s = 'sleep' }
        if (($def -contains $s) -and -not ($out -contains $s)) { $out += $s }
    }
    if ($out.Count -eq 0) { return $def }
    return $out
}

# 倒计时秒数。范围兜底：太小来不及反悔，太大用户会以为按了没反应。
function Get-QuitSeconds {
    $n = 60
    $cfg = Get-LauncherConfig
    if ($cfg) {
        $p = $cfg.PSObject.Properties['shutdownSeconds']
        if ($p -and $null -ne $p.Value) {
            $t = 0
            if ([int]::TryParse(([string]$p.Value).Trim(), [ref]$t)) { $n = $t }
        }
    }
    if ($n -lt 5)   { $n = 5 }
    if ($n -gt 600) { $n = 600 }
    return $n
}

function Get-QuitActionLabel {
    param([string]$Act)
    switch ($Act) {
        'shutdown' { return (TP '关机' 'Shut down') }
        'restart'  { return (TP '重启' 'Restart') }
        'sleep'    { return (TP '睡眠' 'Sleep') }
    }
    return $Act
}

# 【不用 Start-Process】那是个 cmdlet，要过参数绑定+输出流，实测 60~100 毫秒；
# 用 ProcessStartInfo 只要几毫秒。这里虽然不急，但跟开工那边保持同一个写法，
# 省得以后有人以为这两处行为不一样。
function Start-QuitProc {
    param([string]$Path, [string]$Args)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $Path
        $psi.Arguments       = $Args
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        [void][System.Diagnostics.Process]::Start($psi)
        return $true
    } catch {
        Write-Log ('收工命令起不来(' + $Path + ' ' + $Args + '): ' + $_.Exception.Message)
        return $false
    }
}

# 真的去执行。-Preview 时只写日志、什么都不做（自检和截图走这个）。
function Invoke-QuitAction {
    param([string]$Act, [switch]$Preview)
    $lab = Get-QuitActionLabel $Act
    if ($Preview) { Write-Log ('[试运行] 本来要执行：' + $lab); return }
    Write-Log ('收工：执行 ' + $lab)

    $sys = Join-Path $env:SystemRoot 'System32'
    if ($Act -eq 'shutdown') {
        # 这里刻意【不加 /f】。加了会强行关掉没保存的程序（正在写的文档直接丢）；
        # 不加的话 Windows 会自己逐个问那些程序"要不要保存"，行为跟你点开始菜单里的
        # 「关机」完全一样 —— 对用户来说这才是能预期的。
        [void](Start-QuitProc -Path (Join-Path $sys 'shutdown.exe') -Args '/s /t 0')
    } elseif ($Act -eq 'restart') {
        [void](Start-QuitProc -Path (Join-Path $sys 'shutdown.exe') -Args '/r /t 0')
    } elseif ($Act -eq 'sleep') {
        # 睡眠只有 powrprof 里那个 SetSuspendState 能用（0 = 挂起）。
        # ⚠️ 机器上如果开着"休眠"（Win10/11 为了快速启动默认就开着），
        #    这条命令实际会变成休眠 —— 一样省电、下次开机还更快，不算坏事。
        #    这一点在 README.txt 里跟用户说明白了，免得他以为按错了。
        [void](Start-QuitProc -Path (Join-Path $sys 'rundll32.exe') -Args 'powrprof.dll,SetSuspendState 0,1,0')
    }
}

# 点了某一页的某个动作按钮之后走这里：定好结束时刻、翻到倒数页。
# 单独抽成函数是为了事件回调里只写一行 —— 回调里能写的东西越少越好，
# 因为回调跟外面是两个作用域（变量必须 $script: 开头才看得见，这是踩过的坑）。
function Start-QuitCountdown {
    param([string]$Act)
    $script:QuitAct  = $Act
    $script:QuitLeft = -1
    $n = 60
    try { $n = [int]$script:QUi.Num.Value } catch { }
    $script:QuitEnd  = (Get-Date).AddSeconds($n)
    $lab = Get-QuitActionLabel $Act
    try {
        $script:QUi.BigSub.Text = (TP ('秒后' + $lab) ('seconds until ' + $lab.ToLowerInvariant()))
        $script:QUi.PgA.Visible  = $false
        $script:QUi.PgB.Visible  = $true
        $script:QUi.Big.Text     = [string]$n
    } catch { }
    $script:QuitState = 'count'
    Write-Log ('收工窗口：选了「' + $lab + '」，倒数 ' + $n + ' 秒（点【取消】或按 Esc 可以停下）')
}

function Stop-QuitCountdown {
    $script:QuitState = 'done'
    $script:QuitAct   = ''
    Write-Log '收工窗口：被取消了，什么都没做'
}

# ---------------------------------------------------------------- 收工窗口本体
function Show-ShutdownUi {
    # -Preview  只演窗口、绝不执行（-QuitTest 用）
    # -Warm     只把窗口造一遍就走（预热用：让第一次按键不用现编译这一大段）
    # -ShotDir  离屏渲染两张图（选动作页 / 倒数页）然后退出，给预览图用
    param([switch]$Preview, [switch]$Warm, [string]$ShotDir = '')

    if ($script:QuitBusy) {
        Write-Log '收工窗口已经开着，这次按的快捷键忽略'
        return
    }
    $script:QuitBusy  = $true
    $script:QuitState = 'pick'
    $script:QuitAct   = ''
    $f = $null
    try {
        if (-not (Initialize-HintUi)) {
            Write-Log '收工窗口起不来（WinForms 不可用），已放弃'
            return
        }
        # 颜色全部跟着皮肤走：换了皮肤这个窗口也一起换，不会突然冒出一个格格不入的白框
        $sk     = Get-LauncherSkin
        $cCard  = ConvertTo-SkinColor ($sk.card)      '#FFFFFF'
        $cText  = ConvertTo-SkinColor ($sk.text)      '#1F2A37'
        $cSub   = ConvertTo-SkinColor ($sk.subText)   '#6E7681'
        $cAcc   = ConvertTo-SkinColor ($sk.accent)    '#2D6BD8'
        $cAccD  = ConvertTo-SkinColor ($sk.accentDark)'#1F4FA8'
        $cAccT  = ConvertTo-SkinColor ($sk.accentText)'#FFFFFF'
        $cEdge  = ConvertTo-SkinColor ($sk.border)    '#D8DEE8'

        $W = 420
        $H = 236
        $f = New-Object System.Windows.Forms.Form
        $f.Text            = (TP 'F9收工' 'F9 Finish')
        $f.FormBorderStyle = 'FixedDialog'
        $f.MaximizeBox     = $false
        $f.MinimizeBox     = $false
        $f.ShowInTaskbar   = $false
        $f.TopMost         = $true
        $f.StartPosition   = 'CenterScreen'
        $f.BackColor       = $cCard
        $f.ClientSize      = New-Object System.Drawing.Size($W, $H)
        # 键盘事件先给窗体：Esc 才能真正当成"取消"用
        $f.KeyPreview      = $true

        $fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 12,   [System.Drawing.FontStyle]::Bold)
        $fontBody  = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
        $fontBig   = New-Object System.Drawing.Font('Microsoft YaHei UI', 26,   [System.Drawing.FontStyle]::Bold)

        # 顶上一条皮肤色条，跟进度窗、面板标题条保持同一种长相
        $strip = New-Object System.Windows.Forms.Panel
        $strip.BackColor = $cAcc
        $strip.Location  = New-Object System.Drawing.Point(0, 0)
        $strip.Size      = New-Object System.Drawing.Size($W, 4)
        $f.Controls.Add($strip)

        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Font      = $fontTitle
        $lblTitle.ForeColor = $cText
        $lblTitle.BackColor = [System.Drawing.Color]::Transparent
        $lblTitle.Text      = (TP 'F9收工' 'F9 Finish')
        $lblTitle.Location  = New-Object System.Drawing.Point(20, 14)
        $lblTitle.Size      = New-Object System.Drawing.Size(380, 28)
        $f.Controls.Add($lblTitle)

        # 【尺寸别乱改】Label 没有边框、文字也不撑开控件，但它的矩形是实心的，
        # 高一点点就会盖住下面那排控件的上边框（面板里踩过这个坑）。
        # 规矩：这类说明文字高度写 18，并且 Top + Height 要小于下一个控件的 Top。
        $lblHint = New-Object System.Windows.Forms.Label
        $lblHint.Font      = $fontBody
        $lblHint.ForeColor = $cSub
        $lblHint.BackColor = [System.Drawing.Color]::Transparent
        $lblHint.Text      = (TP '点一个按钮，倒数结束后执行；想反悔就点【取消】或按 Esc。' `
                                 'It runs after the countdown. Esc to stop.')
        $lblHint.Location  = New-Object System.Drawing.Point(20, 46)
        $lblHint.Size      = New-Object System.Drawing.Size(380, 18)
        $f.Controls.Add($lblHint)

        # ---- 两页都造好，靠 Visible 切（现场造控件会卡一下，还容易错位）----
        $pgA = New-Object System.Windows.Forms.Panel
        $pgA.Location  = New-Object System.Drawing.Point(0, 76)
        $pgA.Size      = New-Object System.Drawing.Size($W, 160)
        $pgA.BackColor = $cCard
        $f.Controls.Add($pgA)

        $pgB = New-Object System.Windows.Forms.Panel
        $pgB.Location  = New-Object System.Drawing.Point(0, 76)
        $pgB.Size      = New-Object System.Drawing.Size($W, 160)
        $pgB.BackColor = $cCard
        $pgB.Visible   = $false
        $f.Controls.Add($pgB)

        # ===== A 页：选动作 =====
        $lblSec = New-Object System.Windows.Forms.Label
        $lblSec.Font      = $fontBody
        $lblSec.ForeColor = $cText
        $lblSec.BackColor = [System.Drawing.Color]::Transparent
        $lblSec.Text      = (TP '等待' 'Wait')
        $lblSec.Location  = New-Object System.Drawing.Point(20, 4)
        $lblSec.Size      = New-Object System.Drawing.Size(60, 18)
        $pgA.Controls.Add($lblSec)

        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.Location = New-Object System.Drawing.Point(84, 1)
        $num.Size     = New-Object System.Drawing.Size(68, 26)
        $num.Minimum  = 5
        $num.Maximum  = 600
        $num.Increment = 10
        $num.Font     = $fontBody
        $num.Value    = [decimal](Get-QuitSeconds)
        $pgA.Controls.Add($num)

        $lblSec2 = New-Object System.Windows.Forms.Label
        $lblSec2.Font      = $fontBody
        $lblSec2.ForeColor = $cText
        $lblSec2.BackColor = [System.Drawing.Color]::Transparent
        $lblSec2.Text      = (TP '秒' 's')
        $lblSec2.Location  = New-Object System.Drawing.Point(158, 4)
        $lblSec2.Size      = New-Object System.Drawing.Size(24, 18)
        $pgA.Controls.Add($lblSec2)

        $lblSec3 = New-Object System.Windows.Forms.Label
        $lblSec3.Font      = $fontBody
        $lblSec3.ForeColor = $cSub
        $lblSec3.BackColor = [System.Drawing.Color]::Transparent
        $lblSec3.Text      = (TP '（倒数期间随时能取消）' `
                                 '(cancel anytime)')
        $lblSec3.AutoSize  = $false
        $lblSec3.Location  = New-Object System.Drawing.Point(188, 4)
        $lblSec3.Size      = New-Object System.Drawing.Size(212, 18)
        $pgA.Controls.Add($lblSec3)

        # 三个动作按钮：一样大、一样样式 —— 不把「关机」做成又大又红的默认焦点，
        # 免得顺手一个回车就关掉了
        $acts  = @(Get-QuitActions)
        $bx    = 20
        $bW    = 120
        $bGap  = 10
        $made  = @{}
        foreach ($a in $acts) {
            $b = New-Object System.Windows.Forms.Button
            $b.Text      = (Get-QuitActionLabel $a)
            $b.Location  = New-Object System.Drawing.Point($bx, 40)
            $b.Size      = New-Object System.Drawing.Size($bW, 48)
            $b.Font      = $fontTitle
            $b.FlatStyle = 'Flat'
            $b.BackColor = $cAcc
            $b.ForeColor = $cAccT
            $b.FlatAppearance.BorderSize = 0
            $b.FlatAppearance.MouseOverBackColor = $cAccD
            $b.FlatAppearance.MouseDownBackColor = $cAccD
            $b.UseVisualStyleBackColor = $false
            # 回调里只放一行，且必须用 $script:（回调是另一个作用域）
            $b.Tag = $a
            $b.Add_Click({ Start-QuitCountdown ([string]$this.Tag) }.GetNewClosure())
            $pgA.Controls.Add($b)
            $made[$a] = $b
            $bx = $bx + $bW + $bGap
        }

        $btnCancelA = New-Object System.Windows.Forms.Button
        $btnCancelA.Text      = (TP '取消' 'Cancel')
        $btnCancelA.Location  = New-Object System.Drawing.Point(20, 104)
        $btnCancelA.Size      = New-Object System.Drawing.Size(380, 36)
        $btnCancelA.Font      = $fontBody
        $btnCancelA.FlatStyle = 'Flat'
        $btnCancelA.BackColor = $cCard
        $btnCancelA.ForeColor = $cText
        $btnCancelA.FlatAppearance.BorderColor = $cEdge
        $btnCancelA.FlatAppearance.BorderSize  = 1
        $btnCancelA.UseVisualStyleBackColor = $false
        $btnCancelA.Add_Click({ Stop-QuitCountdown })
        $pgA.Controls.Add($btnCancelA)

        # ===== B 页：倒数 =====
        $lblCd = New-Object System.Windows.Forms.Label
        $lblCd.Font      = $fontBig
        $lblCd.ForeColor = $cAcc
        $lblCd.BackColor = [System.Drawing.Color]::Transparent
        $lblCd.TextAlign = 'MiddleCenter'
        $lblCd.Text      = [string](Get-QuitSeconds)
        $lblCd.Location  = New-Object System.Drawing.Point(20, 8)
        $lblCd.Size      = New-Object System.Drawing.Size(380, 54)
        $pgB.Controls.Add($lblCd)

        $lblCdSub = New-Object System.Windows.Forms.Label
        $lblCdSub.Font      = $fontBody
        $lblCdSub.ForeColor = $cSub
        $lblCdSub.BackColor = [System.Drawing.Color]::Transparent
        $lblCdSub.TextAlign = 'MiddleCenter'
        $lblCdSub.Text      = ''
        $lblCdSub.Location  = New-Object System.Drawing.Point(20, 68)
        $lblCdSub.Size      = New-Object System.Drawing.Size(380, 18)
        $pgB.Controls.Add($lblCdSub)

        $btnCancelB = New-Object System.Windows.Forms.Button
        $btnCancelB.Text      = (TP '取消（也可以直接按 Esc）' 'Cancel (or press Esc)')
        $btnCancelB.Location  = New-Object System.Drawing.Point(20, 100)
        $btnCancelB.Size      = New-Object System.Drawing.Size(380, 40)
        $btnCancelB.Font      = $fontBody
        $btnCancelB.FlatStyle = 'Flat'
        $btnCancelB.BackColor = $cCard
        $btnCancelB.ForeColor = $cText
        $btnCancelB.FlatAppearance.BorderColor = $cEdge
        $btnCancelB.FlatAppearance.BorderSize  = 1
        $btnCancelB.UseVisualStyleBackColor = $false
        $btnCancelB.Add_Click({ Stop-QuitCountdown })
        $pgB.Controls.Add($btnCancelB)

        # ---- 文字放不下体检（每次造窗口都量一遍）----
        # 【为什么必须有这道】WinForms 的 Label 默认 AutoSize=true：给它设 Size 是白设的，
        # 它会自己撑宽，超出父面板的部分被硬生生裁掉 —— 跑起来不报错、不卡，只是字少一截，
        # 肉眼扫一眼还以为就是这个写法（这个坑是截图才发现的）。而且换语言才暴露（中文放得下、
        # 英文放不下），所以必须用真字体量、中英各量一次。
        # 只量窗口自己造出来的控件，用 GDI 的 MeasureText，几毫秒，不影响按快捷键的速度。
        $fitWarn = @()
        $fitStack = New-Object System.Collections.Stack
        foreach ($c0 in $f.Controls) { $fitStack.Push($c0) }
        while ($fitStack.Count -gt 0) {
            $c = $fitStack.Pop()
            foreach ($c1 in $c.Controls) { $fitStack.Push($c1) }
            if ($c -isnot [System.Windows.Forms.Label] -and $c -isnot [System.Windows.Forms.Button]) { continue }
            $txt = [string]$c.Text
            if ([string]::IsNullOrEmpty($txt) -or $null -eq $c.Font) { continue }
            $need = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $c.Font).Width
            $lim  = $f
            if ($c.Parent) { $lim = $c.Parent }
            $pad  = 4
            if ($c -is [System.Windows.Forms.Button]) { $pad = 14 }   # 按钮左右各有内边距
            # 两种"切"都要防：① 控件自己的宽度不够 ② 控件在父容器里伸出去了
            $avail = [int]$c.Width
            $byBox = [int]$lim.ClientSize.Width - [int]$c.Left - $pad
            if ($byBox -lt $avail) { $avail = $byBox }
            if ($need -gt $avail) {
                $fitWarn += ('「' + $txt + '」要 ' + $need + 'px 只有 ' + $avail + 'px')
            }
        }
        if ($fitWarn.Count -gt 0) {
            Write-Log ('[警告] 收工窗口有 ' + $fitWarn.Count + ' 处文字会被切掉: ' + ($fitWarn -join '；'))
        } else {
            Write-Log '收工窗口文字排版检查: OK（每个标签都放得下）'
        }

        # 控件袋：事件回调里只有 $script: 看得见，所以全部塞进一个哈希表
        $script:QUi = @{
            Form = $f; PgA = $pgA; PgB = $pgB; Num = $num
            Big = $lblCd; BigSub = $lblCdSub
            Btn = $made; Text = $cText; Sub = $cSub; Acc = $cAcc; Edge = $cEdge
        }

        # Esc = 取消。只有窗口拿到了键盘焦点才收得到，所以下面 Show 之后要努力把它
        # 叫到最前面（后台上来的窗口默认不会到前面，这是 Windows 的前台锁）。
        $f.Add_KeyDown({
            if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Stop-QuitCountdown }
        })
        # 直接点右上角的 X 也当取消。只在"还没走完"的时候清空动作，
        # 不然倒数数到 0 之后我们自己去 Close 它，会被这里把动作又抹掉。
        $f.Add_FormClosing({
            if ($script:QuitState -ne 'done') { Stop-QuitCountdown }
        })

        # ---- 预热：只走到"窗口造好了"就停 ----
        # （该编译的函数都编译了、皮肤也读过了，用户什么都看不到）
        if ($Warm) {
            try { $f.Dispose() } catch { }
            return
        }

        # ---- 离屏渲染两张预览图：把窗口挪到屏幕外再 Show，用户完全看不到 ----
        # 用 PrintWindow 而不是 DrawToBitmap —— 后者画 Panel 颜色会失真（踩过）。
        if ($ShotDir) {
            try {
                if (-not (Test-Path -LiteralPath $ShotDir)) {
                    New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null
                }
                $f.Location = New-Object System.Drawing.Point(-4000, -4000)
                $f.Show()
                for ($i = 0; $i -lt 8; $i++) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 20
                }
                $tw = [int]$f.Width
                $th = [int]$f.Height
                $b1 = Get-WindowShot -Hwnd $f.Handle -W $tw -H $th
                $b1.Save((Join-Path $ShotDir 'quit-1-pick.png'), [System.Drawing.Imaging.ImageFormat]::Png)
                $b1.Dispose()

                # 翻到倒数页再拍一张（数字给个好看的值，别拍成 0）
                $pgA.Visible = $false
                $pgB.Visible = $true
                $lblCd.Text    = '58'
                $lblCdSub.Text = (TP '秒后关机' 'seconds until shut down')
                for ($i = 0; $i -lt 8; $i++) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 20
                }
                $b2 = Get-WindowShot -Hwnd $f.Handle -W $tw -H $th
                $b2.Save((Join-Path $ShotDir 'quit-2-count.png'), [System.Drawing.Imaging.ImageFormat]::Png)
                $b2.Dispose()

                Write-Log ('收工窗口预览图: ' + $ShotDir + ' 尺寸 ' + $tw + 'x' + $th)
            } catch {
                Write-Log ('收工窗口截图失败: ' + $_.Exception.Message)
            } finally {
                try { $f.Hide() } catch { }
                try { $f.Dispose() } catch { }
            }
            return
        }

        # ---- 真的弹出来 ----
        $f.Show()
        # 后台进程弹的窗口默认不会到最前面（前台锁）。复用给软件用的那套四步叫窗，
        # 把自己这个窗口叫上来 —— 用户按了快捷键，屏幕上必须马上有反应。
        $how = ''
        try {
            $how = [string][AppWinProbe]::LastHow
            $code = [AppWinProbe]::Activate([uint32]$PID)
            $how = [string][AppWinProbe]::LastHow
            Write-Log ('收工窗口已弹出（叫窗结果 ' + $code + ': ' + $how + '）')
        } catch {
            try { $f.Activate() } catch { }
            Write-Log ('收工窗口已弹出（Activate 不可用: ' + $_.Exception.Message + '）')
        }

        # ---- 泵消息等结果 ----
        # 这里刻意不写计时器：倒数本来就简单，25 毫秒转一圈算一下还差几秒就行。
        # 写计时器反而要多一个"回调作用域"的坑（进度窗那边就是这么踩的）。
        $swq = [System.Diagnostics.Stopwatch]::StartNew()
        while ($script:QuitState -ne 'done') {
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            if ($script:QuitState -eq 'count') {
                $left = [int][Math]::Ceiling(($script:QuitEnd - (Get-Date)).TotalSeconds)
                if ($left -lt 0) { $left = 0 }
                if ($left -ne $script:QuitLeft) {
                    $script:QuitLeft = $left
                    try { $lblCd.Text = [string]$left } catch { }
                    try {
                        $f.Text = $(if ($left -gt 0) {
                                       $left.ToString() + (TP ' 秒后' 's to ') + (Get-QuitActionLabel $script:QuitAct)
                                   } else { (TP 'F9收工' 'F9 Finish') })
                    } catch { }
                    # 递减的那一秒写一行日志：出问题的时候能看出来"数到哪一步断了"
                    if ($left -gt 0 -and ($left % 10) -eq 0) {
                        Write-Log ('收工倒数: 还有 ' + $left + ' 秒')
                    }
                }
                if ($left -le 0) { $script:QuitState = 'done' }
            }
            Start-Sleep -Milliseconds 25
        }
        $swq.Stop()

        $act = $script:QuitAct
        try { $f.Hide() } catch { }
        # 先把窗口收掉再执行：不然"关机中"的系统画面跟我们的窗口叠在一起，
        # 用户会以为卡住了（进度窗那次也吃过一样的亏）
        try { $f.Close() } catch { }
        try { $f.Dispose() } catch { }
        $f = $null
        $script:QUi = $null

        if ($act) {
            Write-Log ('收工窗口结束（等了 ' + [int]$swq.Elapsed.TotalSeconds + ' 秒）: ' + (Get-QuitActionLabel $act))
            Invoke-QuitAction -Act $act -Preview:$Preview
        } else {
            Write-Log ('收工窗口结束（等了 ' + [int]$swq.Elapsed.TotalSeconds + ' 秒）: 已取消')
        }
    } catch {
        Write-Log ('收工窗口出错: ' + $_.Exception.Message)
    } finally {
        if ($f) {
            try { $f.Close() } catch { }
            try { $f.Dispose() } catch { }
        }
        $script:QUi = $null
        $script:QuitBusy = $false
    }
}

# 「按了一次快捷键」之后要干的事。单独抽成函数有两个好处：
#   1) 消息循环的回调和「模拟按键自检(-SimTrigger)」走的是同一条代码路径
#   2) 可以直接量它花了多少毫秒 —— 这个数就是"从按键到第一个软件真的出去"。
function Invoke-TriggerAction {
    param([int]$Id = 1, [string]$Why = 'hotkey')

    $now = Get-Date
    $gap = ($now - $script:LastTriggerAt).TotalMilliseconds
    if ($gap -lt $script:TriggerMinGapMs) {
        Write-Log ('快捷键 #' + $Id + ' 刚按过（隔 ' + [int]$gap + ' 毫秒），这次忽略，免得同一批软件开两遍')
        return $false
    }
    $script:LastTriggerAt = $now

    # 快捷键名字在注册时就缓存好了，这里不再去读 config.json ——
    # 读一次 config.json 要一百多毫秒，那一下的反馈就不"即时"了。
    $name = '#' + $Id
    if ($script:HotKeyNames -and $Id -ge 1 -and $Id -le $script:HotKeyNames.Count) {
        $name = [string]$script:HotKeyNames[$Id - 1]
    }

    # 这个键是"开工"还是"收工"？回调只给了一个序号（#1、#2…），
    # 靠注册时存下的那张表来认。表里没有就当开工（老行为，绝不会更差）。
    $kind = 'launch'
    if ($script:HotKeyKinds -and $Id -ge 1 -and $Id -le $script:HotKeyKinds.Count) {
        $kind = [string]$script:HotKeyKinds[$Id - 1]
    }

    if ($kind -eq 'quit') {
        # 收工键：弹出「关机 / 重启 / 睡眠」窗口，剩下的交给用户点。
        # 它不占开工那个 LaunchBusy（那会把"开工完了没"搞乱），自己有一套 QuitBusy。
        Write-Log ('按下 ' + $name + ' -> 弹收工窗口（关机 / 重启 / 睡眠）')
        try { Show-ShutdownUi } catch { Write-Log ('收工窗口出错: ' + $_.Exception.Message) }
        return $true
    }

    if ($script:LaunchBusy) {
        Write-Log ('按下 ' + $name + '（上一次开工还没跑完，这次忽略）')
        return $false
    }

    $script:LaunchBusy = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # 【分段计时】按键到"窗口真的亮出来"这一段是用户唯一能感觉到的延迟，
    # 所以每一段都要能量出来。$swPress 从按键那一刻起算，一路传到 Show-Progress。
    $script:SwPress = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Log ('按下 ' + $name + ' -> 后台自己开始开工')
        $cfgHk = Get-LauncherConfig
        $tipHk = Test-ConfigSwitch -Cfg $cfgHk -Key 'showTipAfterRun' -Default $true
        $script:PressCfgMs = $script:SwPress.ElapsedMilliseconds

        # 就在本进程里开干。
        #
        # 以前这里是"起一个新子进程去干活"：那样确实不会卡住消息循环，但代价是
        # 一个全新的 powershell.exe 冷启动 —— 在这台机器上实测 1~9 秒（杀毒软件
        # 对新进程、脚本、编译出来的 exe 都要扫一遍）。用户说的"按了要等好几秒"
        # 就是它。现在自己开：第一个软件 20~60 毫秒就出去了。
        #
        # 代价是开软件的这一秒里消息循环是停的 —— 但那一秒用户正看着进度条在动，
        # 不会有"按了没反应"的感觉；上面那个 LaunchBusy 也挡住了重复触发。
        Invoke-Launch -ShowTip:$tipHk -Cfg $cfgHk
    } catch {
        Write-Log ('开工时出错: ' + $_.Exception.Message)
    } finally {
        $script:LaunchBusy = $false
    }
    $sw.Stop()
    # 【读这个数要小心】从 2026-09-24 起，进度窗会一直流到"软件的窗口真的出现"，
    # 而"等窗口"那一段是交给进度窗自己的定时器去等的（后台不陪等、要留着听快捷键）。
    # 所以这里量到的是"按下 → 软件全点出去"这一段；
    # 真正"按下 → 东西都在屏幕上"的总时长写在进度窗上（"到全部就绪用了 X 秒"）
    # 和 Update-AppWait 的「窗口出现: xxx -> N ms」那几行日志里。
    $tail = ''
    if ($script:PWait) { $tail = '（进度窗还在等窗口出现，总量见下面的「窗口出现」行）' }
    Write-Log ('这次按键（开软件那段）用了 ' + [int]$sw.Elapsed.TotalMilliseconds + ' ms' + $tail)
    return $true
}
# ---------------------------------------------------------------- 完成提示
function Test-ConfigSwitch {
    param($Cfg, [string]$Key, [bool]$Default = $true)
    if (-not $Cfg) { return $Default }
    $p = $Cfg.PSObject.Properties[$Key]
    if (-not $p) { return $Default }
    $v = $p.Value
    if ($null -eq $v) { return $Default }
    if ($v -is [bool]) { return [bool]$v }
    $s = ([string]$v).Trim().ToLowerInvariant()
    if ($s -eq 'false' -or $s -eq '0' -or $s -eq 'no' -or $s -eq 'off') { return $false }
    return $true
}

# 界面语言：config.json 的 lang 字段，zh / en
function Get-LauncherLang {
    $cfg = Get-LauncherConfig
    if (-not $cfg) { return 'zh' }
    $p = $cfg.PSObject.Properties['lang']
    if (-not $p -or $null -eq $p.Value) { return 'zh' }
    if (([string]$p.Value).Trim() -ieq 'en') { return 'en' }
    return 'zh'
}

# 提示窗上的文字（英文界面时换成英文，找不到就保留中文）
$script:TipLang = 'zh'
function TT {
    param([string]$s)
    if ($script:TipLang -ne 'en') { return $s }
    switch ($s) {
        '  清单里还没有东西，先打开「F9开工 · 设置」打勾吧' { return '  The list is empty - open Settings and tick some items first' }
        '  下面这些没找到（可在设置里删掉）：'             { return '  Could not find these (you can remove them in Settings):' }
        '这个提示 6 秒后自动消失'                          { return 'This popup closes itself in 6 seconds' }
        '开工完成'                                        { return 'Opened ' }
        '，已打开 '                                       { return ' items, ' }
        ' 项'                                             { return ' done' }
        '，有 '                                           { return ' - ' }
        ' 项没找到'                                       { return ' item(s) not found' }
    }
    return $s
}

# =====================================================================
#  开工彩蛋：自定义表情包 + 自己设置的语音
#  全部读 config.json，一样都不配就完全不动作（默认零打扰）
# =====================================================================

# 从 JSON 里安全读一个字符串
function Get-ConfigText {
    param($Cfg, [string]$Key, [string]$Default = '')
    if (-not $Cfg) { return $Default }
    $p = $Cfg.PSObject.Properties[$Key]
    if (-not $p -or $null -eq $p.Value) { return $Default }
    $s = [string]$p.Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    return $s.Trim()
}

# 从 JSON 里安全读一个整数（读不出就用默认值）
function Get-ConfigInt {
    param($Cfg, [string]$Key, [int]$Default = 0)
    if (-not $Cfg) { return $Default }
    $p = $Cfg.PSObject.Properties[$Key]
    if (-not $p -or $null -eq $p.Value) { return $Default }
    $n = 0
    if ([int]::TryParse(([string]$p.Value).Trim(), [ref]$n)) { return $n }
    return $Default
}

# 把配置里的相对路径补成绝对路径（相对路径以程序目录为基准）
function Resolve-LauncherPath {
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return '' }
    if ([System.IO.Path]::IsPathRooted($P)) { return $P }
    return (Join-Path $ScriptDir $P)
}

# 读图片：走内存流，不锁文件（用户以后想换图/删图都不受影响）
function Read-ImageNoLock {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # -Check 自检路径不会走到界面那段，System.Drawing 可能还没加载，
    # 不先加载就会报「找不到类型 [System.Drawing.Image]」，这里懒加载兜住
    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ms    = New-Object System.IO.MemoryStream(, $bytes)
        $img   = [System.Drawing.Image]::FromStream($ms)
        return $img
    } catch {
        Write-Log ('图片读不了: ' + $Path + ' :: ' + $_.Exception.Message)
        return $null
    }
}

# 表情包图片：优先用配置里的自定义图片，没配就用当前皮肤的形象图
function Get-StickerImage {
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-LauncherConfig }

    $custom = Resolve-LauncherPath (Get-ConfigText $Cfg 'stickerPath')
    if ($custom) {
        $img = Read-ImageNoLock $custom
        if ($img) { return $img }
        Write-Log ('表情包图片不存在，改用皮肤形象图: ' + $custom)
    }

    $sk = Get-LauncherSkin
    if ($sk -and $sk.art) {
        $f = Join-Path $ArtDir ([string]$sk.art + '.png')
        $img = Read-ImageNoLock $f
        if ($img) { return $img }
    }
    return $null
}

# 开工语音。两种玩法，优先级：音频文件 > 系统语音念一句话
#   1) soundPath  := 自己录的/下载的音频（.wav 直放；.mp3/.wma/.m4a 走系统播放器）
#   2) sayText    := 打一句话，让 Windows 自带的语音念出来（不用装任何东西）
# 注意：播放器对象必须挂到 $script: 上，否则函数一返回就被回收，声音会戛然而止。
function Invoke-LauncherVoice {
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-LauncherConfig }
    if (-not $Cfg) { return }

    $vol = Get-ConfigInt $Cfg 'voiceVolume' 80
    if ($vol -lt 0)   { $vol = 0 }
    if ($vol -gt 100) { $vol = 100 }

    # ---------- 1) 音频文件 ----------
    $sp = Get-ConfigText $Cfg 'soundPath'
    if ($sp) {
        $full = Resolve-LauncherPath $sp
        if (-not (Test-Path -LiteralPath $full)) {
            Write-Log ('开工语音: 找不到音频文件 ' + $full)
        } else {
            $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()

            if ($ext -eq '.wav') {
                # wav 用系统自带的 SoundPlayer，最省事、最稳
                try {
                    $pl = New-Object System.Media.SoundPlayer $full
                    $script:VoicePlayer = $pl
                    $pl.Play()          # 异步播，不卡住提示窗
                    Write-Log ('开工语音: 播放 wav ' + $full)
                    return
                } catch {
                    Write-Log ('开工语音失败(wav): ' + $_.Exception.Message)
                }
            } else {
                # mp3 / wma / m4a 走 WPF 播放器（Windows 10/11 自带，不用装解码器）
                try {
                    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
                    $mp = New-Object System.Windows.Media.MediaPlayer
                    $mp.Open((New-Object System.Uri($full)))
                    $mp.Volume = ($vol / 100.0)
                    $script:VoicePlayer = $mp
                    $mp.Play()
                    Write-Log ('开工语音: 播放 ' + $ext + ' ' + $full)
                    return
                } catch {
                    Write-Log ('开工语音失败(' + $ext + '): ' + $_.Exception.Message)
                }
            }
        }
    }

    # ---------- 2) 系统语音念一句话 ----------
    $say = Get-ConfigText $Cfg 'sayText'
    if (-not $say) { return }
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $spk = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $spk.Volume = $vol

        # 中文内容就优先挑中文嗓子，否则会被英文语音念得不知所云
        $picked = ''
        try {
            if ($say -match '[\u4e00-\u9fff]') {
                foreach ($v in $spk.GetInstalledVoices()) {
                    if ($v.VoiceInfo.Culture.Name -like 'zh*') {
                        $spk.SelectVoice($v.VoiceInfo.Name)
                        $picked = $v.VoiceInfo.Name
                        break
                    }
                }
                if (-not $picked) {
                    Write-Log ('开工语音: 系统里没装中文语音，先用默认嗓子念（想好听点可在 设置-时间和语言-语音 里加一个中文语音包）')
                }
            }
        } catch { }

        $script:VoicePlayer = $spk
        $spk.SpeakAsync($say)     # 异步，说完自己结束
        Write-Log ('开工语音: 系统语音念「' + $say + '」' + $(if ($picked) { ' 嗓子=' + $picked } else { '' }))
    } catch {
        Write-Log ('开工语音失败(系统语音): ' + $_.Exception.Message)
    }
}

# 静默模式（不弹提示窗）下也在屏幕上飘一下表情包，让人知道"开工了"
# 做法：一个无边框 + 抠掉底色的顶层小窗，从屏幕上方掉下来，停一会儿自己消失。
# 这个窗口跟提示窗是两套东西，所以不必为了看表情包而把提示窗打开。
function Show-FloatSticker {
    param($Cfg, [switch]$Force)
    if (-not $Cfg) { $Cfg = Get-LauncherConfig }
    if (-not $Cfg) { return }

    # $Force 是给设置界面的「试听」用的：没勾也照样演一遍，不然用户点了没反应会以为坏了
    if (-not $Force) {
        $on = Test-ConfigSwitch -Cfg $Cfg -Key 'showHeartOnRun' -Default $false
        if (-not $on) { return }
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $img = Get-StickerImage $Cfg
        if (-not $img) {
            Write-Log ('飘表情包: 没有可用图片，跳过')
            return
        }

        $size = 120
        $key  = [System.Drawing.Color]::FromArgb(255, 0, 255)   # 抠色用的洋红，图片里不会用到

        $frm = New-Object System.Windows.Forms.Form
        $frm.FormBorderStyle = 'None'
        $frm.ShowInTaskbar   = $false
        $frm.TopMost         = $true
        $frm.StartPosition   = 'Manual'
        $frm.BackColor       = $key
        $frm.TransparencyKey = $key
        $frm.ClientSize      = New-Object System.Drawing.Size($size, $size)

        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image     = $img
        $pic.SizeMode  = 'Zoom'
        $pic.Dock      = 'Fill'
        $pic.BackColor = $key
        $frm.Controls.Add($pic)

        $wa       = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $endX     = [int]($wa.Right - $size - 70)
        $FEndY    = [int]($wa.Top + $wa.Height * 0.18)
        $FStartY  = [int]($wa.Top - $size)
        $frm.Location = New-Object System.Drawing.Point($endX, $FStartY)

        # 30ms 一跳：前 20 跳掉下来（缓出），停约 1 秒，然后淡出
        # 【重要】计数器必须写成 $script:。
        # 计时器回调是独立的脚本块作用域：读外面的变量没问题，
        # 但 $x++ 这种"赋值"只会写进回调自己的局部变量 —— 结果计数器永远停在 1，
        # 窗口就再也关不掉了（动画也完全不动）。
        $script:FanStep = 0
        $tm = New-Object System.Windows.Forms.Timer
        $tm.Interval = 30
        $tm.Add_Tick({
            try {
                $script:FanStep = $script:FanStep + 1
                $st = $script:FanStep
                if ($st -le 20) {
                    $p = $st / 20.0
                    $ease = 1 - [Math]::Pow(1 - $p, 3)
                    $frm.Top = [int]($FStartY + ($FEndY - $FStartY) * $ease)
                } elseif ($st -le 44) {
                    # 停住不动
                } elseif ($st -le 58) {
                    $frm.Opacity = [Math]::Max(0.08, 1.0 - (($st - 44) / 14.0))
                } else {
                    $tm.Stop()
                    $frm.Close()
                }
            } catch {
                # 兜底：回调里出任何岔子，都要把这个窗口关掉，绝不留下一个关不掉的浮窗
                try { $tm.Stop() } catch { }
                try { $frm.Close() } catch { }
            }
        })
        $frm.Add_Shown({ $tm.Start() })

        Write-Log ('飘表情包: ' + $size + 'px 落点 ' + $endX + ',' + $FEndY + ' 图片=' + $(if (Get-ConfigText $Cfg 'stickerPath') { '自定义' } else { '皮肤形象' }))
        [void]$frm.ShowDialog()
        Write-Log ('飘表情包: 动画结束，窗口已关闭（共 ' + $script:FanStep + ' 帧）')
    } catch {
        Write-Log ('飘表情包失败: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 主流程
# 外面拉着跑的那条路（面板「立即开工一次」、试运行、自检）：真的开软件、亮进度窗，干完就退出。
# 后台常驻进程收到快捷键时【不】走这里，它自己直接跑 Invoke-Launch（少一次进程冷启动）。
if ($Sequence) {
    $script:LogTag = '[开工] '
    $who = '手动'
    if ($Trigger -eq 'hotkey')      { $who = '快捷键' }
    elseif ($Trigger -eq 'icon')    { $who = '桌面图标' }
    elseif ($Trigger -eq 'panel')   { $who = '面板上的立即开工' }
    Write-Log ('(pid ' + $PID + ') 收到开工请求（来自' + $who + '）')

    $script:TipLang = Get-LauncherLang
    $cfgSeq = Get-LauncherConfig
    $tipSeq = $false
    if ($ShowTip) {
        $tipSeq = $true
        if ($NoTip) {
            $tipSeq = $false
            Write-Log '  本次进度窗收尾时不列清单(-NoTip)'
        }
    } elseif (Test-ConfigSwitch -Cfg $cfgSeq -Key 'showTipAfterRun' -Default $true) {
        $tipSeq = $true
    } else {
        Write-Log '  配置里关了完成清单，进度窗到点自己就走'
    }

    # 开着任务管理器看进程时，能一眼看出这是"F9开工"的活
    try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass =
          [System.Diagnostics.ProcessPriorityClass]::AboveNormal } catch { }

    Invoke-Launch -ShowTip:$tipSeq -Cfg $cfgSeq
    Write-Log ('(pid ' + $PID + ') 开工结束，子进程退出')
    exit 0
}

if ($Check) {
    Write-Log '==================== 自检 开始 ===================='
    $defs = @(Get-HotKeyDefs)
    Write-Log ('config.json 里的快捷键: ' + ((Get-PlainHotKeyList $defs) -join ' / '))

    # 新增的两个开关，自检时也顺便报一下
    $cfgChk  = Get-LauncherConfig
    $tipChk  = Test-ConfigSwitch -Cfg $cfgChk -Key 'showTipAfterRun' -Default $true
    $tipTxt  = '否 —— 只在后台安静地打开，不打扰你'
    if ($tipChk) { $tipTxt = '是（默认）' }
    Write-Log ('开工后留完成清单: ' + $tipTxt)

    # 用户最在意的就是「同一个东西别开两遍」，自检时把去重状态明确报出来
    $skipChk = Test-ConfigSwitch -Cfg $cfgChk -Key 'skipIfRunning' -Default $true
    if ($skipChk) {
        $dupTxt = '开 —— 已经在运行的会跳过，清单里填重了也只开一次'
        $runNow = @()
        foreach ($aChk in @($cfgChk.apps)) {
            if ($null -eq $aChk) { continue }
            $pChk = [string]$aChk.path
            if ([string]::IsNullOrWhiteSpace($pChk)) { continue }
            if (Test-AppAlreadyRunning -Exe $pChk) { $runNow += [string]$aChk.name }
        }
        if ($runNow.Count -gt 0) { $dupTxt += ('；现在开着的有: ' + ($runNow -join '、') + '（开工时直接跳过）') }
    } else {
        $dupTxt = '关 —— 每次都会硬开一遍（清单里重复填的仍然只开一次）'
    }
    Write-Log ('不重复打开: ' + $dupTxt)

    # ---- 关键开关的硬断言（2026-09-25 补，血的教训）----
    # 我加 activateIfRunning 的时候，把 $skipRunning 那一行**覆盖**掉了，
    # 结果"不重复打开"整道闸失效（$skipRunning = $null = 假），自检却照样全过 ——
    # 一直到真按了快捷键、把 WorkBuddy / cc-switch 又开了一遍才发现。
    # 所以这里不只看"配置里写了什么"，还要看"源码里那两行赋值还在不在"。
    $actChk = Test-ConfigSwitch -Cfg $cfgChk -Key 'activateIfRunning' -Default $true
    if ($actChk) {
        Write-Log '已在运行就摆到最前面: 开（默认）—— 不再开第二个，而是把已经开着的窗口叫到最前面'
    } else {
        Write-Log '已在运行就摆到最前面: 关 —— 只跳过、不叫窗口（按了快捷键屏幕上会看不到反应）'
    }
    $srcChk = ''
    try { $srcChk = [System.IO.File]::ReadAllText((Join-Path $ScriptDir 'Start-Workday.ps1'), [System.Text.Encoding]::UTF8) } catch { }
    $hasSkip = ($srcChk -match '\$skipRunning\s*=\s*Test-ConfigSwitch')
    $hasAct  = ($srcChk -match '\$activateRunning\s*=\s*Test-ConfigSwitch')
    if ($hasSkip -and $hasAct) {
        Write-Log '去重开关赋值检查: OK（skipRunning 与 activateRunning 都有赋值）'
    } else {
        Write-Log ('去重开关赋值检查: 失败! skipRunning=' + $hasSkip + ' activateRunning=' + $hasAct + ' —— 不重复打开可能会失效，快去修')
    }

    # ---- 一键收工（2026-09-25 加）----
    # 这个功能是"按一个键就关机"，接线接错了后果最严重（按了收工键跑去开工，
    # 或者按了没反应），所以这里既报状态、也做源码级断言。
    $quitDefs = @(Get-QuitHotKeyDefs)
    if ($quitDefs.Count -gt 0) {
        Write-Log ('收工快捷键: ' + ((Get-PlainHotKeyList $quitDefs) -join ' / ') +
                   '（按下去弹出「关机 / 重启 / 睡眠」的窗口）')
        $actZh = @()
        foreach ($a in @(Get-QuitActions)) { $actZh += (Get-QuitActionLabel $a) }
        Write-Log ('  窗口里显示: ' + ($actZh -join ' / ') + '；倒计时 ' + (Get-QuitSeconds) +
                   ' 秒 —— 这段时间里点【取消】或按 Esc 都能停下，不会真关')
    } else {
        Write-Log '收工快捷键: 没配（config.json 的 shutdownHotkey 是空的）—— 收工功能关着'
    }
    $quitVbsChk = Join-Path $ScriptDir 'run-quit.vbs'
    $quitIcoChk = Join-Path $ScriptDir 'quit.ico'
    if (Test-Path -LiteralPath $quitVbsChk) {
        $icoTxt = '图标也有'
        if (-not (Test-Path -LiteralPath $quitIcoChk)) { $icoTxt = '图标缺了，桌面上会显示成白板' }
        Write-Log ('桌面「F9收工」图标: 就绪（' + $icoTxt + '）')
    } else {
        Write-Log '[提示] 还没有 run-quit.vbs —— 桌面「F9收工」图标要先跑一遍 install.bat 才会生成'
    }
    # 三处都不能少：解析(shutdownHotkey) / 分派(认得出是收工键) / 窗口(Show-ShutdownUi)
    $hasQDefs = ($srcChk -match 'function Get-QuitHotKeyDefs')
    $hasQKind = ($srcChk -match "\`$kind\s*-eq\s*'quit'")
    $hasQUi   = ($srcChk -match 'function Show-ShutdownUi')
    if ($hasQDefs -and $hasQKind -and $hasQUi) {
        Write-Log '收工功能接线检查: OK（解析 / 按键分派 / 窗口 三处都在）'
    } else {
        Write-Log ('收工功能接线检查: 失败! 解析=' + $hasQDefs + ' 分派=' + $hasQKind +
                   ' 窗口=' + $hasQUi + ' —— 收工快捷键可能没反应或者跑去开工，快去修')
    }

    $langTxt = '简体中文'
    if ((Get-LauncherLang) -eq 'en') { $langTxt = 'English' }
    Write-Log ('界面语言: ' + $langTxt)
    $skChk = Get-LauncherSkin
    $skTxt = '(读不到，用默认外观)'
    if ($skChk) { $skTxt = $skChk._name + ' / ' + $skChk.label }
    Write-Log ('当前皮肤: ' + $skTxt)

    # ---- 桌面图标靠 run-app.vbs 静默启动 ----
    # VBScript 里字符串的引号要写成两个（""），只写一个双击图标就弹
    # 「Windows Script Host / 语句未结束 / 800A0401」。这里先体检，别等用户撞上。
    $appVbsChk = Join-Path $ScriptDir 'run-app.vbs'
    if (-not (Test-Path -LiteralPath $appVbsChk)) {
        Write-Log '[警告] 缺少 run-app.vbs —— 桌面图标会退化成会闪黑框的启动方式（跑一遍 install.bat 可修复）'
    } else {
        $vbsBadLines = @()
        $lnNo = 0
        foreach ($ln in @(Get-Content -LiteralPath $appVbsChk -Encoding ASCII -ErrorAction SilentlyContinue)) {
            $lnNo++
            if ($ln.TrimStart().StartsWith("'")) { continue }
            $qc = @($ln.ToCharArray() | Where-Object { $_ -eq [char]34 }).Count
            if ($qc % 2 -ne 0) { $vbsBadLines += $lnNo }
        }
        if ($vbsBadLines.Count -gt 0) {
            Write-Log ('[警告] run-app.vbs 第 ' + ($vbsBadLines -join '/') + ' 行引号不成对，双击桌面图标会报「语句未结束」（跑一遍 install.bat 可修复）')
        } else {
            Write-Log '无黑框启动器 run-app.vbs: 引号成对，正常'
        }
    }

    # ---- 开工彩蛋自检（表情包 / 语音）----
    $cfgFan = Get-LauncherConfig
    $stickerOn = Test-ConfigSwitch -Cfg $cfgFan -Key 'showHeartOnRun' -Default $false
    Write-Log ('开工飘表情包: ' + $(if ($stickerOn) { '开' } else { '关' }))
    $spCfg = Get-ConfigText $cfgFan 'stickerPath'
    if ($spCfg) {
        $spFull = Resolve-LauncherPath $spCfg
        if (Test-Path -LiteralPath $spFull) {
            $imgChk = Read-ImageNoLock $spFull
            if ($imgChk) {
                Write-Log ('自定义表情包: ✓ 能读出来 ' + $imgChk.Width + 'x' + $imgChk.Height + '  ' + $spFull)
            } else {
                Write-Log ('自定义表情包: ✗ 读不出图片（格式不支持？） ' + $spFull)
            }
        } else {
            Write-Log ('自定义表情包: ✗ 文件不存在 ' + $spFull)
        }
    } else {
        Write-Log '自定义表情包: 没设（飘图时用当前皮肤的形象图）'
    }

    $sndCfg = Get-ConfigText $cfgFan 'soundPath'
    if ($sndCfg) {
        $sndFull = Resolve-LauncherPath $sndCfg
        if (Test-Path -LiteralPath $sndFull) {
            Write-Log ('开工语音(音频文件): ✓ 找得到 ' + $sndFull)
        } else {
            Write-Log ('开工语音(音频文件): ✗ 文件不存在 ' + $sndFull)
        }
    } else {
        Write-Log '开工语音(音频文件): 没设'
    }

    $sayCfg = Get-ConfigText $cfgFan 'sayText'
    if ($sayCfg) {
        Write-Log ('开工语音(念一句话): 「' + $sayCfg + '」')
        # 顺便查系统里有没有中文嗓子，没有的话中文会念得怪
        try {
            Add-Type -AssemblyName System.Speech -ErrorAction Stop
            $spkChk = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $zhVoices = @()
            foreach ($v in $spkChk.GetInstalledVoices()) {
                if ($v.VoiceInfo.Culture.Name -like 'zh*') { $zhVoices += $v.VoiceInfo.Name }
            }
            if ($zhVoices.Count -gt 0) {
                Write-Log ('  系统中文语音: ✓ ' + ($zhVoices -join ' / '))
            } elseif ($sayCfg -match '[\u4e00-\u9fff]') {
                Write-Log '  系统中文语音: ✗ 没装中文语音包（中文会被英文嗓子念，建议在 设置-时间和语言-语音 里加一个中文语音）'
            } else {
                Write-Log '  系统中文语音: 文本不是中文，不要求中文嗓子'
            }
            $spkChk.Dispose()
        } catch {
            Write-Log ('  系统语音组件不可用: ' + $_.Exception.Message)
        }
    } else {
        Write-Log '开工语音(念一句话): 没设'
    }
    Write-Log ('开工语音音量: ' + (Get-ConfigInt $cfgFan 'voiceVolume' 80))

    # 后台是不是已经在跑了？（在跑的话快捷键被它占着，注册测试必然"失败"，属于正常）
    $daemonRunning = Test-DaemonRunning
    Write-Log ('后台待命进程: ' + $(if ($daemonRunning) { '✓ 正在运行（快捷键随时可用）' } else { '✗ 没在运行 —— 快捷键现在是死的！双击桌面「F9开工」图标会自动把它拉起来' }))

    if (-not (Initialize-HotKeyHost)) {
        Write-Log '自检结果: 内部组件编译失败，程序无法运行'
        exit 1
    }
    Write-Log '自检结果: 内部组件编译成功'

    # 右下角那个进度窗：做不出来不影响开工，但用户会少一个"按键收到了"的反馈
    if (Initialize-HintUi) {
        $swHint = [System.Diagnostics.Stopwatch]::StartNew()
        $hintReady = Initialize-ProgressUi
        $swHint.Stop()
        if ($hintReady) {
            Write-Log ('自检结果: ✓ 右下角进度窗可以显示（准备耗时 ' + [int]$swHint.Elapsed.TotalMilliseconds + ' ms）')
        } else {
            Write-Log '自检结果: ✗ 进度窗没做出来（不影响开工，只是按快捷键后右下角没有进度提示）'
        }
    } else {
        Write-Log '自检结果: ✗ 进度窗不可用（不影响开工）'
    }

    $mods = @()
    $vks  = @()
    foreach ($d in $defs) { $mods += [int]$d.Mods; $vks += [int]$d.Vk }
    $okIds = [HotKeyHost]::Register([int[]]$mods, [int[]]$vks)
    if ($okIds.Count -eq 0) {
        if ($daemonRunning) {
            Write-Log '自检结果: ✓ 后台程序正在运行中，快捷键由它占用（所以这里显示占用，是正常的）'
        } else {
            Write-Log '自检结果: ✗ 没有任何快捷键注册成功(都被别的程序占用了)'
        }
    } else {
        foreach ($id in $okIds) { Write-Log ('自检结果: ✓ 快捷键可用 -> ' + $defs[$id - 1].Text) }
        if ($daemonRunning) { Write-Log '说明: 后台程序已经在跑（这台机器上快捷键应该已经能用了）' }
    }
    [HotKeyHost]::UnregisterAll($defs.Count)

    Write-Log '--- 下面检查软件和网页能不能找到(不会真的打开) ---'
    Invoke-Launch -IsDryRun -NoProgress
    Write-Log '==================== 自检 结束 ===================='
    exit 0
}

# 只演一遍右下角进度窗（进行中 → 完成），不打开任何软件 —— 给"看一眼效果"按钮用
if ($TipTest) {
    $script:TipLang = Get-LauncherLang
    $isEn = ($script:TipLang -eq 'en')
    Write-Log ('进度窗测试 语言=' + $script:TipLang)

    if (-not (Initialize-ProgressUi)) { exit 1 }

    $demo = @('软件：微信', '软件：WPS Office', '网页：1688 进货', '网页：豆包')
    if ($isEn) { $demo = @('App: WeChat', 'App: WPS Office', 'Web: supplier', 'Web: search') }
    $n = @($demo).Count

    if (-not (Show-Progress -Title (TP '⚡ F9开工' '⚡ Starting workday') `
                            -SubText (TP '准备中…' 'Getting ready…') -Foot '')) { exit 1 }

    # 开发验收用：设了 LAUNCHER_SHOT 就先把"进行中"这一态渲染成图
    $shotDir = [string]$env:LAUNCHER_SHOT
    if (-not [string]::IsNullOrWhiteSpace($shotDir)) {
        try {
            if (-not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }
            Set-Progress -SubText $demo[0] -Foot (TP '已完成 0/' 'Done 0/') | Out-Null
            [void](Save-ProgressShot -Path (Join-Path $shotDir 'progress-run.png') -ForceFill 0.45)
        } catch { }
    }

    for ($i = 0; $i -lt $n; $i++) {
        $st = $(if ($isEn) { 'Opening ' + $demo[$i] + ' (' + ($i + 1) + '/' + $n + ')' }
                else        { '正在打开 ' + $demo[$i] + '（' + ($i + 1) + '/' + $n + '）' })
        $ft = $(if ($isEn) { 'Done ' + $i + '/' + $n } else { '已完成 ' + $i + '/' + $n })
        Set-Progress -SubText $st -Foot $ft -Pump
        Wait-WithPump -Milliseconds 420
        Set-Progress -Pct (($i + 1) / [double]$n) -Pump
    }

    $head = $(if ($isEn) { '✓ Workday started - ' + $n + ' item(s) opened' }
              else        { '✓ 开工完成，已打开 ' + $n + ' 项' })
    $lines = @()
    foreach ($d in $demo) { $lines += ('✓ ' + $d) }
    $lines += $(if ($isEn) { '✗ App: something uninstalled' } else { '✗ 软件：某某已卸载的软件' })

    Complete-Progress -Title $head -SubText (TP '共用 1.8 秒' 'Total 1.8 s') -Lines $lines `
                      -Foot (TP '这个窗 3 秒后自动收起' 'This window closes itself in 3 seconds') -HoldMs 3000
    if (-not [string]::IsNullOrWhiteSpace($shotDir)) {
        try { [void](Save-ProgressShot -Path (Join-Path $shotDir ('progress-done-' + $script:TipLang + '.png')) -ForceFill 1.0) } catch { }
        Hide-Progress
        Write-Log '进度窗测试 结束'
        exit 0
    }

    Wait-WithPump -Milliseconds 3000
    Hide-Progress
    Write-Log '进度窗测试 结束'
    exit 0
}

# 桌面图标走这里：按 config.json 的 iconAction 决定是打开面板还是直接开工。
#   panel = 打开控制面板（默认，"应用和设置二合一"）
#   run   = 直接开工，就像以前那样双击一下就全打开
if ($Main) {
    $cfgMain = Get-LauncherConfig
    $act = 'panel'
    try {
        $act = [string](Get-ConfigText $cfgMain 'iconAction' 'panel')
    } catch { $act = 'panel' }
    Write-Log ('桌面图标动作: ' + $act)

    if ($act -eq 'run') {
        # 和 -Run 分支保持完全一致：进度窗要看 config.json 里的 showTipAfterRun
        Write-Log '  按配置直接开工'
        $script:TipLang = Get-LauncherLang
        $tipMain = Test-ConfigSwitch -Cfg $cfgMain -Key 'showTipAfterRun' -Default $true
        if ($NoTip) { $tipMain = $false }
        Invoke-Launch -ShowTip:$tipMain -Cfg $cfgMain
        Ensure-Daemon | Out-Null
        exit 0
    }

    $guiPath = Join-Path $ScriptDir 'Settings-GUI.ps1'
    if (Test-Path -LiteralPath $guiPath) {
        try {
            # 打开面板之前先把后台确认活过来 —— 面板上会显示"后台正在待命"，
            # 用户一看就知道快捷键是好的。后台真死了也是在这一步自愈的。
            Ensure-Daemon | Out-Null
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
            Start-Process -FilePath $psExe -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $guiPath
            ) -WindowStyle Hidden
        } catch {
            Write-Log ('打开控制面板失败: ' + $_.Exception.Message)
        }
    } else {
        Write-Log ('找不到 Settings-GUI.ps1，改成直接开工')
        $script:TipLang = Get-LauncherLang
        $tipFallback = Test-ConfigSwitch -Cfg $cfgMain -Key 'showTipAfterRun' -Default $true
        Invoke-Launch -ShowTip:$tipFallback -Cfg $cfgMain
    }
    exit 0
}

# ================== 一键收工：桌面图标 / 命令行走这里 ==================
# 桌面上的「F9收工」图标双击就跑这个。后台在不在跑都无所谓 ——
# 这条路上窗口是本进程自己弹的，跟后台没有关系（所以后台掉了这个图标照样能用）。
if ($Shutdown) {
    $script:LogTag  = '[收工] '
    $script:TipLang = Get-LauncherLang
    Write-Log '收工窗口（桌面图标 / 命令行）'
    Show-ShutdownUi
    exit 0
}

# 只演一遍收工窗口，绝不真的关机 —— 给"看一眼长什么样"用
if ($QuitTest) {
    $script:LogTag  = '[收工预览] '
    $script:TipLang = Get-LauncherLang
    Write-Log '收工窗口预览（不会执行任何操作，点【取消】就退出）'
    Show-ShutdownUi -Preview
    Write-Log '收工窗口预览 结束'
    exit 0
}

# 离屏渲染收工窗口的两张预览图（只看程序自己的窗口，绝不截用户桌面）
if ($QuitShot) {
    $script:LogTag  = '[收工出图] '
    $script:TipLang = Get-LauncherLang
    Write-Log ('收工窗口出图: ' + $QuitShot)
    Show-ShutdownUi -ShotDir $QuitShot
    Write-Log '收工窗口出图 结束'
    exit 0
}

# 只演一遍开工彩蛋（飘表情包 + 播语音），不打开任何软件 —— 给"试听/预览"按钮用
if ($FanTest) {
    Write-Log '--- 开工彩蛋预览 开始 ---'
    Invoke-LauncherVoice
    Show-FloatSticker -Force
    Write-Log '--- 开工彩蛋预览 结束 ---'
    exit 0
}

if ($DryRun) {
    Invoke-Launch -IsDryRun -NoProgress
    exit 0
}

if ($Run) {
    Write-Log '手动触发(快捷方式/命令行)'
    $script:TipLang = Get-LauncherLang
    $cfgRun = Get-LauncherConfig
    $tipRun = Test-ConfigSwitch -Cfg $cfgRun -Key 'showTipAfterRun' -Default $true
    if ($NoTip) {
        $tipRun = $false
        Write-Log '  本次不显示进度窗(-NoTip)'
    }
    Invoke-Launch -ShowTip:$tipRun -Cfg $cfgRun
    # 顺手确认一下后台还活着（几毫秒的事）。后台要是没在跑，快捷键就是死的，
    # 用户只会觉得"快捷键坏了"，不会想到是后台掉了 —— 所以每个入口都自愈一下。
    Ensure-Daemon | Out-Null
    exit 0
}

# 不用真的按快捷键，把「按键之后」的全流程走一遍。
# 存在的意义：想知道"按一下到底卡不卡、有没有真的把活丢给子进程"，跑这个就行 ——
# 它会报出"处理一次按键花了多少毫秒"。这个数字小，才说明按键永远是灵敏的。
if ($SimTrigger) {
    $script:LogTag = '[模拟] '
    Write-Log '===== 模拟按一次快捷键 ====='
    $script:TipLang  = Get-LauncherLang
    $script:HotKeyNames = @(Get-PlainHotKeyList @(Get-HotKeyDefs))
    $script:HotKeyKinds = @(Get-HotKeyKindList @(Get-HotKeyDefs))

    $swWarm = [System.Diagnostics.Stopwatch]::StartNew()
    Warm-UpDaemon
    $swWarm.Stop()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $did = Invoke-TriggerAction -Id 1 -Why 'hotkey'
    $sw.Stop()

    Write-Log ('预热: ' + [int]$swWarm.Elapsed.TotalMilliseconds + ' ms')
    Write-Log ('处理这一次按键: ' + [int]$sw.Elapsed.TotalMilliseconds + ' ms ' +
               $(if ($did) { '（这段时间后台是被占住的；越小越好，几十毫秒是正常）' }
                 else { '（被"刚按过"的防重复拦掉了）' }))
    Write-Log '===== 模拟结束（真正开软件的是刚才那个子进程）====='
    exit 0
}

# ================== 常驻模式：注册全局快捷键，等按键 ==================
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $script:DaemonMutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-Log '后台已经有一个在跑了，本进程退出'
    exit 0
}

if (-not (Initialize-HotKeyHost)) { exit 1 }

$script:LogTag = '[后台] '
Write-Log ('后台启动 (pid ' + $PID + ')')

# 先把加载 WinForms、造进度窗这些慢活儿做完，
# 免得"第一次按快捷键"比后面的慢一大截
Warm-UpDaemon

$script:OnTriggerAction = [Action[int]]{
    param($id)
    try { [void](Invoke-TriggerAction -Id $id -Why 'hotkey') }
    catch { Write-Log ('处理按键时出错: ' + $_.Exception.Message) }
}
[HotKeyHost]::OnTrigger = $script:OnTriggerAction

while ($true) {
    $defs = @(Get-HotKeyDefs)
    $mods = @()
    $vks  = @()
    foreach ($d in $defs) { $mods += [int]$d.Mods; $vks += [int]$d.Vk }

    $okIds = [HotKeyHost]::Register([int[]]$mods, [int[]]$vks)
    if ($okIds.Count -eq 0) {
        Write-Log '没能注册任何快捷键(都被别的程序占用了)，10 秒后重试'
    } else {
        $names = @()
        foreach ($id in $okIds) { $names += [string]$defs[$id - 1].Text }
        Write-Log ('后台待命中，可用快捷键: ' + ($names -join ' / ') + '（开工键按下去右下角会出开工进度条）')
        $qNames = @()
        foreach ($d in $defs) { if ($d.Kind -eq 'quit') { $qNames += [string]$d.Text } }
        if ($qNames.Count -gt 0) {
            Write-Log ('  其中 ' + ($qNames -join ' / ') + ' 是收工键（弹「关机 / 重启 / 睡眠」窗口，带倒计时）')
        } else {
            Write-Log '  没配收工快捷键（config.json 的 shutdownHotkey 是空的）'
        }
    }
    # 按键时要在提示浮窗上写"按的是哪个键"，名字在这里存一份，
    # 免得每次按键都去读一遍 config.json（那要一百多毫秒，会拖慢那一下的反馈）
    $script:HotKeyNames = @()
    $script:HotKeyKinds = @()
    foreach ($d in $defs) {
        $script:HotKeyNames += [string]$d.Text
        $script:HotKeyKinds += [string]$d.Kind
    }

    try {
        [HotKeyHost]::Loop()
    } catch {
        Write-Log ('消息循环出错: ' + $_.Exception.Message)
    }
    [HotKeyHost]::UnregisterAll($defs.Count)
    Start-Sleep -Seconds 10
}
