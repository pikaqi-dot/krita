#!/usr/bin/env bash
# =============================================================================
#  94-wsl-network.sh —— 修复 WSL2 的网络/代理（apt、git 全部超时的根因）
#
#  典型症状：
#    * Windows 上开了系统代理（如 127.0.0.1:7890）并使用 fake-IP DNS
#    * WSL 处于 NAT 模式：访问不到宿主机的 127.0.0.1:7890，
#      域名又被解析到 198.18.x.x 之类黑洞地址
#    * 结果：apt / git / curl 全部超时，安装依赖失败
#
#  本脚本按下面的顺序自动处理：
#    1) 若发行版能直连外网 -> 什么都不做
#    2) 若 Windows 代理在发行版内可达（代理软件开了"Allow LAN"）
#         -> 写入 /etc/apt/apt.conf.d/99-krita-proxy
#            与 /etc/profile.d/99-krita-proxy.sh
#    3) 否则写入 %USERPROFILE%\.wslconfig 的 networkingMode=mirrored
#       并执行 wsl --shutdown（镜像网络下 127.0.0.1 就是 Windows 本机）
#
#  用法:
#    ./build-android.sh wsl-network                 # 自动诊断并修复
#    ./scripts/94-wsl-network.sh --check            # 只看诊断结果
#    ./scripts/94-wsl-network.sh --proxy 172.20.0.1:7890
#    ./scripts/94-wsl-network.sh --mirrored         # 直接切镜像网络
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config
# shellcheck source=lib/wsl.sh
source "$SCRIPT_DIR/lib/wsl.sh"

CHECK_ONLY=0
FORCED_PROXY=""
FORCE_MIRRORED=0

usage() {
    cat <<'EOF'
用法: 94-wsl-network.sh [选项]

选项:
  --distro NAME        指定发行版
  --proxy HOST:PORT    直接用指定的代理（跳过自动探测）
  --mirrored           直接切到镜像网络模式（写入 .wslconfig + wsl --shutdown）
  --check              只诊断，不修改任何配置
  -h, --help           显示帮助
EOF
}

show_diagnosis() {
    local mode
    mode="$(wsl_networking_mode)"
    info "诊断"
    log "networkingMode : ${mode:-未设置（NAT 模式）}"
    log "宿主机 IP      : $(wsl_host_ip)"
    log "Windows 代理   : $(win_system_proxy)"
    log "站点连通性（apt / git / JDK 下载所需）:"
    if wsl_net_report; then
        ok "关键站点全部可达"
        return 0
    fi
    warn "存在不可达站点（见上），apt / git 会超时"
    return 1
}

main() {
    while (($#)); do
        case "$1" in
            --distro)
                shift
                [[ $# -gt 0 ]] || die "--distro 需要一个发行版名称"
                DISTRO="$1"
                ;;
            --proxy)
                shift
                [[ $# -gt 0 ]] || die "--proxy 需要 HOST:PORT"
                FORCED_PROXY="$1"
                ;;
            --mirrored) FORCE_MIRRORED=1 ;;
            --check) CHECK_ONLY=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    hr
    printf '  %sWSL2 网络 / 代理修复%s\n' "$C_BOLD" "$C_RESET"

    resolve_distro
    local proxy hostip
    proxy="$(win_system_proxy)"
    hostip="$(wsl_host_ip)"

    # 已可用则直接结束
    if show_diagnosis; then
        return 0
    fi

    if (( CHECK_ONLY == 1 )); then
        wsl_print_network_hint "$proxy" "$hostip"
        return 1
    fi

    # 1) 指定代理
    if [[ -n "$FORCED_PROXY" ]]; then
        info "测试指定代理 $FORCED_PROXY"
        if wsl_proxy_ok "$FORCED_PROXY"; then
            wsl_write_proxy_config "$FORCED_PROXY" "$hostip"
            wsl_net_ok && {
                ok "代理可用，网络已打通"
                return 0
            }
        else
            warn "代理 $FORCED_PROXY 在发行版内不可达"
        fi
    fi

    # 2) 强制镜像网络
    if (( FORCE_MIRRORED == 1 )); then
        info "切换到镜像网络模式"
        wsl_enable_mirrored || true
        log "执行 wsl --shutdown（会重启所有发行版）"
        WSL_UTF8=1 MSYS_NO_PATHCONV=1 wsl.exe --shutdown || true
        sleep 3
        resolve_distro >/dev/null
        if wsl_net_ok; then
            ok "镜像网络生效"
            return 0
        fi
        warn "镜像网络下仍有站点不可达"
        wsl_print_network_hint "$proxy" "$hostip"
        return 1
    fi

    # 3) 自动流程：代理 -> 镜像网络
    info "自动修复"
    if wsl_ensure_network; then
        hr
        printf '  网络已就绪，下一步: %s./build-android.sh wsl-install%s\n' "$C_BOLD" "$C_RESET"
        return 0
    fi

    wsl_print_network_hint "$proxy" "$hostip"
    return 1
}

main "$@"
