#!/usr/bin/env bash
# =============================================================================
#  96-wsl-oneclick.sh —— Windows 上的一键流程（wsl-build.bat 调用的就是它）
#
#  依次执行，全部是幂等的（已满足条件会自动跳过）：
#    1) 网络检查/修复          (内部调用 94 的逻辑)
#    2) 发行版工具链检查/安装   (调用 95-wsl-install-deps.sh)
#    3) 完整构建               (调用 99-wsl-build.sh all ...)
#
#  用法:
#    ./scripts/96-wsl-oneclick.sh [--distro Debian] [--prepare-only]
#                                 [--jobs N] [--from 40] [--aab] ...
#    # --prepare-only 只做到第 2 步（用于验证环境，不启动长构建）
#
#  说明：--prepare-only / --distro 由本脚本消费，其余参数原样转给 90-build-all.sh。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config
# shellcheck source=lib/wsl.sh
source "$SCRIPT_DIR/lib/wsl.sh"

PREPARE_ONLY=0
PASSTHRU=()

usage() {
    cat <<'EOF'
用法: 96-wsl-oneclick.sh [选项] [90-build-all.sh 的参数...]

选项:
  --distro NAME    指定发行版
  --prepare-only   只修网络 + 装工具链，不启动构建
  -h, --help       显示帮助

示例:
  ./build-android.sh wsl-oneclick                # 一键：环境 + 构建
  ./build-android.sh wsl-oneclick --prepare-only # 只准备环境
  ./build-android.sh wsl-oneclick --jobs 8       # 指定并行数
  ./build-android.sh wsl-oneclick --from 40      # 从"编译 Krita"开始
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
            --prepare-only) PREPARE_ONLY=1 ;;
            -h|--help) usage; exit 0 ;;
            *) PASSTHRU+=("$1") ;;
        esac
        shift
    done

    hr
    printf '  %s一键流程：环境准备 -> 完整构建%s\n' "$C_BOLD" "$C_RESET"

    local distro_args=()
    if [[ -n "$DISTRO" ]]; then
        distro_args=(--distro "$DISTRO")
    fi

    # --- 步骤 1+2：网络 + 工具链（95 内部会先修网络） ---
    if ! bash "$SCRIPT_DIR/95-wsl-install-deps.sh" ${distro_args[@]+"${distro_args[@]}"}; then
        die "环境准备失败（详见上方输出），修好后重新运行即可"
    fi

    if (( PREPARE_ONLY == 1 )); then
        hr
        ok "环境已就绪（--prepare-only，未启动构建）"
        printf '  开始构建: %s./build-android.sh wsl all%s\n' "$C_BOLD" "$C_RESET"
        hr
        return 0
    fi

    # --- 步骤 3：完整构建 ---
    hr
    printf '  %s开始构建（耗时较长，可随时 Ctrl+C；日志见 logs/latest.log）%s\n' "$C_BOLD" "$C_RESET"
    exec bash "$SCRIPT_DIR/99-wsl-build.sh" ${distro_args[@]+"${distro_args[@]}"} all ${PASSTHRU[@]+"${PASSTHRU[@]}"}
}

main "$@"
