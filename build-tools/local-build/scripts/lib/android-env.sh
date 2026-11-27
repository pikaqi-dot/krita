#!/usr/bin/env bash
# =============================================================================
#  android-env.sh —— Krita Android 构建：配置解析 / 路径推导 / 工具封装
#
#  用法：
#      source "<repo>/scripts/lib/android-env.sh"
#      load_config                      # 解析配置文件 + 默认值 + 导出变量
#
#  解析完成后可用（关键变量）：
#      $KRITA_SRC             Krita 源码目录            ($SRCDIR/krita)
#      $BUILD_DIR             cmake 构建目录            ($KRITA_SRC/_build)
#      $KRITA_INSTALL_DIR     make install 目标目录     ($KRITA_SRC/_install)
#      $PACKAGING_DIR         APK/AAB 输出目录          ($KRITA_SRC/_packaging)
#      $KDECI_ANDROID_SDK_ROOT / $KDECI_ANDROID_NDK_ROOT / $KDECI_ANDROID_ABI
#      $KRITA_TOOLCHAIN_FILE  android-toolchain-krita.cmake
# =============================================================================

if [[ -n "${_KRITA_ANDROID_ENV_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_KRITA_ANDROID_ENV_LOADED=1

_ANDROID_ENV_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_ANDROID_ENV_LIB_DIR/common.sh"

detect_platform

# lib 目录位于 <项目根>/scripts/lib，因此项目根需要上溯两级
PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$_ANDROID_ENV_LIB_DIR/../.." && pwd)}"
export PROJECT_ROOT

# ---------------------------------------------------------------------------
# 配置文件位置
# ---------------------------------------------------------------------------
config_file() {
    printf '%s\n' "${KRITA_ANDROID_CONFIG:-$PROJECT_ROOT/config/android-build.conf}"
}

# ---------------------------------------------------------------------------
# 默认值（配置文件中的同名变量优先级更高）
# ---------------------------------------------------------------------------
resolve_defaults() {
    # --- 目标平台 ---
    # 默认构建 arm64-v8a：这是真机（手机/平板）用的架构。
    # 官方文档与 KDE CI 示例用的是 x86_64（供模拟器使用），本项目不涉及模拟器。
    # 如需 x86_64：ANDROID_ABI=x86_64（切换 ABI 会重新获取依赖并全量重编）。
    : "${ANDROID_ABI:=arm64-v8a}"                    # arm64-v8a | armeabi-v7a | x86_64
    : "${ANDROID_API:=23}"                           # Krita 最低 API 级别
    : "${ANDROID_PLATFORM:=android-33}"              # 编译用 SDK 平台
    # NDK 版本：官方文档写的是 r22b，但 CI 预编译的 Android 依赖是用 NDK r27d 构建的
    # （实测 _install 里有 3422 处 android-ndk-r27d 引用），用 r22b 链接会因 libc++ ABI
    # 不匹配报 "undefined symbol: vtable for std::__ndk1::basic_ostringstream"。
    # 因此默认使用 r27d 对应的 sdkmanager 包版本；要回到文档的 r22b 请设为 r22b。
    : "${ANDROID_NDK_VERSION:=27.3.13750724}"
    : "${ANDROID_NDK_ROOT:=}"
    : "${ANDROID_BUILD_TOOLS:=30.0.3 34.0.0}"
    : "${ANDROID_EXTRA_PACKAGES:=}"

    # --- 目录 ---
    # KRITA_ANDROID_ROOT 显式优先级最高：CI（或任何被宿主环境污染的场景）里
    # ANDROID_ROOT 可能已被别的工具设为系统路径，这里允许强制指定本流程的根目录。
    if [[ -n "${KRITA_ANDROID_ROOT:-}" ]]; then
        ANDROID_ROOT="$KRITA_ANDROID_ROOT"
    fi
    : "${ANDROID_ROOT:=$HOME/android}"               # SDK/NDK/cmdline-tools 根目录
    : "${WORKDIR:=$HOME/persistent}"                 # 缓存与 venv 根目录
    : "${SRCDIR:=$WORKDIR/sources}"                  # 源码根目录
    : "${ENVDIR:=$WORKDIR/envdir}"                   # 包与缓存目录
    : "${VENVDIR:=$WORKDIR/PythonEnv}"               # Python venv

    # --- Krita 仓库与构建 ---
    : "${KRITA_BRANCH:=master}"
    : "${KRITA_CMAKE_BUILD_TYPE:=RelWithDebInfo}"
    : "${KRITA_GRADLE_TASK:=installDebug}"
    : "${KRITA_APP_ID:=org.krita.debug}"
    : "${KRITA_MAIN_ACTIVITY:=org.krita.android.MainActivity}"
    : "${KRITA_JOB_COUNT:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)}"
    : "${KRITA_MIN_FREE_GB:=30}"
    : "${KRITA_FETCH_FULL_DEPS:=0}"                  # 1 = 不加 --only-env（真正下载/编译依赖）

    # --- 产物导出 ---
    : "${KRITA_COPY_TO_DESKTOP:=1}"                  # 1 = 打包后额外复制一份到 Windows 桌面
    : "${KRITA_EXPORT_DIRS:=}"                       # 额外复制目标目录（空格分隔）

    : "${KRITA_REPO_URL:=https://invent.kde.org/graphics/krita.git}"
    : "${KRITA_DEPS_MGMT_URL:=https://invent.kde.org/packaging/krita-deps-management.git}"
    : "${KRITA_CI_UTILS_URL:=https://invent.kde.org/packaging/krita-ci-utilities.git}"

    # --- 下载地址（留空则按平台自动推断） ---
    : "${ANDROID_CMDLINE_TOOLS_URL:=}"
    : "${ANDROID_NDK_URL:=}"

    # --- WSL ---
    : "${WSL_DISTRO:=}"
}

# ---------------------------------------------------------------------------
# NDK 目录解析
#   优先级： 1) 显式 ANDROID_NDK_ROOT
#            2) $SDK/ndk/<version>              （sdkmanager 安装，如 27.3.13750724）
#            3) $ANDROID_ROOT/android-ndk-<ver> （官方 zip 解压布局，如 r22b）
# ---------------------------------------------------------------------------
resolve_ndk_root() {
    local v="$ANDROID_NDK_VERSION"

    # 显式 ANDROID_NDK_ROOT 优先，但必须是"真的 NDK"（含 source.properties）。
    # 这一点在 CI 上很关键：runner 镜像会预置 ANDROID_NDK_ROOT 指向它自带的
    # NDK，而本流程把 SDK/NDK 装在自己的 ANDROID_ROOT 下、镜像那份可能已被删除。
    # 指向不存在的目录时忽略它，避免"装好了却仍报找不到 NDK"。
    if [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then
        if [[ -f "$ANDROID_NDK_ROOT/source.properties" ]]; then
            printf '%s\n' "$ANDROID_NDK_ROOT"
            return 0
        fi
        warn "忽略无效的 ANDROID_NDK_ROOT=$ANDROID_NDK_ROOT（目录里没有 source.properties）"
    fi

    local sdk_ndk="$KDECI_ANDROID_SDK_ROOT/ndk/$v"
    if [[ -f "$sdk_ndk/source.properties" ]]; then
        printf '%s\n' "$sdk_ndk"
        return 0
    fi

    local zip_ndk="$ANDROID_ROOT/android-ndk-$v"
    if [[ -f "$zip_ndk/source.properties" ]]; then
        printf '%s\n' "$zip_ndk"
        return 0
    fi

    # 都不存在时给出 sdkmanager 布局（安装步骤会创建它）
    printf '%s\n' "$sdk_ndk"
}

# ---------------------------------------------------------------------------
# 推导路径
# ---------------------------------------------------------------------------
derive_paths() {
    ANDROID_ROOT="$(normalize_slashes "$ANDROID_ROOT")"
    WORKDIR="$(normalize_slashes "$WORKDIR")"
    SRCDIR="$(normalize_slashes "$SRCDIR")"
    ENVDIR="$(normalize_slashes "$ENVDIR")"
    VENVDIR="$(normalize_slashes "$VENVDIR")"

    KRITA_SRC="$SRCDIR/krita"
    # CMake 会把"传进去的路径"当作 CMAKE_SOURCE_DIR。如果这里是符号链接，
    # 它和 realpath 不一致，ECM/KDE 的安装目录逻辑就会把差值反复拼上去
    # （.../.ci/src/krita/.ci/src/krita/...），最后 CMAKE_INSTALL_PREFIX
    # 指向不存在的目录，configure 报 set_property DIRECTORY ... not found。
    if [[ -L "$KRITA_SRC" ]]; then
        warn "KRITA_SRC 是符号链接: $KRITA_SRC -> $(readlink -f -- "$KRITA_SRC" 2>/dev/null || echo '?')"
        warn "  可能导致 CMake 路径递归；建议让 \$SRCDIR/krita 是真实目录（不要用 symlink 挂源码）"
    fi
    DEPS_MGMT_DIR="$KRITA_SRC/krita-deps-management"
    CI_UTILS_DIR="$DEPS_MGMT_DIR/ci-utilities"
    BUILD_DIR="$KRITA_SRC/_build"
    PACKAGING_DIR="$KRITA_SRC/_packaging"
    # 增量构建标记（内容 = krita_build_fingerprint 的输出）
    BUILD_STAMP_FILE="$BUILD_DIR/.krita-build-stamp"
    PACKAGE_STAMP_FILE="$PACKAGING_DIR/.krita-package-stamp"
    # 打包产物额外导出的位置：Windows 桌面（Git Bash / WSL 均可自动探测）
    KRITA_DESKTOP_DIR="${KRITA_DESKTOP_DIR:-$(windows_desktop_dir 2>/dev/null || true)}"
    KRITA_INSTALL_DIR="${KRITA_INSTALL_PREFIX:-$KRITA_SRC/_install}"
    KRITA_TOOLCHAIN_FILE="$DEPS_MGMT_DIR/tools/android-toolchain-krita.cmake"
    KRITA_CI_SCRIPTS_DIR="$KRITA_SRC/build-tools/ci-scripts"

    KDECI_ANDROID_ABI="$ANDROID_ABI"
    CMDLINE_TOOLS_DIR="$ANDROID_ROOT/cmdline-tools"
    KDECI_ANDROID_SDK_ROOT="$ANDROID_ROOT/sdk"
    KDECI_ANDROID_NDK_ROOT="$(resolve_ndk_root)"
    # 把 export 出去的 ANDROID_NDK_ROOT 对齐到"真正要用的 NDK"：
    # 环境里残留的无效路径（例如 CI runner 镜像预置的那份）不能继续传给
    # run-ci-build.py / cmake 工具链。
    ANDROID_NDK_ROOT="$KDECI_ANDROID_NDK_ROOT"
    ANDROID_HOME="$KDECI_ANDROID_SDK_ROOT"
    ANDROID_SDK_ROOT="$KDECI_ANDROID_SDK_ROOT"

    # run-ci-build.py 的工作目录（类似 CI 里的 /tmp/wd）：
    #   * 它会在这里放 _build 并生成 env：$KDECI_WORKDIR_PATH/<project>/env
    #   * 必须可写（不能用容器路径 /home/appimage/...，否则 PermissionError）
    #   * 必须与 Krita 自己的 _build 分开，否则两边会互相踩目录
    #   env 生成后，30-fetch-deps.sh 会把它复制到 $KRITA_SRC/env（文档的 ./env 位置）
    KDECI_WORKDIR_PATH="${KDECI_WORKDIR_PATH:-$WORKDIR/krita-workdir}"
    KDECI_SHARED_INSTALL_PATH="${KDECI_SHARED_INSTALL_PATH:-$KRITA_INSTALL_DIR}"
}

# ---------------------------------------------------------------------------
# ABI 标记
#   _install 里的预编译依赖、_build 里的 cmake 缓存都与 ABI 绑定；
#   切换 ABI 时必须重新获取依赖并重新配置，否则会出现"架构不匹配"的诡异链接错误。
# ---------------------------------------------------------------------------
ABI_STAMP_NAME=".krita-abi"

# 从 ELF 头读 e_machine，判断某个 .so 是哪个架构的：
#   x86_64 -> 0x3e   AArch64 -> 0xb7   ARM(32) -> 0x28
elf_abi_of_file() {
    local f="$1" bytes
    [[ -f "$f" ]] || return 1
    bytes="$(od -An -tx1 -j18 -N2 -- "$f" 2>/dev/null | tr -d ' \n')"
    case "$bytes" in
        3e00) printf 'x86_64\n' ;;
        b700) printf 'arm64-v8a\n' ;;
        2800) printf 'armeabi-v7a\n' ;;
        *)    return 1 ;;
    esac
}

# 当前 $KRITA_INSTALL_DIR 里的依赖究竟是哪个 ABI 的：
#   1) 优先读标记文件（本套脚本安装后写入）
#   2) 兼容旧版本：直接看已安装的 Qt 库 ELF 架构
installed_abi() {
    local marker="$KRITA_INSTALL_DIR/$ABI_STAMP_NAME"
    if [[ -f "$marker" ]]; then
        head -n 1 "$marker"
        return 0
    fi

    # Android 版 Qt 的库名里直接带架构：libQt5Core_x86_64.so / libQt5Core_arm64-v8a.so
    local f b
    for f in "$KRITA_INSTALL_DIR"/lib/libQt5Core_*.so* \
             "$KRITA_INSTALL_DIR"/lib/libQt6Core_*.so*; do
        [[ -e "$f" ]] || continue
        b="$(basename -- "$f")"
        b="${b%.so*}"          # libQt5Core_arm64-v8a / libQt5Core_x86_64
        b="${b#libQt5Core_}"   # arm64-v8a / x86_64
        b="${b#libQt6Core_}"
        printf '%s\n' "$b"
        return 0
    done

    # 再退回 ELF 头判断
    for f in "$KRITA_INSTALL_DIR"/lib/libQt5Core*.so* \
             "$KRITA_INSTALL_DIR"/lib/libc++_shared.so; do
        if elf_abi_of_file "$f"; then
            return 0
        fi
    done
    return 0
}

record_installed_abi() {
    [[ "${KRITA_DRY_RUN:-0}" == "1" ]] && return 0
    mkdir -p "$KRITA_INSTALL_DIR" 2>/dev/null || return 0
    printf '%s\n' "$ANDROID_ABI" >"$KRITA_INSTALL_DIR/$ABI_STAMP_NAME"
}

built_abi() {
    if [[ -f "$BUILD_DIR/$ABI_STAMP_NAME" ]]; then
        cat "$BUILD_DIR/$ABI_STAMP_NAME" 2>/dev/null | head -n 1
        return 0
    fi

    # 兼容没有标记文件的旧构建：
    # 1) Krita 的构建产物名里带 ABI（libkritaversion_arm64-v8a.so）
    local f b
    for f in "$BUILD_DIR"/lib/libkritaversion_*.so; do
        [[ -e "$f" ]] || continue
        b="$(basename -- "$f")"
        b="${b%.so*}"
        b="${b#libkritaversion_}"
        printf '%s\n' "$b"
        return 0
    done

    # 2) CMake 缓存里的痕迹（可能同时存在多个，取第一个非 OFF 的）
    if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
        sed -n 's/^ANDROID_BUILD_ABI_\([a-zA-Z0-9_-]*\):BOOL=ON$/\1/p' \
            "$BUILD_DIR/CMakeCache.txt" 2>/dev/null | head -n 1
    fi
}

record_built_abi() {
    [[ "${KRITA_DRY_RUN:-0}" == "1" ]] && return 0
    [[ -d "$BUILD_DIR" ]] || return 0
    printf '%s\n' "$ANDROID_ABI" >"$BUILD_DIR/$ABI_STAMP_NAME"
}

# ---------------------------------------------------------------------------
# 编译器标记
#   宿主机（Debian gcc 14）与 Docker 容器（Ubuntu gcc 13）用的编译器不同，
#   同一个 _build 里混用两套目标文件会链接失败；切换构建方式时自动清理。
# ---------------------------------------------------------------------------
current_compiler_id() {
    local v=""
    v="$(c++ --version 2>/dev/null | head -n 1 || true)"
    [[ -n "$v" ]] || v="unknown"
    printf '%s\n' "$v"
    return 0
}

built_compiler() {
    local f="$BUILD_DIR/.krita-compiler"
    # 注意：脚本开了 pipefail，不能写 `cat 不存在 | head`（cat 会以 1 退出，
    # 在 set -e 下把整个脚本带走）。这里先判断文件是否存在。
    if [[ -f "$f" ]]; then
        head -n 1 "$f" 2>/dev/null || true
    fi
    return 0
}

record_built_compiler() {
    [[ "${KRITA_DRY_RUN:-0}" == "1" ]] && return 0
    [[ -d "$BUILD_DIR" ]] || return 0
    current_compiler_id >"$BUILD_DIR/.krita-compiler"
}

# ---------------------------------------------------------------------------
# 增量构建指纹（"没变化就别重编/重打包"）
#
#   把会影响产物的一切输入压成一行字符串：
#     ABI / API / NDK 版本 / 构建类型 / 编译器 / 源码 HEAD / 源码是否有未提交改动
#     / krita-deps-management HEAD / Android 工具链 cmake 文件内容 / 安装前缀
#
#   40-build-krita.sh  成功后写  <build>/.krita-build-stamp
#   50-build-package.sh 成功后写 <packaging>/.krita-package-stamp
#   下次运行时指纹一致 + 产物存在 → 直接跳过（--force 可强制重跑）
#
#   任何一项变化（改代码、切分支、切 ABI、换 NDK/编译器、改工具链文件）都会
#   让指纹变化，从而自动重新编译 —— 不会漏掉该做的构建。
# ---------------------------------------------------------------------------
krita_build_fingerprint() {
    local src_head="nogit" src_dirty="nogit" deps_head="nogit" tc="none"

    if have_cmd git && [[ -d "$KRITA_SRC/.git" ]]; then
        src_head="$(git -C "$KRITA_SRC" rev-parse HEAD 2>/dev/null || echo nogit)"
        # 有过未提交改动也算"变了"：把 status 输出再哈希一次
        src_dirty="$(git -C "$KRITA_SRC" status --porcelain --untracked-files=no 2>/dev/null | hash_stdin)"
    fi
    if have_cmd git && [[ -d "$DEPS_MGMT_DIR/.git" ]]; then
        deps_head="$(git -C "$DEPS_MGMT_DIR" rev-parse HEAD 2>/dev/null || echo nogit)"
    fi
    [[ -f "$KRITA_TOOLCHAIN_FILE" ]] && tc="$(hash_file "$KRITA_TOOLCHAIN_FILE")"

    printf 'fp1|abi=%s|api=%s|ndk=%s|btype=%s|cc=%s|src=%s|dirty=%s|deps=%s|tc=%s|prefix=%s' \
        "$KDECI_ANDROID_ABI" "$ANDROID_API" \
        "$(basename -- "${KDECI_ANDROID_NDK_ROOT:-none}")" \
        "$KRITA_CMAKE_BUILD_TYPE" "$(current_compiler_id 2>/dev/null || echo unknown)" \
        "$src_head" "$src_dirty" "$deps_head" "$tc" "$KRITA_INSTALL_DIR"
}

# 打包指纹 = 编译指纹 + 是否要 AAB +（非 debug 时）包类型
#   50-build-package.sh 写 <packaging>/.krita-package-stamp 时用的就是它；
#   report.sh 也用它比较，避免两边格式漂移（曾经有一次就是这里不一致，
#   导致"打包 stamp 明明存在却永远判为未命中"）。
#   注意：debug 不追加 |type=，这样历史 stamp 仍然有效。
krita_package_fingerprint() {
    local want_aab="${1:-0}" ptype="${2:-debug}"
    local fp
    fp="$(krita_build_fingerprint)|aab=$want_aab"
    if [[ "$ptype" != "debug" ]]; then
        fp="$fp|type=$ptype"
    fi
    printf '%s' "$fp"
}

# 从打包 stamp 的内容里剥掉尾部 |aab=N，得到可与 krita_build_fingerprint
# 直接比较/逐段 diff 的基础指纹（不含该后缀时原样返回）
krita_stamp_base_fingerprint() {
    printf '%s' "${1%|aab=*}"
}

# 编译产物是否齐全（判断"跳过编译"是否安全）
build_artifacts_present() {
    compgen -G "$KRITA_INSTALL_DIR/lib/libkrita*.so*" >/dev/null 2>&1
}

# 打包产物是否齐全（APK 必查；要 AAB 时 AAB 也查）
package_artifacts_present() {
    local want_aab="${1:-0}"
    compgen -G "$PACKAGING_DIR/*.apk" >/dev/null 2>&1 || return 1
    if [[ "$want_aab" == "1" ]]; then
        compgen -G "$PACKAGING_DIR/*.aab" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# 直接用 git 判断源码是否有变化（给 --resume 等场景用）
krita_src_is_clean() {
    have_cmd git && [[ -d "$KRITA_SRC/.git" ]] || return 1
    [[ -z "$(git -C "$KRITA_SRC" status --porcelain --untracked-files=no 2>/dev/null)" ]]
}

# ---------------------------------------------------------------------------
# 导出
# ---------------------------------------------------------------------------
export_vars() {
    export ANDROID_ROOT ANDROID_ABI ANDROID_API ANDROID_PLATFORM ANDROID_NDK_VERSION
    export ANDROID_BUILD_TOOLS ANDROID_EXTRA_PACKAGES
    export ANDROID_HOME ANDROID_SDK_ROOT CMDLINE_TOOLS_DIR
    export WORKDIR SRCDIR ENVDIR VENVDIR
    export KRITA_SRC DEPS_MGMT_DIR CI_UTILS_DIR BUILD_DIR PACKAGING_DIR
    export BUILD_STAMP_FILE PACKAGE_STAMP_FILE
    export KRITA_INSTALL_DIR KRITA_TOOLCHAIN_FILE KRITA_CI_SCRIPTS_DIR
    export KRITA_BRANCH KRITA_CMAKE_BUILD_TYPE KRITA_GRADLE_TASK KRITA_JOB_COUNT
    export KRITA_APP_ID KRITA_MAIN_ACTIVITY KRITA_MIN_FREE_GB KRITA_FETCH_FULL_DEPS
    export KRITA_COPY_TO_DESKTOP KRITA_EXPORT_DIRS KRITA_DESKTOP_DIR
    export KDECI_ANDROID_ABI KDECI_ANDROID_SDK_ROOT KDECI_ANDROID_NDK_ROOT
    export KDECI_WORKDIR_PATH KDECI_SHARED_INSTALL_PATH
}

# ---------------------------------------------------------------------------
# PATH 与原生路径
# ---------------------------------------------------------------------------
prepend_path() {
    local p="$1"
    case ":$PATH:" in
        *":$p:"*) ;;
        *) PATH="$p:$PATH" ;;
    esac
}

native_path() {
    if is_windows_shell; then
        to_win_path "$1"
    else
        printf '%s\n' "$1"
    fi
}

prepare_android_path() {
    prepend_path "$KDECI_ANDROID_SDK_ROOT/platform-tools"
    prepend_path "$CMDLINE_TOOLS_DIR/latest/bin"
    prepend_path "$CMDLINE_TOOLS_DIR/bin"
    export PATH

    if is_windows_shell; then
        # Windows 原生程序（sdkmanager.bat / adb.exe / emulator.exe）需要 C:/ 形式路径
        ANDROID_ROOT_NATIVE="$(to_win_path "$ANDROID_ROOT")"
        SDK_ROOT_NATIVE="$(to_win_path "$KDECI_ANDROID_SDK_ROOT")"
    else
        ANDROID_ROOT_NATIVE="$ANDROID_ROOT"
        SDK_ROOT_NATIVE="$KDECI_ANDROID_SDK_ROOT"
    fi
    export ANDROID_ROOT_NATIVE SDK_ROOT_NATIVE
}

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------
validate_config() {
    case "$ANDROID_ABI" in
        x86_64|armeabi-v7a|arm64-v8a) ;;
        *) die "非法 ANDROID_ABI='$ANDROID_ABI'（可选：x86_64 / armeabi-v7a / arm64-v8a）" ;;
    esac
    case "$ANDROID_ROOT$WORKDIR$SRCDIR" in
        *" "*)
            warn "路径中包含空格，Android SDK/NDK 工具可能失败，建议使用无空格路径"
            ;;
    esac
    if is_windows_shell; then
        warn "当前为 Windows/Git Bash 环境：官方要求必须使用 Linux 构建 Android 版 Krita"
        warn "推荐： ./build-android.sh wsl all   （由 WSL2 执行完整流程）"
        warn "或参考 README.md 使用原生 Linux / CI Docker 镜像"
    fi
}

# ---------------------------------------------------------------------------
# 主入口：加载配置
# ---------------------------------------------------------------------------
load_config() {
    local cfg
    cfg="$(config_file)"
    if [[ -f "$cfg" ]]; then
        log "加载配置: $cfg"
        set -a
        # shellcheck disable=SC1090
        source "$cfg"
        set +a
    else
        warn "未找到配置文件: $cfg（使用内置默认值）"
        warn "可执行: cp $PROJECT_ROOT/config/android-build.conf.example $cfg"
    fi
    resolve_defaults
    derive_paths
    export_vars
    prepare_android_path
    # 失败时保持窗口：Windows 上双击 .sh / .bat 时不至于看不到错误就闪退
    install_failure_hold
    validate_config
}

# ---------------------------------------------------------------------------
# Android 工具定位（Windows 上自动选择 .bat）
# ---------------------------------------------------------------------------
android_tool_path() {
    local name="$1" dir cand
    for dir in "$CMDLINE_TOOLS_DIR/latest/bin" \
               "$CMDLINE_TOOLS_DIR/bin" \
               "$KDECI_ANDROID_SDK_ROOT/cmdline-tools/latest/bin" \
               "$KDECI_ANDROID_SDK_ROOT/platform-tools" \
               "$KDECI_ANDROID_SDK_ROOT/emulator" \
               "$KDECI_ANDROID_SDK_ROOT/tools/bin"; do
        [[ -d "$dir" ]] || continue
        cand="$(find_exe "$dir" "$name" 2>/dev/null)" && {
            printf '%s\n' "$cand"
            return 0
        }
    done
    if have_cmd "$name"; then
        command -v "$name"
        return 0
    fi
    return 1
}

# 说明：MSYS_NO_PATHCONV=1 只在调用 Windows 原生工具时局部生效，
#       避免影响 git / bash 等 MSYS 程序的正常路径转换。
# 统一的工具调用封装：
#   * 打印将要执行的命令
#   * 缺失工具时报错（DRY-RUN 下只提示不报错）
#   * 仅在调用 Windows 原生工具时设置 MSYS_NO_PATHCONV=1，并传入 C:/ 形式路径
# sdkmanager 是 Java 程序，**不会**读取 http_proxy 环境变量，
# 因此在有代理的环境（尤其是 WSL + 宿主机代理）必须显式传 --proxy* 参数。
_sdkmanager_proxy_flags() {
    local hp=""
    if [[ -n "${ANDROID_SDKMANAGER_PROXY:-}" ]]; then
        hp="$ANDROID_SDKMANAGER_PROXY"
    elif [[ "${http_proxy:-}" == http://* || "${HTTP_PROXY:-}" == http://* ]]; then
        hp="${http_proxy:-$HTTP_PROXY}"
        hp="${hp#http://}"
        hp="${hp%/}"
    fi
    [[ "$hp" == *:* ]] || return 0
    if is_windows_shell; then
        MSYS_NO_PATHCONV=1 printf '%s\n' "--proxy=http" "--proxy_host=${hp%%:*}" "--proxy_port=${hp##*:}"
    else
        printf '%s\n' "--proxy=http" "--proxy_host=${hp%%:*}" "--proxy_port=${hp##*:}"
    fi
}

_android_tool_run() {
    local tool="$1"
    shift

    # 代理参数先算出来：即使工具还没装（dry-run）也能在输出里看到
    local -a proxy_flags=()
    if [[ "$tool" == "sdkmanager" ]]; then
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && proxy_flags+=("$line")
        done < <(_sdkmanager_proxy_flags)
    fi
    local extra=""
    if ((${#proxy_flags[@]} > 0)); then
        extra=" ${proxy_flags[*]}"
    fi

    local t=""
    t="$(android_tool_path "$tool" 2>/dev/null || true)"
    if [[ -z "$t" ]]; then
        if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
            printf '    %s$ %s%s %s%s\n' "$C_CYAN" "$tool" "$extra" "$*" "$C_RESET"
            return 0
        fi
        die "未找到 $tool，请先执行 ./build-android.sh sdk"
    fi

    printf '    %s$ %s%s %s%s\n' "$C_CYAN" "$tool" "$extra" "$*" "$C_RESET"
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    if [[ "$tool" == "sdkmanager" ]]; then
        MSYS_NO_PATHCONV=1 "$t" --sdk_root="$SDK_ROOT_NATIVE" \
            ${proxy_flags[@]+"${proxy_flags[@]}"} "$@"
    else
        MSYS_NO_PATHCONV=1 "$t" "$@"
    fi
}

sdkmanager_cmd() { _android_tool_run sdkmanager "$@"; }
adb_cmd()        { _android_tool_run adb "$@"; }

# ---------------------------------------------------------------------------
# Python / venv
# ---------------------------------------------------------------------------
resolve_python() {
    if [[ -n "${PYTHON_BIN:-}" ]] && have_cmd "$PYTHON_BIN"; then
        printf '%s\n' "$PYTHON_BIN"
        return 0
    fi
    if have_cmd python3; then
        printf 'python3\n'
        return 0
    fi
    if have_cmd python; then
        printf 'python\n'
        return 0
    fi
    return 1
}

# 优先返回 venv 中的 python
python_cmd() {
    if [[ -x "$VENVDIR/bin/python" ]]; then
        printf '%s\n' "$VENVDIR/bin/python"
    elif [[ -f "$VENVDIR/Scripts/python.exe" ]]; then
        printf '%s\n' "$VENVDIR/Scripts/python.exe"
    else
        resolve_python
    fi
}

activate_venv() {
    local script=""
    if [[ -f "$VENVDIR/bin/activate" ]]; then
        script="$VENVDIR/bin/activate"
    elif [[ -f "$VENVDIR/Scripts/activate" ]]; then
        script="$VENVDIR/Scripts/activate"
    else
        return 1
    fi
    if ! safe_source "$script"; then
        warn "激活 venv 时出现告警: $script"
    fi
    ok "已激活 Python venv: $(command -v python 2>/dev/null || echo "$VENVDIR")"
}

# 激活运行 run-ci-build.py 生成的构建环境（$WORKDIR/base-env 与 $KRITA_SRC/env）
activate_generated_env() {
    local base_env="$WORKDIR/base-env"
    local env_file="$KRITA_SRC/env"

    # env / base-env 里固化了"生成时"的 KDECI_* 值（例如 KDECI_ANDROID_NDK_ROOT），
    # source 后会覆盖当前配置。这里先记下当前值，source 完再断言回来。
    local keep_ndk_root="${ANDROID_NDK_ROOT:-$KDECI_ANDROID_NDK_ROOT}"
    local keep_ndk="$KDECI_ANDROID_NDK_ROOT"
    local keep_sdk="$KDECI_ANDROID_SDK_ROOT"
    local keep_abi="$KDECI_ANDROID_ABI"
    local keep_install="$KDECI_SHARED_INSTALL_PATH"
    local keep_wd="$KDECI_WORKDIR_PATH"

    if [[ -f "$base_env" ]]; then
        if safe_source "$base_env"; then
            ok "已激活 $base_env"
        else
            warn "$base_env 内部有告警（已尽量应用），继续"
        fi
    fi
    if [[ -f "$env_file" ]]; then
        if safe_source "$env_file"; then
            ok "已激活 $env_file"
        else
            warn "$env_file 内部有告警（已尽量应用），继续"
        fi
    else
        warn "未找到 $env_file —— 请先执行 scripts/30-fetch-deps.sh"
    fi

    # 重新断言成本项目当前配置（否则会退回 env 文件里旧的 NDK/SDK 路径）
    export ANDROID_NDK_ROOT="$keep_ndk_root"
    export KDECI_ANDROID_NDK_ROOT="$keep_ndk"
    export KDECI_ANDROID_SDK_ROOT="$keep_sdk"
    export ANDROID_HOME="$keep_sdk"
    export ANDROID_SDK_ROOT="$keep_sdk"
    export KDECI_ANDROID_ABI="$keep_abi"
    export KDECI_SHARED_INSTALL_PATH="$keep_install"
    export KDECI_WORKDIR_PATH="$keep_wd"
    log "已按当前配置校正 NDK/SDK: NDK=$(basename -- "$keep_ndk") SDK=$keep_sdk"

    # 依赖目录里的宿主工具（gettext 的 msgfmt/msgcat 等）必须在 PATH 中，
    # 而且它们的共享库在 $KRITA_INSTALL_DIR/lib 里 —— 否则会报
    #   msgfmt: error while loading shared libraries: libgettextsrc-0.21.so
    # 进而导致 KF5I18n 的 pofiles 目标 "failed generating .../po"
    if [[ -d "$KRITA_INSTALL_DIR/bin" ]]; then
        prepend_path "$KRITA_INSTALL_DIR/bin"
        export PATH
    fi
    if [[ -d "$KRITA_INSTALL_DIR/lib" ]]; then
        case ":${LD_LIBRARY_PATH:-}:" in
            *":$KRITA_INSTALL_DIR/lib:"*) ;;
            *) export LD_LIBRARY_PATH="$KRITA_INSTALL_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# 打印当前解析结果
# ---------------------------------------------------------------------------
kv() {
    # 标签统一使用 ASCII，保证在任何终端下对齐
    printf '  %-32s : %s\n' "$1" "$2"
}

print_env() {
    hr
    kv "KRITA_OS"                 "$KRITA_OS ($KRITA_SHELL_FLAVOR)"
    kv "PROJECT_ROOT"             "$PROJECT_ROOT"
    kv "CONFIG_FILE"              "$(config_file)"
    hr
    kv "ANDROID_ABI"              "$ANDROID_ABI"
    kv "ANDROID_API"              "$ANDROID_API   (Krita 最低支持 API)"
    kv "ANDROID_PLATFORM"         "$ANDROID_PLATFORM   (编译用 SDK 平台)"
    kv "ANDROID_NDK_VERSION"      "$ANDROID_NDK_VERSION"
    kv "ANDROID_BUILD_TOOLS"      "$ANDROID_BUILD_TOOLS"
    hr
    kv "ANDROID_ROOT"             "$ANDROID_ROOT"
    kv "KDECI_ANDROID_SDK_ROOT"   "$KDECI_ANDROID_SDK_ROOT"
    kv "KDECI_ANDROID_NDK_ROOT"   "$KDECI_ANDROID_NDK_ROOT"
    kv "ANDROID_HOME"             "$ANDROID_HOME"
    kv "WORKDIR"                  "$WORKDIR"
    kv "SRCDIR"                   "$SRCDIR"
    kv "ENVDIR"                   "$ENVDIR"
    kv "VENVDIR"                  "$VENVDIR"
    hr
    kv "KRITA_SRC"                "$KRITA_SRC"
    kv "KRITA_BRANCH"             "$KRITA_BRANCH"
    kv "BUILD_DIR"                "$BUILD_DIR"
    kv "KRITA_INSTALL_DIR"        "$KRITA_INSTALL_DIR"
    kv "PACKAGING_DIR"            "$PACKAGING_DIR"
    kv "KRITA_DESKTOP_DIR"        "${KRITA_DESKTOP_DIR:-（未探测到）}"
    kv "KRITA_COPY_TO_DESKTOP"    "$KRITA_COPY_TO_DESKTOP"
    kv "KRITA_TOOLCHAIN_FILE"     "$KRITA_TOOLCHAIN_FILE"
    kv "KDECI_WORKDIR_PATH"       "$KDECI_WORKDIR_PATH"
    kv "KDECI_SHARED_INSTALL_PATH" "$KDECI_SHARED_INSTALL_PATH"
    hr
    kv "KRITA_CMAKE_BUILD_TYPE"   "$KRITA_CMAKE_BUILD_TYPE"
    kv "KRITA_JOB_COUNT"          "$KRITA_JOB_COUNT"
    kv "KRITA_GRADLE_TASK"        "$KRITA_GRADLE_TASK"
    kv "KRITA_APP_ID"             "$KRITA_APP_ID"
    kv "KRITA_FETCH_FULL_DEPS"    "$KRITA_FETCH_FULL_DEPS"
    hr
}
