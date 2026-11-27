#!/usr/bin/env bash
# =============================================================================
#  20-fetch-sources.sh —— 获取 Krita 源码与管理仓库
#
#  对应官方文档 "Checkout Krita repository and all the management repositories"：
#    $SRCDIR/krita
#      └── krita-deps-management          (krita-deps-management.git)
#            └── ci-utilities             (krita-ci-utilities.git)
#
#  实用加固（官方文档没有、但实践必需）：
#    * 大仓库 + 本地代理会触发
#        "RPC failed; curl 56 GnuTLS recv error (-9)" / "early EOF"
#      解决：git 走 HTTP/1.1、加大 postBuffer、浅克隆（默认 --depth 1）
#    * 克隆失败自动清理并重试（逐次更保守）
#
#  用法:
#    ./scripts/20-fetch-sources.sh [--depth N] [--full] [--update]
#                                  [--retries N] [--no-git-tune]
#
#     --depth N      浅克隆深度（默认 1；0 或 --full = 完整克隆）
#     --retries N    失败后的额外重试次数（默认 2）
#     --update       已存在的仓库执行 fetch + pull --ff-only
#     --no-git-tune  不修改 WSL 里的全局 git 传输参数
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

UPDATE=0
GIT_TUNE=1
RETRIES=2
FORCE_RECLONE=0
DEPTH="${KRITA_CLONE_DEPTH:-1}"

usage() {
    cat <<'EOF'
用法: 20-fetch-sources.sh [选项]

选项:
  --depth N       浅克隆深度（默认 1；0 = 完整克隆）
  --full          等价于 --depth 0（完整克隆，最慢、最容易被代理打断）
  --retries N     失败后的额外重试次数（默认 2）
  --update        对已存在的仓库执行 fetch + pull --ff-only（增量更新）
  --force-reclone 删除已存在的仓库后重新克隆（默认是增量，不会重下）
  --no-git-tune   不改动 WSL 里的全局 git 传输参数
  -h, --help      显示帮助

说明:
  Krita 仓库很大（完整克隆 1GB+）。默认 --depth 1 只需十分之一左右，
  构建 Android 版完全够用；需要完整历史时用 --full。
EOF
}

repo_head() {
    local dir="$1" desc=""
    if [[ -d "$dir/.git" ]]; then
        desc="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
        if ! git -C "$dir" rev-parse --verify --quiet HEAD~1 >/dev/null 2>&1; then
            desc="$desc (shallow)"
        fi
        printf '%s\n' "$desc"
    else
        printf '%s\n' '-'
    fi
}

# ---------------------------------------------------------------------------
# git 传输参数（针对大仓库 + 代理）
# ---------------------------------------------------------------------------
prepare_git_config() {
    info "0/3 设置 git 传输参数"
    if (( GIT_TUNE == 0 )); then
        warn "已跳过（--no-git-tune）"
        return 0
    fi

    local kvs=(
        "http.version=HTTP/1.1"          # HTTP/2 经代理时极易出现 GnuTLS recv error
        "http.postBuffer=524288000"      # 让大包走 POST，避免分块传输被代理截断
        "http.maxRequestBuffer=104857600"
        "http.lowSpeedLimit=0"
        "http.lowSpeedTime=999999"
        "core.compression=0"
    )
    local kv key
    for kv in "${kvs[@]}"; do
        key="${kv%%=*}"
        git config --global "$key" "${kv#*=}" 2>/dev/null &&
            ok "$key = ${kv#*=}" || warn "无法设置 $key"
    done
    git config --global --get http.proxy >/dev/null 2>&1 &&
        warn "检测到 git 全局 http.proxy，请确认仍可用（当前: $(git config --global --get http.proxy)）"
    log "如需恢复默认： git config --global --unset http.version"
}

# ---------------------------------------------------------------------------
# 克隆（带重试；逐次更保守）
# ---------------------------------------------------------------------------
clone_url() {
    local url="$1" dir="$2" branch="$3" depth="$4" label="$5"
    local -a args=(clone)

    if [[ -n "$branch" ]]; then
        args+=(--branch "$branch")
    fi
    if [[ "$depth" != "0" ]]; then
        args+=(--depth "$depth" --shallow-submodules --no-tags)
    fi
    args+=(--recursive "$url" "$dir")

    printf '    %s$ git %s%s\n' "$C_CYAN" "${args[*]}" "$C_RESET"
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    git "${args[@]}"
}

clone_or_update() {
    local url="$1" dir="$2" branch="$3" label="$4"
    local attempt depth

    if [[ -d "$dir/.git" ]] && (( FORCE_RECLONE == 1 )); then
        warn "强制重新克隆 $label: 删除 $dir"
        rm -rf -- "$dir"
    fi

    if [[ -d "$dir/.git" ]]; then
        ok "$label 已存在: $dir"
        log "当前: $(repo_head "$dir")"
        if (( UPDATE == 1 )); then
            run git -C "$dir" fetch --all --prune || warn "fetch 失败"
            if [[ -n "$branch" ]]; then
                run git -C "$dir" checkout "$branch" || warn "checkout 失败"
            fi
            if git -C "$dir" pull --ff-only; then
                ok "$label 已更新: $(repo_head "$dir")"
            else
                warn "$label 无法快进更新（可能有本地改动），已跳过"
            fi
        fi
        return 0
    fi

    mkdir -p "$(dirname -- "$dir")"

    for ((attempt = 0; attempt <= RETRIES; attempt++)); do
        # 第 1 次按配置；之后强制浅克隆 + 关闭进度输出，尽量减小传输量
        if (( attempt == 0 )); then
            depth="$DEPTH"
        else
            depth=1
            warn "第 $((attempt + 1)) 次尝试 $label（改用 --depth 1 --no-tags）"
        fi
        if (( attempt > 0 )); then
            rm -rf -- "$dir"
        fi

        if clone_url "$url" "$dir" "$branch" "$depth" "$label"; then
            ok "$label 克隆完成: $(repo_head "$dir")"
            return 0
        fi

        warn "$label 克隆失败"
        if (( attempt < RETRIES )); then
            warn "将清理 $dir 后重试"
        fi
    done

    rm -rf -- "$dir"
    return 1
}

report_clone_failure() {
    hr
    err "源码克隆失败（网络/代理把 TLS 流截断了）"
    printf '  典型报错： curl 56 GnuTLS recv error (-9) / early EOF / RPC failed\n\n'
    printf '  建议按顺序尝试：\n'
    printf '    1) 直接重跑本步骤（会自动清理并重试，已完成的步骤会跳过）\n'
    printf '       %s./build-android.sh wsl --shell ./scripts/20-fetch-sources.sh%s\n' "$C_BOLD" "$C_RESET"
    printf '    2) 确认 WSL 代理可用： ./build-android.sh wsl-network --check\n'
    printf '    3) 让代理软件关闭 TLS 嗅探/证书替换（或在 Clash 里把 invent.kde.org 设为直连）\n'
    printf '    4) 仍不行时手工浅克隆后再重跑本步骤：\n'
    printf '       wsl -d %s -- bash -lc "cd %s && git clone --depth 1 --recursive %s krita"\n' \
        "$DISTRO" "$SRCDIR" "$KRITA_REPO_URL"
    hr
}

main() {
    while (($#)); do
        case "$1" in
            --update) UPDATE=1 ;;
            --force-reclone) FORCE_RECLONE=1 ;;
            --no-git-tune) GIT_TUNE=0 ;;
            --full) DEPTH=0 ;;
            --depth)
                shift
                [[ $# -gt 0 ]] || die "--depth 需要一个数值参数"
                DEPTH="$1"
                ;;
            --retries)
                shift
                [[ $# -gt 0 ]] || die "--retries 需要一个数值参数"
                RETRIES="$1"
                ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    hr
    printf '  %s获取 Krita 源码与管理仓库%s\n' "$C_BOLD" "$C_RESET"
    log "SRCDIR = $SRCDIR"
    if [[ "$DEPTH" == "0" ]]; then
        log "克隆模式: 完整（历史全量，1GB+）"
    else
        log "克隆模式: 浅克隆 --depth $DEPTH"
    fi

    require_cmds git || die "请先安装 git"
    run mkdir -p "$SRCDIR"

    prepare_git_config

    info "1/3 Krita 主仓库"
    clone_or_update "$KRITA_REPO_URL" "$KRITA_SRC" "$KRITA_BRANCH" "krita" || {
        report_clone_failure
        exit 1
    }

    info "2/3 依赖管理仓库"
    clone_or_update "$KRITA_DEPS_MGMT_URL" "$DEPS_MGMT_DIR" "" "krita-deps-management" || {
        report_clone_failure
        exit 1
    }

    info "3/3 CI 工具仓库"
    clone_or_update "$KRITA_CI_UTILS_URL" "$CI_UTILS_DIR" "" "krita-ci-utilities" || {
        report_clone_failure
        exit 1
    }

    hr
    if [[ -f "$KRITA_TOOLCHAIN_FILE" ]]; then
        ok "Android 工具链文件: $KRITA_TOOLCHAIN_FILE"
    else
        warn "未找到工具链文件: $KRITA_TOOLCHAIN_FILE"
        warn "请确认 krita-deps-management 克隆成功"
    fi
    if [[ -f "$DEPS_MGMT_DIR/requirements.txt" ]]; then
        ok "Python 依赖清单: $DEPS_MGMT_DIR/requirements.txt"
    fi
    hr
    printf '  下一步: %s./build-android.sh deps%s\n' "$C_BOLD" "$C_RESET"
}

main "$@"
