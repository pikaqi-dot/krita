# 在 Windows 上原生构建 Krita（llvm-mingw + Ninja + CMake 3.31）

对应官方文档 [Building on Windows](https://docs.krita.org/en/untranslatable_pages/building_krita_windows.html)。
本目录把那一长串 CMD 手工命令，封装成**一个 PowerShell 脚本 + 一个双击即可的 .bat**，
并且把「环境变量 / PATH / 目录」这些容易出错的点全部自动化。

> 说明：这是**原生 Windows 构建**（生成 `krita.exe`），与本仓库另一套「Android APK」流程互不相干。

**目录**：[文件](#文件) · [快速开始](#快速开始) · [子命令 / 参数](#子命令--参数) ·
[工具链来源](#工具链全部来自-depsroot默认-cdeps不碰系统里装的东西) ·
[官方文档核查](#官方文档有没有过时逐条核查2026-10-实测) · [常见问题](#常见问题) ·
[实测记录](#实测记录本机-windows-11--ryzen-16-核) · [增量构建](#增量构建--日常开发)

---

## 文件

| 文件 | 作用 |
| --- | --- |
| [`krita-build.bat`](krita-build.bat:1) | 双击入口（纯 ASCII，`chcp 65001` + 失败暂停 + 日志） |
| [`build-krita-windows.ps1`](build-krita-windows.ps1:1) | 全部逻辑：检查 / 工具链 / 依赖 / 源码 / 配置 / 编译 / 运行（**UTF-8 with BOM**，PS 5.1 必需） |

---

## 快速开始

```bat
rem 1) 先看环境（不会改任何东西）
windows\krita-build.bat check

rem 2) 一条命令做完全部（缺 Python 3.13 时自动装到 <DepsRoot>\python313）
windows\krita-build.bat all -InstallPython

rem 3) 运行构建出来的 Krita
windows\krita-build.bat run
```

**想放到别的盘？只加一个 `-Root` 就行**（盘符写你机器上真实存在的，C/D/E/F… 都可以）：

```bat
rem 所有东西都进 D 盘：D:\krita\dev（源码/构建/依赖缓存）+ D:\krita\deps（工具链）
windows\krita-build.bat all -Root D:\krita -InstallPython
```

默认布局（全部可用参数改）：

```text
C:\krita-dev\                    <- -Workspace（用 -Root 时是 <Root>\dev）
├── krita\                       <- 源码
├── krita-deps-management\       <- 依赖管理仓库（含 ci-utilities）
├── cache\                       <- 下载的预编译依赖包（重跑只补缺）
├── PythonEnv\                   <- venv（Python 3.13）
├── env.bat                      <- setup-env.py 生成，构建时自动 call
├── _install\                    <- 预编译依赖 + 编译安装结果
├── b_krita\                     <- Ninja 构建目录
└── logs\                        <- 每次运行的完整日志

C:\deps\                         <- -DepsRoot（用 -Root 时是 <Root>\deps）
├── llvm-mingw-20251118-ucrt-x86_64\
├── cmake-3.31.12-windows-x86_64\  (或你自己已有的任意 3.31.x)
├── ninja\ninja.exe
└── python313\                   (用 -InstallPython 时)
```

> 也就是说：**工具链、源码、依赖包缓存、构建产物，全部只写在你指定的盘符里**，
> 不会跑到 `C:` 或其他盘（除了 `%TEMP%` 里临时生成的几 KB `.cmd` 调度文件）。

---

## 子命令 / 参数

| 子命令 | 说明 |
| --- | --- |
| `all` | check → toolchain → env → sources → configure → build |
| `check` | 只检查（git / cmake 3.31.x / ninja / llvm-mingw / Python 3.13 / PATH 污染 / 磁盘） |
| `toolchain` | 下载 llvm-mingw、ninja、cmake 3.31.6 便携版；`-InstallPython` 时静默装 Python 3.13 |
| `env` | 建 venv → pip 安装 requirements → `setup-env.py --full-krita-env` → 生成 `env.bat`（会下载约 100 个预编译依赖包） |
| `sources` | `git clone` krita（`-Shallow` 用浅克隆） |
| `configure` | `cmake -G Ninja ...`（`-CleanBuild` 先清空 `b_krita`）；**配置输入没变则跳过** |
| `build` | `ninja -jN install`；**源码/配置没变且 `krita.exe` 还在 → 整步跳过（秒回）** |
| `deploy` | 把 llvm-mingw 运行时 DLL（`libc++.dll` / `libunwind.dll` / `libwinpthread-1.dll` / `libomp.dll`）与 Qt 平台插件补到 `_install\bin`，让 `krita.exe` **可以直接双击** |
| `run` | 用 `env.bat` 的环境启动 `_install\bin\krita.exe` |
| `clean` | 删除 `b_krita` |
| `info` | 打印当前解析出的所有路径（含 `-Root` 派生结果、增量状态） |
| `logs` | 打印日志目录、最近 10 个 `win-build-*.log`，以及 `latest.log` 的末尾 40 行 |

常用参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Root` | 空 | **推荐**：只给这一个，所有东西都落到该盘 —— `<Root>\dev` 当工作区、`<Root>\deps` 放工具链。例：`-Root D:\krita`、`-Root E:\build\krita`（必须是绝对路径） |
| `-Workspace` | `C:\krita-dev` | 源码/构建/venv/env.bat 所在目录（**不能有空格**）；给了 `-Root` 时可单独覆盖 |
| `-DepsRoot` | `C:\deps` | 工具链根目录（不能有空格）；给了 `-Root` 时可单独覆盖 |
| `-PythonExe` | 自动查找 | 指定 `python.exe`（必须是 3.13） |
| `-InstallPython` | 关 | 缺 Python 3.13 时**自动下载官方安装包并静默装到 `<DepsRoot>\python313`**（不写系统 PATH、不装 py launcher、不需要管理员权限）。已存在则跳过 |
| `-UseSystemTools` | 关 | **默认不用系统工具**；加这个开关才允许回退到 PATH 里的 cmake/ninja/python |
| `-Jobs` | CPU 核数 | `ninja -jN` |
| `-ForceToolchain` | 关 | 重新下载工具链 |
| `-SkipToolchain` | 关 | 跳过下载（工具链已就绪时） |
| `-Force` | 关 | 忽略增量标记：强制重新 configure + 重新 `ninja install`（源码没变也编） |
| `-CleanBuild` | 关 | 配置前清空 `b_krita`（比 `-Force` 更彻底：连缓存一起删） |
| `-Shallow` | 关 | 源码浅克隆 |
| `-Update` | 关 | 对已有仓库执行 `git pull` |
| `-HttpProxy` | 空 | 例：`http://127.0.0.1:7890`。会同时设置 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`（pip、git、python 都生效），并补 `NO_PROXY=localhost,127.0.0.1,::1` |
| `-NoProxy` | 关 | 本次运行**完全绕过代理**（清环境变量 + `NO_PROXY=*`，连 Windows 系统代理一起压过）。TUN/虚拟网卡模式就加它 |
| `-SkipEnv` | 关 | 跳过第 3 步，直接复用已有 `env.bat`（不联网，连检查都不做） |
| `-RefreshEnv` | 关 | 忽略 env 增量标记，**强制联网**重新获取依赖（deps 仓库更新后用） |
| `-EnvRetries` | `3` | `env` 步骤失败重试次数（代理/直连自动交替）；`1` = 不重试 |
| `-EnvIdleTimeout` | `120` | `env` 里单次执行多久没有新输出就判定卡死并终止（秒）；`0` = 不限 |
| `-RecreateVenv` | 关 | 删除重建 `PythonEnv`（现有 venv 的 Python 不是 3.13 时用） |
| `-RunArgs` | 空 | 配合 `-Step run`：传给 `krita.exe` 的参数，如 `-RunArgs "--version"` |
| `-Branch` | `master` | 依赖管理所用的 krita 分支（`krita/5.2` 需要 Python 3.10，见下） |
| `-SourceRef` | 空 | 源码检出的分支/tag（只影响 `sources` 步骤）；留空 = 用 `-Branch`。CI 用它检出 fork 的分支 |
| `-RepoUrl` | `https://invent.kde.org/graphics/krita.git` | Krita 源码仓库地址；CI 里指向自己的 fork |

> 忘了参数名？执行下面这条会打印完整帮助（`.PARAMETER` 里有每个开关的说明）：
>
> ```powershell
> powershell -NoProfile -Command "Get-Help .\windows\build-krita-windows.ps1 -Detailed"
> ```
>
> `.bat` 的用法在文件头注释里（`type windows\krita-build.bat | more`）。

---

## 工具链：全部来自 `-DepsRoot`（默认 `C:\deps`），不碰系统里装的东西

默认模式（不加 `-UseSystemTools`）下，脚本**只在 `-DepsRoot` 里找工具**，完全不看系统 PATH。
下表位置列的都是默认 `-DepsRoot = C:\deps` 时的路径，换了 `-DepsRoot` / `-Root` 就整体跟着变：

| 组件 | 来源 | 位置 |
| --- | --- | --- |
| llvm-mingw 20251118（clang 21） | 下载 zip 解压 | `C:\deps\llvm-mingw-20251118-ucrt-x86_64\` |
| CMake 3.31.x | 下载便携版 zip | `C:\deps\cmake-3.31.12-windows-x86_64\` |
| Ninja | 下载 GitHub release | `C:\deps\ninja\ninja.exe`（也认 `Ninja` 大小写） |
| Python 3.13 | 官方安装包静默安装 | `C:\deps\python313\` |
| 编译器 | **显式传参** `-DCMAKE_C_COMPILER=…\clang.exe`、`-DCMAKE_CXX_COMPILER=…\clang++.exe` | 同上 llvm-mingw |
| 运行时 DLL | `deploy` 步骤复制到 `_install\bin` | `libc++.dll` / `libunwind.dll` / `libwinpthread-1.dll` / `libomp.dll` |

所以你机器上已有的 **CMake 4.2.1、其他 Python、MinGW/MSYS 都不会被用到**（`check` 里也会打印：
`工具链来源 : 只用 <DepsRoot> 里下载的工具（不读系统 PATH 里的 cmake/ninja/python）`）。

仍然需要的外部依赖只有两个，都是"绕不开"的：

1. **Git**（克隆源码/管理仓库用）；
2. **Windows 自带的 UCRT**（Windows 10/11 系统组件，llvm-mingw 的 `-ucrt` 版本链接它）——
   这不是"用系统编译器"，而是操作系统运行库。

想把工具链放到别的盘/目录：

```bat
rem 工具链单独换位置（工作区仍在 C:\krita-dev）
windows\krita-build.bat all -DepsRoot D:\tools\krita-deps

rem 工作区 + 工具链一起换盘（推荐，最省事）
windows\krita-build.bat all -Root D:\krita
```

脚本在下载前会先校验目标盘符：**不存在 / 是光驱（只读）/ 剩余空间不足 5GB** 都会立刻报错，
并列出本机可写的盘符，例如：

```text
工作区(-Workspace) 指向的盘符 D: 不可用：这是光驱（只读，不能当构建目录）。
本机可写的盘符: C: —— 请换成其中之一，例如 -Root C:\krita
```

若确实想复用系统里已装的工具，显式加 `-UseSystemTools`。

---

## 官方文档有没有过时？逐条核查（2026-10 实测）

| 文档内容 | 结论 | 说明 |
| --- | --- | --- |
| `llvm-mingw-20251118-ucrt-x86_64.zip` 链接 | ✅ 仍有效 | 实测 206，可下载 |
| CMake **3.31.x**，4.x 不支持 | ✅ 仍然成立 | 本机 PATH 里是 CMake 4.2.1，配置时直接报错；脚本会强制用 3.31.x 绝对路径 |
| Ninja 从 GitHub releases 下载 | ✅ 仍有效 | 最新 `v1.13.2`，脚本默认用它；也接受你已有的 `<DepsRoot>\ninja` / `<DepsRoot>\Ninja` |
| Python **精确 3.13** | ✅ 仍然成立 | 本机原先只有 3.10/3.12，脚本自动装了 3.13.11；`setup-env.py` 与 PyQt 均需匹配 |
| 5.2 分支要用 Python 3.10 | ✅ 仍然成立 | 两个分支需要两套 Python，都不进 `%PATH%` |
| `setup-env.py --full-krita-env -v PythonEnv -p ...` | ✅ 仍然有效 | `--help` 里三个参数都在，`-p` 可重复 |
| 生成 `env.bat`，每次构建前 `env.bat` | ✅ 仍然有效 | 脚本自动 `call env.bat`，无需手工 |
| `mkdir -p C:\krita-dev\b_krita` | ⚠️ **文档小错** | CMD 不支持 `-p`，会创建一个名为 `-p` 的目录。脚本用 `New-Item` 正确创建 |
| "CI workers 使用 llvm-mingw 20240619 / LLVM 18.1.8" | ⚠️ 描述过时 | 同页上方已经注明 2025-11 切到 `20251118`（clang 21）；以 20251118 为准 |
| `cmake ... -DCMAKE_BUILD_TYPE=RelWithDebInfo` 等开关 | ✅ 仍然有效 | 脚本照抄这些参数 |

另外两个**实测发现**（文档没写）：

1. `setup-env.py` 内部会调用 `run-ci-build.py`，后者用**当前目录**决定 `_install`/`_build`/`env` 写到哪里。
   如果在别的目录调用，会把这堆东西写到调用者目录里（曾经把 `env.bat`、`_build` 写进了本仓库）。
   → 脚本已固定在 `-Workspace` 里执行。
2. 控制台里会出现 `'ccache' is not recognized ...` 与
   `CMake Warning ... CMAKE_PREFIX_PATH variable is not set, we might NOT be able to detect SIP modules`：
   前者是 Windows 上 `use-ccache: False` 的无害提示；后者只影响 **PyQt 插件**
   （`SIP` 包没找到 → Krita 的 Python 插件不构建），不影响 Krita 主体和 `krita.exe`。

---

## 常见问题

**Q：`check` 说 cmake 是 4.x**
A：官方不支持 CMake 4。不用卸载，执行 `windows\krita-build.bat toolchain` 会在
`<DepsRoot>`（默认 `C:\deps`）放一个 3.31.x 便携版；脚本之后都用它的绝对路径。

**Q：`check` 找不到 Python 3.13**
A：`windows\krita-build.bat toolchain -InstallPython`（会下 27MB 安装包，静默装到 `<DepsRoot>\python313`）。
手动装的话，装完保证 `python.exe -V` 是 3.13，并用 `-PythonExe` 指给脚本。

**Q：`-InstallPython` 到底是干什么的？**
A：它是一个**开关**（不用给值），只在 `toolchain` 步骤生效：

1. `<DepsRoot>\python313\python.exe` 已存在 → 直接跳过，不会重复装；
2. 否则下载官方 `python-3.13.11-amd64.exe`（约 27MB）到 `<DepsRoot>`；
3. 用 `TargetDir=<DepsRoot>\python313` 静默安装，附带 `Include_pip=1`、`Include_venv=1`，
   同时 `PrependPath=0`、`Include_launcher=0` —— 所以**不写系统 PATH、不装 py launcher、不污染系统环境**；
4. 装完立即回读版本，不是 3.13 就报错。

为什么一定要 3.13：`krita-deps-management` 的 `requirements.txt`、`setup-env.py` 生成的
`env.bat`、以及 PyQt/SIP 都对 Python 版本敏感，官方要求精确 3.13（3.10/3.12/3.14 都不认）。
一句话：**“缺 3.13 就帮我下官方包、装到我指定的盘、别动系统”**。

**Q：`env` 报 `ProxyError` / `RemoteDisconnected` / `Unable to locate ... ext_xxx`**
A：这**全是网络**，不是依赖缺失。Python 的 `requests` 在 Windows 上会取两种代理来源：

1. `HTTP_PROXY` / `HTTPS_PROXY` 环境变量；
2. **没有环境变量时读注册表里的「系统代理」（WinINET）** —— 这就是"我没设代理、它却走了代理"的原因。

所以 Clash 用 **TUN/虚拟网卡** 时，流量本来已经由网卡接管，但系统代理开关没关（`ProxyEnable=1`、
`ProxyServer=127.0.0.1:7890`），requests 仍然会去连那个 HTTP 端口；节点抖动时就会
`RemoteDisconnected`，而 `run-ci-build.py` 不重试，把网络错误误报成
`Unable to locate requested dependency`。

脚本现在的处理：

| 情况 | 行为 |
| --- | --- |
| 检测到代理（环境变量或注册表） | 先测端口，再**真发一个 HTTPS 请求**验证；不可用 → 自动改直连 `NO_PROXY=*` |
| `env` 步骤失败 | 按 `-EnvRetries`（默认 3）重试，并在**代理 / 直连**之间交替 |
| 依赖清单没变 | **自动跳过第 3 步**（`env.bat` 在 + deps-management/ci-utilities commit 没变）→ `all` 约 5 秒 |
| 想彻底不碰网络 | `-SkipEnv`（连标记检查都省掉） |
| deps 仓库更新了 | `-RefreshEnv` 强制联网重新获取 |
| 重试仍失败，但 `env.bat` 已存在 | **自动回退**：打印警告后继续用旧环境往下走（依赖没变时安全） |
| 执行卡住没输出 | `-EnvIdleTimeout`（默认 120s）到点自动 taskkill 并换模式重试；输出是实时刷新的（不再"假死"） |
| TUN 用户想一步到位 | `-NoProxy` |

```bat
rem 依赖已就绪：完全跳过第 3 步
windows\krita-build.bat all -SkipEnv

rem TUN/虚拟网卡：强制直连
windows\krita-build.bat all -NoProxy

rem 换代理端口 + 多重试几次
windows\krita-build.bat env -HttpProxy http://127.0.0.1:7897 -EnvRetries 6
```

> 注意：`run-ci-build.py` **每次都会联网查 GitLab 的 package_files 列表**（即使依赖已在
> `cache/` 里），所以这一步天生需要网络；`-SkipEnv` 是"依赖没变就别查"的逃生口。

`env` 步骤的 Python 输出（含完整 traceback）现在也会写进
`<Workspace>\logs\win-build-*.log`（以前只在控制台）。

**Q：`venv Python: 3.11.9` 之类的提示**
A：旧版本脚本可能用 pyenv 的 3.11 建过 `PythonEnv`。官方要求 3.13，脚本现在会提示；
用 `-RecreateVenv` 重建即可（会自动用 `-DepsRoot` 里的 3.13 建新 venv 并重装 requirements）。

注意区分：这个提示说的是 **venv 里的** Python，不是系统 `python`。
本机系统 python 是 pyenv 的 3.11.9 完全没关系 —— 只要 `PythonEnv` 里是 3.13 就行，
`-Step check` 会显示 `python : 3.13.11 (...)`。

**Q：`-Root` 换盘后 `-Step env` 报"找不到 Python 3.13"，但 venv 明明是好的？**
A：已修复。venv 一旦存在且里面是 3.13，就**不再需要** `<DepsRoot>\python313` 这个 base python
（venv 带着自己的解释器和 site-packages）；只有"新建 / `-RecreateVenv` 重建"时才需要它。
`-Step check` 也做了同样区分：base python 缺失但 venv 是 3.13 时显示为通过。

**Q：`env` 卡住 / 下载失败**
A：依赖走 GitLab Packages（约 1~2GB）。有代理就加 `-HttpProxy http://127.0.0.1:7890`；
已下载的包会缓存在 `<Workspace>\cache`（默认 `C:\krita-dev\cache`），重跑只补缺
（`KDECI_ALLOW_PACKAGE_OVERRIDE_BY_CACHE=1` 时优先用缓存）。
若报 `Unable to locate requested dependency in the registry: ext_seexpr`，
通常是元数据接口被网络/代理截断 —— 修好代理或换网络后重试即可。

**Q：`configure` 报 `CMAKE_PREFIX_PATH variable is not set ... SIP`**
A：只是警告（PyQt 插件不构建）。要构建 Python 插件请按官方说明处理 SIP/PyQt。

**Q：直接双击 `_install\bin\krita.exe` 提示找不到 DLL**
A：这是 llvm-mingw 构建的正常现象 —— Krita 的 `make install` **不会**复制编译器运行时
（`libc++.dll`、`libunwind.dll`、`libwinpthread-1.dll`），它们只在 `env.bat` 的 PATH 里。
执行一次即可修复：

```bat
windows\krita-build.bat deploy
```

它会把这几个 DLL 复制到 `_install\bin`（并补一份 Qt `platforms\qwindows.dll`），
之后双击 `krita.exe` 就能直接启动。`all` 流程已自动包含这一步。

**Q：编译很慢**
A：默认 `-j<CPU核心数>`。第一次约 **40~60 分钟**（5k+ 个编译单元），之后增量几分钟：
`windows\krita-build.bat build`。

**Q：第二次跑 `build` 什么都没干就结束了？**
A：这是有意的 —— `configure` 与 `build` 各自写一个"增量标记"：

```text
b_krita\.krita-win-config-stamp   <- 源码目录/构建目录/安装前缀/编译器/生成器/CMake 参数
b_krita\.krita-win-build-stamp    <- 上面这些 + krita 的 git HEAD + 未提交改动哈希 + cmake 版本
```

下一次运行时若标记内容与当前一致、且 `_install\bin\krita.exe` 还在，就直接跳过（`info` 里
的「增量状态」也会显示"无变化"）。**动过代码、切换过工具链、改过 CMake 参数，指纹就会变，自动重编**，
不会漏构建。想强制重编：

```bat
windows\krita-build.bat build -Force          rem 忽略标记，重跑 configure + ninja
windows\krita-build.bat configure -CleanBuild rem 删掉 b_krita 从零来（最彻底）
```

**Q：想换盘符 / 换工作区位置**
A：一个参数搞定：`windows\krita-build.bat all -Root D:\krita`
→ 工具链进 `D:\krita\deps`，源码/依赖缓存/构建产物进 `D:\krita\dev`。
想分开指定就同时给 `-Workspace <工作区> -DepsRoot <工具链目录>`（两者必须都是绝对路径、不含空格）。
盘符换成你机器上真实存在的即可（`check` 会打印每个盘符的剩余空间）。

**Q：`-Root` 报「盘符不可用」**
A：脚本只接受**存在、可写、剩余 ≥ 5GB** 的盘符。空光驱（如某些机器的 `D:`）会被拒绝，
提示里会列出本机可写的盘符，挑一个即可；`D:\krita` 这类路径会由脚本自动创建。

**Q：怎么彻底重来**
A：`windows\krita-build.bat clean` 只删构建目录（`b_krita`）；
要连依赖/源码一起重来，直接删整个工作区 `<Workspace>`（默认 `C:\krita-dev`）——
工具链在 `<DepsRoot>`（默认 `C:\deps`），不受影响；连工具链也要重下就再删 `<DepsRoot>`。

**Q：构建日志到底存在哪？**
A：每次运行都会在**工作区的 `logs\`** 下写一份完整日志（默认 `C:\krita-dev\logs\`）：

```text
C:\krita-dev\logs\
├── win-build-20261017-213728.log   <- 本次运行的完整日志（启动时第一行会打印路径）
└── latest.log                      <- 最近一次运行的副本，永远指向最新
```

即：`<Workspace>\logs\win-build-<yyyyMMdd-HHmmss>.log`；
`-Root D:\krita` 时就是 `D:\krita\dev\logs\...`。
每次启动都会打印 `日志:` 和 `最新:` 两行，`info` 里也有 `最新日志 :`。

**Q：`C:\krita-dev\logs\` 里堆了很多 `win-build-*.log`**
A：用项目根的 `clean-logs`（同一个脚本也能清 Android 侧的 `logs/`）：

```bat
rem 只清 Windows 工作区的日志（-y = 不再询问）
clean-logs.bat --dirs "C:\krita-dev\logs" -y

rem 只保留最近 3 个构建日志
clean-logs.bat --dirs "C:\krita-dev\logs" --keep 3 -y

rem 只删 7 天以前的（最近一周的留着）
clean-logs.bat --dirs "C:\krita-dev\logs" --older-than 7 -y

rem 先看看会删什么
clean-logs.bat --dirs "C:\krita-dev\logs" --list
```

---

## 实测记录（本机 Windows 11 + Ryzen 16 核）

```text
check       : git 2.56 / cmake 4.2.1（被拒绝）/ ninja 1.13.1 / clang 21.1.6 / 无 Python 3.13
toolchain   : 复用已有 llvm-mingw + ninja + cmake 3.31.12；自动安装 Python 3.13.11（27.4MB，28s）
env         : venv + requirements 秒过；下载 ~100 个 Windows 预编译依赖（约 4.5 分钟）
sources     : git clone --depth 1，约 39s
configure   : 38.4s 配置 + 15.7s 生成；Qt5/KF5/Boost/Immer/Zug/QuaZip… 全部 found
build       : ninja -j16 install，5093 个目标，约 66 分钟（含 BUILD_TESTING=ON 的测试与基准程序）
结果        : C:\krita-dev\_install\bin\krita.exe（329,728 字节）+ 全部插件/locale/presets
冒烟        : 启动进程后窗口标题为 "Krita"，进程存活，验证后已关闭
```

> 关于 `krita --version`：Windows 上 `krita.exe` 是 GUI 子系统程序，`--version` 不会往控制台打印
> （静默退出码 0），这是正常现象；判断能否运行请看进程/窗口，或直接双击 `krita.exe`。

---

## 增量构建 / 日常开发

```bat
rem 没改代码：直接跳过，几秒结束
windows\krita-build.bat build

rem 改完代码后（只重编受影响的部分）
windows\krita-build.bat build

rem 强制重编（源码没变也编）
windows\krita-build.bat build -Force

rem 改了 CMake 选项/依赖后从零配置
windows\krita-build.bat configure -CleanBuild

rem 想确认"现在到底需不需要编译"
windows\krita-build.bat info
```

`all` 一步到位时同样生效：只要环境、源码、配置都没变，`configure` 与 `build` 都会秒过，
只有真的改过东西才会花时间编译。
