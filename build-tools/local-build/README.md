# Krita for Android 构建脚本（Git Bash / WSL2 友好）

本目录（`build-tools/local-build/`）把官方文档 [Building Krita for Android](https://docs.krita.org/en/untranslatable_pages/building_krita_android.html) 中的全部手工步骤，封装成一套可直接执行的 shell 脚本，覆盖：

- 环境前置检查（Java 17 / Python ≥ 3.10 / cmake / 磁盘空间）
- 安装 Android cmdline-tools、NDK（默认 r27d）、SDK 组件
- 克隆 `krita` / `krita-deps-management` / `krita-ci-utilities`
- 创建 Python venv 并生成 `base-env` / `env` 构建环境
- `cmake` 配置 + `make -jN install`
- 打包 **debug / release / nightly** APK 与 AAB（默认 **arm64-v8a**，真机可直接安装；产物自动复制到 `dist/` 与 Windows 桌面）
- **release 包签名**（`zipalign` + `apksigner`，自动创建本地 keystore 或使用你自己的）
- 迭代重建 + `gradlew installDebug` + 自动启动（真机）
- **增量构建**：源码/配置没变就跳过编译与打包，`--force` 可强制重来
- **产物报告**（`report`）：一条命令看清产物、签名状态、增量标记、体积与剩余磁盘
- Windows 下通过 WSL2 一键执行完整流程（可透传 `--release --sign`）
- Windows 原生构建 `krita.exe`（`windows/`，同样带增量）
- **Linux 桌面版构建并打成 `.deb`**（`deb` 子命令：系统 Qt5/KF5，独立于 Android 流水线）
- 清理缓存 / 日志，释放磁盘空间

> **本目录在仓库中的位置：`build-tools/local-build/`。**
> 它是随 Krita 源码一起分发的"本地构建辅助脚本"：所有命令都在这个目录里执行（先 `cd build-tools/local-build`），
> 脚本只按自身位置推导路径，产物写到 `dist/`、`logs/` 或配置中的 `WORKDIR`，**不会改动 Krita 源码树**。
> 对上游 `KDE/krita` 而言它只是新增文件（外加仓库根的 `.github/workflows/local-build-*.yml`），
> 因此与上游同步（merge / rebase）不会产生冲突。

> 只想动手不想读文档？直接看下面「目录」里的 §〇（点哪个 `.bat`）和 §四（命令一览）。

## 目录

| 章节   | 讲什么                                                                     |
| ---- | ----------------------------------------------------------------------- |
| §〇   | **该点哪个 `.bat`**，以及 `.sh` / `.bat` / `wsl-build.bat` 三个入口的关系             |
| §一   | 为什么必须用 Linux 构建                                                         |
| §二   | 目录结构（每个文件干什么）                                                           |
| §三   | 快速开始（6 步命令 + release 流程）                                                |
| §三之二 | Windows 下用 `.bat` 启动                                                    |
| §三之三 | 在 WSL2 里准备构建环境                                                          |
| §三之四 | **缓存 / 中断续跑 / 增量编译**（什么时候会跳过）                                           |
| §三之五 | Docker 构建（可选）                                                           |
| §四   | **命令一览** + 常用开关 + 示例                                                    |
| §五   | 配置项（`config/android-build.conf`）                                        |
| §六   | 与官方文档的对应关系                                                              |
| §七 | **常见问题 1–36**（含增量、日志清理、产物报告、release 签名、debug/release 区别、Linux deb、入口区别、SDK 许可证、依赖清单） |
| §八   | 环境变量的等价手工命令                                                             |
| §九   | Windows 原生构建（生成 `krita.exe`）                                            |
| §十   | 自检与 CI（lint 检查 + Windows / Android 构建工作流）                                  |
| §十一  | **Linux 桌面版 `.deb`**（`deb` 子命令）                                         |

---

## 〇、我该运行哪个 `.bat`？（先看这里）

**Windows 上只需要一个：[`wsl-build.bat`](entrypoints/wsl-build.bat:1)，双击即可。**

它会自动依次完成：**修网络 → 装工具链（含 JDK 17）→ 完整构建**，每一步都是幂等的（已满足就自动跳过），可以随时重复运行。

> 所有双击快捷方式都放在 **`entrypoints/`** 子目录；下文表格与示例按文件名简写。
> 在命令行里从本目录调用时写 `entrypoints\wsl-build.bat`，或直接用根目录的 `build-android.bat <子命令>`。

其余 `.bat` 都是辅助与排查用的：

| 文件                  | 什么时候用                                                      | 等价命令           |
| ------------------- | ---------------------------------------------------------- | -------------- |
| `build-android.bat` | 通用入口：任何子命令都能从这里走（如 `build-android.bat deb --check-deps`）   | 任意子命令          |
| **`wsl-build.bat`** | **⭐ 默认点这个：Windows 上从环境准备一路做到 APK**                         | `wsl-oneclick` |
| `wsl-check.bat`     | 只想看 WSL 里缺什么（不做任何修改）                                       | `wsl --check`  |
| `wsl-setup.bat`     | 只想安装/修复 WSL 里的工具链                                          | `wsl-install`  |
| `wsl-network.bat`   | apt / git 超时，怀疑网络或代理                                       | `wsl-network`  |
| `check.bat`         | 检查 Windows 侧（Git Bash、JDK、配置解析）                            | `check`        |
| `report.bat`        | 看"手上的 APK 是不是最新的"（体积 / ABI / HEAD / 增量标记 / 剩余磁盘，只读）        | `report`       |
| `setup-sdk.bat`     | 安装 Android SDK / NDK                                       | `sdk`          |
| `build-all.bat`     | 当前已经处在 Linux/WSL 环境里时用；Windows 上请优先 `wsl-build.bat`        | `all`          |
| `docker-build.bat`  | **可选**：想在 Docker 容器里构建（可复现环境）时用                            | `docker`       |
| `clean-logs.bat`    | `logs/` 太大时清日志（`--keep N` 留最近几个、`--older-than N` 只删 N 天前）  | `clean-logs`   |
| `deb.bat`           | 构建 **Linux 桌面版** Krita 并打成 `.deb`（在 WSL 里跑；Android 流程不受影响） | `deb`          |

> 所有 `.bat` 都把完整输出写入 `logs/latest.log`，失败时窗口不会立刻关闭。
> 只想先验证环境而不想跑长构建：`wsl-build.bat --prepare-only`。
> 想要 release 包（含签名）：`wsl-build.bat --release --sign`（参数会一路透传到 `all`）。
> **默认不走 Docker**；只有显式执行 `docker` / 双击 `docker-build.bat` 才会用容器。

### 三个入口的关系：`.sh` / `.bat` / `wsl-build.bat`

常被问到"为什么有两个 `build-android`"。答案是：**一份逻辑 + 两个平台外壳 + 一个预设快捷方式**。

```text
                      ┌─ build-android.sh        ← 唯一实现（bash，16 个子命令 + 别名）
Linux / WSL / Git Bash ┘         ↑
                                 │  bash scripts/run.sh <cmd>（实时输出 + 写 logs/latest.log）
Windows cmd / 双击 ─── build-android.bat ─┘
                        entrypoints/wsl-build.bat = call ..\build-android.bat wsl-oneclick %*
```

| 文件                                         | 角色             | 具体做什么                                                                                                                                                                                          |
| ------------------------------------------ | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`build-android.sh`](build-android.sh:1)   | **核心分发器**      | 真正的逻辑入口：`check` / `sdk` / `sources` / `deps` / `build` / `apk` / `sign` / `dev` / `deb` / `report` / `all` / `docker` / `wsl*` / `clean` / `clean-logs` / `env`。必须在 Linux / WSL / Git Bash 下运行 |
| [`build-android.bat`](build-android.bat:1) | **Windows 外壳** | 不实现业务，只做四件事：① 显式定位 **Git Bash**（并**拒绝** `C:\Windows\System32\bash.exe`——那是 WSL 启动器，会立刻关窗口）② `chcp 65001` ③ 调 `scripts/run.sh`（记录日志）④ 失败或双击时保持窗口                                                |
| [`wsl-build.bat`](entrypoints/wsl-build.bat:1)         | **预设快捷方式**     | 正文就一句 `call ..\build-android.bat wsl-oneclick %*`，即"修网络 + 装工具链 + 在 WSL 里跑 `all`"                                                                                                                  |

为什么不能合并成一个：Windows 不认识 shebang，`cmd` 执行不了 `.sh`；Linux 也执行不了 `.bat`。这是平台边界，不是冗余。

等价写法：

| 想做的事           | cmd / 双击                                 | Git Bash / WSL                    |
| -------------- | ---------------------------------------- | --------------------------------- |
| 完整构建（含环境准备）    | `wsl-build.bat`                          | `./build-android.sh wsl-oneclick` |
| 任意单步           | `build-android.bat apk --force`          | `./build-android.sh apk --force`  |
| release 包 + 签名 | `build-android.bat all --release --sign` | 同左                                |
| Linux 桌面 deb   | `deb.bat`                                | `./build-android.sh deb`          |
| 看帮助            | `build-android.bat`（不带参数）                | `./build-android.sh --help`       |

> `.bat` 的**帮助已经委托**给 `build-android.sh help`（单一事实来源），所以两边列出的命令永远一致。
> 早期 `.bat` 里手抄过一份英文列表，结果漏掉了 `sign` / `deb` / `report`、也没提 `--release`
> —— 这类"两个入口各维护一份列表"的漂移，现在由 [`scripts/check-docs.sh`](scripts/check-docs.sh:1) 兜底。

两个常见误解：

1. **`wsl-build.bat check` 并不会"只检查环境"**。它固定执行 `wsl-oneclick`，`check` 会作为多余参数一路透传到 `all`，
   被 `90-build-all.sh` 忽略后**照样跑完整构建**。只想检查请用 `wsl-check.bat` 或 `build-android.bat check`。
2. **`build-android.sh` 不能在 `cmd` 里直接执行**。它用 bash 语义与 `/c/...` 路径（还依赖 `cygpath` 做转换），
   只在 Git Bash / WSL / Linux 下有效；Windows 上请走 `.bat`。

---

## 一、重要前提：必须使用 Linux 构建

官方文档明确写明：

> Use Linux to build Krita for Android. Building Krita for Android on another system is NOT supported yet.
> 使用 Linux 构建 Android 版 Krita。目前尚不支持在其他系统上构建 Android 版 Krita。

因此在不同系统上的可用范围如下：

| 环境                     | 可以做什么                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| **Linux / WSL2**       | 全部功能（完整构建 → APK/AAB）                                                                         |
| **Windows + Git Bash** | 环境检查、SDK/NDK 安装、源码拉取、`adb install`/`adb logcat`（需真机）、驱动 WSL2 构建；**不能**在 Git Bash 里直接编译 Krita |
| **macOS**              | 官方不支持，仅可参考                                                                                   |

Windows 上无需纠结，直接用 [`99-wsl-build.sh`](scripts/99-wsl-build.sh:1)：它在 Git Bash 里调用 `wsl.exe`，把整个流程交给 WSL2 中的 Linux 执行，即：

```bash
./build-android.sh wsl --check     # 检查 WSL2 环境与依赖
./build-android.sh wsl all         # 一键完整构建
```

---

## 二、目录结构

```
build-tools/local-build/                # ← 本目录（位于 Krita 源码仓库内）
├── README.md                           # 本文档
├── build-android.sh                    # ★ 统一入口（Git Bash / WSL / Linux）
├── build-android.bat                   # ★ 同一入口的 Windows 外壳（含日志与错误暂停）
├── entrypoints/                        # Windows 双击快捷方式（只做参数转发）
│   ├── wsl-build.bat                   # ⭐ 推荐：修网络 → 装工具链 → 完整构建
│   ├── wsl-check.bat                   # 检查 WSL2 发行版依赖（只读）
│   ├── wsl-setup.bat                   # 在 WSL 内装齐工具链
│   ├── wsl-network.bat                 # 修复 WSL 网络 / 代理
│   ├── check.bat                       # 环境检查
│   ├── setup-sdk.bat                   # 安装 Android SDK / NDK
│   ├── build-all.bat                   # 完整流程（已在 Linux 环境里时用）
│   ├── docker-build.bat                # 在 Docker 容器内构建（可选）
│   ├── report.bat                      # 产物 / 增量状态报告（只读）
│   ├── clean-logs.bat                  # 清理日志
│   └── deb.bat                         # 构建 Linux 桌面版并打 .deb（走 WSL）
├── config/
│   └── android-build.conf.example      # 配置示例（复制为 android-build.conf 后修改）
├── docker/
│   └── Dockerfile                      # Docker 构建镜像（只含工具链，不含 SDK/NDK）
├── scripts/
│   ├── lib/                            # 公共库（被各步骤脚本 source）
│   │   ├── common.sh                   # 日志 / 路径转换 / 下载 / 解压
│   │   ├── android-env.sh              # 配置解析、变量导出、Android 工具封装
│   │   └── wsl.sh                      # WSL2 探测 / 安装 / 网络修复
│   ├── run.sh                          # .bat 的日志包装器（实时输出 + 落盘 + 退出码 + 每 30s 磁盘）
│   ├── 00-check-prereqs.sh             # 环境前置检查
│   ├── 10-setup-sdk.sh                 # cmdline-tools + NDK + SDK 组件
│   ├── 20-fetch-sources.sh             # 克隆源码与仓库
│   ├── 30-fetch-deps.sh                # Python venv + base-env + env
│   ├── 40-build-krita.sh               # cmake 配置 + 编译安装（带增量指纹）
│   ├── 50-build-package.sh             # 打包 APK / AAB / release / nightly
│   ├── 55-sign-apk.sh                  # APK release 签名（zipalign + apksigner）
│   ├── 60-docker-build.sh              # Docker 容器内构建（可选）
│   ├── 65-build-linux-deb.sh           # Linux 桌面版构建 + dpkg-deb
│   ├── 70-dev-rebuild.sh               # 迭代重建 + 安装 + 启动（真机）
│   ├── 90-build-all.sh                 # 一键完整流程（--from / --only）
│   ├── 94-wsl-network.sh               # WSL2 网络 / 代理诊断与修复
│   ├── 95-wsl-install-deps.sh          # 在 WSL 发行版内装工具链
│   ├── 96-wsl-oneclick.sh              # 一键：修网络 + 装工具链 + 完整构建
│   ├── 99-wsl-build.sh                 # Windows 下经 WSL2 执行
│   ├── clean.sh                        # 清理产物 / 缓存 / SDK
│   ├── clean-logs.sh                   # 清理日志（--keep / --older-than）
│   ├── report.sh                       # 产物 + 增量状态报告（只读，--json）
│   ├── check-syntax.sh                 # 全部脚本 bash -n
│   ├── check-powershell.ps1            # Windows 脚本 BOM / CRLF / AST 检查
│   ├── check-docs.sh                   # 文档一致性（命令表 / 目录树 / FAQ 编号）
│   └── fix-line-endings.sh             # 统一行尾（*.sh=LF，*.bat/*.ps1=CRLF）
├── windows/                            # Windows 原生构建（生成 krita.exe）
│   ├── build-krita-windows.ps1         # 主脚本（-Step check/toolchain/env/sources/build/run/logs）
│   ├── disk-monitor.ps1                # 构建期间每 30 秒打印磁盘剩余空间
│   ├── krita-build.bat                 # 双击包装
│   └── README.md                       # 参数、FAQ、实测记录
├── logs/                               # 运行期日志（已忽略；latest.log 为最近一次）
├── .gitattributes                      # 本目录行尾策略（作用于整个子树）
└── .gitignore                          # 只提交脚本/文档/示例，忽略产物与个人配置
```

---

## 三、快速开始（Linux / WSL2）

```bash
# 进入本套脚本所在目录（相对 Krita 仓库根）
cd build-tools/local-build

# 0) （可选）个性化配置：主要修改 ANDROID_ROOT / WORKDIR
cp config/android-build.conf.example config/android-build.conf

# 1) 环境检查（Java 17、Python >= 3.10、cmake、磁盘空间）
./build-android.sh check

# 2) 安装 Android SDK / NDK / cmdline-tools
./build-android.sh sdk

# 3) 获取源码
./build-android.sh sources

# 4) 准备构建环境（venv + base-env + env）
./build-android.sh deps

# 5) 编译 Krita
./build-android.sh build

# 6) 打包 APK（加 --aab 同时生成 AAB）
./build-android.sh apk
```

也可以一条命令走完：

```bash
./build-android.sh all --jobs 8
./build-android.sh all --from 40          # 从“编译 Krita”开始
./build-android.sh all --only 6 --aab     # 只执行打包并生成 AAB
```

**要 release 包（可上架/分发）**：

```bash
./build-android.sh apk --release      # 或 all --release：gradlew assembleRelease
./build-android.sh sign               # 签名（第一次会自动建本地 keystore）
./build-android.sh report             # 核对：产物、签名状态、增量标记

# Windows 双击党：参数会一路透传，一条命令搞定
#   entrypoints\wsl-build.bat --release --sign
#   entrypoints\wsl-build.bat --release --sign --from 6   （只重打+签名，不重编）
```

细节见 [FAQ 30（产物报告）](#30-手上的-apk-是不是最新的要不要重编) 与
[FAQ 31（release 与签名）](#31-怎么打-release-包并签名)。

Windows（Git Bash）用户：

```bash
./build-android.sh wsl --check
./build-android.sh wsl all --jobs 8
```

---

## 三之二、Windows 下用 .bat 启动（双击即可）

> 如果你双击 `.bat` 后窗口一闪就消失、错误信息看不到，原因基本是这两个：
> 
> 1. PATH 里的 `bash` 其实是 `C:\Windows\System32\bash.exe`（**WSL 启动器**，不是 Git Bash）。它不认识 `/c/...` 这类 MSYS 路径，会立刻退出；
> 2. 脚本报错后 cmd 直接关窗，错误随之消失。

本目录的 [`build-android.bat`](build-android.bat:1) 已针对这两点做了处理：

- 依次从 `%KRITA_BASH%`、`%ProgramFiles%\Git\bin\bash.exe`、`%ProgramFiles(x86)%\Git\...`、`%LocalAppData%\Programs\Git\...`、scoop 目录以及 `where git.exe` 推导的位置查找 Git Bash；
- 主动识别并**拒绝** WSL 的 `bash.exe`（先比对路径，再探测 `$OSTYPE` 是否含 `linux`）；
- 输出**实时显示在窗口**，同时完整写入 `logs/` 目录（`logs/latest.log` 永远是最新一次）；
- 失败时打印退出码与日志路径；**双击**启动（或 `cmd /c 文件.bat`）时自动 `pause`，窗口不会消失；
- 从已打开的终端运行时不会额外 pause，方便连续在命令行里用。

双击即可的快捷方式（都在 `entrypoints/` 下，双击后会自动定位到本目录）：

| 文件                                                 | 等价命令                                                    |
| -------------------------------------------------- | ------------------------------------------------------- |
| [`check.bat`](entrypoints/check.bat:1)             | `build-android.bat check`                               |
| [`setup-sdk.bat`](entrypoints/setup-sdk.bat:1)     | `build-android.bat sdk`                                 |
| [`build-all.bat`](entrypoints/build-all.bat:1)     | `build-android.bat all`                                 |
| [`wsl-build.bat`](entrypoints/wsl-build.bat:1)     | `build-android.bat wsl all`（**Windows 上推荐**）            |
| [`wsl-check.bat`](entrypoints/wsl-check.bat:1)     | `build-android.bat wsl --check`（检查 WSL2 发行版里的工具链）   |
| [`wsl-setup.bat`](entrypoints/wsl-setup.bat:1)     | `build-android.bat wsl-install`（自动装齐 WSL 里的工具链）     |
| [`wsl-network.bat`](entrypoints/wsl-network.bat:1) | `build-android.bat wsl-network`（修代理/网络）                 |
| [`docker-build.bat`](entrypoints/docker-build.bat:1) | `build-android.bat docker`（可选：容器内构建）                |
| [`report.bat`](entrypoints/report.bat:1)           | `build-android.bat report`（只读：产物 / 增量状态）              |
| [`clean-logs.bat`](entrypoints/clean-logs.bat:1)   | `build-android.bat clean-logs`                          |
| [`deb.bat`](entrypoints/deb.bat:1)                 | `build-android.bat deb`（Linux 桌面版 `.deb`）              |

参数与 `.sh` 完全一致：

```bat
build-android.bat check
build-android.bat sdk --dry-run
build-android.bat apk --aab
set KRITA_BAT_NOPAUSE=1 && build-android.bat all
set "KRITA_BASH=C:\Program Files\Git\bin\bash.exe" && build-android.bat env
```

可用的额外环境变量：

| 变量                    | 作用                             |
| --------------------- | ------------------------------ |
| `KRITA_BASH`          | 指定 Git 的 `bash.exe` 路径（跳过自动查找） |
| `KRITA_BAT_NOPAUSE=1` | 结束后不暂停                         |
| `KRITA_LOG_DIR`       | 自定义日志目录（默认 `logs/`）            |

> `build-android.bat` 内部刻意只用 ASCII 文本：cmd.exe 切换代码页时解析含 UTF-8 中文的批处理可能出错。窗口里的中文输出来自 bash 脚本本身，靠 `chcp 65001` 正常显示。若仍乱码，请在 Windows Terminal 中运行，或把控制台字体换成支持中文的字体。
> 
> 行尾已由 [`fix-line-endings.sh`](scripts/fix-line-endings.sh:1) 统一（`*.sh` = LF、`*.bat` = CRLF）。若脚本是从别处拷贝来的、出现 `$'\r'` 报错，执行一次：
> 
> ```bash
> ./scripts/fix-line-endings.sh
> ```

---

## 三之三、在 WSL2 里准备构建环境（Windows 推荐路线）

Windows 上真正的编译由 WSL2 里的 Linux 完成，所以发行版内必须先装好工具链。

**最省事的方式（一条命令搞定网络 + 工具链）**：

```bash
./build-android.sh wsl-install        # 或双击 wsl-setup.bat
```

它会依次完成：

1. **网络检查**：宿主机代理在发行版内可达时，写入 `/etc/apt/apt.conf.d/99-krita-proxy` 与 `/etc/profile.d/99-krita-proxy.sh`；否则写入 `.wslconfig` 的 `networkingMode=mirrored` 并重启 WSL；
2. `apt-get install` 基础工具链（用 `pkgconf` 提供 `pkg-config`）；
3. **JDK 17**：优先 `openjdk-17-jdk`；仓库没有时（Debian 13 / trixie 已移除）自动改用 Adoptium Temurin 17，解压到 `/opt/jdk17` 并配置 `/etc/profile.d/jdk17.sh` 与 `/usr/local/bin` 软链接；
4. 复查并打印结果（实测最终会显示 `javac 17.0.20.1` 与 `发行版工具链就绪`）。

若只想自检，不安装：

```bash
./build-android.sh wsl --check        # 或双击 wsl-check.bat
```

输出示例（本机实测）：

```
==> 发行版环境检查
    distro      : Debian GNU/Linux 13 (trixie)
    kernel      : Linux 6.18.54.1-microsoft-standard-WSL2 x86_64
    home        : /home/along
    cpus        : 16
    git         : git version 2.47.3
    unzip       : 缺失
    cmake       : cmake version 3.31.6
    ninja       : 1.12.1
    g++         : g++ (Debian 14.2.0-19) 14.2.0
    pkg-config  : 缺失
    python3     : Python 3.13.5
    java        : 缺失
    javac       : 缺失
  当前判定缺失/不合规: unzip pkg-config java javac
```

若想手工装（**`javac` 必须是 17**）：

```bash
wsl -d Debian
sudo apt update
sudo apt install -y build-essential cmake ninja-build pkgconf git \
    curl unzip python3 python3-pip python3-venv
sudo apt install -y openjdk-17-jdk || echo "仓库里没有 17 -> 交给 wsl-install 走 Temurin 17"
```

> 两个实测坑（脚本已自动处理）：
> 
> 1. **Debian 13 (trixie) 仓库里没有 `openjdk-17-jdk`**（`pkg-config` 也已由 `pkgconf` 取代）；
> 2. **Windows 开着系统代理（例如 `127.0.0.1:7890`）并用 fake-IP DNS 时，NAT 模式的 WSL 会把域名解析到 `198.18.x.x` 黑洞**，apt / git 全部超时。用 `./build-android.sh wsl-network`（或 `wsl-network.bat`）修复，或让代理软件开启 Allow LAN。

补齐后即可开始构建：

```bash
./build-android.sh wsl all --jobs 8   # 或双击 wsl-build.bat
```

`99-wsl-build.sh` 的行为说明：

- 进入发行版前会先探测环境；**关键依赖缺失时直接中止**并打印上面那条 `apt` 命令（不想中止可加 `--force`）；
- 发行版内缺少 `make` 但装了 `ninja` 时只告警（CMake 会用 Ninja 生成器）；
- 所有 `wsl.exe` 调用都带 `WSL_UTF8=1`，避免 UTF-16 导致的乱码；
- 探测脚本写到 `logs/wsl-probe.sh` 再交给发行版执行，避免多行脚本被命令行参数破坏。

> **不要把 `.sh` 文件双击运行**（包括 `99-wsl-build.sh`）：Windows 会为它新开一个控制台，脚本一结束窗口就关闭 —— 这就是"闪退"。
> 请统一用 `.bat`。若确实要直接运行 `.sh`：本套脚本在 Windows + 交互式终端下**失败时会显示 `--- 按 Enter 键关闭窗口 ---`** 并等你按键（`KRITA_HOLD=0` 关闭该行为，`KRITA_HOLD=1` 强制总是等待）。

---

## 三之四、缓存 · 中断续跑 · 增量编译

**默认行为（不需要任何参数，绝不重复下载 / 重复编译）**：

| 环节                      | 默认行为                                                         |
| ----------------------- | ------------------------------------------------------------ |
| SDK / NDK               | 压缩包已在 `$ANDROID_ROOT/dl`、目录已存在 => 直接复用                       |
| 源码                      | 已克隆就复用（只有 `--update` 才 `git fetch/pull`）                     |
| Python venv / pip       | 复用 venv；依赖已装则秒过                                              |
| KDE 预编译依赖               | 复用 `_install` 与 `$KDECI_CACHE_PATH` 缓存                       |
| cmake 配置                | `_build/CMakeCache.txt` 存在则跳过配置                              |
| 编译                      | **先比对增量指纹**：没变化 → 整步跳过（秒回）；有变化 → `make install` 增量，只重编改动过的文件 |
| Gradle 打包               | **先比对增量指纹**：没变化且 APK 在 → 跳过 Gradle；复制产物时也会跳过已是最新的副本          |
| Windows exe（`windows/`） | 同上：configure / ninja 各有自己的 stamp，无变化直接跳过                     |

**增量指纹是什么**（`40-build-krita.sh` / `50-build-package.sh` 各写一个 stamp 文件）：

```text
_build/.krita-build-stamp      <- 编译成功后写入
_packaging/.krita-package-stamp <- 打包成功后写入
内容 = fp1|abi=arm64-v8a|api=23|ndk=... |btype=RelWithDebInfo|cc=<编译器版本>
       |src=<krita HEAD>|dirty=<未提交改动的哈希>|deps=<deps-management HEAD>
       |tc=<android-toolchain-krita.cmake 的哈希>|prefix=<安装目录>
```

打包 stamp 在此基础上还会追加两项（所以两者不会互相干扰）：

```text
_packaging/.krita-package-stamp  = <上面的指纹>|aab=<0|1>|type=<release|nightly，debug 省略>
```

`btype=RelWithDebInfo` 是**编译**类型（C++ 怎么编）；`type=release` 是**打包**类型
（Gradle 怎么打），两者互相独立，见 [FAQ 32](#32-debug-还是-release-这两层到底有什么区别)。
所以 debug / release 交替打时，打包 stamp 每次都会失配 → 重新打包（这是正确行为）。

只要这里面**任何一项**变了（改代码、切分支、切 ABI、换 NDK/编译器、改工具链文件、
改安装前缀、宿主机 ↔ Docker 混用），指纹就变，自动重新编译 —— 不会漏掉该做的构建。
`sdk` / `sources` / `deps` 三步不受影响（它们本来就有自己的存在性判断）。

**中断了怎么继续（推荐）**：

```bat
entrypoints/wsl-build.bat --resume      rem 自动从"第一个未完成的步骤"继续
entrypoints/wsl-build.bat --from 40     rem 或手动指定：从"编译"起（50 = 打包）
```

`--resume` 的判定顺序：NDK/SDK → 源码 → `env` → 已安装的 `libkrita*.so` → 已产出的 APK，
第一个不满足的步骤就是起点；全部完成时默认回到第 5 步做增量重编。

**想强制重来**：

| 需求                     | 参数                                       | 等价于                                    |
| ---------------------- | ---------------------------------------- | -------------------------------------- |
| 忽略增量指纹、强制重编 + 重打包      | `--force`（`build` / `apk` / `all` 都认）    | 删两个 `.krita-*-stamp`                   |
| 重新下载 SDK / NDK         | `--force-download`                       | 删 `~/android/dl`、`~/android/sdk/ndk/*` |
| 重新克隆源码                 | `--force-reclone`                        | 删 `~/persistent/sources/krita`         |
| 全量重新编译（连 `_build` 一起清） | `--clean-build`                          | 删 `.../krita/_build`                   |
| 清理所有产物与缓存              | `./build-android.sh clean --all --force` | —                                      |

**耗时参考（本机实测）**：SDK/NDK 下载约 2 分钟（NDK 1.1GB）· 源码浅克隆约 2 分钟 ·
依赖与 env 约 1 分钟 · **首次编译约 40 分钟** · 打包约 3 分钟。
之后改代码的增量构建通常 **1~5 分钟**。

---

## 三之五、Docker 构建（可选，默认不走 Docker）

**默认路线仍然是宿主机 / WSL2**（第 1~6 步直接跑）。Docker 只是"另一种可选执行方式"，
适合想要可复现工具链、或 CI 场景。两者是互斥选择，不会自动切换。

### 1. 准备 Docker（在 WSL2 里）

```bash
# 方案 A：Docker Desktop → Settings → Resources → WSL Integration 打开 Debian
# 方案 B：发行版内自装
sudo apt install -y docker.io
sudo service docker start
docker info          # 能输出信息就绪
```

### 2. 首次：构建镜像（约 1~2 分钟）

```bash
./build-android.sh docker --build-image
```

镜像来自 [`docker/Dockerfile`](docker/Dockerfile:1)（Ubuntu 24.04 + cmake/ninja/gcc/
python3/ccache/JDK 17）。**镜像里不含 Android SDK/NDK**，它们从宿主机挂进去复用。

> **镜像是自己构建的，不是从 Hub 拉的现成构建镜像。**
> 底座是官方 `ubuntu:24.04`（119MB，从 Docker Hub 或其镜像源拉取），
> 其余约 1.1GB 是本目录 Dockerfile 用 apt 装出来的工具链，最终
> `krita-android-build:local` 约 **1.23GB**。
> Docker Hub 直连失败时（本机实测 `registry-1.docker.io` 报 EOF），
> 脚本会自动改用 `docker.m.daocloud.io` 重试并提示；也可显式指定：
> 
> ```bash
> KRITA_DOCKER_BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04 \
>   ./build-android.sh docker --build-image
> ```

### 3. 之后：在容器里构建

```bash
./build-android.sh docker                       # 完整 6 步
./build-android.sh docker --from 5 --jobs 8     # 只编译+打包
./build-android.sh docker --shell ./scripts/50-build-package.sh
KRITA_DOCKER_IMAGE=my/krita:latest ./build-android.sh docker   # 用自己的镜像
KRITA_DOCKER_EXTRA="-m 16g --cpus 8" ./build-android.sh docker # 限制资源
```

Windows 上直接双击 [`docker-build.bat`](entrypoints/docker-build.bat:1)（会自动转给 WSL2 执行）。

### 4. 容器里挂载了什么

| 宿主路径                         | 说明                                   |
| ---------------------------- | ------------------------------------ |
| `$PROJECT_ROOT`              | 本目录（脚本 + `dist/` 产物 + `logs/`）       |
| `$WORKDIR`（`~/persistent`）   | 源码、依赖缓存、venv、ccache —— 容器内路径与宿主机完全一致 |
| `$ANDROID_ROOT`（`~/android`） | SDK / NDK（Linux 版，容器直接用）             |
| `~/.gradle`                  | Gradle/Maven 缓存，避免重复下载               |

- 以 `--user <你的uid>:<gid>` 运行，挂载目录里的文件属主不会被改成 root。
- Linux 下用 `--network host`，容器可直接访问宿主代理（如 `172.24.176.1:7890`）。
- `http_proxy/https_proxy/all_proxy/no_proxy` 以及全部 `KDECI_*`、`ANDROID_*`、`KRITA_*`
  环境变量会透传进容器。

### 5. 与宿主机构建的关系

- 依赖缓存、源码、SDK/NDK 共用 → 不会重复下载；
- 但**编译器不同**（宿主机 Debian gcc 14 vs 容器 Ubuntu gcc 13），
  `_build` 里的目标文件不能混用。脚本为此记录了 `_build/.krita-compiler`：
  检测到编译器变化会自动清空 `_build` 重配，所以**首次在另一种方式下构建需要全量编译一次**，
  之后在该方式内继续是增量。
- ABI 记录同理（`_build/.krita-abi`、`_install/.krita-abi`）。

### 6. 为什么没有照抄官方文档的 Docker 步骤

官方文档《Building Krita for Android → Using prebuilt docker image》的流程是：

```bash
cd ~/persistent/krita
./bin/bootstrap-deps.sh --android=x86_64    # 1) 下载依赖 + QtCreator
./bin/build_image --android                 # 2) 构建/拉取 CI 镜像
./bin/run_container                         # 3) 起容器
./bin/enter                                 # 4) 进容器后手工 export 一堆变量
source /var/lib/ci-files/setup-environment.sh
export KDECI_ANDROID_ABI=x86_64
export KDECI_WORKDIR_PATH=/home/appimage/appimage-workspace
export KDECI_SHARED_INSTALL_PATH=/home/appimage/appimage-workspace/deps/usr
mkdir -p $KDECI_WORKDIR_PATH/krita/_build && cd $KDECI_WORKDIR_PATH/krita/_build
cmake ... && make -j8 install
python ~/persistent/krita/build-tools/ci-scripts/build-android-package.py
```

**实测结论：这套 `bin/` 脚本在当前的 `krita-deps-management`（master）里已经不存在了**，
所以无法"照抄"；文档这一节相对 CI 的 `android.yml` 已经过时。四条可自查的证据：

```text
1) 仓库根目录 113 项，除 ext_* 外只有：
   ci-utilities/ cmake/ latest/ pipelines/ repo-metadata/ tools/
   global-config.yml README.md requirements*.txt how-to-*.md notes-*.md   ← 没有 bin/
2) GitLab API: /repository/tree?path=bin  → HTTP 404
3) grep -r 'bootstrap-deps|run_container|build_image' (sh/md/py/yml) → 0 命中
4) 现在的 Android 流水线是 pipelines/android.yml：
   seed-package-registry.py + run-ci-build.py，
   依赖包按 ABI 分开存在 GitLab Packages（teams/ci-artifacts/krita-android-<abi>）
```

**原因**：旧的 `bin/`（`bootstrap-deps.sh` / `build_image` / `run_container` / `enter`）是
"手工进容器开发"时代的辅助脚本；后来 KDE 把依赖管理统一成
`run-ci-build.py` + `krita-ci-utilities` + `pipelines/*.yml` + GitLab 包注册表，
这些本地脚本就被删掉了，而 docs.krita.org 那一页没有同步更新
（文档里自己也写着"The ground truth ... is the android.yml script"）。

另外补充一点：即使 `bin/build_image` 还在，它拉的也是 **KDE 自己 GitLab 容器仓库
（invent.kde.org 的 registry）** 里的镜像，**不是 Docker Hub 上的现成镜像**。

因此本目录采用的是**等价但可维护**的做法：自建一个只装工具链的小镜像，
用同一套 `build-tools/ci-scripts` 与 `krita-deps-management` 完成同样的阶段，
并把官方强调的两条约束原样保留：

| 官方要求                                                 | 本目录的实现                                                            |
| ---------------------------------------------------- | ----------------------------------------------------------------- |
| `CMAKE_INSTALL_PREFIX` 必须与依赖同目录                      | `KRITA_INSTALL_DIR = $SRCDIR/krita/_install`，cmake 里显式传           |
| 设置 `KDECI_WORKDIR_PATH`，否则 androiddeployqt 跳过 QML 模块 | 环境里设置该变量；打包时把它校正到"`_build` 所在位置"，见 FAQ 23                         |
| 用 `ANDROID_ENABLE_STDIO_FORWARDING=ON` 把日志转发到 logcat | cmake 参数默认开启                                                      |
| 容器内要重复手工 export 一堆变量                                 | 由 [`60-docker-build.sh`](scripts/60-docker-build.sh:1) 一次性透传，无需手工 |

> 因为上游 CI 的 `android.yml` 才是"真相"，等 KDE 恢复 `bin/` 脚本后，
> 直接 `KRITA_DOCKER_IMAGE=他们的镜像 ./build-android.sh docker` 也能复用本套流程。

---

## 四、命令一览

`./build-android.sh <命令> [参数]`

| 命令             | 对应脚本                                                         | 说明                                                                                                                                                                                                                                   |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `check`        | [`00-check-prereqs.sh`](scripts/00-check-prereqs.sh:1)       | Java **17**、Python ≥ 3.10、cmake/make/ninja、SDK/NDK 状态、磁盘空间。`--strict` 有警告也返回非零                                                                                                                                                       |
| `sdk`          | [`10-setup-sdk.sh`](scripts/10-setup-sdk.sh:1)               | 下载并安装 cmdline-tools、NDK（默认 r27d）、`platform-tools`、`platforms;android-33`、`build-tools;30.0.3`、`build-tools;34.0.0`，并接受许可证（**不装模拟器**）                                                                                                 |
| `sources`      | [`20-fetch-sources.sh`](scripts/20-fetch-sources.sh:1)       | 克隆 krita、krita-deps-management、ci-utilities。`--update` 可更新                                                                                                                                                                           |
| `deps`         | [`30-fetch-deps.sh`](scripts/30-fetch-deps.sh:1)             | 建 venv、装 requirements、`setup-env.py`、`generate-deps-file.py`、`run-ci-build.py --only-env`；`--full-deps` 去掉 `--only-env`                                                                                                              |
| `build`        | [`40-build-krita.sh`](scripts/40-build-krita.sh:1)           | `cmake -DCMAKE_TOOLCHAIN_FILE=... -DANDROID_ENABLE_STDIO_FORWARDING=ON` + `make -jN install`；**增量指纹没变则整步跳过**；`--force` 强制重编、`--reconfigure` 强制重配                                                                                     |
| `apk`          | [`50-build-package.sh`](scripts/50-build-package.sh:1)       | `build-android-package.py`；**增量指纹没变且 APK 在则跳过 Gradle**；产物自动复制到 `dist/` **和 Windows 桌面**（已最新的副本不重拷）；`--aab` 追加 `--archive-artifacts` + `build-android-appbundle.py`；`--release` / `--nightly` 走 `assembleRelease` / `assembleNightly` |
| `sign`         | [`55-sign-apk.sh`](scripts/55-sign-apk.sh:1)                 | 给 APK 做 release 签名：`zipalign -p -f 4` → `apksigner sign` → `apksigner verify --print-certs`。默认自动创建本地 keystore（`config/krita-release.keystore`，RSA 4096）；口令读 `KRITA_KEYSTORE_PASS`；`--verify` 只校验、`--generate-only` 只建 keystore       |
| `dev`          | [`70-dev-rebuild.sh`](scripts/70-dev-rebuild.sh:1)           | 重新 `make install` → `./gradlew installDebug` → `adb shell am start`（需真机）                                                                                                                                                             |
| `report`       | [`report.sh`](scripts/report.sh:1)                           | **只读**快照：配置、源码 HEAD 与脏改动、`_install` 的实际 ABI、编译/打包增量标记是否命中、产物大小与 `.so` 数量、各目录体积、剩余磁盘；`--json` 给 CI 用，`--quiet` 只看增量状态。**退出码 0 = 一切最新，1 = 需要重编/重打包**                                                                                   |
| `deb`          | [`65-build-linux-deb.sh`](scripts/65-build-linux-deb.sh:1)   | **Linux 桌面版**（不是 APK）：检查/安装发行版依赖 → cmake → ninja → `DESTDIR` staging → `dpkg-deb` 生成 `dist/krita_<ver>_<arch>.deb`；带增量标记；`--check-deps` / `--install-deps` / `--pack-only` / `--qt6`。详见 §十一                                          |
| `all`          | [`90-build-all.sh`](scripts/90-build-all.sh:1)               | 按顺序执行 6 个步骤（宿主/WSL 内，**不用 Docker**）；`--release` / `--nightly` 透传到第 6 步，`--sign` 在最后补一步签名                                                                                                                                             |
| `docker`       | [`60-docker-build.sh`](scripts/60-docker-build.sh:1)         | **可选**：在 Docker 容器内跑同一套流程；`--build-image` 构建镜像，其余参数转给 `all`                                                                                                                                                                          |
| `wsl`          | [`99-wsl-build.sh`](scripts/99-wsl-build.sh:1)               | 在 Windows 上把命令转发给 WSL2                                                                                                                                                                                                               |
| `wsl-install`  | [`95-wsl-install-deps.sh`](scripts/95-wsl-install-deps.sh:1) | 在 WSL 发行版内装齐工具链（apt + JDK 17；自动处理 Debian 13 已无 `openjdk-17-jdk` 的情况）                                                                                                                                                                 |
| `wsl-network`  | [`94-wsl-network.sh`](scripts/94-wsl-network.sh:1)           | 诊断并修复 WSL2 网络/代理（apt、git 超时的根因）                                                                                                                                                                                                      |
| `wsl-oneclick` | [`96-wsl-oneclick.sh`](scripts/96-wsl-oneclick.sh:1)         | **一键**：修网络 → 装工具链 → 完整构建（`wsl-build.bat` 调用的就是它；`--prepare-only` 只做环境准备）                                                                                                                                                             |
| `clean`        | [`clean.sh`](scripts/clean.sh:1)                             | `--build` / `--deps` / `--venv` / `--sdk` / `--all`                                                                                                                                                                                  |
| `clean-logs`   | [`clean-logs.sh`](scripts/clean-logs.sh:1)                   | 删除所有 `*.log` / `*.txt`：默认先列表再询问，**跳过 git 跟踪的文件**；`--list` 只看、`-y` 不询问、`--keep N` 保留最近 N 个、`--older-than N` 只删 N 天前的、`--dirs "A B"` 额外目录、`--log-only` / `--txt-only`                                                                  |
| `env`          | —                                                            | 打印配置文件解析后的全部变量，用于排查路径问题                                                                                                                                                                                                              |

> **命令别名**（脚本都认，正文只用主名）：
> `apk` = `package` · `report` = `status` · `deb` = `linux-deb` ·
> `wsl-oneclick` = `wsl-build` / `oneclick` · `wsl-install` = `wsl-deps` ·
> `wsl-network` = `wsl-net` · `clean-logs` 还认 `logs-clean` / `clean-logs-*` ·
> `deb --install-deps` = `--deps-only`。

### 常用开关（可以加在大多数子命令后面）

| 开关                                     | 作用                           | 适用于                                     |
| -------------------------------------- | ---------------------------- | --------------------------------------- |
| `--force`                              | 忽略增量指纹，强制重编 / 重打包            | `build` `apk` `all`                     |
| `--release` / `--nightly` / `--debug`  | 选择 Gradle 打包类型（默认 `debug`）   | `apk` `all`                             |
| `--sign`                               | 全部跑完后给 APK 签名                | `all`（`wsl-build.bat --release --sign`） |
| `--aab`                                | 同时生成 AAB                     | `apk` `all`                             |
| `--jobs N`                             | 并行编译任务数                      | `build` `dev` `all`                     |
| `--from N` / `--only N`                | 从第 N 步开始 / 只跑第 N 步           | `all`                                   |
| `--resume`                             | 自动从"第一个未完成的步骤"继续             | `all`                                   |
| `--full-deps`                          | 第 4 步完整获取依赖（去掉 `--only-env`） | `deps` `all`                            |
| `--clean-build`                        | 删掉 `_build` 后全量重编（最彻底，最慢）    | `build` `all`                           |
| `--force-download` / `--force-reclone` | 重新下载 SDK/NDK / 重新克隆源码        | `sdk` `sources` `all`                   |
| `--dry-run`                            | 只打印将执行的命令                    | 全部                                      |

### 常用子命令示例

```bash
# 安装到已连接的 Android 真机
adb install -r dist/krita-arm64-v8a-*-debug.apk

# 查看日志
adb logcat -s krita:V AndroidRuntime:E

# 现在到底有没有最新产物？（只读，0=最新 / 1=要重来）
./build-android.sh report
./build-android.sh report --quiet
./build-android.sh report --json | python3 -m json.tool

# release 包 + 签名（本地 keystore 不存在时会自动创建）
./build-android.sh apk --release
./build-android.sh sign
./build-android.sh sign --verify --apk dist/krita-*-signed.apk

# 每次改完代码后的迭代循环
./build-android.sh dev
./build-android.sh dev --skip-run --jobs 12

# 清理
./build-android.sh clean --list                     # 先看体积
./build-android.sh clean --build --deps --force
```

---

## 五、配置项

复制 [`config/android-build.conf.example`](config/android-build.conf.example:1) 为 `config/android-build.conf`（已在 `.gitignore` 中忽略）。

常用变量：

| 变量                          | 默认值                                         | 说明                                                                                                                                                   |
| --------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ANDROID_ABI`               | `arm64-v8a`                                 | 目标架构：`arm64-v8a`（**默认，手机/平板用这个**）/ `armeabi-v7a`（老 32 位机）。`x86_64` 仅 KDE CI 与模拟器需要，本项目不使用。切换会重新获取依赖并全量重编，见 FAQ 25                                    |
| `ANDROID_API`               | `23`                                        | Krita 支持的最低 API 级别                                                                                                                                   |
| `ANDROID_PLATFORM`          | `android-33`                                | 编译使用的 SDK 平台                                                                                                                                         |
| `ANDROID_NDK_VERSION`       | `27.3.13750724`                             | 官方文档写 r22b，但预编译依赖是 r27d 构建的，见 FAQ 17                                                                                                                 |
| `ANDROID_BUILD_TOOLS`       | `30.0.3 34.0.0`                             | 空格分隔，逐个安装                                                                                                                                            |
| `ANDROID_NDK_ROOT`          | 自动探测                                        | 直接指定 NDK 目录（优先级最高，压过 `ANDROID_NDK_VERSION`）                                                                                                          |
| `ANDROID_EXTRA_PACKAGES`    | 空                                           | 额外安装的 SDK 包（空格分隔，如 `"ndk;22.1.7171670"`）；本项目不装 emulator / system-images                                                                              |
| `ANDROID_ROOT`              | `$HOME/android`                             | SDK / NDK / cmdline-tools 根目录                                                                                                                        |
| `WORKDIR`                   | `$HOME/persistent`                          | 缓存与 venv 根目录                                                                                                                                         |
| `SRCDIR`                    | `$WORKDIR/sources`                          | 源码目录（`krita` 在其下）                                                                                                                                    |
| `VENVDIR`                   | `$WORKDIR/PythonEnv`                        | Python 虚拟环境                                                                                                                                          |
| `ENVDIR`                    | `$WORKDIR/envdir`                           | 依赖包与缓存目录（`setup-env.py` 用到）                                                                                                                          |
| `KRITA_BRANCH`              | `master`                                    | Krita 分支                                                                                                                                             |
| `KRITA_REPO_URL`            | `https://invent.kde.org/graphics/krita.git` | **换成镜像/加速源时改这个**                                                                                                                                     |
| `KRITA_DEPS_MGMT_URL`       | `…/krita-deps-management.git`               | 依赖管理仓库（`setup-env.py` 来源）                                                                                                                            |
| `KRITA_CI_UTILS_URL`        | `…/krita-ci-utilities.git`                  | KDE CI 工具仓库（`run-ci-build.py` 在这）                                                                                                                    |
| `KRITA_CMAKE_BUILD_TYPE`    | `RelWithDebInfo`                            | **native 层**的编译类型（`.so` 的优化级别与调试符号）：`RelWithDebInfo`（官方推荐）/ `Debug` / `Release`。它**不是** debug/release APK 的开关，那个用 `apk --release`，见 FAQ 32。改动会触发全量重编 |
| `KRITA_JOB_COUNT`           | CPU 核心数                                     | 并行任务数                                                                                                                                                |
| `KRITA_INSTALL_PREFIX`      | `$SRCDIR/krita/_install`                    | **必须与依赖同目录**                                                                                                                                         |
| `KRITA_FETCH_FULL_DEPS`     | `0`                                         | 置 1 则完整获取依赖                                                                                                                                          |
| `KRITA_COPY_TO_DESKTOP`     | `1`                                         | 打包后额外复制一份到 Windows 桌面                                                                                                                                |
| `KRITA_EXPORT_DIRS`         | 空                                           | 额外导出目录（空格分隔）                                                                                                                                         |
| `KRITA_DESKTOP_DIR`         | 自动探测                                        | 产物额外复制到哪个目录（留空 = 自动找 Windows 桌面）                                                                                                                     |
| `KRITA_DOCKER_IMAGE`        | `krita-android-build:local`                 | `docker` 子命令使用的镜像                                                                                                                                    |
| `KRITA_DOCKER_EXTRA`        | 空                                           | 追加给 `docker run` 的参数（如 `-m 16g --cpus 8`）                                                                                                            |
| `KRITA_APP_ID`              | `org.krita.debug`                           | 调试版包名                                                                                                                                                |
| `KRITA_MAIN_ACTIVITY`       | `org.krita.android.MainActivity`            | 启动 Activity                                                                                                                                          |
| `KRITA_GRADLE_TASK`         | `installDebug`                              | `dev` 子命令执行的 Gradle 任务                                                                                                                               |
| `ANDROID_SDKMANAGER_PROXY`  | 空                                           | `sdkmanager` 是 Java 程序、**不读** `http_proxy`，这里显式给 `HOST:PORT`；留空则从 `http_proxy` 推断                                                                    |
| `ANDROID_CMDLINE_TOOLS_URL` | 按平台推断                                       | 覆盖 cmdline-tools 下载地址（内网镜像用）                                                                                                                         |
| `ANDROID_NDK_URL`           | 按平台推断                                       | 覆盖 NDK 压缩包下载地址                                                                                                                                       |
| `KRITA_MIN_FREE_GB`         | `30`                                        | 磁盘剩余空间告警阈值（GB）                                                                                                                                       |
| `WSL_DISTRO`                | 空（取第一个）                                     | WSL2 发行版                                                                                                                                             |

其它可用环境变量：

| 变量                                       | 作用                                                                 |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `KRITA_ANDROID_CONFIG`                   | 指定配置文件路径（默认 `config/android-build.conf`）                           |
| `KRITA_DRY_RUN=1`                        | 所有脚本只打印命令，不执行                                                      |
| `NO_COLOR=1`                             | 关闭彩色输出                                                             |
| `KRITA_KEYSTORE_PASS` / `KRITA_KEY_PASS` | `sign` 用的 keystore / key 口令（推荐用这个，而不是 `--store-pass`，避免口令进进程命令行）   |
| `KRITA_LOG_DIR`                          | 覆盖日志目录（默认 `logs/`）                                                 |
| `KRITA_HOLD=0`                           | 禁止失败后暂停等待（CI / 脚本化调用时用）                                            |
| `KRITA_HOLD_ALWAYS=1`                    | 即使成功也暂停（想慢慢看输出时用）                                                  |
| `KRITA_DEPS_RETRIES`                     | 下载依赖包的重试次数                                                         |
| `KRITA_DOCKER_APT_MIRROR`                | 容器内 apt 镜像（国内网络加速）                                                 |
| `KRITA_LINUX_BUILD_DIR`                  | Linux deb 的构建目录（默认 `<源码>/_build_linux`）                            |
| `KRITA_LINUX_STAGING`                    | deb 的 staging 根（默认 `_build_linux/staging`）；`deb --pack-only` 时配合使用 |
| `KRITA_LINUX_BUILD_TYPE`                 | deb 的编译类型（默认 `RelWithDebInfo`）                                     |
| `KRITA_LINUX_DEB_OUT`                    | deb 输出目录（默认 `dist/`）                                               |

---

## 六、与官方文档的对应关系

| 官方文档小节                                                           | 本目录实现                                                                                                   |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Installing Prerequisites（Java 17 / Python ≥ 3.10）                | [`00-check-prereqs.sh`](scripts/00-check-prereqs.sh:1)                                                  |
| Setting up Android SDK and NDK / Configure environment variables | [`10-setup-sdk.sh`](scripts/10-setup-sdk.sh:1)、[`lib/android-env.sh`](scripts/lib/android-env.sh:1)     |
| Fetch Krita Deps（clone + venv + setup-env.py + run-ci-build.py）  | [`20-fetch-sources.sh`](scripts/20-fetch-sources.sh:1)、[`30-fetch-deps.sh`](scripts/30-fetch-deps.sh:1) |
| Configure Krita / Then build Krita as usual                      | [`40-build-krita.sh`](scripts/40-build-krita.sh:1)                                                      |
| Building the APK package（APK / AAB）                              | [`50-build-package.sh`](scripts/50-build-package.sh:1)                                                  |
| Iteratively rebuild Krita and its package after making changes   | [`70-dev-rebuild.sh`](scripts/70-dev-rebuild.sh:1)                                                      |
| Installing Android Emulator                                      | 不适用（本项目只产出真机可装的 `arm64-v8a` APK，不涉及模拟器）                                                                 |
| Debugging crashes（adb logcat）                                    | `adb logcat -s krita:V AndroidRuntime:E`                                                                |
| cleanup section（磁盘清理）                                            | [`clean.sh`](scripts/clean.sh:1)                                                                        |
| Using prebuilt docker image（CI Docker 流程）                        | 见下方“Docker 流程”                                                                                          |

### 官方文档中的两个关键警告，脚本已内置

1. **`CMAKE_INSTALL_PREFIX` 必须指向依赖所在目录**，因为 APK 打包脚本无法跨目录查找资源 —— 默认 `$SRCDIR/krita/_install`。
2. **不要在未设置 `KDECI_WORKDIR_PATH` 的情况下构建**（例如直接在源码树里按其它平台的习惯构建），否则 `androiddeployqt` 会跳过全部 Qt QML 模块 —— 脚本会检查并给出提示。
3. `ANDROID_ENABLE_STDIO_FORWARDING=ON` 已默认开启，`stdout/stderr` 会转发到 `logcat`。

### Docker 流程

**本目录自带的 Docker 方式**（推荐，见「三之五」）：一个只装工具链的小镜像 + 挂载宿主机的
SDK/NDK/缓存，一条命令即可：

```bash
./build-android.sh docker --build-image     # 首次
./build-android.sh docker                   # 之后
```

**官方文档的 CI Docker 镜像路线**（手工流程）。官方文档给的是：

```bash
cd ~/persistent/krita
./bin/bootstrap-deps.sh --android=<abi>    # 下载依赖 + QtCreator
./bin/build_image --android                # 构建/拉取 CI 镜像
./bin/run_container
./bin/enter
```

> **注意：这套 `bin/` 脚本在当前 `krita-deps-management`（master）里已经不存在**
> （克隆下来只有 `ext_*`、`ci-utilities`、`cmake` 等，没有 `bin/` 目录），
> 所以这一段目前无法照抄；详细说明与替代方案见「三之五」第 6 小节。

如果你手上有旧版 `krita-deps-management`（含 `bin/`）或 KDE CI 的镜像，进入容器后需要**每次**手工设置：

```bash
source /var/lib/ci-files/setup-environment.sh
export KDECI_ANDROID_ABI=arm64-v8a
export KDECI_WORKDIR_PATH=/home/appimage/appimage-workspace
export KDECI_SHARED_INSTALL_PATH=/home/appimage/appimage-workspace/deps/usr
```

随后在容器内即可照搬本目录的流程：把源码与脚本目录 mount 进容器，执行 `./build-android.sh build && ./build-android.sh apk`。
也可以用 `KRITA_DOCKER_IMAGE=<他们的镜像> ./build-android.sh docker` 让脚本自动完成挂载与环境透传。

---

## 七、常见问题

共 32 条，按主题分组（点编号即跳到对应小节）：

| 主题               | 相关条目                                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **环境 / 工具链**     | 1 行尾 CRLF · 2 `javac` 不是 17 · 3 Python/venv · 4 `sdkmanager` 找不到 · 9 磁盘空间 · 11 复用已装 SDK · 12 只有 JDK 21/8 · 14 双击 `.sh` 一闪而过 · 22 `ccache` 127                                                           |
| **依赖 / 编译**      | 5 CMake 找不到 Qt · 6 androiddeployqt 跳过 QML · 13 deps 只生成 env · 16 第 5 步找不到 Qt · 17 NDK 版本不匹配（vtable 报错） · 19 `moc_*.cpp` not found · 20 找不到 ECM · 21 `build-pofiles.cmake` · 23 `Makefile: No such file` · **36 `--only-deps` 装了 0 个包** |
| **打包 / 安装 / 产物** | 7 真机闪退 · 18 Gradle 下载失败（代理） · 24 APK 在哪 · 25 换 ABI · 27 什么都没改为什么跳过了 · 28 满屏 `could not find libc.so` · **30 产物是不是最新的（`report`）** · **31 release 与签名** · **32 debug/release 两层区别**                       |
| **日志 / 清理**      | 8 需要更多日志 · 26 Docker 报错 · 29 清理 `logs/`                                                                                                                                                                 |
| **网络 / Git**     | 10 路径被吃掉 · 15 `git clone` 被代理截断                                                                                                                                                                         |
| **Linux 桌面 deb** | **33 `deb` 子命令的常见问题**（依赖 / sudo / 编译时间 / 产物位置）                                                                                                                                                          |
| **入口文件**         | **34 `build-android.sh` / `.bat` / `wsl-build.bat` 的关系**                                                                                                                                                |
| **SDK 安装** | **35 许可证未接受导致 NDK 被跳过** |

### 1. `bash: ./build-android.sh: /usr/bin/env: bad interpreter`

脚本被存成了 CRLF。已提供 [`.gitattributes`](.gitattributes:1) 强制 LF；若文件已损坏，可执行：

```bash
sed -i 's/\r$//' build-android.sh scripts/*.sh scripts/lib/*.sh
```

### 2. `javac` 版本不是 17

官方要求**精确的 17**（Gradle 的 Android 插件依赖 JDK 17）：

```bash
sudo add-apt-repository ppa:openjdk-r/ppa
sudo apt update
sudo apt install openjdk-17-jdk
javac --version          # 必须显示 17.x
ls -l /usr/lib/jvm/*     # 确认没有其它版本干扰
```

### 3. Python 版本 / venv 问题

官方要求 ≥ 3.10（3.9 未测试，3.8 确认不可用）：

```bash
sudo apt install -y python3 python3-pip python3-venv
python3 --version
```

### 4. `sdkmanager: command not found`

执行 `./build-android.sh sdk` 自动下载 cmdline-tools；若在公司网络下无法下载，可手动下载后解压到 `$ANDROID_ROOT/cmdline-tools`，确保存在 `cmdline-tools/bin/sdkmanager`。

### 5. CMake 找不到 Qt / 依赖

多半是 `deps` 步骤只生成了环境文件（`--only-env`），并未真正落地依赖：

```bash
./build-android.sh deps --full-deps     # 完整获取依赖
./build-android.sh env                  # 检查 KDECI_SHARED_INSTALL_PATH 等变量
```

### 6. `androiddeployqt` 跳过了 Qt 的 QML 模块

说明构建目录不在 `KDECI_WORKDIR_PATH` 对应的工作区内，或 `KDECI_WORKDIR_PATH` 未设置 —— 请使用默认的 `_build` / `_install` 布局，不要挪动它们。

### 7. 装到真机上闪退 / 无法启动

- 先确认装的是匹配 ABI 的包。本目录**默认构建 `arm64-v8a`**（真机可用）：
  `krita-arm64-v8a-*.apk` 装到 64 位 ARM 手机；`x86_64` 的包只能装到模拟器 / x86 设备。
- 安装：`adb install -r dist/krita-arm64-v8a-*-debug.apk`，
  若提示 `INSTALL_FAILED_OLDER_SDK` 说明设备 API 低于 23（Krita 最低 Android 6.0）。
- 老 32 位机型：把 `ANDROID_ABI` 设为 `armeabi-v7a` 重新走完整流程（见 FAQ 25）。

### 8. 需要更多日志

`ANDROID_ENABLE_STDIO_FORWARDING=ON` 已开启，Krita 的 `stdout/stderr` 会转发到 `logcat`：

```bash
adb logcat -s krita:V AndroidRuntime:E      # 只看 krita 与崩溃
adb logcat > /tmp/krita-log.txt             # 完整输出到文件
adb logcat -c                               # 清空缓冲区
```

### 9. 磁盘空间

完整构建（源码 + 依赖 + 构建产物）通常需要数十 GB。查看与清理：

```bash
./build-android.sh env
./build-android.sh clean --list
./build-android.sh clean --all --force
```

### 10. Windows 下出现路径被“吃掉”的情况

Git Bash 会把形如 `/c/...` 的参数自动转换成 Windows 路径。脚本仅在调用 Windows 原生工具（`sdkmanager.bat` / `adb.exe`）时局部设置 `MSYS_NO_PATHCONV=1` 并显式传入 `C:/...` 形式路径，其余命令保持 MSYS 的正常行为。

---

### 11. 已经装过 Android Studio / Android SDK，想直接复用

脚本期望的布局是 `$ANDROID_ROOT/sdk`、`$ANDROID_ROOT/android-ndk-r22b`、`$ANDROID_ROOT/cmdline-tools`。
Android Studio 默认把 SDK 放在 `%LOCALAPPDATA%\Android\Sdk`（即 `C:/Users/<用户名>/AppData/Local/Android/Sdk`），因此可以这样配置：

```conf
# 注意：末尾不要带 /sdk
ANDROID_ROOT=C:/Users/<用户名>/AppData/Local/Android
```

请确认该 SDK 中**至少**存在 `platforms;android-33`、`build-tools;30.0.3`、`build-tools;34.0.0` 以及 NDK r22b；缺失的组件继续用 `./build-android.sh sdk` 补齐即可（脚本不会覆盖已有目录）。

### 12. 机器上只有 JDK 21 / JDK 8

官方要求**精确的 17**（`javac --version` 必须显示 17.x）。若系统有多个 JDK，请把 `JAVA_HOME` 与 `PATH` 都指向 17：

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
javac --version
```

在 Windows 上如果 Gradle 报 `Unsupported class file major version`，同样是 JDK 版本不匹配导致的。

### 13. `deps` 步骤只生成了 env，没有真正下载依赖

按官方宿主机流程，`run-ci-build.py --only-env` 只生成 `$KRITA_SRC/env`。若之后 CMake 找不到 Qt 或其它依赖，说明依赖还没落地：

```bash
./build-android.sh deps --full-deps     # 去掉 --only-env，完整获取依赖
```

---

### 14. 双击 `.sh`（例如 `99-wsl-build.sh`）一闪而过

`.sh` 不是 Windows 的可执行类型。双击时系统会临时开一个控制台运行它，脚本一退出窗口就关闭 —— 与脚本内容无关。再加上 `wsl all` 在发行版缺 `javac`/`unzip` 时会很快失败，看起来就更像"闪退"。

正确做法：

```bat
entrypoints/wsl-check.bat      rem 先看 WSL2 侧缺什么
entrypoints/wsl-build.bat      rem 再开始构建
```

或命令行：`build-android.bat wsl --check` / `build-android.bat wsl all`。

如果坚持直接运行 `.sh`，在 Windows 的交互式终端下**失败时会等待你按 Enter**（见上文 `KRITA_HOLD`），窗口不会立刻消失。

---

### 15. `git clone krita` 中断：`curl 56 GnuTLS recv error (-9)` / `early EOF`

大仓库经本地代理传输时，git 默认的 HTTP/2 很容易被代理截断 TLS 流。脚本已自动加固：

- `http.version=HTTP/1.1`、`http.postBuffer=500MB`、`core.compression=0`
- **默认浅克隆**（`--depth 1 --shallow-submodules --no-tags`，体积约为完整克隆的十分之一）
- 失败后自动清理并重试（第 2 次起更保守）

中断后**直接重跑**即可，已完成的步骤会自动跳过：

```bat
entrypoints/wsl-build.bat --from 20
```

需要完整历史用 `--full`，或在配置里设 `KRITA_CLONE_DEPTH=0`。

### 16. 第 5 步 cmake 报找不到 Qt / KDE 依赖

说明依赖只"生成了环境文件"而没有真正落地，用完整依赖模式重跑第 4 步：

```bat
entrypoints/wsl-build.bat --from 30 --full-deps
```

`--full-deps` 会去掉 `run-ci-build.py` 的 `--only-env`，真正下载/构建依赖（耗时与磁盘占用显著增加）。

---

### 17. 链接报 `undefined symbol: vtable for std::__ndk1::basic_ostringstream`（NDK 版本不匹配）

**原因**：CI 预编译的 Android 依赖（`_install` 里那 1.4GB 的 Qt / Boost / folly 等）是用 **NDK r27d（27.3.13750724）** 构建的；官方文档写的 `r22b` 已经过时，用 r22b 链接会因 libc++ ABI 不一致报这个错（`strings.cpp.o` in `libunwindstack.a`）。

**脚本的处理**：

- `ANDROID_NDK_VERSION` 默认已改为 `27.3.13750724`（用 `sdkmanager` 装到 `$SDK/ndk/`）；
- 要回到文档的旧流程时写 `r22b`，会走官方 zip 下载（`$ANDROID_ROOT/android-ndk-r22b`）；
- 也可以直接指定目录：`ANDROID_NDK_ROOT=/path/to/ndk`（优先级最高）。

**换 NDK 后必须做两件事**（脚本已自动处理第二件，但仍建议第一件）：

```bash
# 1) 删掉用旧 NDK 配置过的构建目录
rm -rf ~/persistent/sources/krita/_build

# 2) 重新生成 env（env 文件里固化了生成时的 NDK/SDK 路径）
./build-android.sh wsl --shell ./scripts/30-fetch-deps.sh
```

> 脚本在 `source env` 之后会**按当前配置重新断言** `KDECI_ANDROID_NDK_ROOT` / `KDECI_ANDROID_SDK_ROOT` 等变量，避免被 env 文件里的旧值覆盖——这正是"换了 NDK 却仍然用旧 NDK 链接"的根因。

---

### 18. 打包阶段 Gradle 下载 Maven 依赖失败（TLS handshake / 超时）

Gradle 是 Java 程序，**不读 `http_proxy`/`https_proxy`**。在需要代理的环境里（如 Clash fake-IP）会报：

```
Could not GET 'https://repo.maven.apache.org/.../slf4j-api-1.7.30.pom'
  > The server may not support the client's requested TLS protocol versions
  > Remote host terminated the handshake
```

[`50-build-package.sh`](scripts/50-build-package.sh:1) 已自动处理：从 `https_proxy` 解析代理，写入 `~/.gradle/gradle.properties` 的 `systemProp.http(s).proxyHost/Port`，并设置 `JAVA_TOOL_OPTIONS`（Gradle wrapper 与 `androiddeployqt` 的 JVM 都会读取）。核查：

```bash
grep -A8 'krita-android proxy' ~/.gradle/gradle.properties
```

### 19. 编译到 98% 报 `'XXXXXX/moc_xxx.cpp' file not found`

Qt5 AUTOMOC 在 `-j` 高并发下的已知竞态：`mocs_compilation.cpp` 抢在 moc 产物生成之前被编译。**不是代码问题，重跑即可通过**。

[`40-build-krita.sh`](scripts/40-build-krita.sh:1) 已内置：首轮全并发，失败后自动用 `-j4` 增量重试一次（只补缺失部分）。

---

### 20. `cmake` 报 `Could not find a package configuration file provided by "ECM"`

说明 `_install` 里的依赖没了（常见原因：跑过 `clean --all`，它会删掉安装目录）。
依赖包本身还在缓存里（`~/persistent/cache/ext_*.tar`），**不需要重新下载**，
[`30-fetch-deps.sh`](scripts/30-fetch-deps.sh:1) 现在会自动离线解包恢复：

```bash
./build-android.sh wsl --shell ./scripts/30-fetch-deps.sh    # 自动检测并恢复
```

> 提醒：`./build-android.sh clean --all` 会同时删除 `_install`（1.4GB 预编译依赖）与 venv。
> 只想重新编译请用 `--clean-build`（只删 `_build`）。

### 21. `KF5I18n/build-pofiles.cmake: failed generating .../po`

链接日志里的真因通常是：

```
.../_install/bin/msgfmt: error while loading shared libraries: libgettextsrc-0.21.so
```

即依赖目录里的 `msgfmt` 找不到自己的共享库（`_install/lib` 不在 `LD_LIBRARY_PATH`）。
脚本已在 `source env` 之后自动补上 `PATH`（`_install/bin`）与 `LD_LIBRARY_PATH`（`_install/lib`），
并把系统 `gettext` 一并装好。若仍失败：

```bash
sudo apt install -y gettext
./build-android.sh wsl --shell ./scripts/40-build-krita.sh --reconfigure   # 重新探测 msgfmt
```

### 22. `ccache -M 20G ... exit status 127`

仓库自带 `.kde-ci.yml` 里 `use-ccache: True`，因此需要 `ccache`：

```bash
sudo apt install -y ccache
```

已加入 [`95-wsl-install-deps.sh`](scripts/95-wsl-install-deps.sh:1) 的安装清单。

### 23. 第 6 步打包报 `gmake: Makefile: No such file or directory` / `## Failed to build apk`

**原因**：`build-android-package.py` 的目录定位规则是

```python
base = os.path.join(os.environ['KDECI_WORKDIR_PATH'], 'krita')  # 若该变量存在
base = os.getcwd()                                               # 否则
buildPath = base/_build
```

`KDECI_WORKDIR_PATH` 一度被设为 `$WORKDIR/krita-workdir`（为避免与 deps 构建的 scratch 目录互相踩），
于是打包脚本跑去 `~/persistent/krita-workdir/krita/_build` 找 `Makefile` —— 那里是空的，
而真正的构建目录是 `$SRCDIR/krita/_build`，所以 `cmake --build . --target create-apk` 直接失败。

**已修复**：[`50-build-package.sh`](scripts/50-build-package.sh:1) 在调用打包脚本前会检查
`KDECI_WORKDIR_PATH` 是否等于 `dirname($KRITA_SRC)`；不是则本次打包临时 `unset`，改用 cwd 定位，
并打印实际使用的构建目录。单独重跑第 6 步即可：

```bash
./build-android.sh wsl --shell ./scripts/50-build-package.sh
```

### 24. 打包成功后 APK 在哪

`create-apk` 产物先被移到 `$SRCDIR/krita/_packaging/`，随后脚本会复制到：

```text
<项目根>/dist/krita-arm64-v8a-5.4.0-prealpha-<sha>-debug.apk     # 仓库内
C:\Users\<你>\Desktop\krita-arm64-v8a-5.4.0-prealpha-<sha>-debug.apk  # Windows 桌面
```

桌面目录是自动探测的（Git Bash 用 `%USERPROFILE%\Desktop`；WSL 用 `/mnt/c/Users/<用户>/Desktop`，
也会优先识别"项目本身就在桌面上"的情况）。控制方式：

```bash
KRITA_COPY_TO_DESKTOP=0     # 不要复制到桌面
KRITA_DESKTOP_DIR=/path     # 指定桌面目录
KRITA_EXPORT_DIRS="C:/apk"             # 额外再复制到其它目录（可写多个，空格分隔）
```

`./build-android.sh env` 里的 `KRITA_DESKTOP_DIR` 就是当前探测结果。

安装：`adb install -r dist/xxx.apk`（需先在设备上开启 USB 调试）。

### 25. 想换 ABI（arm64-v8a ↔ armeabi-v7a ↔ x86_64）

默认就是真机用的 `arm64-v8a`。切换只需改一个变量，脚本会自动处理依赖与构建目录：

```bash
# 临时切换（本次生效）
ANDROID_ABI=armeabi-v7a entrypoints/wsl-build.bat
# 或写进 config/android-build.conf 长期生效
```

切换时脚本会自动做三件事（不需要手工删目录）：

1. `_install` 里的预编译依赖是分架构的 → 旧目录被改名为 `_install.<旧ABI>` 保存，
   并从 KDE CI 重新下载当前架构的依赖包（约 1.2GB；之后再切回来会直接复用备份，秒切）；
2. `_build` 里的目标文件是另一套指令集 → 自动清空重配（否则链接会报
   `ld.lld: error: xxx.o is incompatible with aarch64linux`）；
3. `--resume` 会在检测到依赖 ABI 不匹配时自动回到第 4 步，而不是误判为"已完成"。

ABI 记录在两个标记文件里，可用 `./build-android.sh env` 或直接查看：

```bash
$SRCDIR/krita/_install/.krita-abi    # 依赖的架构
$SRCDIR/krita/_build/.krita-abi      # 构建目录的架构
```

实测耗时（16 核 WSL2）：arm64-v8a 首次全量编译约 **40 分钟**，打包约 1~3 分钟，
产物 `krita-arm64-v8a-5.4.0-prealpha-903a173-debug.apk` 约 **180MB**，
APK 内 `lib/arm64-v8a/` 下共 345 个 `.so`。

### 26. Docker 构建相关报错

- **`未找到 docker 命令`**：WSL 里没装，或 Docker Desktop 没开 WSL Integration：
  
  ```bash
  sudo apt install -y docker.io && sudo service docker start
  ```
- **`docker 守护进程不可用（docker info 失败）`**：服务没起来（`sudo service docker start`），
  或当前用户没权限：`sudo usermod -aG docker $USER` 后重开终端。
- **`Permission denied` / 文件属主变成 root**：容器默认以 root 写入挂载目录。
  脚本已用 `--user $(id -u):$(id -g)` 规避；若你手工跑 `docker run`，请同样加上。
- **镜像构建很慢 / apt 失败**：基础镜像拉取与 apt 都走网络，代理环境下先确认
  WSL 内 `curl -I https://registry-1.docker.io` 可通；必要时
  `KRITA_DOCKER_EXTRA="--build-arg HTTP_PROXY=..."`（或直接在 WSL 的
  `/etc/docker/daemon.json` 配代理）。
- **容器里第一次编译很慢 / 报 `incompatible`**：与宿主机编译器不同，
  脚本会检测 `_build/.krita-compiler` 并自动清空重配，所以切换构建方式后
  第一次是全量编译（约 40 分钟），之后仍为增量。
- **不想用了**：直接不用 `docker` 子命令即可 —— **默认路线从来不是 Docker**。
  删除镜像：`docker rmi krita-android-build:local`。

### 27. 什么都没改，为什么 `build` / `apk` 直接跳过了？

这是增量优化的**预期行为**：两个脚本各自记录一份"增量指纹"，内容一致就直接跳过。

```bash
$SRCDIR/krita/_build/.krita-build-stamp        # 编译成功后写入
$SRCDIR/krita/_packaging/.krita-package-stamp  # 打包成功后写入
```

| 你以为            | 实际                                                    |
| -------------- | ----------------------------------------------------- |
| 我改了代码，肯定编译     | ✅ 指纹里含 `git status` 的哈希，改了就变 → 正常增量编译                 |
| 我切换了 ABI / NDK | ✅ 指纹变了 → 重新编译（`check_abi_of_build_dir` 还会先清 `_build`） |
| 我从宿主机切到 Docker | ✅ 编译器 ID 变了 → 重新编译                                    |
| 我只是重新跑了一遍      | ✅ 指纹一致 → 跳过，几秒结束                                      |

跳过时屏幕上会明确打印 `自上次编译以来源码与配置均无变化 → 跳过编译` 并列出指纹。
想强制重来：

```bash
./build-android.sh build --force     # 忽略标记，重新编译
./build-android.sh apk --force       # 忽略标记，重新打包
./build-android.sh all --force       # 两个都强制
./build-android.sh build --clean-build   # 连 _build 一起删掉（最彻底）
```

想彻底重置增量状态又不想删产物：`rm -f _build/.krita-build-stamp _packaging/.krita-package-stamp`。

### 28. 打包时满屏 `-- could not find libc.so in .../_build/lib .../_install/lib/`

**这是无害的提示，不是错误。** 它来自 `androiddeployqt`（Qt 的 Android 部署工具），
出现在这行之后：

```text
Generating krita with /…/krita/_install/bin/androiddeployqt
-- could not find libc.so  in …/krita/_build/lib …/krita/_install/lib/
-- could not find libm.so  in …/krita/_build/lib …/krita/_install/lib/
-- could not find libdl.so in …/krita/_build/lib …/krita/_install/lib/
-- could not find libc++_shared.so in …/krita/_build/lib …/krita/_install/lib/
```

它在做的事：读每个 `.so` 的 `DT_NEEDED`（它依赖谁），然后**只在这两个目录**里找对应文件：

| 库                                  | 实际情况                                                               |
| ---------------------------------- | ------------------------------------------------------------------ |
| `libc.so` / `libm.so` / `libdl.so` | **Android 系统库**，运行时由设备的 `/system/lib64` 提供；NDK 里只有 stub，本来就不该进 APK |
| `libc++_shared.so`                 | 由 NDK/Qt 的部署逻辑另行提供，**不是**放在 `_install/lib` 里                       |

所以它只是"我在 `_build/lib`、`_install/lib` 里没找到这几个库"，随后照常继续打包。
本目录产出的 APK 实测：`lib/arm64-v8a/` 下共 **345 个 `.so`，其中包含 `libc++_shared.so`**。

**什么时候才需要担心**：

- APK 里**没有** `libc++_shared.so` → 真机启动会报
  `dlopen failed: library "libc++_shared.so" not found`；
- 或启动/运行时报 `cannot locate symbol ...`。

自检（Windows PowerShell）：

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z=[IO.Compression.ZipFile]::OpenRead("$PWD\dist\krita-arm64-v8a-*-debug.apk")
$z.Entries | Where-Object { $_.FullName -like 'lib/arm64-v8a/libc++_shared.so' }
```

（Linux/WSL：`unzip -l dist/*.apk | grep libc++`）

嫌吵可以过滤掉，不影响构建：

```bash
./build-android.sh apk 2>&1 | grep -v 'could not find lib'
```

### 29. `logs/` 越积越大，怎么一次清干净？

用 `clean-logs`（`scripts/clean-logs.sh`，也有双击版 `clean-logs.bat`）：

```bash
./build-android.sh clean-logs --list              # 只列出将删除的文件
./build-android.sh clean-logs -y                  # 全删（*.log + *.txt）
./build-android.sh clean-logs --keep 5 -y         # 每个目录保留最近 5 个 *.log
./build-android.sh clean-logs --log-only -y       # 只删日志，保留 *.txt
./build-android.sh clean-logs --dirs "C:/krita-dev/logs" -y   # 顺带清 Windows 侧
./build-android.sh clean-logs --older-than 7 -y   # 只删 7 天以前的（本周的留着）
./build-android.sh clean-logs --older-than 7 --keep 3 -y  # 两个条件可叠加
```

安全规则：**被 git 跟踪的文件默认不删**（`--include-tracked` 才能删，
否则误删源码里的 `.txt` 会让仓库变 dirty）；`.git`、`dist`、`_build*`、
`_install*`、`PythonEnv*`、`node_modules` 等目录直接跳过；非交互环境必须加 `-y`。
执行顺序是：先由 `--older-than N` 按修改时间筛出候选，再由 `--keep N` 排除掉
（相对同目录内排名）最新 N 个 `*.log`。所以 `--older-than 7 --keep 3` 只会在
"7 天以前的文件"里再留 3 个，实际很少删到东西，日常二选一即可。

`clean-logs.bat` 与 `check.bat` 一样会暂停等你按回车（双击场景）；
脚本里调用请用 `build-android.bat clean-logs -y` 并 `set KRITA_BAT_NOPAUSE=1`。

Windows 侧的原生构建日志在 `<Workspace>\logs\`（默认 `C:\krita-dev\logs\`）：
每次运行一个 `win-build-<时间戳>.log`，并额外复制一份 `latest.log` 指向最近一次
（脚本启动时打印的 `日志:` / `最新:` 两行就是它们）。同样可以一条命令清掉：

```bat
entrypoints/clean-logs.bat --dirs "C:\krita-dev\logs" -y
```

---

### 30. 手上的 APK 是不是最新的？要不要重编？

用 `report`（只读，不编译不下载）：

```bash
./build-android.sh report            # 完整快照
./build-android.sh report --quiet    # 只看增量状态 + 产物
./build-android.sh report --json     # 给 CI / 脚本消费
```

它会打印一段结论，直接告诉下一步该做什么：

| 结论      | 含义                                  | 下一步                      |
| ------- | ----------------------------------- | ------------------------ |
| 一切都是最新的 | 编译/打包增量标记都命中，产物齐全                   | 改完代码直接 `dev`             |
| 需要重新打包  | 编译没变，但 APK 不是这次的                    | `apk`（编译可复用）             |
| 需要完整编译  | `_install` 里没有 `libkrita*.so`，或指纹变了 | `all`（或 `build` 后 `apk`） |

报告里的几个关键项：

- **编译指纹 / 打包指纹**：未命中时会逐段列出"哪个输入变了"（`src` / `dirty` / `abi` / `ndk` / `tc` …），不会只说一句"要重编"；
- **`_install` 的 ABI**：会与配置里的 ABI 比对，不一致直接警告（切换 ABI 后必须先重跑 `deps`）；
- **产物**：每个 APK/AAB 的大小、里面的 `.so` 数量、是否已签名、mtime；
- **退出码**：`0` = 一切最新，`1` = 需要重编/重打包 —— 可以直接写进 CI 判断。

签名判定说明：`minSdkVersion` 是 24，所以 Gradle 与 apksigner 默认**只写 v2/v3 签名块**
（不在 `META-INF/` 里放 `CERT.RSA`）。因此 `report` 判断"已签"用的是 `apksigner verify`，
不是看 `META-INF`；找不到 apksigner 时才会退化成 v1 检测并显示"未知"。

---

### 31. 怎么打 release 包并签名？

Krita 的 `krita_build_apk/build.gradle` 里**没有 `signingConfigs`**，官方 CI 也是在打包之后
用外部 notary 服务补签的。所以本地分两步：**先出 `-unsigned` 包，再签**。

```bash
# 1) release 包（gradlew assembleRelease；产物名里带 -unsigned）
./build-android.sh apk --release

# 2) 签名（keystore 不存在时会自动创建一个本地调试用的）
./build-android.sh sign

# 3) 校验
./build-android.sh sign --verify --apk dist/krita-*-signed.apk
```

`sign` 做的事：`zipalign -p -f 4`（4 字节对齐 + `.so` 页对齐）→ `apksigner sign`
（v1/v2/v3 由 apksigner 按 `minSdkVersion=24` 自动选择，无需手动指定）→
`apksigner verify --print-certs`（打印证书 DN 与 SHA-256 指纹）。

口令与 keystore：

```bash
# 用自己的 keystore（推荐；口令走环境变量，不出现在进程命令行里）
export KRITA_KEYSTORE_PASS='你的口令'
export KRITA_KEY_PASS='你的口令'
./build-android.sh sign --keystore D:/keys/krita.jks --alias krita

# 只建 keystore，先不签
./build-android.sh sign --generate-only

# 默认的本地 keystore（仅调试用，口令是内置默认值，别用来发版）
#   config/krita-release.keystore  （已在 .gitignore 里忽略）
```

`sign` 的完整开关：

| 开关                                 | 说明                                                                                 |
| ---------------------------------- | ---------------------------------------------------------------------------------- |
| `--apk PATH`                       | 要签名的 APK（默认取 `_packaging` 下最新的 `.apk`）                                             |
| `--out PATH`                       | 输出文件（默认 `dist/<原名>-signed.apk`；临时目录建在同目录，`mv` 是原子改名）                               |
| `--keystore PATH` / `--alias NAME` | keystore 与密钥别名（默认 `config/krita-release.keystore` / `krita`）                       |
| `--store-pass` / `--key-pass`      | keystore / key 口令（**更推荐**环境变量 `KRITA_KEYSTORE_PASS` / `KRITA_KEY_PASS`，不会出现在进程命令行） |
| `--verify`                         | 只校验签名（`apksigner verify --print-certs`），不重签                                        |
| `--generate-only`                  | 只创建 keystore，不签名                                                                   |
| `--force` / `--dry-run`            | 输出已存在时强制重签 / 只打印命令                                                                 |

`report` 会把每个 APK 的签名状态（已签 / 未签 / 未知）一并列出来，签完可以直接核对。

**我平时双击 `wsl-build.bat`，怎么打 release？**

`wsl-build.bat` 会把命令行参数一路透传（`wsl-build.bat %*` → `wsl-oneclick` → `all`），
所以直接给它加参数就行：

```bat
entrypoints/wsl-build.bat --release --sign
```

- `--release` → 第 6 步跑 `gradlew assembleRelease`（产物带 `-unsigned`）
- `--sign` → 全部跑完后自动签名（第一次会自动创建本地 keystore）
- 想连 AAB 一起：`entrypoints/wsl-build.bat --release --sign --aab`
- 只想重打不重编：`entrypoints/wsl-build.bat --release --sign --from 6`

不加任何参数 = debug 包（默认行为，与 `dev` 一致）。

---

### 32. debug 还是 release？这两层到底有什么区别？

最容易混淆的是：这个项目里有**两层** debug/release，互不相干。

| 层                         | 由谁决定                        | 影响什么                             | 选项                                        |
| ------------------------- | --------------------------- | -------------------------------- | ----------------------------------------- |
| **native 层**（C++ / `.so`） | 配置 `KRITA_CMAKE_BUILD_TYPE` | 优化级别、调试符号、`assert`               | `RelWithDebInfo`（默认）/ `Debug` / `Release` |
| **打包层**（Gradle / APK）     | 子命令参数                       | 是否可调试、是否 minify+proguard、产物命名、签名 | `--debug`（默认）/ `--release` / `--nightly`  |

```bash
# 只改 native 层：会触发全量重编（指纹里的 btype 变了）
KRITA_CMAKE_BUILD_TYPE=Release ./build-android.sh build

# 只改打包层：编译产物可复用
./build-android.sh apk --release

# 两层都按发版来
KRITA_CMAKE_BUILD_TYPE=Release ./build-android.sh all --release --sign
```

常见组合：

| 场景        | native                   | 打包           | 命令                                        |
| --------- | ------------------------ | ------------ | ----------------------------------------- |
| 日常改代码     | RelWithDebInfo           | debug        | `./build-android.sh dev`                  |
| 自己装个能用的   | RelWithDebInfo           | debug        | `./build-android.sh apk`                  |
| 测性能 / 看帧率 | RelWithDebInfo 或 Release | release      | `./build-android.sh apk --release`        |
| 对外分发      | Release                  | release + 签名 | `./build-android.sh all --release --sign` |

怎么确认手上的是哪一类：

```bash
./build-android.sh report --quiet
#   打包指纹 : 命中（apk 会跳过 Gradle；stamp 记录 aab=0 type=debug）

# 或者看文件名
#   ...-903a173-debug.apk          <- debug
#   ...-release-unsigned.apk       <- release，还没签名
#   ...-debug-signed.apk           <- 签过名的

# 或者看 APK 内的构建元数据
unzip -p dist/xxx.apk META-INF/com/android/build/gradle/app-metadata.properties
```

补充两点：

- `dev` 始终走 **debug 变体**（`KRITA_GRADLE_TASK=installDebug`），它不参与 release；release 只能走 `apk --release` 或 `all --release`。
- 签名只与打包层有关：debug 包由 Gradle 用 debug keystore 自动签好（`minSdk=24`，只写 v2/v3），release 包是 `-unsigned`，必须再 `sign`。

---

### 33. `./build-android.sh deb` 的常见问题

**Q：`--install-deps` 提示要密码 / 报 "需要 root 权限"**
A：它内部对每条 `apt-get` 都用 `sudo`，所以会要你的密码（交互输入）。
如果不想让脚本动系统：先跑 `--check-deps`，它会打印一条现成的
`sudo apt-get install -y <包...>`，你自己执行；装完后直接跑 `./build-android.sh deb` 即可
（脚本每次都会复查依赖，不依赖 `--install-deps` 的状态）。

**Q：编译多久？**
A：首次 30~60 分钟（16 核，RelWithDebInfo）；之后改代码走增量。想快些可用 `--build-type Release`。

**Q：为什么是 `_build_linux` 而不是 `_build`？**
A：`_build` 是 Android（NDK 交叉编译）的 CMakeCache，工具链/系统名完全不同，混用会互相覆盖并
出现"架构不匹配"的链接错误。见 §十一 第 3 张对比表。

**Q：`dpkg-deb: error: invalid package name 'xxx'`**
A：早期版本会把日志行写进 `Depends`（`compute_depends` 在命令替换里调用了 `log`）。
现在这些提示统一走 stderr，`Depends` 只包含 `dpkg-shlibdeps` / `ldd` 的结果。
真遇到了用 `--pack-only` 重打包即可，不用重编。

**Q：装好之后怎么运行 / 卸载？**

```bash
sudo apt install ./dist/krita_5.4.0~prealpha_amd64.deb   # 装
krita                                                     # 运行
sudo apt remove krita                                     # 卸
```

**Q：KSeExpr / MLT / JPEGXL 缺了会怎样？**
A：Krita 里它们都是 OPTIONAL/RECOMMENDED。缺 KSeExpr → 少 SeExpr 填充层；
缺 MLT → 少部分动画渲染；缺 JPEGXL → 少一种图像格式。核心绘画不受影响。
想装全就 `deb --install-deps`（不要加 `--skip-optional`）。

---

### 34. `build-android.sh` 和 `build-android.bat` 有什么区别？

一份逻辑 + 两个平台外壳：

| 文件                  | 角色              | 关键点                                                                                                                               |
| ------------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `build-android.sh`  | **核心分发器**（bash） | 所有子命令都在这里分发；只能在 Linux / WSL / Git Bash 下跑                                                                                         |
| `build-android.bat` | **Windows 启动器** | 找 Git Bash（拒绝 `C:\Windows\System32\bash.exe`，那是 WSL 启动器）→ `chcp 65001` → 调 `scripts/run.sh` 记日志 → 调 `build-android.sh`；失败/双击时保持窗口 |
| `wsl-build.bat`     | **预设快捷方式**      | 正文就一句 `call ..\build-android.bat wsl-oneclick %*`                                                                                    |

```text
Linux / WSL / Git Bash ─→ build-android.sh          （唯一实现）
Windows cmd / 双击 ─→ build-android.bat ─→ run.sh ─→ build-android.sh
                      entrypoints/wsl-build.bat = call ..\build-android.bat wsl-oneclick
```

两个容易踩的坑：

- `wsl-build.bat check` **不会**只检查环境：它固定跑 `wsl-oneclick`，`check` 会透传到 `all` 后被忽略，
  照样开始完整构建。只想检查用 `wsl-check.bat` / `build-android.bat check`。
- 在 `cmd` 里直接敲 `build-android.sh` 不成立（bash 语义 + `/c/...` 路径），Windows 上必须走 `.bat`。

完整对照表、等价写法见 §〇 的「三个入口的关系」。

### 35. `Skipping following packages as the license is not accepted` / 装完却找不到 NDK

**现象**（多在第一次跑 `wsl-build.bat` 装 SDK 时）：

```text
January 16, 2019
---------------------------------------
Accept? (y/N): Skipping following packages as the license is not accepted:
NDK (Side by side) 27.3.13750724
  ndk;27.3.13750724

[err]  sdkmanager 安装后仍找不到 NDK: .../android/sdk/ndk/27.3.13750724
```

**原因**：`sdkmanager` 在安装任何组件之前都会校验 `$SDK/licenses/`。
如果 SDK 被清空过（或是一台新机器），`licenses/` 也不在了；而非交互环境下那个
`Accept? (y/N):` 读到的是 EOF，等同于回答 `N` —— 于是它把 `ndk;...` **"跳过"** 了，
而且**退出码仍然是 0**，所以表现出来就是"装完了却没有 NDK"。

**已修复**：[`scripts/10-setup-sdk.sh`](scripts/10-setup-sdk.sh:1) 现在

1. 把"接受许可证"**提前到安装 NDK 之前**（原来的顺序是先装 NDK、再接受许可证，正好反了）；
2. 判据改成"`$SDK/licenses/` 里是否出现文件"，而不是看命令退出码
   （`yes | sdkmanager` 在 sdkmanager 提前退出时会收到 SIGPIPE 返回 141，配合 `pipefail` 会被误判成失败）；
3. 安装 NDK / 各 SDK 组件失败时，自动再喂一遍 `y` 重试一次。

**现在怎么修**：直接重跑即可

```bat
entrypoints/wsl-build.bat        rem 或者只补 SDK： entrypoints\wsl-setup.bat
```

只想单独接受许可证（不装任何组件）：

```bash
./build-android.sh sdk --licenses-only
```

验证：

```bash
ls ~/android/sdk/licenses     # 应有 8 个文件（android-sdk-license 等）
ls ~/android/sdk/ndk          # 应有 27.3.13750724
```

> 顺带说明：`build-android.bat check` 报 `javac 21` 是 **Windows 侧** 的 JDK，和 `wsl-build.bat` 无关 ——
> WSL 构建用的是发行版内 apt 装的 JDK 17。只有 `windows\krita-build.bat`（原生 `krita.exe`）才真的需要 Windows 侧 JDK 17。

### 36. `deps` 卡在「依赖仍缺失: .../ECMConfig.cmake」，`--only-deps` 装了 0 个包

**现象**：

```text
==> 5.5/6 校验依赖安装目录
    [warn] 依赖目录为空或缺少 ECM
    [warn] 本地缓存不可用，改用 run-ci-build.py --only-deps 尝试下载安装

==> 5/6 run-ci-build.py
    ## Disable ECM's Android toolchain file: True
    [err]  依赖仍缺失: .../_install/share/ECM/cmake/ECMConfig.cmake
```

注意中间**只有一行输出**，没有任何 `## Fetching dependency:` / `## Unpacking dependency:`。

**原因**：`run-ci-build.py --only-deps` 的依赖清单来自 `$KRITA_SRC/.kde-ci.yml` 的
`Dependencies:` 段。而 **krita 仓库自带的 `.kde-ci.yml` 只有 `Options` / `PostInstallScripts`，
没有 `Dependencies`** —— 于是它解析出 **0 个依赖**、**返回码 0**，看起来"成功"，
实际一个包都没下载，直到紧跟着的 ECM 校验才暴露。

依赖清单必须由 `krita-deps-management` 的种子文件生成：

```bash
cd <你的源码>/krita
python3 krita-deps-management/tools/replace-branch-in-seed-file.py \
        krita-deps-management/latest/krita-deps.yml -p -o branch-corrected-deps.yml -d master
python3 krita-deps-management/tools/generate-deps-file.py \
        -s branch-corrected-deps.yml -o .kde-ci.yml
grep -c '^Dependencies:' .kde-ci.yml      # 应该是 1
```

**已修复**：[`scripts/30-fetch-deps.sh`](scripts/30-fetch-deps.sh:1) 在真正 fetch 依赖
（`--only-deps` 或 `--full-deps`）之前会检查 `.kde-ci.yml` 是否含 `Dependencies:`，
没有就自动按上面两步生成一份，生成后再校验一次。

**实测**（Debian 13 / WSL2 / arm64-v8a）：

```text
## Unpacking dependency: ext_qt (FromRemote)
## Unpacking dependency: ext_mlt (FromRemote)
## Unpacking dependency: ext_seexpr (FromRemote)
## Unpacking dependency: ext_kimageformats (FromRemote)
... 共 30 个 ext_* 预编译包

_install = 1.2G
_install/share/ECM/cmake/ECMConfig.cmake  ← 已就位
```

**注意**：生成后 `.kde-ci.yml` 会变成 dirty（`git status` 能看到），这是**预期**的；
想让源码树保持干净：

```bash
git -C <你的源码>/krita checkout -- .kde-ci.yml
```

> 顺带解释你可能会疑惑的一点：`--dry-run` 会打印
> `ERROR: argument --skip-dependencies-fetch conflicts with --only-deps`。
> 那是 `run-ci-build.py` 内部 `if arguments.dry_run: arguments.skip_dependencies_fetch = True`
> 造成的，**真实运行时不会出现**，不是错误。

---

## 八、环境变量的等价手工命令

脚本解析后等价于官方文档中的以下手工设置（可用 `./build-android.sh env` 查看当前值）：

```bash
export ANDROID_ROOT=$HOME/android
export KDECI_ANDROID_SDK_ROOT=$ANDROID_ROOT/sdk
export KDECI_ANDROID_NDK_ROOT=$ANDROID_ROOT/sdk/ndk/27.3.13750724
export ANDROID_HOME=$ANDROID_ROOT/sdk
export PATH="$ANDROID_ROOT/sdk/platform-tools/:$ANDROID_ROOT/cmdline-tools/bin/:$PATH"
export KDECI_ANDROID_ABI=arm64-v8a      # 真机；模拟器/CI 用 x86_64
```

Android 环境一旦变化（例如切换 ABI），只需修改配置文件后重新执行对应步骤，脚本会自动重新生成 `base-env` 与 `env`。

---

## 九、Windows 原生构建（可选，生成 `krita.exe`）

本目录前半部分都是 **Android APK**（Linux/WSL2 构建）；如果你还想在 Windows 上
**原生编译 Krita 桌面版**（llvm-mingw + Ninja + CMake 3.31），用的是另一套脚本：

> 以下命令同样在 **本目录** 下执行（`windows\` 是相对路径）。

```bat
windows\krita-build.bat check                        rem 看环境缺什么
windows\krita-build.bat all -InstallPython           rem 一条命令：工具链 + 依赖 + 源码 + 配置 + 编译
windows\krita-build.bat all -Root D:\krita           rem 全部放到 D 盘（D:\krita\dev + D:\krita\deps）
windows\krita-build.bat run                          rem 启动 _install\bin\krita.exe
```

- 详细用法、参数、与官方文档的差异核对、FAQ：见 [`windows/README.md`](windows/README.md:1)。
- 默认工作区 `C:\krita-dev`，工具链 `C:\deps`，均可用 `-Workspace` / `-DepsRoot` 改（路径不能有空格）。
- 缺 Python 3.13 时加 `-InstallPython`：下载官方包静默装到 `<DepsRoot>\python313`，
  **不写系统 PATH、不装 py launcher**，也不影响你系统里已有的其他 Python。
- **想放在别的盘符**：只加 `-Root <盘符>:\<目录>`（如 `-Root D:\krita`），
  工具链（`<Root>\deps`）、源码、依赖包缓存（`<Root>\dev\cache`）、构建产物**全部**落在该盘；
  脚本下载前会校验盘符存在、可写、剩余 ≥5GB，不可用（例如光驱 `D:`）会直接报错并列出可用盘符。
- **工具链全部来自 `<DepsRoot>`（默认 `C:\deps`）**（llvm-mingw / CMake 3.31 / Ninja / Python 3.13 都是脚本下载的，
  编译器用 `-DCMAKE_C_COMPILER` 显式指向该目录），不会使用系统里已装的 CMake 4.x、其他 Python 或 MSYS 工具；
  唯一外部依赖是 Git 与 Windows 自带的 UCRT。要复用系统工具需显式加 `-UseSystemTools`。
- **增量**：`configure` 与 `build` 各自写一份 stamp（源码 HEAD + 未提交改动 + 编译器 + CMake 参数），
  没变化就整步跳过；`info` 会显示「增量状态」。强制重编加 `-Force`，从零来加 `-CleanBuild`。
- **看日志**：每次运行写 `<Workspace>\logs\win-build-<时间戳>.log` 并复制 `latest.log`；
  `windows\krita-build.bat logs` 会列出日志目录、最近 10 个文件，并打印 `latest.log` 末尾 40 行。
- **每步耗时**：每个 `-Step` 结束时打印 `[步骤] 用时 x.x s`，整套流程末尾打印总用时，便于发现哪一步变慢。
- **启动参数**：`-Step run -RunArgs "--version"` 可给 `krita.exe` 传参（默认不带参数直接启动）。
- **env 也是增量的**：`krita-deps-management` / `ci-utilities` 的 commit 没变且 `env.bat` 在
  → 第 3 步直接跳过（不联网）；改动后用 `env -RefreshEnv` 强制刷新。实测 `all` 约 **2 秒**。
- 已实测：自动识别/补齐 llvm-mingw、ninja、CMake 3.31.x，自动安装 Python 3.13.11，
  自动下载约 100 个 Windows 预编译依赖，`cmake` 配置与 `ninja install` 均可跑通。

---

## 十、自检与 CI（lint + 构建）

仓库根的 `.github/workflows/` 里有三个工作流，互相独立：

| 文件                                                                                          | 做什么                                   | 触发                               | 产物                                    |
| ------------------------------------------------------------------------------------------- | ------------------------------------- | -------------------------------- | ------------------------------------- |
| [`local-build-lint.yml`](../../../.github/workflows/local-build-lint.yml:1)                 | 静态检查（语法 / 行尾 / BOM / 文档一致性）           | **仅手动** `Run workflow`             | 无（失败即红）                                |
| [`local-build-windows.yml`](../../../.github/workflows/local-build-windows.yml:1)           | 原生 Windows 构建（llvm-mingw + Ninja）    | **仅手动** `Run workflow`             | `krita-windows-x86_64-<sha>.zip`         |
| [`local-build-android.yml`](../../../.github/workflows/local-build-android.yml:1)           | Android APK / AAB（Linux）              | **仅手动** `Run workflow`             | `krita-*.apk` / `krita-*.aab`            |

> 三个工作流都**不会随 push / PR 自动运行**，只在 Actions 页面点 `Run workflow` 时执行；
> 想恢复自动触发，把对应 yml 里 `on:` 下注释掉的 `push:` / `pull_request:` 打开即可。

### 1. lint：只做静态检查

`local-build-lint.yml` 手动触发一次即可跑完下面四项，不编译、不下载，几十秒结束：

| 检查         | 命令                                                               | 抓什么                                                                                                                                 |
| ---------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| bash 语法    | `bash scripts/check-syntax.sh`                                   | `bash -n` 全部 `*.sh`（可选 shellcheck）                                                                                                  |
| 行尾策略       | `bash scripts/fix-line-endings.sh --check --strict`              | `.sh`/`.md` 必须 LF，`.bat`/`.ps1` 必须 CRLF；有偏差即失败                                                                                      |
| PowerShell | [`scripts/check-powershell.ps1`](scripts/check-powershell.ps1:1) | `windows/*.ps1` **UTF-8 with BOM** + CRLF + AST 解析；`windows/`、`entrypoints/` 与本目录根部的 `*.bat` 纯 ASCII                              |
| **文档一致性**  | [`scripts/check-docs.sh`](scripts/check-docs.sh:1)               | ① 命令表写了但代码不认 ② 脚本没进 §二 / `.bat` 没进 §〇 ③ FAQ 编号断号或重复 ④ README 提到的开关脚本没解析 ⑤ `config` 示例里的变量没进 §五 配置表 ⑥ 脚本读取的 `KRITA_*` 环境变量 README 没提 |

### 怎么确认这些检查真的跑过了？

| 方式       | 做法                                                            | 说明                                                                                           |
| -------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| 网页       | 打开 `https://github.com/<owner>/<repo>/actions`，找名为 `local-build-lint` 的运行 | 私有仓库需要登录；在 Actions 页面点 `Run workflow` 手动发起                                          |
| 命令行      | `gh run list --limit 5` / `gh run watch`                      | 需先装 [GitHub CLI](https://cli.github.com/) 并 `gh auth login`；本机若没装 `gh`，匿名调 API 对私有仓库只会得到 404 |
| **本地等价** | 直接跑下面三条命令                                                     | **和 CI 用的是同一批脚本、同一套判定**，本地绿基本等价于 CI 绿                                                        |

> 三者里最靠谱的是本地等价执行：CI 只是把同样的脚本在 `ubuntu-latest` + `pwsh` 上再跑一遍，
> 而 `check-powershell.ps1` 判断 BOM / CRLF 用的是读字节，与用哪个 PowerShell 版本无关，
> 所以在 Windows 上用 PowerShell 5.1 跑出来的结论与 CI 一致。

本地等价执行（Windows）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\check-powershell.ps1
```

```bash
# Git Bash / WSL
bash scripts/check-syntax.sh
bash scripts/fix-line-endings.sh --check --strict
```

> 为什么要这么严：PowerShell 5.1 读**不带 BOM** 的 UTF-8 会按 GBK 解码，
> 中文字符串全乱、甚至直接语法错误；而 `cmd.exe` 对非 ASCII 的 `.bat` 也会解析异常。
> 这两类问题在 CI 里几秒钟就能拦住，不必等一次 40 分钟的编译才发现。

### 2. Windows / Android 构建工作流

两个构建工作流都只手动触发（`workflow_dispatch`），**提交/推送不会自动执行**，
避免每次提交都跑几小时的重活。想改成"打标签自动构建"，把 yml 里注释掉的
`on.push.tags`（`windows-build-*` / `android-build-*`）打开即可。

| 工作流     | 输入          | 说明                                                                 |
| ------- | ----------- | ------------------------------------------------------------------ |
| Windows | `runner`    | runner 标签，默认 `windows-latest`；有更大或自托管的 Windows 机器时填它                  |
| Windows | `jobs`      | `ninja -jN`，默认 `2`（runner 核少，别开太大）                                  |
| Windows | `source_ref` | 要构建的 Krita 分支 / tag；留空 = 本次运行的分支                                    |
| Windows | `repo_url`  | 源码仓库地址；留空 = 本仓库（fork 会自动用它，而不是 invent.kde.org）                      |
| Android | `runner`    | 默认 `ubuntu-latest`；**Krita Android 需要 ~30 GB 磁盘，建议用更大或自托管的 Linux runner** |
| Android | `abi`       | `arm64-v8a`（默认，真机）/ `armeabi-v7a` / `x86_64`（模拟器）                   |
| Android | `package`   | `debug`（默认，可直接装机）/ `release` / `nightly`                            |
| Android | `aab`       | 同时生成 AAB                                                           |
| Android | `jobs`      | 并行编译数；留空 = 核数                                                       |

两个工作流的做法：

- **Windows**：等价于 `windows\krita-build.bat all -Root C:\krita -InstallPython -Shallow`，
  产物在 `C:\krita\dev\_install`，压成 `krita-windows-x86_64-<sha>.zip` 上传；
  `C:\krita\deps`（工具链）、`dev\cache`、`dev\krita-deps-management`、`dev\PythonEnv` 走缓存。
- **Android**：等价于在 `build-tools/local-build` 里执行 `./build-android.sh all --jobs N`；
  它**复用本次 checkout 作为 Krita 源码**（符号链接挂到 `$SRCDIR/krita`），
  所以打出来的 APK 就是当前提交，而不是另克隆的上游 master；
  SDK/NDK 与 venv/依赖下载分别走 `actions/cache`。
- 两者都会在失败时额外上传 `logs/` 工件；`release` 包是 `-unsigned` 的，
  要签名请配好 keystore 后改用 `./build-android.sh sign`（或本地 `--sign`）。

#### 日志（尽量"完备"）

| 场景                 | 内容                                                                                                                                                          |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 控制台                | 脚本每执行一条命令都会先打印 `$ <命令>`，子进程 stdout/stderr 实时透传（`2>&1`），Actions 的步骤日志就是完整原始输出                                                                    |
| Android 完整日志       | 工作流通过 [`scripts/run.sh`](scripts/run.sh:1) 启动，完整输出 tee 到 `build-tools/local-build/logs/<时间戳>-all.log`，并维护 `logs/latest.log`                              |
| Android 诊断快照       | `logs/diagnostics/`：`summary.txt`（uname / CPU / 磁盘 / 内存 / 工具版本 / `KRITA_*` 等配置 / git HEAD 与 dirty 列表 / dist 清单）、`env`、`base-env`、`CMakeCache.txt`、`CMakeOutput.log`、`CMakeError.log` |
| Windows 完整日志       | `build-krita-windows.ps1` 自身同时写控制台与 `C:\krita\dev\logs\win-build-<时间戳>.log`，并维护 `latest.log`                                                              |
| 工件                 | 两个工作流都在 `always()` 时上传 `*-build-logs-*`（保留 7 天）——失败与成功都留档                                                                                                  |
| 运行摘要               | 失败时把第一条 `[err]` / `[ERR]` 用 `::error::` 注解，并把日志最后 150–200 行贴进 Summary，无需下载工件即可定位                                                                     |
| 磁盘监控               | 构建期间**每 30 秒**打印一行 `[disk] HH:MM:SS  <大小> total, <已用> used, <剩余> free (<百分比> used)`：Android 写进同一份 `-all.log`，Windows 写进 `win-build-*.log`（构建开始前先打一行基线）；`KRITA_DISK_MONITOR=0` 关闭，`KRITA_DISK_MONITOR_INTERVAL=N` 改间隔 |

---

## 十一、Linux 桌面版 `.deb`（可选）

前面所有章节都是 **Android APK**；这一节是 **Linux 桌面版**：在 Linux / WSL2 里用
**系统 Qt5 + KF5** 编译出 `krita`，再打成可以直接 `apt install` 的 `.deb`。

> 官方仓库的 `packaging/linux/` 只有 **appimage / flatpak / snap**，**没有 deb**。
> 所以这个 deb 是本目录自己组装的 —— 它是"你自己构建的包"，不是官方发行版包。

### 1. 三条命令

```bash
./build-android.sh deb --check-deps      # 只看缺什么（不装、不改）
./build-android.sh deb --install-deps    # apt 装齐 60+ 个 -dev 包（需要 sudo）
./build-android.sh deb                   # 配置 + 编译 + 打包（增量）
```

Windows 上双击 [`deb.bat`](entrypoints/deb.bat:1)（参数会自动转进 WSL）。

产物：`dist/krita_<版本>_<架构>.deb`，例如 `dist/krita_5.4.0~prealpha_amd64.deb`。

### 2. 它到底做了什么

| #   | 动作   | 细节                                                                                                                                                          |
| --- | ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | 依赖   | `apt-get install -y --no-install-recommends <60+ 个 -dev 包>`；`--skip-optional` 可跳过 KSeExpr/MLT/JPEGXL/PyQt5 等                                                |
| 2   | 配置   | `cmake -S <源码> -B <源码>/_build_linux -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_TESTING=OFF -DKDE_SKIP_TEST_SETTINGS=ON` |
| 3   | 编译   | `cmake --build _build_linux --parallel N`（首次约 30~60 分钟@16 核）                                                                                                |
| 4   | 安装   | `DESTDIR=_build_linux/staging cmake --install` → 得到一棵 `/usr/...` 目录树                                                                                        |
| 5   | 依赖计算 | `dpkg-shlibdeps` 扫所有 ELF 生成 `Depends`；失败则回退 `ldd` + `dpkg -S`，再失败用内置列表                                                                                      |
| 6   | 打包   | 生成 `staging/DEBIAN/control` → `dpkg-deb --build --root-owner-group`                                                                                         |

`DEBIAN/control` 里写了：`Package: krita`、版本（从构建产物 `kritaversion.h` 读，
`5.4.0-prealpha` 会转成 Debian 规范的 `5.4.0~prealpha`）、`Architecture`（`dpkg --print-architecture`）、
`Installed-Size`、`Section: graphics`、`Depends`（自动算）。

### 3. 与 Android 流水线完全隔离

|      | Android（`apk` / `all`） | Linux 桌面（`deb`）             |
| ---- | ---------------------- | --------------------------- |
| 产物   | `dist/*.apk`           | `dist/krita_*.deb`          |
| 构建目录 | `<源码>/_build`          | `<源码>/_build_linux`         |
| 安装目录 | `<源码>/_install`        | `<源码>/_build_linux/staging` |
| 工具链  | NDK r27d 交叉编译          | 系统 gcc + 发行版 Qt5/KF5        |
| 源码   | **共用**同一份 `krita` 检出   | 同左                          |

脚本会主动 `unset CC/CXX/ANDROID_*`，避免把 Android 的工具链带进 Linux 配置。
两边可以来回切换，互不影响。

### 4. 常用开关

| 开关                    | 作用                                                                               |
| --------------------- | -------------------------------------------------------------------------------- |
| `--check-deps`        | 只检查依赖；有缺失时打印一条可直接复制的 `apt-get install` 命令，退出码 2                                  |
| `--install-deps`      | 自动 `apt-get update && install`（`--no-update` 跳过 update，`--skip-optional` 少装可选项）  |
| `--build-type T`      | `RelWithDebInfo`（默认）/ `Release` / `Debug`                                        |
| `--qt6`               | 走 Qt6 路线（`-DBUILD_WITH_QT6=ON`）；**实验性**，源码 Qt6 分支是 `6.x-prealpha`，需要 KF6 + ECM 6 |
| `--jobs N`            | 并行数（默认核数）                                                                        |
| `--prefix PATH`       | 安装前缀，写进包内路径（默认 `/usr`；想装到 `/usr/local` 就改这个）                                     |
| `--out DIR`           | `.deb` 输出目录（默认 `dist/`）                                                          |
| `--pack-only`         | 不编译，只用现有 staging 重新生成 `.deb`（配合 `KRITA_LINUX_STAGING=/某/staging`）                |
| `--no-deb`            | 只编译并安装到 staging，不打包（调试用）                                                         |
| `--force` / `--clean` | 忽略增量标记 / 删掉 `_build_linux` 从零来                                                   |
| `--dry-run`           | 只打印命令                                                                            |

### 5. 本机实测（Debian 13 trixie / WSL2 / x86_64）

- 依赖在 trixie 全部可用：`qtbase5-dev 5.15.15`、`libkf5* 5.116.0`、`libkseexpr-dev 4.0.4`、
  `libmlt-dev`、`libjxl-dev`、`libimmer-dev`、`libzug-dev` …（`--check-deps` 逐个核对过）
- **KSeExpr 在 Krita 里是 OPTIONAL**（只影响 SeExpr 填充层），缺了也能编
- deb 组装链路已实测：用最小 staging（一个 ELF + 一个 `.desktop`）打出 14 KB 的 deb，
  `dpkg-deb -I` 显示 `Depends: libc6 (>= 2.34)`（由 `dpkg-shlibdeps` 自动算出），属主 `root/root`
- `--install-deps --dry-run` 会完整打印 67 个包的安装命令（可在别的机器上直接复制）

### 6. 两点提醒

- **不要用 `sudo` 跑整个构建**：`--install-deps` 内部会自己用 sudo；编译本身应该用普通用户，
  否则 `_build_linux` 里会留一堆 root 属主文件，之后的增量构建会报权限错。
- Qt6 路线（`--qt6`）目前是"能配就配"，别指望一次成功：Krita 的 Qt6 分支还在 prealpha，
  依赖 KF6 全家桶。日常请用默认的 Qt5 路线。
