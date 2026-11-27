#!/usr/bin/env bash
# =============================================================================
#  clean-logs.sh —— 删除构建日志与临时文本文件（*.log / *.txt）
#
#  典型场景：logs/ 下堆了几百 MB 的构建日志、调试时留下的 *.txt，
#  一条命令清掉，不用手工翻目录。
#
#  安全设计（重要）：
#    * 默认**跳过被 git 跟踪的文件**（避免误删仓库里的 .txt 源文件，
#      删了会让 git 变成 dirty）；
#    * 跳过 .git / dist / _build / _install* / PythonEnv* / node_modules 等目录；
#    * 默认**先列出再询问**；非交互环境（脚本/CI）必须显式加 -y 才会真删；
#    * 支持 --list 只看不删、--keep N 保留最近 N 个日志。
#
#  用法:
#    ./scripts/clean-logs.sh [选项]
#    ./build-android.sh clean-logs [选项]
#
#  选项:
#    -n, --list, --dry-run   只列出将删除的文件，不删除
#    -y, --yes, --force      不询问，直接删除（非交互环境必需）
#        --log-only          只删 *.log
#        --txt-only          只删 *.txt
#        --keep N            每个目录只保留最新 N 个 *.log（默认 0 = 全部删除）
#        --older-than N      只删 N 天以前的文件（默认 0 = 不限）
#        --dirs "A B"        额外要清理的目录（可多次指定，递归）
#        --include-tracked   连 git 跟踪的文件也删（危险，默认关闭）
#    -h, --help              显示帮助
#
#  示例:
#    ./build-android.sh clean-logs --list
#    ./build-android.sh clean-logs --keep 5 -y
#    ./build-android.sh clean-logs --dirs "/mnt/c/krita-dev/logs C:/temp/logs" -y
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
detect_platform
install_failure_hold

LIST_ONLY=0
ASSUME_YES=0
DO_LOG=1
DO_TXT=1
KEEP=0
OLDER_THAN=0
INCLUDE_TRACKED=0
EXTRA_DIRS=()

usage() {
    cat <<'EOF'
用法: clean-logs.sh [选项]

选项:
  -n, --list, --dry-run   只列出将删除的文件，不删除
  -y, --yes, --force      不询问，直接删除（非交互环境必需）
      --log-only          只删 *.log
      --txt-only          只删 *.txt
      --keep N            每个目录只保留最新 N 个 *.log（默认 0 = 全部删除）
      --older-than N      只删修改时间在 N 天以前的文件（默认 0 = 不限）
      --dirs "A B"        额外要清理的目录（可多次指定，递归）
      --include-tracked   连 git 跟踪的文件也删（危险，默认关闭）
  -h, --help              显示帮助

默认清理范围:
  项目根目录（本仓库）下所有 *.log 与 *.txt，但会跳过：
    .git  dist  _build*  _install*  PythonEnv*  node_modules  .venv
  以及被 git 跟踪的文件（--include-tracked 可关闭此保护）。

示例:
  ./build-android.sh clean-logs --list
  ./build-android.sh clean-logs --keep 5 -y
  ./build-android.sh clean-logs --dirs "C:/krita-dev/logs" -y
EOF
}

# ---------------------------------------------------------------------------
# 收集要清理的文件
# ---------------------------------------------------------------------------
FILES=()

add_files_from_dir() {
    local dir="$1" name f
    [[ -d "$dir" ]] || return 0

    # 注意：多个 -iname 之间必须显式加 -o，否则 find 会要求同时满足（永远为空）
    local -a age_args=()
    (( OLDER_THAN > 0 )) && age_args+=(-mtime "+$OLDER_THAN")
    local -a name_args=()
    if (( DO_LOG == 1 )); then
        name_args+=(-iname '*.log')
    fi
    if (( DO_TXT == 1 )); then
        ((${#name_args[@]} > 0)) && name_args+=(-o)
        name_args+=(-iname '*.txt')
    fi
    ((${#name_args[@]} > 0)) || return 0

    while IFS= read -r -d '' f; do
        [[ -n "$f" ]] || continue
        FILES+=("$f")
    done < <(find "$dir" \
        \( -path '*/.git' -o -path '*/.git/*' \
        -o -path '*/dist' -o -path '*/dist/*' \
        -o -path '*/_build*' -o -path '*/_build*/*' \
        -o -path '*/_install*' -o -path '*/_install*/*' \
        -o -path '*/PythonEnv*' -o -path '*/PythonEnv*/*' \
        -o -path '*/node_modules' -o -path '*/node_modules/*' \
        -o -path '*/.venv' -o -path '*/.venv/*' \
        -o -path '*/b_krita' -o -path '*/b_krita/*' \) -prune \
        -o -type f \( "${name_args[@]}" \) ${age_args[@]+"${age_args[@]}"} -print0 2>/dev/null)
}

# git 跟踪清单（相对仓库根，正斜杠）
TRACKED=""

load_tracked() {
    have_cmd git || return 0
    [[ -d "$PROJECT_ROOT/.git" ]] || return 0
    TRACKED="$(git -C "$PROJECT_ROOT" ls-files 2>/dev/null | sort -u)"
}

is_tracked() {
    local f="$1" rel
    [[ -n "$TRACKED" ]] || return 1
    rel="${f#"$PROJECT_ROOT"/}"
    [[ "$rel" != "$f" ]] || return 1
    printf '%s\n' "$TRACKED" | grep -Fxq -- "$rel"
}

# 每个目录里最近 N 个 *.log 之外的，才删
within_keep() {
    (( KEEP > 0 )) || return 1
    local f="$1"
    [[ "$(basename -- "$f")" == *.log || "$(basename -- "$f")" == *.LOG ]] || return 1
    local dir
    dir="$(dirname -- "$f")"
    local rank
    # 按修改时间倒序，看 targets 排第几；用 substr 比较尾部，避免路径里的
    # 正则元字符（如 [ ]）被当作 pattern
    rank="$(find "$dir" -maxdepth 1 -type f -iname '*.log' -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | awk -v target="$f" '
            {
                n++
                if (substr($0, length($0) - length(target) + 1) == target) { print n; exit }
            }')"
    [[ -n "$rank" ]] || return 1
    (( rank > KEEP ))
}

human_size() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.1fG", b/1073741824}'
    elif (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.1fM", b/1048576}'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.1fK", b/1024}'
    else
        printf '%dB' "$bytes"
    fi
}

confirm() {
    (( ASSUME_YES == 1 )) && return 0
    if [[ ! -t 0 ]]; then
        warn "非交互环境，未指定 -y，已中止（用 --list 可先查看）"
        return 1
    fi
    local answer=""
    printf '  确认删除以上文件? 输入 yes 继续: '
    read -r answer
    [[ "$answer" == "yes" ]]
}

main() {
    while (($#)); do
        case "$1" in
            -n|--list|--dry-run) LIST_ONLY=1 ;;
            -y|--yes|--force)    ASSUME_YES=1 ;;
            --log-only)          DO_LOG=1; DO_TXT=0 ;;
            --txt-only)          DO_LOG=0; DO_TXT=1 ;;
            --keep)
                shift
                [[ $# -gt 0 ]] || die "--keep 需要一个数值"
                KEEP="$1"
                [[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep 需要非负整数: $KEEP"
                ;;
            --older-than)
                shift
                [[ $# -gt 0 ]] || die "--older-than 需要一个数值（天）"
                OLDER_THAN="$1"
                [[ "$OLDER_THAN" =~ ^[0-9]+$ ]] || die "--older-than 需要非负整数: $OLDER_THAN"
                ;;
            --dirs)
                shift
                [[ $# -gt 0 ]] || die "--dirs 需要一个目录列表（空格分隔）"
                local d
                for d in $1; do EXTRA_DIRS+=("$d"); done
                ;;
            --include-tracked)   INCLUDE_TRACKED=1 ;;
            -h|--help)           usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    (( DO_LOG == 1 || DO_TXT == 1 )) || die "--log-only 与 --txt-only 不能同时使用"

    hr
    printf '  %s清理日志 / 文本文件%s   (log=%s txt=%s keep=%s older-than=%s)\n' \
        "$C_BOLD" "$C_RESET" \
        "$([[ $DO_LOG == 1 ]] && echo on || echo off)" \
        "$([[ $DO_TXT == 1 ]] && echo on || echo off)" \
        "$KEEP" "$OLDER_THAN"

    load_tracked
    add_files_from_dir "$PROJECT_ROOT"
    local d
    for d in ${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}; do
        [[ -n "$d" ]] && add_files_from_dir "$d"
    done

    # 去重 + 过滤（跟踪文件 / --keep）
    local -a selected=()
    local -A seen=()
    local f skipped_tracked=0 skipped_keep=0
    for f in ${FILES[@]+"${FILES[@]}"}; do
        [[ -n "${seen[$f]:-}" ]] && continue
        seen[$f]=1
        if (( INCLUDE_TRACKED == 0 )) && is_tracked "$f"; then
            skipped_tracked=$((skipped_tracked + 1))
            continue
        fi
        if within_keep "$f"; then
            skipped_keep=$((skipped_keep + 1))
            continue
        fi
        selected+=("$f")
    done

    if ((${#selected[@]} == 0)); then
        ok "没有需要清理的日志/文本文件"
        (( skipped_tracked > 0 )) && log "（跳过 git 跟踪的文件 $skipped_tracked 个）"
        (( skipped_keep > 0 )) && log "（--keep $KEEP 保留了 $skipped_keep 个）"
        hr
        return 0
    fi

    printf '  %-10s %s\n' "大小" "文件"
    local total=0 size
    for f in "${selected[@]}"; do
        size="$(wc -c <"$f" 2>/dev/null || echo 0)"
        total=$((total + size))
        printf '  %-10s %s\n' "$(human_size "$size")" "$f"
    done
    hr
    printf '  合计: %s（%d 个文件）\n' "$(human_size "$total")" "${#selected[@]}"
    (( skipped_tracked > 0 )) && printf '  跳过: %d 个被 git 跟踪的文件（--include-tracked 可删）\n' "$skipped_tracked"
    (( skipped_keep > 0 )) && printf '  保留: %d 个（--keep %d）\n' "$skipped_keep" "$KEEP"
    hr

    if (( LIST_ONLY == 1 )); then
        log "--list：只列出，不删除"
        return 0
    fi
    if ! confirm; then
        warn "已取消"
        return 1
    fi

    local n=0 freed=0
    for f in "${selected[@]}"; do
        size="$(wc -c <"$f" 2>/dev/null || echo 0)"
        if rm -f -- "$f" 2>/dev/null; then
            n=$((n + 1))
            freed=$((freed + size))
        else
            warn "删除失败: $f"
        fi
    done

    hr
    ok "已删除 $n 个文件，释放 $(human_size "$freed")"
    # 顺手删掉空的 logs/ 子目录（只删空目录，不动 logs 本身）
    if [[ -d "$PROJECT_ROOT/logs" ]]; then
        find "$PROJECT_ROOT/logs" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    fi
    hr
    return 0
}

main "$@"
