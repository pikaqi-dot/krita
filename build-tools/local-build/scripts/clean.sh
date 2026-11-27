#!/usr/bin/env bash
# =============================================================================
#  clean.sh —— 清理构建产物 / 缓存，释放磁盘空间
#
#  对应官方文档提到的 "cleanup section"（磁盘紧张时清理缓存）。
#
#  用法:
#    ./scripts/clean.sh [--build] [--deps] [--venv] [--sdk] [--all]
#                       [--force] [--dry-run] [--list]
#
#  说明:
#    --build   删除 _build / _install / _packaging
#    --deps    删除依赖缓存、base-env、env、.kde-ci.yml、envdir
#    --venv    删除 Python venv
#    --sdk     删除 Android SDK / NDK / cmdline-tools（需重新执行 setup-sdk）
#    --all     等价于 --build --deps --venv
#    默认（不带参数）= --build
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

DO_BUILD=0
DO_DEPS=0
DO_VENV=0
DO_SDK=0
FORCE=0
LIST_ONLY=0

usage() {
    cat <<'EOF'
用法: clean.sh [选项]

选项:
  --build    删除 _build / _install / _packaging（默认）
  --deps     删除依赖缓存、base-env、env、.kde-ci.yml、envdir
  --venv     删除 Python 虚拟环境
  --sdk      删除 Android SDK / NDK / cmdline-tools
  --all      == --build --deps --venv
  --list     只列出将被删除的路径与体积
  --force    不询问，直接删除
  --dry-run  只打印命令
  -h, --help 显示帮助
EOF
}

TARGETS=()

add_target() {
    local label="$1" path="$2"
    [[ -n "$path" ]] || return 0
    if [[ -e "$path" ]]; then
        TARGETS+=("$label|$path")
    fi
}

collect() {
    TARGETS=()
    if (( DO_BUILD == 1 )); then
        add_target "构建目录"   "$BUILD_DIR"
        add_target "安装目录"   "$KRITA_INSTALL_DIR"
        add_target "打包产物"   "$PACKAGING_DIR"
        # Linux 桌面版（deb 目标）的独立构建目录，与 Android 的 _build 分开
        add_target "Linux 构建" "$KRITA_SRC/_build_linux"
    fi
    if (( DO_DEPS == 1 )); then
        add_target "依赖缓存"   "$WORKDIR/deps"
        add_target "envdir"     "$ENVDIR"
        add_target "base-env"   "$WORKDIR/base-env"
        add_target "构建环境"   "$KRITA_SRC/env"
        add_target "deps 描述"  "$KRITA_SRC/.kde-ci.yml"
    fi
    if (( DO_VENV == 1 )); then
        add_target "Python venv" "$VENVDIR"
    fi
    if (( DO_SDK == 1 )); then
        add_target "Android SDK"  "$KDECI_ANDROID_SDK_ROOT"
        add_target "Android NDK"  "$KDECI_ANDROID_NDK_ROOT"
        add_target "cmdline-tools" "$CMDLINE_TOOLS_DIR"
    fi
}

confirm() {
    if (( FORCE == 1 )); then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "非交互环境，未指定 --force，已中止"
        return 1
    fi
    local answer=""
    printf '  确认删除以上内容? 输入 yes 继续: '
    read -r answer
    [[ "$answer" == "yes" ]]
}

main() {
    while (($#)); do
        case "$1" in
            --build)   DO_BUILD=1 ;;
            --deps)    DO_DEPS=1 ;;
            --venv)    DO_VENV=1 ;;
            --sdk)     DO_SDK=1 ;;
            --all)     DO_BUILD=1; DO_DEPS=1; DO_VENV=1 ;;
            --list)    LIST_ONLY=1 ;;
            --force)   FORCE=1 ;;
            --dry-run) KRITA_DRY_RUN=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    if (( DO_BUILD + DO_DEPS + DO_VENV + DO_SDK == 0 )); then
        DO_BUILD=1
    fi

    collect

    hr
    printf '  %s清理目标%s\n' "$C_BOLD" "$C_RESET"
    if ((${#TARGETS[@]} == 0)); then
        ok "没有需要清理的内容"
        hr
        return 0
    fi

    local entry label path size total=0
    for entry in "${TARGETS[@]}"; do
        label="${entry%%|*}"
        path="${entry#*|}"
        size="$(du_size "$path")"
        printf '  %-14s %-10s %s\n' "$label" "${size:-?}" "$path"
    done
    hr

    if (( LIST_ONLY == 1 )); then
        return 0
    fi

    if ! confirm; then
        warn "已取消"
        return 1
    fi

    for entry in "${TARGETS[@]}"; do
        label="${entry%%|*}"
        path="${entry#*|}"
        run rm -rf -- "$path"
        ok "已删除[$label]: $path"
    done

    hr
    if (( DO_SDK == 1 )); then
        warn "SDK/NDK 已删除，下次构建请先执行: ./build-android.sh sdk"
    fi
    if (( DO_DEPS == 1 || DO_VENV == 1 )); then
        warn "构建环境已清理，下次构建请先执行: ./build-android.sh deps"
    fi
    ok "清理完成"
    hr
    printf '  剩余空间（%s）: %sGB\n' "$WORKDIR" "$(free_space_gb "$WORKDIR" || echo '?')"
}

main "$@"
