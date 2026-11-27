#!/usr/bin/env bash
# =============================================================================
#  99-wsl-build.sh —— 在 Windows 上用 WSL2（Linux）执行完整构建
#
#  背景：官方要求必须用 Linux 构建 Android 版 Krita，Windows 下最省事的做法是
#        把整个流程交给 WSL2 里的 Linux 执行。本脚本在 Git Bash 中运行，负责
#        调用 wsl.exe 并转发参数。
#
#  前置：
#    1) 安装 WSL2 与发行版:   wsl --install -d Debian
#    2) 发行版内安装工具链（可一条命令搞定）:
#         ./build-android.sh wsl-install        # 或双击 wsl-setup.bat
#       等价于手工执行:
#         sudo apt update && sudo apt install -y build-essential cmake \
#             ninja-build pkgconf git curl unzip openjdk-17-jdk python3 \
#             python3-pip python3-venv
#
#  用法:
#    ./scripts/99-wsl-build.sh --check       # 只检查 WSL 与发行版依赖
#    ./scripts/99-wsl-build.sh all           # 一键完整构建
#    ./scripts/99-wsl-build.sh all --jobs 8
#    ./scripts/99-wsl-build.sh --shell ./scripts/00-check-prereqs.sh
#
#  Windows 用户注意：不要双击 .sh 文件（窗口会随脚本结束而关闭）。
#  请使用 wsl-check.bat / wsl-setup.bat / wsl-build.bat，或
#  build-android.bat wsl all。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config
# shellcheck source=lib/wsl.sh
source "$SCRIPT_DIR/lib/wsl.sh"

CHECK_ONLY=0
FORCE=0
INNER_CMD="./scripts/90-build-all.sh"
PASSTHRU=()

usage() {
    cat <<'EOF'
用法: 99-wsl-build.sh [选项] [传递给 90-build-all.sh 的参数...]

选项:
  --distro NAME   指定 WSL 发行版（默认取 WSL_DISTRO 配置或第一个已安装发行版）
  --shell CMD     自定义在 WSL 中执行的命令（默认 ./scripts/90-build-all.sh）
  --check         只检查 WSL / 发行版依赖 / 路径映射，不构建
  --force         发行版依赖缺失时也继续（默认中止并给出安装命令）
  -h, --help      显示帮助

示例:
  ./scripts/99-wsl-build.sh --check
  ./scripts/99-wsl-build.sh all --jobs 8
  ./scripts/99-wsl-build.sh all --from 40

依赖缺失时可直接自动安装:
  ./build-android.sh wsl-install      （Windows 上双击 wsl-setup.bat）
EOF
}

main() {
    while (($#)); do
        case "$1" in
            --distro)
                shift
                [[ $# -gt 0 ]] || die "--distro 需要一个发行版名称"
                DISTRO="$1"
                ;;
            --shell)
                shift
                [[ $# -gt 0 ]] || die "--shell 需要一个命令"
                INNER_CMD="$1"
                ;;
            --check) CHECK_ONLY=1 ;;
            --force) FORCE=1 ;;
            -h|--help) usage; exit 0 ;;
            *) PASSTHRU+=("$1") ;;
        esac
        shift
    done

    hr
    printf '  %s通过 WSL2 执行 Android 构建%s\n' "$C_BOLD" "$C_RESET"

    wsl_prepare

    info "发行版环境检查"
    wsl_analyze_probe "$WSL_PROBE_OUT"

    if ((${#CRITICAL_LIST[@]} > 0)); then
        warn "发行版依赖不完整"
        wsl_print_apt_hint
        printf '  也可以直接自动安装: %s./build-android.sh wsl-install%s\n' "$C_BOLD" "$C_RESET"
    else
        ok "发行版依赖检查通过"
    fi

    if (( CHECK_ONLY == 1 )); then
        hr
        if ((${#CRITICAL_LIST[@]} > 0)); then
            printf '  补齐依赖后执行: %s./build-android.sh wsl all%s\n' "$C_BOLD" "$C_RESET"
        else
            printf '  下一步: %s./build-android.sh wsl all%s\n' "$C_BOLD" "$C_RESET"
        fi
        return 0
    fi

    if ((${#CRITICAL_LIST[@]} > 0)) && (( FORCE == 0 )); then
        die "请先自动安装依赖（./build-android.sh wsl-install），或加 --force 强制继续"
    fi

    hr
    log "在发行版内执行: $INNER_CMD ${PASSTHRU[*]-}"
    hr
    # 通过 generated 启动脚本 + argv 传参，避免把整条命令当程序名以及引号丢失
    wsl_run_pipeline "$WSL_ROOT" "$INNER_CMD" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
}

main "$@"
