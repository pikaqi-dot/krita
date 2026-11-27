#!/usr/bin/env bash
# =============================================================================
#  95-wsl-install-deps.sh —— 在 WSL2 发行版内安装构建所需的工具链
#
#  自动完成：
#    0) 网络检查/修复（代理或镜像网络；apt、git 超时的根因）
#    1) 探测发行版现有工具
#    2) apt 安装基础工具链
#         build-essential cmake ninja-build pkgconf git curl unzip
#         python3 python3-pip python3-venv
#    3) 安装 JDK 17
#         - 优先 apt install openjdk-17-jdk
#         - 仓库没有（Debian 13/trixie 已移除）时自动用 Adoptium Temurin 17
#           -> /opt/jdk17，并写 /etc/profile.d/jdk17.sh 与 /usr/local/bin 软链接
#    4) 复查并报告
#
#  以 WSL root 执行（默认免密码），无需在 Windows 输入 sudo 密码。
#
#  用法:
#    ./build-android.sh wsl-install            # 或双击 wsl-setup.bat
#    ./scripts/95-wsl-install-deps.sh [--distro Debian] [--check] [--skip-network]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config
# shellcheck source=lib/wsl.sh
source "$SCRIPT_DIR/lib/wsl.sh"

CHECK_ONLY=0
SKIP_NETWORK=0
JDK_SOURCE=""

usage() {
    cat <<'EOF'
用法: 95-wsl-install-deps.sh [选项]

选项:
  --distro NAME   指定发行版（默认 WSL_DISTRO 或第一个已安装发行版）
  --check         只检查，不安装
  --skip-network  跳过网络/代理自动修复
  -h, --help      显示帮助

安装内容:
  apt : build-essential cmake ninja-build pkgconf git curl unzip \
        python3 python3-pip python3-venv
  JDK : 优先 openjdk-17-jdk（apt），仓库没有时自动用 Adoptium Temurin 17
EOF
}

report_apt_failure() {
    hr
    err "apt 安装失败"
    printf '  常见原因与对策：\n'
    printf '    * 网络/代理问题：先运行 ./build-android.sh wsl-network\n'
    printf '    * 发行版未启用 root：改用 sudo 手工执行\n'
    printf '    * 非 Debian/Ubuntu 系发行版：本脚本只支持 apt\n\n'
    printf '  手工命令：\n'
    printf '    wsl -d %s\n' "$DISTRO"
    printf '    sudo apt update && sudo apt install -y %s %s\n' "$WSL_APT_PACKAGES" "$WSL_JDK_APT"
}

report_java_fallback() {
    hr
    warn "javac 仍不是 17（当前: ${JAVAC_MAJOR:-未知}）—— 官方要求精确的 17"
    printf '  可手工处理：\n\n'
    printf '    # 查看发行版里有哪些 JDK\n'
    printf '    wsl -d %s -u root -- bash -lc "ls -d /usr/lib/jvm/* %s 2>/dev/null"\n\n' "$DISTRO" "$WSL_TEMURIN_DIR"
    printf '    # 让 javac 指向 Temurin 17\n'
    printf '    wsl -d %s -u root -- bash -lc "ln -sf %s/bin/javac /usr/local/bin/javac && javac --version"\n' "$DISTRO" "$WSL_TEMURIN_DIR"
    hr
}

main() {
    while (($#)); do
        case "$1" in
            --distro)
                shift
                [[ $# -gt 0 ]] || die "--distro 需要一个发行版名称"
                DISTRO="$1"
                ;;
            --check) CHECK_ONLY=1 ;;
            --skip-network) SKIP_NETWORK=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    hr
    printf '  %s在 WSL 发行版内安装构建工具链%s\n' "$C_BOLD" "$C_RESET"

    wsl_prepare

    info "1/4 当前状态"
    wsl_analyze_probe "$WSL_PROBE_OUT"

    if ((${#CRITICAL_LIST[@]} == 0)); then
        ok "依赖已齐全，无需安装"
        hr
        printf '  下一步: %s./build-android.sh wsl all%s\n' "$C_BOLD" "$C_RESET"
        return 0
    fi
    warn "缺失/不合规: ${CRITICAL_LIST[*]}"

    if (( CHECK_ONLY == 1 )); then
        printf '\n  去掉 --check 执行即可自动安装：\n'
        printf '    %s./build-android.sh wsl-install%s\n' "$C_BOLD" "$C_RESET"
        hr
        return 0
    fi

    info "0/4 网络检查（apt / git 超时的常见根因）"
    if (( SKIP_NETWORK == 0 )); then
        if ! wsl_ensure_network; then
            warn "网络未打通：apt / git 仍可能失败"
            wsl_print_network_hint "$(win_system_proxy)" "$(wsl_host_ip)"
        fi
    else
        warn "已跳过网络检查（--skip-network）"
    fi

    info "2/4 安装基础工具链（apt）"
    log "包列表: $WSL_APT_PACKAGES"
    if ! wsl_apt_install "$WSL_APT_PACKAGES"; then
        report_apt_failure
        die "安装未完成"
    fi
    ok "apt 基础工具链完成"

    info "3/4 安装 JDK 17"
    if wsl_apt_install_pkgs "$WSL_JDK_APT"; then
        JDK_SOURCE="apt:$WSL_JDK_APT"
        ok "已通过 apt 安装 $WSL_JDK_APT"
    else
        warn "apt 仓库中没有 $WSL_JDK_APT（Debian 13/trixie 等已移除该包）"
        if ! wsl_install_jdk_temurin; then
            report_java_fallback
            die "JDK 17 安装失败"
        fi
        JDK_SOURCE="temurin:$WSL_TEMURIN_DIR"
    fi

    info "4/4 复查"
    WSL_PROBE_OUT="$(wsl_probe_distro "$WSL_ROOT")"
    JAVAC_MAJOR="$(get_field "$WSL_PROBE_OUT" JAVAC_MAJOR)"
    if [[ -n "$JAVAC_MAJOR" && "$JAVAC_MAJOR" != "17" ]]; then
        wsl_fix_java_alternatives
        WSL_PROBE_OUT="$(wsl_probe_distro "$WSL_ROOT")"
    fi
    wsl_analyze_probe "$WSL_PROBE_OUT"

    hr
    if ((${#CRITICAL_LIST[@]} > 0)); then
        warn "仍有缺失: ${CRITICAL_LIST[*]}"
        wsl_print_apt_hint
        return 1
    fi
    if [[ -n "${JAVAC_MAJOR:-}" && "$JAVAC_MAJOR" != "17" ]]; then
        report_java_fallback
        return 1
    fi

    ok "发行版工具链就绪（javac ${JAVAC_MAJOR:-?}${JDK_SOURCE:+, $JDK_SOURCE}）"
    printf '  下一步: %s./build-android.sh wsl all%s\n' "$C_BOLD" "$C_RESET"
    hr
}

main "$@"
