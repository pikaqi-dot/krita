#!/usr/bin/env bash
# =============================================================================
#  10-setup-sdk.sh —— 安装 Android cmdline-tools / NDK / SDK 组件
#
#  对应官方文档：
#    Setting up Android SDK and NDK
#    Configure environment variables
#    Install SDKs and build tools
#
#  默认安装：
#    platform-tools / platforms;android-33 / build-tools;30.0.3
#    build-tools;34.0.0
#    NDK（默认 r27d，见 android-env.sh 的 ANDROID_NDK_VERSION 说明）
#
#  说明：不安装 emulator / system-images（本项目只负责编译出 APK，
#        不提供模拟器流程；如需安装请用 ANDROID_EXTRA_PACKAGES 追加）。
#
#  用法:
#    ./scripts/10-setup-sdk.sh [--licenses-only] [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

LICENSES_ONLY=0
FORCE=0

usage() {
    cat <<'EOF'
用法: 10-setup-sdk.sh [选项]

选项:
  --licenses-only   只接受许可证，不安装组件
  --force           强制重新安装 cmdline-tools 与 NDK（默认已存在就跳过）
  --dry-run         只打印将执行的命令
  -h, --help        显示帮助
EOF
}

# --------------------------------------------------------------------------
# 平台相关的默认下载地址
# --------------------------------------------------------------------------
default_cmdline_tools_url() {
    case "$KRITA_OS" in
        linux)   printf '%s\n' "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" ;;
        windows) printf '%s\n' "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" ;;
        macos)   printf '%s\n' "https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip" ;;
        *)       printf '%s\n' "" ;;
    esac
}

default_ndk_url() {
    local host=""
    case "$KRITA_OS" in
        linux)   host="linux-x86_64" ;;
        windows) host="windows-x86_64" ;;
        macos)   host="darwin-x86_64" ;;
        *)       host="" ;;
    esac
    if [[ -z "$host" ]]; then
        printf '%s\n' ""
    else
        printf '%s\n' "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-${host}.zip"
    fi
}

# --------------------------------------------------------------------------
ensure_dirs() {
    info "1/5 创建目录"
    local d
    for d in "$ANDROID_ROOT" "$WORKDIR" "$SRCDIR" "$ENVDIR" "$ANDROID_ROOT/dl"; do
        if [[ -d "$d" ]]; then
            ok "已存在: $d"
        else
            run mkdir -p "$d" && ok "已创建: $d"
        fi
    done
}

ensure_cmdline_tools() {
    info "2/5 Android command line tools"
    local t=""
    t="$(android_tool_path sdkmanager 2>/dev/null || true)"
    if [[ -n "$t" ]]; then
        ok "sdkmanager 已可用: $t"
        return 0
    fi

    local url="${ANDROID_CMDLINE_TOOLS_URL:-$(default_cmdline_tools_url)}"
    if [[ -z "$url" ]]; then
        warn "当前平台无默认下载地址，请手动下载 command line tools"
        warn "解压后应满足: $CMDLINE_TOOLS_DIR/bin/sdkmanager"
        return 0
    fi

    local zip="$ANDROID_ROOT/dl/$(basename -- "$url")"
    download_file "$url" "$zip"

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        printf '    %s$ unzip %s -d <tmp>%s\n' "$C_CYAN" "$zip" "$C_RESET"
        printf '    %s$ mv <tmp>/cmdline-tools %s%s\n' "$C_CYAN" "$CMDLINE_TOOLS_DIR" "$C_RESET"
        return 0
    fi

    local tmp="$ANDROID_ROOT/dl/_cmdline_tools_extract"
    if [[ "${KRITA_DRY_RUN:-0}" != "1" ]]; then
        rm -rf -- "$tmp"
    fi
    extract_zip "$zip" "$tmp"

    if [[ ! -d "$tmp/cmdline-tools" ]]; then
        die "压缩包结构异常（未找到 cmdline-tools/）: $zip"
    fi
    if [[ -d "$CMDLINE_TOOLS_DIR" ]]; then
        if (( FORCE == 1 )); then
            warn "强制重装 cmdline-tools: $CMDLINE_TOOLS_DIR"
            run rm -rf -- "$CMDLINE_TOOLS_DIR"
            run mv "$tmp/cmdline-tools" "$CMDLINE_TOOLS_DIR" && ok "已重装: $CMDLINE_TOOLS_DIR"
        else
            ok "保留已有目录: $CMDLINE_TOOLS_DIR（--force 可强制重装）"
        fi
    else
        run mv "$tmp/cmdline-tools" "$CMDLINE_TOOLS_DIR" && ok "已安装: $CMDLINE_TOOLS_DIR"
    fi
    if ! have_cmd java; then
        warn "未找到 java：sdkmanager 需要 JDK 17（见 00-check-prereqs.sh）"
    fi
}

# NDK 安装：
#   * 版本形如 27.3.13750724（对应 r27d）-> 用 sdkmanager 安装到 $SDK/ndk/<ver>
#   * 版本形如 r22b（官方文档的老写法）  -> 下载官方 zip 解压到 $ANDROID_ROOT
ensure_ndk() {
    info "4/5 Android NDK ${ANDROID_NDK_VERSION}"
    if [[ -f "$KDECI_ANDROID_NDK_ROOT/source.properties" ]]; then
        if (( FORCE == 1 )); then
            warn "强制重装 NDK: $KDECI_ANDROID_NDK_ROOT"
            run rm -rf -- "$KDECI_ANDROID_NDK_ROOT"
        else
            ok "NDK 已安装: $KDECI_ANDROID_NDK_ROOT（--force 可强制重装）"
            return 0
        fi
    fi

    if [[ "$ANDROID_NDK_VERSION" == r* ]]; then
        # ---- 官方 zip 布局（文档里的 r22b 流程）----
        local url="${ANDROID_NDK_URL:-$(default_ndk_url)}"
        if [[ -z "$url" ]]; then
            warn "当前平台无默认 NDK 下载地址"
            warn "请手动解压 NDK ${ANDROID_NDK_VERSION} 到: $KDECI_ANDROID_NDK_ROOT"
            return 0
        fi

        local zip="$ANDROID_ROOT/dl/$(basename -- "$url")"
        download_file "$url" "$zip"

        if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
            printf '    %s$ unzip %s -d %s%s\n' "$C_CYAN" "$zip" "$ANDROID_ROOT" "$C_RESET"
            return 0
        fi

        extract_zip "$zip" "$ANDROID_ROOT"
        if [[ -f "$KDECI_ANDROID_NDK_ROOT/source.properties" ]]; then
            ok "已安装 NDK: $KDECI_ANDROID_NDK_ROOT"
        else
            die "NDK 解压后路径不符合预期: $KDECI_ANDROID_NDK_ROOT"
        fi
        return 0
    fi

    # ---- sdkmanager 布局（默认，与 CI 预编译依赖保持一致）----
    warn "官方文档写的 NDK r22b 已过时：CI 预编译依赖由 NDK r27d 构建，"
    warn "用 r22b 链接会报 libc++ 未定义符号。这里安装 ndk;${ANDROID_NDK_VERSION}"
    if ! sdkmanager_cmd "ndk;${ANDROID_NDK_VERSION}"; then
        warn "首次安装失败，尝试自动接受许可证后重试…"
        # 非交互环境下 sdkmanager 遇到未接受的许可证会默认回答 N 并跳过该包，
        # 所以再喂一遍 y 兜底（printf 而非 yes：避免 SIGPIPE 被 pipefail 误判）
        printf 'y\n%.0s' {1..200} | sdkmanager_cmd "ndk;${ANDROID_NDK_VERSION}" ||
            die "安装 ndk;${ANDROID_NDK_VERSION} 失败（可先执行 ./build-android.sh sdk --licenses-only 再重试）"
    fi

    if [[ -f "$KDECI_ANDROID_NDK_ROOT/source.properties" ]]; then
        ok "已安装 NDK: $KDECI_ANDROID_NDK_ROOT"
    else
        die "sdkmanager 安装后仍找不到 NDK: $KDECI_ANDROID_NDK_ROOT"
    fi
}

accept_licenses() {
    info "3/5 接受 SDK 许可证"
    local lic_dir="$KDECI_ANDROID_SDK_ROOT/licenses"
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        printf '    %s$ printf "y\\n"x200 | sdkmanager --licenses%s\n' "$C_CYAN" "$C_RESET"
        return 0
    fi
    mkdir -p "$lic_dir" 2>/dev/null || true

    # 已有许可证文件就不折腾（绝大多数重跑都会走到这里）
    local n
    n="$(find "$lic_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${n:-0}" -gt 0 ]]; then
        ok "许可证已存在（$lic_dir，$n 个文件）"
        return 0
    fi

    # 用 printf 造 200 个 y：
    #   `yes | sdkmanager` 在 sdkmanager 提前退出时会收到 SIGPIPE(141)，
    #   配合 `set -o pipefail` 会被误判成失败，所以这里统一忽略退出码，
    #   改为"$licenses 目录里是否出现文件"作为唯一判据。
    local try
    for try in 1 2 3; do
        printf 'y\n%.0s' {1..200} | sdkmanager_cmd --licenses >/dev/null 2>&1 || true
        n="$(find "$lic_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${n:-0}" -gt 0 ]]; then
            ok "许可证已接受（$lic_dir，$n 个文件）"
            return 0
        fi
        warn "第 $try 次执行 --licenses 后 $lic_dir 仍为空，重试…"
        sleep 1
    done

    warn "无法自动接受 SDK 许可证（sdkmanager 可能缺 JDK，或网络/代理不通）"
    warn "请手工执行一次，然后重跑 ./build-android.sh sdk："
    warn "  ./build-android.sh sdk --licenses-only"
    return 1
}

install_packages() {
    info "5/5 安装 SDK 组件"

    local api="${ANDROID_PLATFORM#android-}"
    local pkgs=()
    pkgs+=("platform-tools")
    pkgs+=("platforms;android-${api}")

    local bt
    for bt in $ANDROID_BUILD_TOOLS; do
        pkgs+=("build-tools;${bt}")
    done

    local extra
    for extra in ${ANDROID_EXTRA_PACKAGES:-}; do
        pkgs+=("$extra")
    done

    local p
    for p in "${pkgs[@]}"; do
        if sdkmanager_cmd "$p"; then
            ok "已安装/已是最新: $p"
            continue
        fi
        warn "安装 $p 失败，尝试自动接受许可证后重试…"
        if printf 'y\n%.0s' {1..200} | sdkmanager_cmd "$p"; then
            ok "已安装（自动接受许可证后）: $p"
            continue
        fi
        case "$p" in
            tools|emulator|system-images*)
                warn "安装 $p 失败（可选组件，可忽略）"
                ;;
            *)
                die "安装 $p 失败（可先执行 ./build-android.sh sdk --licenses-only 再重试）"
                ;;
        esac
    done
}

summary() {
    hr
    ok "SDK 根目录      : $KDECI_ANDROID_SDK_ROOT"
    ok "NDK 根目录      : $KDECI_ANDROID_NDK_ROOT"
    ok "cmdline-tools   : $CMDLINE_TOOLS_DIR"
    hr
    printf '  等价的 shell 环境变量（每次进入新终端都需要设置）：\n\n'
    printf '    export ANDROID_ROOT=%s\n' "$ANDROID_ROOT"
    printf '    export KDECI_ANDROID_SDK_ROOT=$ANDROID_ROOT/sdk\n'
    printf '    export KDECI_ANDROID_NDK_ROOT=$ANDROID_ROOT/android-ndk-%s\n' "$ANDROID_NDK_VERSION"
    printf '    export ANDROID_HOME=$ANDROID_ROOT/sdk\n'
    printf '    export PATH="$ANDROID_ROOT/sdk/platform-tools/:$ANDROID_ROOT/cmdline-tools/bin/:$PATH"\n'
    printf '    export KDECI_ANDROID_ABI=%s\n' "$ANDROID_ABI"
    printf '\n  （本套脚本会自动设置以上变量，无需手工 export）\n'
    hr
}

main() {
    while (($#)); do
        case "$1" in
            --licenses-only) LICENSES_ONLY=1 ;;
            --force)         FORCE=1; KRITA_FORCE_DOWNLOAD=1; export KRITA_FORCE_DOWNLOAD ;;
            --dry-run)       KRITA_DRY_RUN=1 ;;
            -h|--help)       usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    hr
    printf '  %sAndroid SDK / NDK 安装%s\n' "$C_BOLD" "$C_RESET"
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        warn "DRY-RUN 模式：只打印命令，不实际执行"
    fi

    ensure_dirs
    ensure_cmdline_tools

    # 顺序很关键：sdkmanager 安装任何组件前都会校验许可证。
    # 非交互环境下遇到未接受的许可证会默认回答 N，然后"跳过该包"
    # （NDK 就是这样被跳过，最后报"安装后仍找不到 NDK"）。
    # 所以必须先把许可证接受完，再去装 NDK / 组件。
    accept_licenses

    if (( LICENSES_ONLY == 1 )); then
        summary
        return 0
    fi
    ensure_ndk
    install_packages
    summary
}

main "$@"
