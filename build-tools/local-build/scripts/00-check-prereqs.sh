#!/usr/bin/env bash
# =============================================================================
#  00-check-prereqs.sh —— 构建环境前置检查
#
#  对照官方文档《Building Krita for Android / Installing Prerequisites》：
#    * 必须是 Linux（Windows 请用 WSL2）
#    * Java 必须是 17（精确版本）
#    * Python >= 3.10
#    * git / cmake / make 或 ninja / curl
#
#  用法:
#    ./scripts/00-check-prereqs.sh [--strict] [--quiet]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

FAILED=0
WARNED=0
STRICT=0
QUIET=0

usage() {
    cat <<'EOF'
用法: 00-check-prereqs.sh [选项]

选项:
  --strict    存在警告时也返回非零退出码（适用于 CI）
  --quiet     只输出结论
  -h, --help  显示帮助

退出码: 0 通过 / 1 存在失败项 / 2 仅存在警告(--strict)
EOF
}

note_fail() { err "$1"; FAILED=$((FAILED + 1)); }
note_warn() { warn "$1"; WARNED=$((WARNED + 1)); }
note_ok()   { ok "$1"; }

# 版本号比较：version_ge 3.10.2 3.10
version_ge() {
    local a="$1" b="$2"
    printf '%s\n%s\n' "$b" "$a" | sort -V -C 2>/dev/null
}

# --------------------------------------------------------------------------
check_platform() {
    info "1/7 平台检查"
    log "uname: $(uname -srm 2>/dev/null || echo unknown)"
    case "$KRITA_OS" in
        linux)
            note_ok "Linux 环境（官方唯一支持的系统）"
            ;;
        windows)
            note_warn "Windows / Git Bash 环境：Android 版 Krita 必须使用 Linux 构建"
            note_warn "请使用 WSL2 执行完整流程： ./build-android.sh wsl all"
            note_warn "Git Bash 可直接使用的功能：环境检查、SDK 安装、adb 安装 APK / logcat（需真机）"
            ;;
        macos)
            note_warn "macOS 官方不支持，仅供实验"
            ;;
        *)
            note_fail "无法识别的系统: ${KRITA_OS}"
            ;;
    esac
}

check_basic_tools() {
    info "2/7 基础工具"
    local t
    for t in git curl; do
        if have_cmd "$t"; then
            note_ok "$t -> $(command -v "$t")"
        else
            note_fail "缺少 $t"
        fi
    done

    for t in cmake make ninja; do
        if have_cmd "$t"; then
            local v
            v="$("$t" --version 2>/dev/null | head -n 1)"
            note_ok "$t -> ${v:-unknown}"
        else
            case "$t" in
                cmake)
                    note_fail "缺少 cmake"
                    ;;
                make)
                    # 官方文档使用 make，但 CMake 走 Ninja 生成器时并不是必需的
                    if have_cmd ninja; then
                        note_warn "未找到 make，将使用 ninja 完成安装（build.ninja）"
                    else
                        note_fail "缺少 make（且未安装 ninja）"
                    fi
                    ;;
                ninja)
                    note_warn "未找到 ninja（CMake 若使用 Ninja 生成器则必需）"
                    ;;
            esac
        fi
    done

    if have_cmd unzip || have_cmd tar; then
        note_ok "压缩包解压工具可用"
    else
        note_warn "未找到 unzip/tar，将退回使用 Python 解压"
    fi

    if is_linux; then
        for t in gcc g++ pkg-config; do
            if have_cmd "$t"; then
                note_ok "$t -> $(command -v "$t")"
            else
                note_fail "缺少 $t（构建主机工具需要 C/C++ 工具链）"
            fi
        done
    fi
}

check_python() {
    info "3/7 Python（官方要求 >= 3.10）"
    local py=""
    if py="$(resolve_python)"; then
        PYTHON_BIN="$py"
    else
        note_fail "未找到 python3/python"
        return 0
    fi
    local ver
    ver="$("$py" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo unknown)"
    log "$py -> $ver"

    if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
        note_ok "Python 版本满足要求 ($ver)"
    elif "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
        note_warn "Python $ver 未经过官方测试（要求 >= 3.10）"
    else
        note_fail "Python $ver 版本过低（3.8 及以下确认不可用）"
    fi

    if "$py" -m pip --version >/dev/null 2>&1; then
        note_ok "pip 可用: $("$py" -m pip --version 2>/dev/null | head -n 1)"
    else
        note_fail "pip 不可用，请安装 python3-pip / python3-venv"
    fi
}

check_java() {
    info "4/7 Java（必须精确为 17）"
    if ! have_cmd java; then
        note_fail "未找到 java（需要 openjdk-17-jdk）"
        return 0
    fi

    local jmajor=""
    jmajor="$(java -version 2>&1 | head -n 1 | awk -F'"' '{print $2}' | awk -F. '{ if ($1 == "1") print $2; else print $1 }')"
    log "java -version -> $(java -version 2>&1 | head -n 1)"

    if have_cmd javac; then
        local cmajor=""
        cmajor="$(javac -version 2>&1 | awk '{print $2}' | awk -F. '{ if ($1 == "1") print $2; else print $1 }')"
        log "javac -version -> $(javac -version 2>&1 | head -n 1)"
        if [[ "$cmajor" == "17" ]]; then
            note_ok "javac 主版本为 17"
        else
            note_fail "javac 主版本为 $cmajor（需要 17；Gradle 的 Android 插件依赖 JDK 17）"
        fi
    else
        note_warn "未找到 javac"
    fi

    if [[ "$jmajor" == "17" ]]; then
        note_ok "java 主版本为 17"
    else
        note_warn "java 运行时主版本为 ${jmajor:-未知}（要求 17）"
    fi

    if [[ -n "${JAVA_HOME:-}" ]]; then
        note_ok "JAVA_HOME=$JAVA_HOME"
    else
        local detected=""
        detected="$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.home/ {print $2; exit}')" || true
        if [[ -n "$detected" ]]; then
            export JAVA_HOME="$detected"
            note_warn "JAVA_HOME 未设置，已自动推断: $JAVA_HOME（建议写入配置文件）"
        else
            note_warn "JAVA_HOME 未设置，sdkmanager/gradle 可能失败"
        fi
    fi
}

check_android_components() {
    info "5/7 Android SDK / NDK 状态"
    if [[ -d "$KDECI_ANDROID_SDK_ROOT" ]]; then
        note_ok "SDK 目录: $KDECI_ANDROID_SDK_ROOT"
    else
        note_warn "SDK 未安装（执行 ./build-android.sh sdk）: $KDECI_ANDROID_SDK_ROOT"
    fi

    if [[ -f "$KDECI_ANDROID_NDK_ROOT/source.properties" ]]; then
        note_ok "NDK ${ANDROID_NDK_VERSION}: $KDECI_ANDROID_NDK_ROOT"
    else
        note_warn "NDK ${ANDROID_NDK_VERSION} 未安装（执行 ./build-android.sh sdk）: $KDECI_ANDROID_NDK_ROOT"
    fi

    local t=""
    t="$(android_tool_path sdkmanager 2>/dev/null || true)"
    if [[ -n "$t" ]]; then
        note_ok "sdkmanager: $t"
    else
        note_warn "未找到 sdkmanager（cmdline-tools 未安装）"
    fi
    t="$(android_tool_path adb 2>/dev/null || true)"
    if [[ -n "$t" ]]; then
        note_ok "adb: $t"
    else
        note_warn "未找到 adb"
    fi
}

check_disk() {
    info "6/7 磁盘空间"
    local free=""
    free="$(free_space_gb "$WORKDIR" || true)"
    if [[ -n "$free" ]]; then
        if (( free < KRITA_MIN_FREE_GB )); then
            note_warn "剩余 ${free}GB < 建议 ${KRITA_MIN_FREE_GB}GB（$WORKDIR）"
        else
            note_ok "剩余 ${free}GB（$WORKDIR）"
        fi
    else
        note_warn "无法检测 $WORKDIR 的磁盘空间"
    fi
}

check_summary_config() {
    info "7/7 关键构建参数"
    note_ok "ANDROID_ABI           = $ANDROID_ABI"
    note_ok "ANDROID_PLATFORM      = $ANDROID_PLATFORM（最低 API $ANDROID_API）"
    note_ok "ANDROID_NDK_VERSION   = $ANDROID_NDK_VERSION"
    note_ok "KRITA_SRC             = $KRITA_SRC"
    note_ok "BUILD_DIR             = $BUILD_DIR"
    note_ok "KRITA_INSTALL_DIR     = $KRITA_INSTALL_DIR"
    note_ok "并行任务数            = $KRITA_JOB_COUNT"
    if [[ -f "$KRITA_TOOLCHAIN_FILE" ]]; then
        note_ok "工具链文件存在: $KRITA_TOOLCHAIN_FILE"
    else
        note_warn "工具链文件缺失（执行 ./build-android.sh sources）: $KRITA_TOOLCHAIN_FILE"
    fi
}

summary() {
    hr
    if (( FAILED > 0 )); then
        err "检查结果: $FAILED 项失败, $WARNED 项警告"
        exit 1
    fi
    if (( WARNED > 0 )); then
        warn "检查结果: 通过（$WARNED 项警告）"
        if (( STRICT > 0 )); then
            exit 2
        fi
        return 0
    fi
    ok "检查结果: 全部通过"
}

main() {
    while (($#)); do
        case "$1" in
            --strict) STRICT=1 ;;
            --quiet)  QUIET=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    if (( QUIET == 0 )); then
        hr
        printf '  %sKrita Android 构建环境检查%s\n' "$C_BOLD" "$C_RESET"
    fi

    check_platform
    check_basic_tools
    check_python
    check_java
    check_android_components
    check_disk
    check_summary_config
    summary
}

main "$@"
