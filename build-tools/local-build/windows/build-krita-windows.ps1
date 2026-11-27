<#
.SYNOPSIS
    在 Windows 上原生构建 Krita（llvm-mingw + Ninja + CMake 3.31）的自动化脚本。

.DESCRIPTION
    对应当前官方文档 "Building on Windows" 的步骤：
      1. 检查 git / cmake 3.31.x / ninja / llvm-mingw / Python 3.13
      2. 下载并解压工具链（llvm-mingw 20251118-ucrt、ninja、cmake 3.31.6，可选 Python 3.13）
      3. 建 venv + pip 装 requirements + setup-env.py --full-krita-env（生成 env.bat）
      4. 克隆 krita 源码
      5. cmake -G Ninja 配置
      6. ninja install
      7. 运行 _install\bin\krita.exe

    所有构建命令都在 `call env.bat` 之后执行，所以不需要手工设置 PATH。

.PARAMETER Step
    all（默认）/ check / toolchain / env / sources / configure / build / deploy / run / clean / info / logs
    logs：打印日志目录、最近 10 个日志文件，以及 latest.log 的末尾 40 行

.PARAMETER Root
    单一根目录，所有下载都落在该盘：<Root>\dev 当工作区、<Root>\deps 放工具链。
    例：-Root D:\krita。必须是带盘符的绝对路径；盘符不存在/是光驱/剩余<5GB 会直接报错。

.PARAMETER Workspace
    工作区：源码、依赖缓存、venv、env.bat、_install、b_krita、logs 都在这里。
    留空则由 -Root 派生（<Root>\dev）；都没给时默认 C:\krita-dev。路径不能有空格。

.PARAMETER DepsRoot
    工具链根目录：llvm-mingw / cmake / ninja / python313。
    留空则由 -Root 派生（<Root>\deps）；都没给时默认 C:\deps。路径不能有空格。

.PARAMETER PythonExe
    指定 python.exe（必须精确 3.13）。留空则依次查找：<DepsRoot>\python313、<DepsRoot>\python*。
    加 -UseSystemTools 时才会回退到 PATH 里的 python。

.PARAMETER InstallPython
    缺 Python 3.13 时自动下载官方安装包并静默安装到 <DepsRoot>\python313。
    不写系统 PATH、不装 py launcher、不需要管理员权限；已存在则跳过。

.PARAMETER UseSystemTools
    默认关闭：只用 <DepsRoot> 里下载的 cmake / ninja / python。
    加此开关才允许回退到系统 PATH 里的同名工具（不推荐，官方要求环境干净）。

.PARAMETER HttpProxy
    下载用的 HTTP 代理，例如 http://127.0.0.1:7890。
    会把 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 一并设给子进程（pip / git / python requests 都能用），
    并自动补 NO_PROXY=localhost,127.0.0.1,::1。

.PARAMETER NoProxy
    本次运行**完全绕过代理**（直连）：清理 HTTP_PROXY 等环境变量，并设 NO_PROXY=*，
    这同时压过 Windows「系统代理」（注册表 WinINET）—— Python 的 requests 会读它。
    典型场景：用 Clash 的 TUN / 虚拟网卡模式，本来就不需要 HTTP 代理，
    但系统代理开关没关，残留指向 127.0.0.1:7890，于是 pip / run-ci-build.py 报 ProxyError。

.PARAMETER EnvRetries
    `env` 步骤（setup-env.py）失败时的重试次数，默认 4（1 = 不重试）。
    重试时会在「按配置代理」与「直连」之间交替 —— 代理节点抖动/切换时非常有效。

.PARAMETER RecreateVenv
    删除并重建 <Workspace>\PythonEnv。
    现有 venv 的 Python 不是 3.13 时（旧版本脚本用 pyenv 3.11 建过），建议重建。

.PARAMETER EnvIdleTimeout
    `env` 步骤里单次执行的"无输出超时"（秒），默认 120。
    超过这么久一行输出都没有，就判定卡死（网络请求挂住），杀掉该次并换网络模式重试。
    依赖需要真正下载耗时很久时不会误杀 —— 只要它还在持续输出。

.PARAMETER RefreshEnv
    忽略 env 的增量标记，强制重新获取依赖（会联网）。
    默认：若 krita-deps-management / ci-utilities 的 commit 与上次一致、且 env.bat 还在，
    第 3 步直接跳过 —— 不再每次联网查 GitLab。

.PARAMETER RunArgs
    传给 `krita.exe` 的参数（仅 `-Step run` 生效），例如 `-RunArgs "--nosplash"`、
    `-RunArgs "D:\pics\test.kra"`。

.PARAMETER SkipEnv
    跳过第 3 步（依赖获取），直接复用已有的 <Workspace>\env.bat。
    run-ci-build.py 每次都要联网查 GitLab 的 package_files 列表（即使依赖已在缓存里），
    网络/代理不稳时这一步最容易失败；依赖已经装好时加它就能直接进 configure/build。

.PARAMETER Jobs
    ninja 并行任务数；0（默认）= CPU 核心数。

.PARAMETER Branch
    krita 分支，默认 master（krita/5.2 需要 Python 3.10）。

.PARAMETER Force
    忽略增量标记，强制重新编译（configure + ninja install 都重跑）。
    默认：源码 HEAD / 未提交改动 / 编译器 / CMake 参数 / 目录都没变，且
    _install\bin\krita.exe 还在 → build 步骤直接跳过（一步到位，不扫描 5000 个目标）。
    想连 _build 一起清掉重来请用 -CleanBuild。

.PARAMETER ForceToolchain
    重新下载/解压工具链（即使已存在）。

.PARAMETER SkipToolchain
    跳过工具链下载步骤（假设已就绪）。

.PARAMETER CleanBuild
    配置前清空构建目录 b_krita。

.PARAMETER Shallow
    克隆源码时用 --depth 1（更快，git 历史不完整）。

.PARAMETER Update
    对已存在的仓库执行 git pull --ff-only。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File windows\build-krita-windows.ps1 -Step all

.EXAMPLE
    # 一条命令：所有东西（工具链 + 源码 + 依赖缓存 + 构建产物）都放到 D 盘
    .\build-krita-windows.ps1 -Step all -Root D:\krita

.EXAMPLE
    # 只装工具链：工作区用默认 C:\krita-dev，工具链放到 C:\krita-deps
    .\build-krita-windows.ps1 -Step toolchain -DepsRoot C:\krita-deps
#>

# 注意：#Requires 必须放在基于注释的帮助块之后。
# 如果它出现在文件第一行，Get-Help 会解析不到 .SYNOPSIS/.PARAMETER（只剩语法行）。
#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('all', 'check', 'toolchain', 'env', 'sources', 'configure', 'build', 'deploy', 'run', 'clean', 'info', 'logs')]
    [string]$Step = 'all',

    # 根目录：只给这一个参数，所有东西都会落到它所在的盘符
    #   <Root>\dev   -> 工作区（源码 / 构建目录 / venv / env.bat / 依赖缓存 cache）
    #   <Root>\deps  -> 工具链（llvm-mingw / cmake / ninja / python）
    # 例：-Root D:\krita       （D 盘会新建 D:\krita\dev 和 D:\krita\deps）
    #     -Root E:\build\krita
    [string]$Root = '',

    # 工作区（源码、构建目录、venv、env.bat 都放这里；路径不要有空格）
    # 留空 = 由 -Root 派生；没给 -Root 时默认 C:\krita-dev
    [string]$Workspace = '',

    # 工具链根目录（llvm-mingw / ninja / cmake / 可选 python 放这里）
    # 留空 = 由 -Root 派生；没给 -Root 时默认 C:\deps
    [string]$DepsRoot = '',

    # 指定 python.exe（必须是 3.13）；留空则自动查找
    [string]$PythonExe = '',

    # 需要代理时填写，例如 http://127.0.0.1:7890
    [string]$HttpProxy = '',

    # 本次运行完全绕过代理（清环境变量 + NO_PROXY=*，压过系统代理）
    [switch]$NoProxy,

    # env 步骤失败时的重试次数（默认 3；重试时代理/直连交替）
    [int]$EnvRetries = 3,

    # 删除并重建 PythonEnv（venv 的 Python 不是 3.13 时用）
    [switch]$RecreateVenv,

    # 跳过第 3 步（依赖获取），直接复用已有 env.bat
    [switch]$SkipEnv,

    # 传给 krita.exe 的参数（-Step run 时用），例如 "--nosplash" 或某个 .kra 路径
    [string]$RunArgs = '',

    # env 步骤单次执行的"无输出超时"（秒）；0 = 不限制
    [int]$EnvIdleTimeout = 120,

    # 强制重新获取依赖（忽略 env 的增量标记，联网重跑 setup-env.py）
    [switch]$RefreshEnv,

    # 并行编译任务数；0 = CPU 核心数
    [int]$Jobs = 0,

    # krita 分支（克隆时使用；CI 里可传 tag 或 fork 的分支名）
    [string]$Branch = 'master',

    # Krita 源码仓库地址（默认官方 invent.kde.org；CI 里可指向自己的 fork）
    [string]$RepoUrl = 'https://invent.kde.org/graphics/krita.git',

    # 源码检出的分支/tag（只影响 sources 步骤）；留空 = 沿用 -Branch
    [string]$SourceRef = '',

    # 没装 Python 3.13 时，自动下载官方安装包并静默装到 <DepsRoot>\python313
    [switch]$InstallPython,

    # 默认只用 DepsRoot 里自带的工具链（cmake / ninja / llvm-mingw / python），
    # 不去 PATH 里捡系统已安装的版本；加这个开关才会回退到系统工具
    [switch]$UseSystemTools,

    # 重新下载/解压工具链
    [switch]$ForceToolchain,

    # 配置前清空构建目录（b_krita）
    [switch]$CleanBuild,

    # 忽略增量标记：强制重新 configure + 重新编译（源码没变也编）
    [switch]$Force,

    # 跳过工具链下载（假设已就绪）
    [switch]$SkipToolchain,

    # 克隆源码时用浅克隆（更快，但 git 历史不完整）
    [switch]$Shallow,

    # 已存在的仓库执行 git pull
    [switch]$Update
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 路径解析：-Root 一个参数搞定
#   -Root D:\krita  ->  Workspace = D:\krita\dev ，DepsRoot = D:\krita\deps
# 盘符就是你机器上真实存在的盘（C:/D:/E:...），所有下载都落在该盘。
# 若同时显式给了 -Workspace / -DepsRoot，则以你给的为准。
# ---------------------------------------------------------------------------
function ConvertTo-FullPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = $Path.Trim().Trim('"').Trim()
    if (-not $p) { return '' }
    # 允许只写盘符："D:" / "D:\" / "D:/"
    if ($p -match '^[A-Za-z]:$') { $p = $p + '\' }
    $p = $p -replace '/', '\'
    try { return [IO.Path]::GetFullPath($p) } catch { return $p }
}

function Get-DriveOfPath {
    param([string]$FullPath)
    if ($FullPath -match '^([A-Za-z]):') { return ($Matches[1].ToUpper() + ':') }
    return $null   # UNC / 相对路径
}

# 纯字符串拼接：内置 Join-Path 在盘符不存在时会抛 DriveNotFoundException，
# 那样 Assert-TargetPath 的友好提示就来不及显示了
function Join-PathSafe {
    param([string]$Base, [string]$Child)
    if (-not $Base) { return $Child }
    if (-not $Child) { return $Base }
    return ($Base.TrimEnd('\') + '\' + $Child.TrimStart('\'))
}

$RootGiven = -not [string]::IsNullOrWhiteSpace($Root)
$WsGiven   = ($PSBoundParameters.ContainsKey('Workspace')) -and (-not [string]::IsNullOrWhiteSpace($Workspace))
$DepsGiven = ($PSBoundParameters.ContainsKey('DepsRoot'))  -and (-not [string]::IsNullOrWhiteSpace($DepsRoot))

$Script:RootPath = ''

if ($RootGiven) {
    $raw = $Root.Trim().Trim('"').Trim()
    if (-not [IO.Path]::IsPathRooted($raw)) {
        throw "-Root 必须带盘符的绝对路径（例如 -Root D:\krita），收到: '$Root'"
    }
    $rootFull = ConvertTo-FullPath $raw
    if (($rootFull -notmatch '^[A-Za-z]:\\') -and ($rootFull -notmatch '^\\\\')) {
        throw "-Root 必须是绝对路径（例如 -Root D:\krita），收到: '$Root'"
    }
    $rootFull = $rootFull.TrimEnd('\')
    if ($rootFull -match '^[A-Za-z]:$') { $rootFull = $rootFull + '\' }   # 例如 -Root D:\
    $Script:RootPath = $rootFull
    # 注意：这里用字符串拼接而不是 Join-Path —— 盘符不存在时 Join-Path 会直接抛
    # DriveNotFoundException，那样就看不到 Assert-TargetPath 给的友好提示了
    $rootSep = $rootFull.TrimEnd('\') + '\'
    if (-not $WsGiven)   { $Workspace = $rootSep + 'dev' }
    if (-not $DepsGiven) { $DepsRoot  = $rootSep + 'deps' }
}

if (-not $Workspace) { $Workspace = 'C:\krita-dev' }
if (-not $DepsRoot)  { $DepsRoot  = 'C:\deps' }

$Workspace = (ConvertTo-FullPath $Workspace).TrimEnd('\')
$DepsRoot  = (ConvertTo-FullPath $DepsRoot).TrimEnd('\')

# 只在路径为空时兜底（TrimEnd 后可能变成 "D:"，此时还原成 "D:\"）
if ($Workspace -match '^[A-Za-z]:$') { $Workspace = $Workspace + '\' }
if ($DepsRoot  -match '^[A-Za-z]:$') { $DepsRoot  = $DepsRoot  + '\' }

# PowerShell 5.1 默认可能仍用 TLS 1.0，GitHub / python.org 会握手失败
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# 常量（与官方文档保持一致；如上游更新，只改这里）
# ---------------------------------------------------------------------------
$Script:LlvmVersion = '20251118'
$Script:LlvmFolder  = "llvm-mingw-$($Script:LlvmVersion)-ucrt-x86_64"
$Script:LlvmUrl     = "https://github.com/mstorsjo/llvm-mingw/releases/download/$($Script:LlvmVersion)/$($Script:LlvmFolder).zip"

$Script:NinjaVersion = 'v1.13.2'
$Script:NinjaUrl     = "https://github.com/ninja-build/ninja/releases/download/$($Script:NinjaVersion)/ninja-win.zip"

$Script:CmakeVersion = '3.31.6'   # 官方：3.31.x，4.x 尚不支持
$Script:CmakeFolder  = "cmake-$($Script:CmakeVersion)-windows-x86_64"
$Script:CmakeUrl     = "https://github.com/Kitware/CMake/releases/download/v$($Script:CmakeVersion)/$($Script:CmakeFolder).zip"

$Script:PythonVersion = '3.13.11'  # 官方：必须 3.13（master 分支）
$Script:PythonUrl     = "https://www.python.org/ftp/python/$($Script:PythonVersion)/python-$($Script:PythonVersion)-amd64.exe"

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
$Script:LlvmDir    = Join-PathSafe $DepsRoot $Script:LlvmFolder
$Script:LlvmBin    = Join-PathSafe $Script:LlvmDir 'bin'
$Script:LlvmSysBin = Join-PathSafe $Script:LlvmDir 'x86_64-w64-mingw32\bin'

$Script:NinjaDir = Join-PathSafe $DepsRoot 'ninja'
$Script:NinjaExe = Join-PathSafe $Script:NinjaDir 'ninja.exe'

$Script:CmakeDir = Join-PathSafe $DepsRoot $Script:CmakeFolder
$Script:CmakeExe = Join-PathSafe $Script:CmakeDir 'bin\cmake.exe'

$Script:PyLocalExe = Join-PathSafe $DepsRoot 'python313\python.exe'

$Script:DepsMgmt = Join-PathSafe $Workspace 'krita-deps-management'
$Script:VenvDir  = Join-PathSafe $Workspace 'PythonEnv'
$Script:EnvBat   = Join-PathSafe $Workspace 'env.bat'
$Script:SrcDir   = Join-PathSafe $Workspace 'krita'
$Script:BuildDir = Join-PathSafe $Workspace 'b_krita'
$Script:InstallDir = Join-PathSafe $Workspace '_install'

$Script:EnvStamp = Join-PathSafe $Workspace '.krita-win-env-stamp'
$Script:LogDir  = Join-PathSafe $Workspace 'logs'
$Script:LogFile = Join-PathSafe $Script:LogDir ("win-build-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
# 每次运行结束时复制一份到这里，方便"看最近一次"（与 Android 侧 logs/latest.log 对齐）
$Script:LatestLog = Join-PathSafe $Script:LogDir 'latest.log'

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'STEP')]
        [string]$Level = 'INFO'
    )
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'STEP' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    if ($Script:LogFile) {
        try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

# 把本次日志复制为 logs\latest.log（在最后一行写入之后调用）
function Update-LatestLog {
    if (-not $Script:LogFile -or -not $Script:LatestLog) { return }
    if (-not (Test-Path -LiteralPath $Script:LogFile)) { return }
    if ($Script:LogFile -eq $Script:LatestLog) { return }
    try {
        Copy-Item -LiteralPath $Script:LogFile -Destination $Script:LatestLog -Force -ErrorAction Stop
    } catch { }
}

function Write-Hr {
    $msg = '-' * 75
    Write-Host $msg -ForegroundColor DarkGray
    if ($Script:LogFile) {
        try { Add-Content -LiteralPath $Script:LogFile -Value $msg -Encoding UTF8 } catch { }
    }
}

function Fail {
    param([string]$Message)
    Write-Log $Message 'ERR'
    throw $Message
}

# 校验目标目录：盘符必须存在，目录必须可写（否则下载会失败在几百 MB 之后）
function Assert-TargetPath {
    param([string]$Path, [string]$What)

    $full = ConvertTo-FullPath $Path
    $drive = Get-DriveOfPath $full

    if ($drive) {
        $letter = $drive.TrimEnd(':')
        $ready = $false
        $why = ''
        try {
            $di = New-Object System.IO.DriveInfo ($letter + ':')
            if ($di.DriveType -eq [System.IO.DriveType]::CdRom) {
                $why = '这是光驱（只读，不能当构建目录）'
            } elseif ($di.DriveType -eq [System.IO.DriveType]::NoRootDirectory) {
                $why = '盘符没有根目录'
            } elseif (-not $di.IsReady) {
                $why = '盘符存在但没有介质 / 未就绪（空光驱、读卡器等）'
            } elseif ($di.AvailableFreeSpace -lt 5GB) {
                $why = ('剩余空间只有 {0:N1} GB，构建 Krita 至少要 40GB' -f ($di.AvailableFreeSpace / 1GB))
            } else {
                $ready = $true
            }
        } catch {
            $why = '盘符不存在'
        }
        if (-not $ready) {
            $have = ''
            try {
                $have = ([System.IO.DriveInfo]::GetDrives() |
                         Where-Object { @('Fixed', 'Removable', 'Network') -contains $_.DriveType } |
                         ForEach-Object { $_.Name.Substring(0, 2) }) -join '  '
            } catch { }
            Fail ("{0} 指向的盘符 {1} 不可用：{2}。本机可写的盘符: {3} —— 请换成其中之一，例如 -Root C:\krita" -f $What, $drive, $why, $have)
        }
    }

    if (-not (Test-Path -LiteralPath $full)) {
        try {
            New-Item -ItemType Directory -Path $full -Force | Out-Null
            Write-Log ("已创建目录: {0}" -f $full) 'OK'
        } catch {
            Fail ("{0} 无法创建: {1}（{2}）" -f $What, $full, $_.Exception.Message)
        }
    }

    $probe = Join-Path $full ('.krita-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    } catch {
        Fail ("{0} 不可写: {1}（{2}）—— 换一个有写权限的目录/盘符" -f $What, $full, $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
function Test-Exe {
    param([string]$Path)
    if (-not $Path) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

# 查找 cmake：只认 DepsRoot 下任意 3.31.x 便携版；
# 只有显式 -UseSystemTools 时才回退到 PATH（PATH 里若是 4.x 会被拒绝）
function Find-CmakeExe {
    $cands = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $DepsRoot) {
        # -Filter 不支持带路径分隔符的写法，这里先列出 cmake-* 目录再拼 bin\cmake.exe
        Get-ChildItem -Path $DepsRoot -Directory -Filter 'cmake-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { [void]$cands.Add((Join-Path $_.FullName 'bin\cmake.exe')) }
    }
    if ($UseSystemTools) {
        $cmd = Get-Command 'cmake.exe' -ErrorAction SilentlyContinue
        if ($cmd) { [void]$cands.Add($cmd.Source) }
    }

    foreach ($c in $cands) {
        if (-not (Test-Exe $c)) { continue }
        $ver = Get-VersionOf $c
        if ($ver -match '(3\.31\.[0-9]+)') { return $c }
    }
    return $null
}

# 查找 ninja：DepsRoot\ninja、DepsRoot\Ninja 或 PATH
function Find-NinjaExe {
    $cands = @(
        (Join-Path $DepsRoot 'ninja\ninja.exe'),
        (Join-Path $DepsRoot 'Ninja\ninja.exe')
    )
    foreach ($c in $cands) { if (Test-Exe $c) { return $c } }
    if ($UseSystemTools) {
        $cmd = Get-Command 'ninja.exe' -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# 查找 llvm-mingw：DepsRoot 下任意 llvm-mingw-* 目录
function Find-LlvmDir {
    $dirs = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Script:LlvmDir) { [void]$dirs.Add($Script:LlvmDir) }
    if (Test-Path -LiteralPath $DepsRoot) {
        Get-ChildItem -Path $DepsRoot -Directory -Filter 'llvm-mingw-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { [void]$dirs.Add($_.FullName) }
    }
    foreach ($d in $dirs) {
        if (Test-Exe (Join-Path $d 'bin\clang.exe')) { return $d }
    }
    return $null
}

# 把找到的工具链路径写回全局变量（后续步骤统一使用）
function Resolve-ToolchainPaths {
    $llvm = Find-LlvmDir
    if ($llvm) {
        $Script:LlvmDir = $llvm
        $Script:LlvmBin = Join-Path $llvm 'bin'
        $Script:LlvmSysBin = Join-Path $llvm 'x86_64-w64-mingw32\bin'
    }
    $ninja = Find-NinjaExe
    if ($ninja) {
        $Script:NinjaExe = $ninja
        $Script:NinjaDir = Split-Path -Parent $ninja
    }
    $cmake = Find-CmakeExe
    if ($cmake) {
        $Script:CmakeExe = $cmake
        $Script:CmakeDir = Split-Path -Parent (Split-Path -Parent $cmake)
    }
}

function Resolve-Cmake { return (Find-CmakeExe) }
function Resolve-Ninja { return (Find-NinjaExe) }

function Get-VersionOf {
    param([string]$Exe, [string]$Argument = '--version')
    try {
        $out = & $Exe $Argument 2>$null
        if ($out) { return (($out | Select-Object -First 1) -as [string]).Trim() }
    } catch { }
    return $null
}

function Resolve-Python313 {
    $candidates = New-Object System.Collections.ArrayList
    if ($PythonExe) { [void]$candidates.Add($PythonExe) }
    [void]$candidates.Add($Script:PyLocalExe)
    # DepsRoot 下任意 python* 目录（python313 / Python-3.13 / Python313 ...），
    # 这样工具链整体搬家（换盘符）后仍然能找到
    if (Test-Path -LiteralPath $DepsRoot) {
        Get-ChildItem -Path $DepsRoot -Directory -Filter 'python*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { [void]$candidates.Add((Join-Path $_.FullName 'python.exe')) }
    }
    if ($UseSystemTools) {
        $cmd = Get-Command 'python.exe' -ErrorAction SilentlyContinue
        if ($cmd) { [void]$candidates.Add($cmd.Source) }
    }

    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        try {
            $ver = (& $c -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null)
            if (($ver -as [string]).Trim() -eq '3.13') { return $c }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 增量构建指纹（"没变化就别重编"）
#   配置指纹：源码目录 / 构建目录 / 安装前缀 / 编译器 / 生成器 / 固定的 CMake 参数
#   编译指纹：配置指纹 + 源码 HEAD + 未提交改动哈希 + cmake 版本
#   分别写入 b_krita\.krita-win-config-stamp 与 .krita-win-build-stamp；
#   下次一致且 krita.exe 存在 → configure / build 直接跳过（-Force 可强制）。
# ---------------------------------------------------------------------------
function Get-StringSha256 {
    param([string]$Text)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
            return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally { $sha.Dispose() }
    } catch {
        return 'nohash'
    }
}

function Get-GitSnapshot {
    param([string]$RepoDir)

    $out = @{ Head = 'nogit'; Dirty = 'nogit' }
    if (-not (Test-Path -LiteralPath $RepoDir)) { return $out }
    if (-not (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) { return $out }

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $h = & git -C $RepoDir rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $h) { $out.Head = (($h | Select-Object -First 1) -as [string]).Trim() }
        $st = & git -C $RepoDir status --porcelain --untracked-files=no 2>$null
        $out.Dirty = Get-StringSha256 (($st -join "`n"))
    } catch { } finally {
        $ErrorActionPreference = $oldEap
    }
    return $out
}

function Get-ConfigFingerprint {
    $parts = @(
        'cfg1'
        "src=$($Script:SrcDir)"
        "build=$($Script:BuildDir)"
        "prefix=$($Script:InstallDir)"
        "cc=$(Join-Path $Script:LlvmBin 'clang.exe')"
        "cxx=$(Join-Path $Script:LlvmBin 'clang++.exe')"
        'gen=Ninja'
        'flags=-DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=ON -DINSTALL_BENCHMARKS=ON -DKRITA_ENABLE_PCH=OFF -DHIDE_SAFE_ASSERTS=OFF'
    )
    return ($parts -join '|')
}

function Get-EnvFingerprint {
    $deps = Get-GitSnapshot -RepoDir $Script:DepsMgmt
    $ci = Get-GitSnapshot -RepoDir (Join-PathSafe $Script:DepsMgmt 'ci-utilities')
    $parts = @(
        'env1'
        "deps=$($deps.Head)"
        "deps_dirty=$($deps.Dirty)"
        "ci=$($ci.Head)"
        "branch=$Branch"
        "workspace=$Workspace"
        "venv=$($Script:VenvDir)"
    )
    return ($parts -join '|')
}

function Get-BuildFingerprint {
    $snap = Get-GitSnapshot -RepoDir $Script:SrcDir
    $cmakeVer = ''
    if (Test-Exe $Script:CmakeExe) { $cmakeVer = Get-VersionOf $Script:CmakeExe }
    $parts = @(
        (Get-ConfigFingerprint)
        "src_head=$($snap.Head)"
        "src_dirty=$($snap.Dirty)"
        "cmake=$cmakeVer"
    )
    return ($parts -join '|')
}

function Test-Stamp {
    param([string]$Path, [string]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        return ((Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim() -eq $Value)
    } catch { return $false }
}

function Save-Stamp {
    param([string]$Path, [string]$Value)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and (-not (Test-Path -LiteralPath $dir))) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8 -NoNewline -ErrorAction Stop
    } catch {
        Write-Log "无法写入增量标记: $Path" 'WARN'
    }
}

function Get-ConfigStampPath { return (Join-Path $Script:BuildDir '.krita-win-config-stamp') }
function Get-BuildStampPath  { return (Join-Path $Script:BuildDir '.krita-win-build-stamp') }

# ---------------------------------------------------------------------------
# 代理处理
#   常见事故：系统里残留 HTTP_PROXY=127.0.0.1:7890 但代理没开，于是 pip / git /
#   python requests 全报 "ProxyError: Unable to connect to proxy"。
#   这里统一处理：-NoProxy 清空；-HttpProxy 写入；否则探测代理端口是否可连。
# ---------------------------------------------------------------------------
$Script:ProxyEnvNames = @(
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'
)
# 配置层面"想用的代理"（可能是 -HttpProxy、环境变量或注册表里的系统代理）
$Script:ConfiguredProxy = ''

function Get-ProxyEnvValue {
    foreach ($n in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        # 注意：环境变量经常带尾随空格/引号（cmd 的 set 很容易带进来），
        # 不 Trim 会让 [Uri] 解析出荒唐的端口（实测 "…:7890 " → 13348）。
        if ($v) { return $v.Trim().Trim('"') }
    }
    return ''
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMs)) { $client.Close(); return $false }
        $ok = $client.Connected
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

# 端口"能连上"不代表代理真的能用：SOCKS/HTTP 混合端口在规则未命中、
# 上游断开时会直接掐掉连接，Python 侧表现就是 RemoteDisconnected。
# 所以真发一个请求验证（HTTPS 走 CONNECT）。
function Test-ProxyUsable {
    param([string]$Proxy, [int]$TimeoutSec = 8)
    foreach ($method in @('Head', 'Get')) {
        try {
            $r = Invoke-WebRequest -Uri 'https://invent.kde.org/' -Proxy $Proxy `
                -UseBasicParsing -TimeoutSec $TimeoutSec -Method $method -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { return $true }
        } catch { }
    }
    return $false
}

# Windows 的"系统代理"存在注册表里（WinINET）。Python 的 urllib/requests 在
# **没有** HTTP_PROXY 环境变量时会去读它 —— 这就是"没设环境变量、请求却走了代理"的原因。
function Get-SystemProxy {
    $r = @{ Enabled = $false; Server = '' }
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $p = Get-ItemProperty -Path $key -ErrorAction Stop
        if (($p.ProxyEnable -eq 1) -and $p.ProxyServer) {
            $r.Enabled = $true
            $s = ([string]$p.ProxyServer).Trim()
            # 可能是 "host:port" 或 "http=host:port;https=host:port"
            if ($s -match '=') {
                if ($s -match '(?:^|;)\s*https?=([^;]+)') { $s = $Matches[1] }
                else { $s = ($s -split '=')[-1] }
            }
            if ($s -notmatch '^[A-Za-z]+://') { $s = 'http://' + $s }
            $r.Server = $s.Trim().TrimEnd('/')
        }
    } catch { }
    return $r
}

# NO_PROXY=* 让 requests/urllib 完全绕过代理（包括注册表里的系统代理）。
# 虚拟网卡（TUN）模式正是这种场景：流量已经由网卡接管，不需要 HTTP 代理。
function Set-NoProxyEnv {
    Set-Item Env:\NO_PROXY '*' -ErrorAction SilentlyContinue
    Set-Item Env:\no_proxy '*' -ErrorAction SilentlyContinue
}

function Clear-ProxyEnv {
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        Remove-Item ("Env:\" + $n) -ErrorAction SilentlyContinue
    }
}

# 运行期切换网络模式（env 步骤重试时在"代理 / 直连"之间交替）
function Use-DirectMode {
    Clear-ProxyEnv
    Set-NoProxyEnv
    Write-Log '网络模式 → 直连（NO_PROXY=*，绕过代理与系统代理）' 'WARN'
}

function Use-ProxyMode {
    if (-not $Script:ConfiguredProxy) { Use-DirectMode; return }
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        Set-Item ("Env:\" + $n) $Script:ConfiguredProxy -ErrorAction SilentlyContinue
    }
    Set-Item Env:\NO_PROXY 'localhost,127.0.0.1,::1' -ErrorAction SilentlyContinue
    Set-Item Env:\no_proxy 'localhost,127.0.0.1,::1' -ErrorAction SilentlyContinue
    Write-Log ("网络模式 → 代理 {0}" -f $Script:ConfiguredProxy) 'WARN'
}

function Initialize-ProxyEnv {
    if ($NoProxy) {
        Clear-ProxyEnv
        Set-NoProxyEnv
        $Script:ConfiguredProxy = ''
        Write-Log '-NoProxy：本次直连（NO_PROXY=*，同时压过 Windows 系统代理）' 'WARN'
        return
    }

    if ($HttpProxy) {
        # 去掉可能的尾随空格/引号/斜杠，否则 [Uri] 会解析出错误端口
        $hp = $HttpProxy.Trim().Trim('"').TrimEnd('/')
        foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
            Set-Item ("Env:\" + $n) $hp -ErrorAction SilentlyContinue
        }
        $noProxy = $env:NO_PROXY
        if (-not $noProxy) { $noProxy = 'localhost,127.0.0.1,::1' }
        Set-Item Env:\NO_PROXY $noProxy -ErrorAction SilentlyContinue
        Set-Item Env:\no_proxy $noProxy -ErrorAction SilentlyContinue
        Write-Log ("-HttpProxy：HTTP(S)_PROXY = {0}（pip / git / python 都会用）" -f $hp) 'OK'
        $target = $hp
        $source = '-HttpProxy'
        $Script:ConfiguredProxy = $hp
    } else {
        $target = Get-ProxyEnvValue
        $source = 'HTTP(S)_PROXY 环境变量'
        if (-not $target) {
            $sys = Get-SystemProxy
            if ($sys.Enabled) { $target = $sys.Server; $source = 'Windows 系统代理（注册表）' }
        }
        if (-not $target) {
            Write-Log '未检测到代理（环境变量与系统代理都为空）→ 直连' 'OK'
            return
        }
        $target = $target.Trim().Trim('"').TrimEnd('/')
        Write-Log ("检测到{0}: {1}" -f $source, $target) 'WARN'
        $Script:ConfiguredProxy = $target
    }

    # 探测代理端口；连不上就自动改直连（TUN 虚拟网卡 + 系统代理开关没关，很常见）
    $u = $null
    try { $u = [Uri]$target } catch { }
    if (-not ($u -and $u.Host)) { return }

    $port = 8080
    if ($u.Port -gt 0) { $port = $u.Port }

    if (-not (Test-TcpPort -HostName $u.Host -Port $port -TimeoutMs 2000)) {
        Write-Log ("代理 {0}:{1} 连不上（pip / requests 会因此报 ProxyError）" -f $u.Host, $port) 'ERR'
    } elseif (-not (Test-ProxyUsable -Proxy $target)) {
        Write-Log ("代理 {0}:{1} 端口开着，但经它访问 invent.kde.org 失败（RemoteDisconnected 就是这个）" -f $u.Host, $port) 'ERR'
    } else {
        Write-Log ("代理 {0}:{1} 可用" -f $u.Host, $port) 'OK'
        return
    }

    # 代理不可用 → 自动改直连（TUN 虚拟网卡就是这种场景：根本不需要 HTTP 代理）
    Use-DirectMode
    Write-Log '走 TUN/虚拟网卡时直连就是对的；要强制用代理请 -HttpProxy http://127.0.0.1:<端口>' 'WARN'
    Write-Log '（env 步骤失败时还会自动在代理/直连之间交替重试，见 -EnvRetries）' 'INFO'
}

# 跑外部程序：实时把新增输出打到控制台并写日志，同时做"无输出超时"保护
#   * 用 Start-Process 让子进程直接写文件，避免 PS 管道把 Python 输出缓冲住
#     （之前的现象：明明在跑，却好几分钟一行输出都没有）
#   * IdleTimeoutSec > 0 时，超过这么久没有任何新输出就判定卡死，
#     taskkill 掉并返回 124（Step-Env 会据此换网络模式重试）
function Invoke-LoggedCommand {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$WorkingDir,
        [int]$IdleTimeoutSec = 0
    )
    if (-not (Test-Path -LiteralPath $WorkingDir)) {
        New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null
    }

    Write-Log ("执行: {0} {1}" -f $Exe, ($Arguments -join ' '))
    if ($IdleTimeoutSec -gt 0) {
        Write-Log ("（超过 {0}s 没有任何输出会自动中止并重试）" -f $IdleTimeoutSec) 'INFO'
    }

    $base = Join-Path $env:TEMP ('krita-cmd-' + [guid]::NewGuid().ToString('N'))
    $outFile = $base + '.out'
    $errFile = $base + '.err'
    foreach ($f in @($outFile, $errFile)) {
        try { Set-Content -LiteralPath $f -Value '' -Encoding UTF8 -ErrorAction Stop } catch { }
    }

    # Start-Process 的 -ArgumentList 是"空格拼接"的，含空格的参数要自己加引号
    $argList = @($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        })

    $proc = $null
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList $argList -WorkingDirectory $WorkingDir `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
        # PS5.1 的坑：不先摸一下 Handle，进程退出后 ExitCode 会是 $null（不是 0！）
        try { $null = $proc.Handle } catch { }
    } catch {
        Write-Log ("启动失败: {0}" -f $_.Exception.Message) 'ERR'
        return 1
    }

    function Emit-New([string]$path, [ref]$seen) {
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop) } catch { return $false }
        if ($lines.Count -le $seen.Value) { return $false }
        for ($k = $seen.Value; $k -lt $lines.Count; $k++) {
            Write-Host $lines[$k]
            if ($Script:LogFile) {
                try { Add-Content -LiteralPath $Script:LogFile -Value $lines[$k] -Encoding UTF8 } catch { }
            }
        }
        $seen.Value = $lines.Count
        return $true
    }

    $seenOut = 0
    $seenErr = 0
    $lastChange = Get-Date
    $killed = $false

    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 800
        $changed = $false
        if (Emit-New $outFile ([ref]$seenOut)) { $changed = $true }
        if (Emit-New $errFile ([ref]$seenErr)) { $changed = $true }
        if ($changed) {
            $lastChange = Get-Date
        } elseif (($IdleTimeoutSec -gt 0) -and (((Get-Date) - $lastChange).TotalSeconds -ge $IdleTimeoutSec)) {
            Write-Log ("超过 {0}s 没有任何输出 → 判定卡死，终止（多半是网络请求挂住）" -f $IdleTimeoutSec) 'ERR'
            try { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
            $killed = $true
            break
        }
    }

    try { if (-not $proc.HasExited) { $proc.WaitForExit() } } catch { }
    $null = Emit-New $outFile ([ref]$seenOut)
    $null = Emit-New $errFile ([ref]$seenErr)

    $code = 124
    if (-not $killed) {
        $code = 0
        try {
            if ($null -ne $proc.ExitCode) { $code = [int]$proc.ExitCode }
        } catch { $code = 0 }
    }
    foreach ($f in @($outFile, $errFile)) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $code
}

function Invoke-Download {
    param([string]$Url, [string]$Destination)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Write-Log "下载 ($i/3): $Url"
            $params = @{ Uri = $Url; OutFile = $Destination; UseBasicParsing = $true }
            if ($HttpProxy) { $params['Proxy'] = $HttpProxy }
            Invoke-WebRequest @params
            $size = (Get-Item -LiteralPath $Destination).Length
            Write-Log ("已下载 {0:N1} MB -> {1}" -f ($size / 1MB), $Destination) 'OK'
            return
        } catch {
            Write-Log "下载失败: $($_.Exception.Message)" 'WARN'
            if ($i -lt 3) { Start-Sleep -Seconds 3 }
        }
    }
    Fail "下载失败（已重试 3 次）: $Url"
}

function Expand-ZipArchive {
    param(
        [string]$Zip,
        [string]$Destination,
        # 只删除压缩包自己在 Destination 下展开的那一层目录（避免误删整个 DepsRoot）
        [string[]]$CleanTopLevel = @()
    )
    foreach ($t in $CleanTopLevel) {
        if (-not $t) { continue }
        $p = Join-Path $Destination $t
        if (Test-Path -LiteralPath $p) {
            Write-Log "清空旧目录: $p" 'WARN'
            Remove-Item -LiteralPath $p -Recurse -Force
        }
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        Fail "目标不是目录: $Destination"
    }
    Write-Log "解压: $Zip -> $Destination"
    # Windows 10+ 自带 tar，解 zip 比 Expand-Archive 快得多
    $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    if ($tar) {
        & tar.exe -xf $Zip -C $Destination
        if ($LASTEXITCODE -eq 0) { return }
        Write-Log 'tar 解压失败，回退到 Expand-Archive' 'WARN'
    }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
}

function Ensure-Repo {
    param([string]$Url, [string]$Dir, [switch]$DepthOne, [string]$BranchName = '')
    if (Test-Path -LiteralPath (Join-Path $Dir '.git')) {
        if ($Update) {
            Write-Log "更新仓库: $Dir"
            & git -C $Dir pull --ff-only
            if ($LASTEXITCODE -ne 0) { Write-Log "git pull 失败（继续使用当前版本）" 'WARN' }
        } else {
            Write-Log "已存在仓库: $Dir" 'OK'
        }
        return
    }
    $gitArgs = @('clone')
    if ($BranchName -and $BranchName -ne 'master') { $gitArgs += @('--branch', $BranchName) }
    if ($DepthOne) { $gitArgs += @('--depth', '1') }
    $gitArgs += @($Url, $Dir)
    Write-Log ("git " + ($gitArgs -join ' '))
    & git @gitArgs
    if ($LASTEXITCODE -ne 0) { Fail "克隆失败: $Url" }
    Write-Log "已克隆: $Dir" 'OK'
}

function Test-PathPollution {
    $bad = @('python', 'anaconda', 'miniconda', 'msys', 'mingw', 'cygwin', 'strawberry', 'qt\', 'llvm')
    $hits = New-Object System.Collections.ArrayList
    foreach ($entry in ($env:PATH -split ';')) {
        if (-not $entry) { continue }
        $low = $entry.ToLower()
        foreach ($b in $bad) {
            if ($low.Contains($b)) { [void]$hits.Add($entry); break }
        }
    }
    return ($hits | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# 步骤：权限/环境检查
# ---------------------------------------------------------------------------
function Step-Check {
    Write-Log '===== 1. 环境检查 =====' 'STEP'
    Write-Hr
    $problems = 0
    Resolve-ToolchainPaths

    if ($Script:RootPath) {
        Write-Log ("根目录      : {0}  （工具链 + 源码 + 依赖缓存 + 构建产物都在这个盘）" -f $Script:RootPath)
    }
    Write-Log ("工作区      : {0}" -f $Workspace)
    Write-Log ("工具链目录  : {0}" -f $DepsRoot)
    if ($UseSystemTools) {
        Write-Log '工具链来源  : 先找 <DepsRoot>，缺失时回退系统工具（-UseSystemTools）' 'WARN'
    } else {
        Write-Log '工具链来源  : 只用 <DepsRoot> 里下载的工具（不读系统 PATH 里的 cmake/ninja/python）' 'OK'
    }

    foreach ($p in @($Workspace, $DepsRoot)) {
        if ($p -match '\s') {
            Write-Log "路径包含空格：$p（官方要求不能有空格）" 'WARN'
            $problems++
        }
    }

    # git
    if (Get-Command 'git.exe' -ErrorAction SilentlyContinue) {
        Write-Log ("git         : {0}" -f (Get-VersionOf 'git.exe')) 'OK'
    } else {
        Write-Log '缺少 git（https://git-scm.com/downloads）' 'WARN'
        $problems++
    }

    # cmake
    $cmake = Resolve-Cmake
    if ($cmake) {
        $ver = Get-VersionOf $cmake
        if ($ver -match '([0-9]+\.[0-9]+\.[0-9]+)') {
            $v = $Matches[1]
            if ($v -like '3.31.*') {
                Write-Log ("cmake       : {0} ({1})" -f $v, $cmake) 'OK'
            } elseif ($v -like '4.*') {
                Write-Log ("cmake       : {0} —— CMake 4.x 尚不支持，需要 3.31.x（-Step toolchain 可自动装）" -f $v) 'WARN'
                $problems++
            } else {
                Write-Log ("cmake       : {0} —— 官方要求 3.31.x" -f $v) 'WARN'
                $problems++
            }
        }
    } else {
        Write-Log '缺少 cmake 3.31.x（-Step toolchain 可自动下载便携版）' 'WARN'
        $problems++
    }

    # ninja
    $ninja = Resolve-Ninja
    if ($ninja) {
        Write-Log ("ninja       : {0}" -f (Get-VersionOf $ninja)) 'OK'
    } else {
        Write-Log '缺少 ninja（-Step toolchain 可自动下载）' 'WARN'
        $problems++
    }

    # llvm-mingw
    $clang = Join-Path $Script:LlvmBin 'clang.exe'
    if (Test-Exe $clang) {
        Write-Log ("llvm-mingw  : {0}  ({1})" -f (Get-VersionOf $clang), $Script:LlvmDir) 'OK'
    } else {
        Write-Log ("缺少 llvm-mingw：在 {0} 下没找到 llvm-mingw-*\\bin\\clang.exe（-Step toolchain 可自动下载）" -f $DepsRoot) 'WARN'
        $problems++
    }

    # python：base python 3.13 或"已有 3.13 的 venv"都算满足
    $py = Resolve-Python313
    if ($py) {
        $ver = & $py -c "import sys;print(sys.version.split()[0])"
        Write-Log ("python      : {0} ({1})" -f $ver, $py) 'OK'
    } else {
        $venvPyChk = Join-Path $Script:VenvDir 'Scripts\python.exe'
        $vv = ''
        if (Test-Exe $venvPyChk) {
            try {
                $vv = ((& $venvPyChk -c "import sys;print(sys.version.split()[0])" 2>$null) -as [string]).Trim()
            } catch { $vv = '' }
        }
        if ($vv -like '3.13*') {
            Write-Log ("python      : {0}（来自 venv {1}；base python313 未安装，只有重建 venv 时才需要）" -f $vv, $Script:VenvDir) 'OK'
        } else {
            Write-Log '缺少 Python 3.13（官方要求精确 3.13；可加 -InstallPython 自动安装）' 'WARN'
            $problems++
        }
    }

    # PATH 污染
    $dirty = Test-PathPollution
    if ($dirty.Count -gt 0) {
        Write-Log 'PATH 里可能有干扰项（官方强烈建议清干净）：' 'WARN'
        foreach ($d in $dirty) { Write-Log "    - $d" 'WARN' }
    } else {
        Write-Log 'PATH 未见明显干扰项' 'OK'
    }

    # 磁盘空间（工作区与工具链可能在不同盘符，逐盘检查）
    $seen = @{}
    foreach ($pair in @(@{ P = $Workspace; What = '工作区' }, @{ P = $DepsRoot; What = '工具链' })) {
        $letter = $null
        if ($pair.P -match '^([A-Za-z]):') { $letter = $Matches[1].ToUpper() }
        if (-not $letter) { continue }
        if ($seen.ContainsKey($letter)) { continue }
        $seen[$letter] = $true
        try {
            $ps = Get-PSDrive -Name $letter -ErrorAction Stop
            $freeGB = [math]::Round($ps.Free / 1GB, 1)
            if ($freeGB -lt 40) {
                Write-Log ("盘符 {0} 剩余 {1} GB —— 构建 Krita 建议 40GB 以上（工作区约 25GB + 工具链约 3GB）" -f ($letter + ':'), $freeGB) 'WARN'
            } else {
                Write-Log ("盘符 {0} 剩余 {1} GB" -f ($letter + ':'), $freeGB) 'OK'
            }
        } catch {
            Write-Log ("盘符 {0} 无法读取剩余空间" -f ($letter + ':')) 'WARN'
        }
    }

    Write-Hr
    if ($problems -gt 0) {
        Write-Log ("检查完成：{0} 项需要注意（可执行 -Step toolchain 自动补齐工具链）" -f $problems) 'WARN'
    } else {
        Write-Log '检查完成：全部就绪' 'OK'
    }
}

# ---------------------------------------------------------------------------
# 步骤：工具链
# ---------------------------------------------------------------------------
function Install-Python313 {
    if (Test-Exe $Script:PyLocalExe) {
        Write-Log "已存在 Python 3.13: $($Script:PyLocalExe)" 'OK'
        return
    }
    $installer = Join-Path $DepsRoot ("python-{0}-amd64.exe" -f $Script:PythonVersion)
    if (-not (Test-Path -LiteralPath $installer)) {
        Invoke-Download -Url $Script:PythonUrl -Destination $installer
    }
    $target = Join-Path $DepsRoot 'python313'
    $argList = @(
        '/quiet',
        'InstallAllUsers=0',
        "TargetDir=$target",
        'Include_launcher=0',
        'PrependPath=0',
        'AppendPath=0',
        'Include_doc=0',
        'Include_test=0',
        'Include_pip=1',
        'Include_venv=1'
    )
    Write-Log ("静默安装 Python {0} -> {1}" -f $Script:PythonVersion, $target)
    $proc = Start-Process -FilePath $installer -ArgumentList $argList -Wait -PassThru
    if ($proc.ExitCode -ne 0) { Fail ("Python 安装失败，退出码 {0}" -f $proc.ExitCode) }
    if (-not (Test-Exe $Script:PyLocalExe)) { Fail "安装后仍找不到 $($Script:PyLocalExe)" }
    Write-Log "Python 已就绪" 'OK'
}

function Step-Toolchain {
    if ($SkipToolchain) {
        Write-Log '已指定 -SkipToolchain，跳过工具链下载' 'WARN'
        return
    }
    Write-Log '===== 2. 下载/准备工具链 =====' 'STEP'
    if (-not (Test-Path -LiteralPath $DepsRoot)) {
        New-Item -ItemType Directory -Path $DepsRoot -Force | Out-Null
    }

    # llvm-mingw
    $foundLlvm = Find-LlvmDir
    if ($foundLlvm -and (-not $ForceToolchain)) {
        Write-Log "已存在 llvm-mingw: $foundLlvm" 'OK'
    } else {
        $zip = Join-Path $DepsRoot 'llvm-mingw.zip'
        Invoke-Download -Url $Script:LlvmUrl -Destination $zip
        Expand-ZipArchive -Zip $zip -Destination $DepsRoot -CleanTopLevel @($Script:LlvmFolder)
        if (-not (Test-Exe (Join-Path $Script:LlvmBin 'clang.exe'))) {
            Fail "解压后仍找不到 $($Script:LlvmBin)\clang.exe（压缩包结构可能变了）"
        }
        Write-Log "llvm-mingw 就绪: $($Script:LlvmDir)" 'OK'
    }

    # ninja
    $foundNinja = Find-NinjaExe
    if ($foundNinja -and (-not $ForceToolchain)) {
        Write-Log "已存在 ninja: $foundNinja" 'OK'
    } else {
        $zip = Join-Path $DepsRoot 'ninja.zip'
        Invoke-Download -Url $Script:NinjaUrl -Destination $zip
        if (Test-Path -LiteralPath $Script:NinjaDir) {
            Remove-Item -LiteralPath $Script:NinjaDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $Script:NinjaDir -Force | Out-Null
        Expand-ZipArchive -Zip $zip -Destination $Script:NinjaDir
        if (-not (Test-Exe $Script:NinjaExe)) { Fail "解压后仍找不到 $($Script:NinjaExe)" }
        Write-Log "ninja 就绪: $($Script:NinjaExe)" 'OK'
    }

    # cmake（官方要求 3.31.x；4.x 不支持）
    $existing = Find-CmakeExe
    $needCmake = $true
    if ($existing -and (-not $ForceToolchain)) { $needCmake = $false }
    if ($needCmake) {
        $zip = Join-Path $DepsRoot 'cmake.zip'
        Invoke-Download -Url $Script:CmakeUrl -Destination $zip
        Expand-ZipArchive -Zip $zip -Destination $DepsRoot -CleanTopLevel @($Script:CmakeFolder)
        if (-not (Test-Exe $Script:CmakeExe)) { Fail "解压后仍找不到 $($Script:CmakeExe)" }
        Write-Log "cmake 就绪: $($Script:CmakeExe)" 'OK'
    } else {
        Write-Log "已存在可用 cmake: $existing" 'OK'
    }

    # 重新解析，使后续步骤用上刚装好的工具链
    Resolve-ToolchainPaths

    # python（可选自动安装）
    if ($InstallPython) {
        Install-Python313
    }
    $py = Resolve-Python313
    if (-not $py) {
        Fail '仍未找到 Python 3.13：请自行安装，或加 -InstallPython 让脚本安装'
    }
    Write-Log "python 就绪: $py" 'OK'
}

# ---------------------------------------------------------------------------
# 步骤：venv + 依赖 + env.bat
# ---------------------------------------------------------------------------
function Step-Env {
    Write-Log '===== 3. 准备 Python 环境并获取依赖 =====' 'STEP'

    if ($SkipEnv) {
        if (Test-Path -LiteralPath $Script:EnvBat) {
            Write-Log ("已指定 -SkipEnv：复用 {0}（跳过依赖获取，不联网）" -f $Script:EnvBat) 'WARN'
            return
        }
        Fail "已指定 -SkipEnv，但缺少 $($Script:EnvBat)：先不带 -SkipEnv 跑一次 env"
    }

    # 依赖清单没变 + env.bat 还在 + _install 里确实有依赖 → 直接跳过（不联网）
    $envFp = Get-EnvFingerprint
    $depsPresent = (Test-Path -LiteralPath (Join-Path $Script:InstallDir 'share\ECM\cmake\ECMConfig.cmake')) -or
        (Test-Path -LiteralPath (Join-Path $Script:InstallDir 'lib\cmake\KF5'))

    if ((-not $RefreshEnv) -and $depsPresent -and (Test-Path -LiteralPath $Script:EnvBat) -and
        (Test-Stamp -Path $Script:EnvStamp -Value $envFp)) {
        Write-Log '依赖清单（krita-deps-management / ci-utilities）与上次一致 → 跳过 env（不联网）' 'OK'
        Write-Log '强制刷新: windows\krita-build.bat env -RefreshEnv' 'INFO'
        return
    }
    if ((-not $depsPresent) -and (Test-Path -LiteralPath $Script:EnvBat)) {
        Write-Log ("env.bat 在，但 {0} 里缺依赖（可能被 clean 掉了）→ 需要重新获取依赖" -f $Script:InstallDir) 'WARN'
    }
    if ($RefreshEnv) {
        Write-Log '-RefreshEnv：忽略 env 增量标记，重新联网获取依赖' 'WARN'
    }

    if (-not (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) { Fail '缺少 git' }
    if (-not (Test-Path -LiteralPath $Workspace)) {
        New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
    }

    Ensure-Repo -Url 'https://invent.kde.org/packaging/krita-deps-management.git' -Dir $Script:DepsMgmt
    Ensure-Repo -Url 'https://invent.kde.org/packaging/krita-ci-utilities.git' `
        -Dir (Join-Path $Script:DepsMgmt 'ci-utilities')

    $venvPy = Join-Path $Script:VenvDir 'Scripts\python.exe'
    $venvExists = Test-Exe $venvPy

    # 先看现有 venv 的 Python 版本（官方要求精确 3.13）
    $venvVer = ''
    if ($venvExists) {
        try {
            $venvVer = ((& $venvPy -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null) -as [string]).Trim()
        } catch { }
    }

    if ($venvExists -and (-not $RecreateVenv)) {
        # 关键：venv 已存在且是 3.13 时**根本不需要** base python。
        # 换 -Root / 清理过 deps 之后 <DepsRoot>\python313 可能已经不在了，
        # 但 venv 里带着自己的解释器与 site-packages，完全可以继续用；
        # 以前这里无条件先 Resolve-Python313 并 Fail，会让完好的环境直接报错。
        if ($venvVer -eq '3.13') {
            Write-Log ("复用 venv: {0}（Python {1}）" -f $Script:VenvDir, $venvVer) 'OK'
        } else {
            Write-Log ("注意：现有 venv 的 Python 是 {0}，官方要求 3.13 —— 能跑但不保证一致；建议加 -RecreateVenv 重建" -f $venvVer) 'WARN'
        }
    } else {
        # 需要创建 / 重建 venv 时，才必须有一个 3.13 的 base python
        $py = Resolve-Python313
        if (-not $py) {
            Fail '找不到 Python 3.13（先执行 -Step toolchain，或加 -InstallPython；只有需要新建 venv 时才需要它）'
        }
        if ($venvExists) {
            Write-Log ("-RecreateVenv：删除旧 venv（Python {0}）并重建" -f $venvVer) 'WARN'
            Remove-Item -LiteralPath $Script:VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "创建 venv: $($Script:VenvDir)"
        }
        & $py -m venv $Script:VenvDir --upgrade-deps
        if ($LASTEXITCODE -ne 0) { Fail '创建 venv 失败' }
        if (-not (Test-Exe $venvPy)) { Fail "创建后仍缺少 $venvPy" }
        try {
            $venvVer = ((& $venvPy -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null) -as [string]).Trim()
        } catch { }
        Write-Log ("venv 已创建: {0}（Python {1}）" -f $Script:VenvDir, $venvVer) 'OK'
    }

    Write-Log '安装 requirements.txt（可能需要几分钟）'
    $null = Invoke-LoggedCommand -Exe $venvPy -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip') -WorkingDir $Workspace
    $req = Join-Path $Script:DepsMgmt 'requirements.txt'
    $pipRc = Invoke-LoggedCommand -Exe $venvPy -Arguments @('-m', 'pip', 'install', '-r', $req) -WorkingDir $Workspace
    if ($pipRc -ne 0) {
        Write-Log 'pip install 失败 —— 若上面是 ProxyError / 超时：启动代理或加 -NoProxy；若只是版本冲突请看最后几行' 'WARN'
        Fail 'pip install 失败'
    }

    $setup = Join-Path $Script:DepsMgmt 'tools\setup-env.py'
    if (-not (Test-Path -LiteralPath $setup)) { Fail "缺少 $setup" }

    $llvmBinOk = Test-Exe (Join-Path $Script:LlvmBin 'clang.exe')
    $ninjaOk = Test-Exe $Script:NinjaExe
    if (-not $llvmBinOk -or -not $ninjaOk) {
        Write-Log '警告：llvm-mingw / ninja 尚未就绪，env.bat 里的 PATH 可能缺少它们' 'WARN'
    }

    $argv = @(
        $setup,
        '--full-krita-env',
        '-r', $Workspace,
        '-v', $Script:VenvDir,
        '-p', $Script:LlvmBin,
        '-p', $Script:LlvmSysBin,
        '-p', $Script:NinjaDir
    )
    if ($Branch -and $Branch -ne 'master') { $argv += @('-b', $Branch) }

    # 关键：setup-env.py 会调用 run-ci-build.py，而后者用"当前目录"决定
    # KDECI_WORKDIR_PATH / _install / _build / env 文件的位置。
    # 必须在 $Workspace 里执行，否则会写到调用者的目录（例如本仓库）。
    # Invoke-LoggedCommand 会把 Python 的整段 traceback 同时写进日志（原来只在控制台）。
    #
    # 重试：GitLab/代理偶发 RemoteDisconnected 是常态（节点切换），而 run-ci-build.py
    # 不重试、直接把网络错误说成 "Unable to locate requested dependency"。
    # 这里在"按配置用代理"与"直连"之间交替重试（-EnvRetries，默认 4 次）。
    $attempts = $EnvRetries
    if ($attempts -lt 1) { $attempts = 1 }
    $envOk = $false
    for ($i = 1; $i -le $attempts; $i++) {
        if ($i -gt 1) {
            if (($i % 2) -eq 0) { Use-DirectMode } else { Use-ProxyMode }
            Start-Sleep -Seconds 3
        }
        Write-Log ("setup-env.py  尝试 {0}/{1}" -f $i, $attempts) 'INFO'
        $rc = Invoke-LoggedCommand -Exe $venvPy -Arguments $argv -WorkingDir $Workspace `
            -IdleTimeoutSec $EnvIdleTimeout
        if ($rc -eq 0) { $envOk = $true; break }
        if ($rc -eq 124) {
            Write-Log ("尝试 {0} 因长时间无输出被判定卡死并终止（已自动重试）" -f $i) 'WARN'
            continue
        }
        Write-Log ("第 {0} 次失败（网络抖动/代理断开时很常见；依赖文件本身没坏，会自动换网络模式重试）" -f $i) 'WARN'
    }
    if (-not $envOk) {
        Write-Log 'setup-env.py 重试仍失败：完整 Python 报错见上面（也已写入日志文件）' 'WARN'
        if (Test-Path -LiteralPath $Script:EnvBat) {
            Write-Log ("但 {0} 已存在 → 继续用旧环境往下走（依赖内容没变时这是安全的）" -f $Script:EnvBat) 'WARN'
            # 把"当前依赖清单"记下来：deps-management / ci-utilities 的 commit 没变时，
            # 之后的运行就直接跳过这一步（不再每次联网）。真的更新过依赖请 -RefreshEnv。
            Save-Stamp -Path $Script:EnvStamp -Value $envFp
            Write-Log '已记录依赖状态：下次 deps 清单不变会直接跳过 env（想强制刷新：env -RefreshEnv）' 'INFO'
            return
        }
        if ($NoProxy) {
            Write-Log '本次是 -NoProxy 直连：若报超时，说明需要代理 → 去掉 -NoProxy 并加 -HttpProxy http://127.0.0.1:7890' 'WARN'
        } elseif ($HttpProxy) {
            Write-Log ("本次用代理 {0}：若报 ProxyError，说明代理没开或端口不对" -f $HttpProxy) 'WARN'
        } else {
            Write-Log '若报 ProxyError：启动代理，或用 -NoProxy 直连（TUN/虚拟网卡模式）' 'WARN'
            Write-Log '若报 Unable to locate requested dependency：多半是上面某个请求被网络/代理切断，换节点后重跑' 'WARN'
        }
        Fail 'setup-env.py 执行失败（依赖获取失败）'
    }

    # Windows 上环境文件可能是 env.bat；兼容只有 env 的情况
    if (-not (Test-Path -LiteralPath $Script:EnvBat)) {
        $bare = Join-Path $Workspace 'env'
        if (Test-Path -LiteralPath $bare) {
            Move-Item -LiteralPath $bare -Destination $Script:EnvBat -Force
            Write-Log "已把 env 重命名为 env.bat" 'WARN'
        }
    }
    if (-not (Test-Path -LiteralPath $Script:EnvBat)) { Fail "未生成 $($Script:EnvBat)" }
    Save-Stamp -Path $Script:EnvStamp -Value $envFp
    Write-Log "已生成环境脚本: $($Script:EnvBat)" 'OK'
    Write-Log '已记录依赖增量标记（下次 deps 清单不变会直接跳过 env）' 'INFO'
}

# ---------------------------------------------------------------------------
# 步骤：源码
# ---------------------------------------------------------------------------
function Step-Sources {
    Write-Log '===== 4. 获取 Krita 源码 =====' 'STEP'
    if (-not (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) { Fail '缺少 git' }
    $ref = if ($SourceRef) { $SourceRef } else { $Branch }
    Ensure-Repo -Url $RepoUrl -Dir $Script:SrcDir -DepthOne:$Shallow -BranchName $ref
}

# ---------------------------------------------------------------------------
# 步骤：cmake 配置 / 编译 / 运行
# ---------------------------------------------------------------------------
function Invoke-InEnv {
    param([string]$Command, [string]$WorkingDir)

    if (-not (Test-Path -LiteralPath $Script:EnvBat)) {
        Fail "缺少 $($Script:EnvBat)：先执行 -Step env"
    }
    if (-not (Test-Path -LiteralPath $WorkingDir)) {
        New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null
    }

    $tmp = Join-Path $env:TEMP ('krita-win-' + [guid]::NewGuid().ToString('N') + '.cmd')
    $lines = @(
        '@echo off',
        ('call "' + $Script:EnvBat + '" >nul'),
        ('cd /d "' + $WorkingDir + '"'),
        $Command,
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -LiteralPath $tmp -Value ($lines -join "`r`n") -Encoding ASCII

    Write-Log ("执行: " + $Command)

    # PowerShell 5.1 的坑：$ErrorActionPreference='Stop' 时，把原生命令的 stderr
    # 用 2>&1 合并会被当成 NativeCommandError 直接中止流水线（只能看到第一行）。
    # 这里临时改成 Continue，让 cmake/ninja 的输出完整显示并记录。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 手动写日志（UTF-8），保证与 Write-Log 的编码一致；
        # 不用 Tee-Object，因为 PS5.1 的 Tee 默认写 UTF-16，混在同一文件里会乱码。
        & cmd.exe /d /c ('"' + $tmp + '"') 2>&1 | ForEach-Object {
            Write-Host $_
            if ($Script:LogFile) {
                try { Add-Content -LiteralPath $Script:LogFile -Value $_ -Encoding UTF8 } catch { }
            }
        }
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($rc -ne 0) { Fail ("命令失败，退出码 {0}: {1}" -f $rc, $Command) }
}

function Step-Configure {
    Write-Log '===== 5. CMake 配置 =====' 'STEP'
    if (-not (Test-Path -LiteralPath (Join-Path $Script:SrcDir 'CMakeLists.txt'))) {
        Fail "缺少源码：$($Script:SrcDir)（先执行 -Step sources）"
    }
    if (-not (Test-Path -LiteralPath $Script:EnvBat)) {
        Fail "缺少 $($Script:EnvBat)（先执行 -Step env）"
    }

    if ($CleanBuild -and (Test-Path -LiteralPath $Script:BuildDir)) {
        Write-Log "清空构建目录: $($Script:BuildDir)" 'WARN'
        Remove-Item -LiteralPath $Script:BuildDir -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $Script:BuildDir)) {
        New-Item -ItemType Directory -Path $Script:BuildDir -Force | Out-Null
    }

    # 增量：构建文件在 + 配置输入（目录/编译器/参数）没变 → 跳过 cmake
    $cfgFp = Get-ConfigFingerprint
    $cfgStamp = Get-ConfigStampPath
    if ((-not $CleanBuild) -and (-not $Force) -and
        (Test-Path -LiteralPath (Join-Path $Script:BuildDir 'build.ninja')) -and
        (Test-Stamp -Path $cfgStamp -Value $cfgFp)) {
        Write-Log 'CMake 配置输入未变化（编译器/参数/目录一致）→ 跳过 configure' 'OK'
        return
    }
    if ($Force) { Write-Log '-Force：忽略增量标记，重新运行 cmake 配置' 'WARN' }

    $ninja = Resolve-Ninja
    if (-not $ninja) { Fail '找不到 ninja（-Step toolchain）' }
    # 必须用解析到的 3.31.x 绝对路径：PATH 里可能装了 CMake 4.x（Krita 不支持）
    $cmake = Resolve-Cmake
    if (-not $cmake) { Fail '找不到 cmake 3.31.x（-Step toolchain）' }

    # 显式指定编译器：确保用的是 <DepsRoot> 里那套 llvm-mingw，而不是 PATH 里别的 clang/gcc
    $clang   = Join-Path $Script:LlvmBin 'clang.exe'
    $clangxx = Join-Path $Script:LlvmBin 'clang++.exe'
    if (-not (Test-Exe $clang)) { Fail "找不到 clang：$clang（-Step toolchain）" }
    if (-not (Test-Exe $clangxx)) { Fail "找不到 clang++：$clangxx（-Step toolchain）" }

    $cmd = '"{0}" -S "{1}" -B "{2}" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX="{3}" -DBUILD_TESTING=ON -DINSTALL_BENCHMARKS=ON -DKRITA_ENABLE_PCH=OFF -DHIDE_SAFE_ASSERTS=OFF -DCMAKE_MAKE_PROGRAM="{4}" -DCMAKE_C_COMPILER="{5}" -DCMAKE_CXX_COMPILER="{6}"' -f `
        $cmake, $Script:SrcDir, $Script:BuildDir, $Script:InstallDir, $ninja, $clang, $clangxx

    Invoke-InEnv -Command $cmd -WorkingDir $Script:BuildDir
    Save-Stamp -Path $cfgStamp -Value $cfgFp
    Write-Log 'CMake 配置完成' 'OK'
}

function Step-Build {
    Write-Log '===== 6. 编译并安装 =====' 'STEP'
    if (-not (Test-Path -LiteralPath (Join-Path $Script:BuildDir 'build.ninja'))) {
        Fail "构建目录未配置：$($Script:BuildDir)（先执行 -Step configure）"
    }

    # 增量：源码 HEAD / 未提交改动 / 编译器 / CMake 参数都没变，且 krita.exe 还在
    # → 直接跳过 ninja（省掉 5000+ 目标的一次全量扫描，秒回）
    $exe = Join-Path $Script:InstallDir 'bin\krita.exe'
    $buildFp = Get-BuildFingerprint
    $bStamp = Get-BuildStampPath
    if ((-not $Force) -and (Test-Exe $exe) -and (Test-Stamp -Path $bStamp -Value $buildFp)) {
        Write-Log '源码与配置自上次编译以来没有变化 → 跳过编译（增量）' 'OK'
        Write-Log '强制重编: windows\krita-build.bat build -Force      全量重来: -CleanBuild' 'INFO'
        Write-Log ("已有产物: {0}" -f $exe) 'OK'
        return
    }
    if ($Force) { Write-Log '-Force：忽略增量标记，强制重新编译' 'WARN' }

    $n = $Jobs
    if ($n -le 0) { $n = [Environment]::ProcessorCount }
    Write-Log ("并行任务: {0}" -f $n)
    Invoke-InEnv -Command ("ninja -j{0} install" -f $n) -WorkingDir $Script:BuildDir
    Save-Stamp -Path $bStamp -Value $buildFp
    Write-Log ("安装完成: {0}" -f $Script:InstallDir) 'OK'
    Write-Log '已记录增量标记（下次无改动会跳过编译）' 'INFO'
    Write-Log ("运行：-Step run  或  _install\bin\krita.exe") 'INFO'
}

# llvm-mingw 的运行时 DLL 不会随 Krita 的 make install 一起复制，
# 直接双击 krita.exe 时会提示缺少 libc++.dll / libunwind.dll / libwinpthread-1.dll。
# 这里把它们复制到 _install\bin，让"双击就能跑"。
function Step-Deploy {
    Write-Log '===== 6.5 补齐运行时 DLL（让 krita.exe 可直接双击）=====' 'STEP'

    $binDir = Join-Path $Script:InstallDir 'bin'
    if (-not (Test-Path -LiteralPath $binDir)) {
        Fail "未找到 $binDir（先执行 -Step build）"
    }

    Resolve-ToolchainPaths
    $sources = @($Script:LlvmSysBin, $Script:LlvmBin) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if ($sources.Count -eq 0) {
        Fail '找不到 llvm-mingw 的 bin 目录（-Step toolchain）'
    }

    $names = @('libc++.dll', 'libunwind.dll', 'libwinpthread-1.dll', 'libomp.dll')
    $copied = 0
    foreach ($n in $names) {
        $src = $null
        foreach ($d in $sources) {
            $cand = Join-Path $d $n
            if (Test-Path -LiteralPath $cand) { $src = $cand; break }
        }
        if (-not $src) { continue }

        $dst = Join-Path $binDir $n
        $needCopy = $true
        if (Test-Path -LiteralPath $dst) {
            $a = (Get-Item -LiteralPath $src).Length
            $b = (Get-Item -LiteralPath $dst).Length
            if ($a -eq $b) { $needCopy = $false }
        }
        if ($needCopy) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Log "复制 $n -> $binDir" 'OK'
            $copied++
        }
    }

    if ($copied -eq 0) {
        Write-Log '运行时 DLL 已齐全（无需复制）' 'OK'
    } else {
        Write-Log ("已补齐 $copied 个运行时 DLL") 'OK'
    }

    # Qt 平台插件若不在 bin\platforms，双击时也会报 "could not load the Qt platform plugin"
    $qtPluginSrc = Join-Path $Script:InstallDir 'plugins\platforms'
    $qtPluginDst = Join-Path $binDir 'platforms'
    if ((Test-Path -LiteralPath $qtPluginSrc) -and -not (Test-Path -LiteralPath (Join-Path $qtPluginDst 'qwindows.dll'))) {
        New-Item -ItemType Directory -Path $qtPluginDst -Force | Out-Null
        Copy-Item -Path (Join-Path $qtPluginSrc '*') -Destination $qtPluginDst -Recurse -Force
        Write-Log "复制 Qt 平台插件 -> $qtPluginDst" 'OK'
    }

    Write-Log ("现在可以直接双击: " + (Join-Path $binDir 'krita.exe')) 'OK'
}

function Step-Run {
    Write-Log '===== 7. 运行 Krita =====' 'STEP'
    $exe = Join-Path $Script:InstallDir 'bin\krita.exe'
    if (-not (Test-Exe $exe)) { Fail "未找到 $exe（先执行 -Step build）" }
    $cmd = 'start "" "' + $exe + '"'
    if ($RunArgs) {
        $cmd = $cmd + ' ' + $RunArgs
        Write-Log ("附加参数: {0}" -f $RunArgs)
    }
    Invoke-InEnv -Command $cmd -WorkingDir $Workspace
    Write-Log '已启动 krita.exe' 'OK'
}

function Step-Clean {
    Write-Log '===== 清理 =====' 'STEP'
    if (Test-Path -LiteralPath $Script:BuildDir) {
        Write-Log "删除 $($Script:BuildDir)"
        Remove-Item -LiteralPath $Script:BuildDir -Recurse -Force
        Write-Log '已删除构建目录' 'OK'
    } else {
        Write-Log '构建目录不存在，跳过' 'INFO'
    }
}

# 方便排查：列出日志目录 + 最近 10 个日志 + 最新日志的末尾 40 行
function Step-Logs {
    Write-Log '===== 日志 =====' 'STEP'
    Write-Log ("日志目录 : {0}" -f $Script:LogDir)
    Write-Log ("最新日志 : {0}" -f $Script:LatestLog)

    if (Test-Path -LiteralPath $Script:LogDir) {
        Write-Hr
        Write-Log '最近 10 个构建日志：' 'INFO'
        Get-ChildItem -LiteralPath $Script:LogDir -Filter 'win-build-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 10 |
            ForEach-Object {
                Write-Log ("  {0}  {1,8:N1} KB  {2}" -f $_.LastWriteTime.ToString('MM-dd HH:mm'), ($_.Length / 1KB), $_.Name)
            }
    }

    if (Test-Path -LiteralPath $Script:LatestLog) {
        Write-Hr
        Write-Log '--- latest.log 末尾 40 行 ---' 'INFO'
        Get-Content -LiteralPath $Script:LatestLog -Tail 40 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host $_ }
    } else {
        Write-Log '还没有 latest.log（先执行任意步骤即可生成）' 'WARN'
    }
    Write-Hr
}

function Show-Info {
    Write-Log '===== 当前配置 =====' 'STEP'
    if ($Script:RootPath) { Write-Log ("Root        : {0}" -f $Script:RootPath) }
    Write-Log ("Workspace   : {0}" -f $Workspace)
    Write-Log ("DepsRoot    : {0}" -f $DepsRoot)
    Write-Log ("llvm-mingw  : {0}" -f $Script:LlvmDir)
    Write-Log ("ninja       : {0}" -f $Script:NinjaExe)
    Write-Log ("cmake       : {0}" -f $Script:CmakeExe)
    Write-Log ("python      : {0}" -f (Resolve-Python313))
    Write-Log ("源码        : {0}" -f $Script:SrcDir)
    Write-Log ("构建目录    : {0}" -f $Script:BuildDir)
    Write-Log ("安装目录    : {0}" -f $Script:InstallDir)
    Write-Log ("env.bat     : {0}" -f $Script:EnvBat)
    Write-Log ("日志        : {0}" -f $Script:LogFile)
    Write-Log ("最新日志    : {0}" -f $Script:LatestLog)

    try {
        $exe = Join-Path $Script:InstallDir 'bin\krita.exe'
        $bfp = Get-BuildFingerprint
        if ((Test-Exe $exe) -and (Test-Stamp -Path (Get-BuildStampPath) -Value $bfp)) {
            Write-Log '增量状态    : 无变化 —— build 会直接跳过（-Force 可强制重编）' 'OK'
        } else {
            Write-Log '增量状态    : 需要编译（源码/配置有变化，或缺少产物）' 'WARN'
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
# 计时包装：跑一个步骤并打印耗时（出错也会打印，便于定位慢在哪）
function Invoke-Timed {
    param([string]$Name, [scriptblock]$Body)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
    } finally {
        $sw.Stop()
        Write-Log ("[{0}] 用时 {1:N1}s" -f $Name, $sw.Elapsed.TotalSeconds) 'INFO'
    }
}

function Main {
    # 先确认盘符存在 + 可写，再开始下载（避免下了 2GB 才发现盘符写错）
    Assert-TargetPath -Path $Workspace -What '工作区(-Workspace)'
    Assert-TargetPath -Path $DepsRoot  -What '工具链目录(-DepsRoot)'

    if (-not (Test-Path -LiteralPath $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }
    Resolve-ToolchainPaths
    Write-Hr
    Write-Log ("Krita Windows 构建脚本   step={0}" -f $Step) 'STEP'
    if ($Script:RootPath) {
        Write-Log ("根目录      : {0}（所有下载都会写在这个盘）" -f $Script:RootPath) 'OK'
    }
    Write-Log ("工作区      : {0}" -f $Workspace)
    Write-Log ("工具链目录  : {0}" -f $DepsRoot)
    Write-Log ("日志: {0}" -f $Script:LogFile)
    Write-Log ("最新: {0}" -f $Script:LatestLog)
    Initialize-ProxyEnv
    # Python 的 stdout 被重定向/管道时会块缓冲 —— 不加这个会"看着卡住，其实在跑"
    $env:PYTHONUNBUFFERED = '1'
    Write-Hr

    $total = [System.Diagnostics.Stopwatch]::StartNew()
    switch ($Step) {
        'info'      { Invoke-Timed 'info' { Show-Info } }
        'check'     { Invoke-Timed 'check' { Step-Check } }
        'toolchain' { Invoke-Timed 'toolchain' { Step-Toolchain } }
        'env'       { Invoke-Timed 'env' { Step-Env } }
        'sources'   { Invoke-Timed 'sources' { Step-Sources } }
        'configure' { Invoke-Timed 'configure' { Step-Configure } }
        'build'     { Invoke-Timed 'build' { Step-Build } }
        'deploy'    { Invoke-Timed 'deploy' { Step-Deploy } }
        'run'       { Invoke-Timed 'run' { Step-Run } }
        'clean'     { Invoke-Timed 'clean' { Step-Clean } }
        'logs'      { Step-Logs }
        'all' {
            Invoke-Timed 'check' { Step-Check }
            Invoke-Timed 'toolchain' { Step-Toolchain }
            Invoke-Timed 'env' { Step-Env }
            Invoke-Timed 'sources' { Step-Sources }
            Invoke-Timed 'configure' { Step-Configure }
            Invoke-Timed 'build' { Step-Build }
            Invoke-Timed 'deploy' { Step-Deploy }
            Write-Hr
            Write-Log '全部步骤完成' 'OK'
            Write-Log ("产物: {0}" -f (Join-Path $Script:InstallDir 'bin\krita.exe')) 'OK'
            Write-Log '运行：windows\krita-build.bat run' 'INFO'
        }
    }
    $total.Stop()
    if ($Step -ne 'info' -and $Step -ne 'logs') {
        Write-Log ("总用时 {0:N1}s" -f $total.Elapsed.TotalSeconds) 'INFO'
    }
    Write-Hr
    Update-LatestLog
}

try {
    Main
    exit 0
} catch {
    Write-Log ("失败: " + $_.Exception.Message) 'ERR'
    Write-Log ("日志: " + $Script:LogFile) 'ERR'
    Update-LatestLog
    exit 1
}
