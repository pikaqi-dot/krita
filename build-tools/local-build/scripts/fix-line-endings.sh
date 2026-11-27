#!/usr/bin/env bash
# =============================================================================
#  fix-line-endings.sh —— 统一行尾符号
#
#  Windows 上混用 CRLF/LF 会导致两类典型问题：
#    * *.sh  有 CRLF  -> "bad interpreter" / 奇怪的 $'\r' 报错
#    * *.bat 只有 LF  -> cmd.exe 个别情况下解析标签/块异常
#
#  本脚本： *.sh -> LF，*.bat / *.ps1 -> CRLF，.example/.conf -> LF
#
#  用法:
#    ./scripts/fix-line-endings.sh [--check]
#      --check  只检查并报告，不修改文件
# =============================================================================
set -uo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

CHECK_ONLY=0
STRICT=0
for arg in "$@"; do
    case "$arg" in
        --check)  CHECK_ONLY=1 ;;
        --strict) STRICT=1 ;;
        -h|--help)
            printf '用法: fix-line-endings.sh [--check] [--strict]\n'
            printf '  --check   只检查不修改\n'
            printf '  --strict  与 --check 搭配：有需要修正的文件时返回非零（给 CI 用）\n'
            exit 0
            ;;
    esac
done

has_cr() {
    # 文件包含 CR 时返回 0
    grep -qU $'\r' "$1" 2>/dev/null
}

convert() {
    local f="$1" mode="$2" tmp="$1.tmp.$$"
    if [[ "$mode" == "crlf" ]]; then
        awk 'BEGIN { ORS = "\r\n" } { sub(/\r$/, ""); print }' "$f" >"$tmp"
    else
        awk '{ sub(/\r$/, ""); print }' "$f" >"$tmp"
    fi
    if [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

printf '项目根目录: %s\n\n' "$PROJECT_ROOT"

fixed=0
checked=0

while IFS= read -r -d '' f; do
    f="./${f#./}"
    case "$f" in
        # cmd.exe / PowerShell 传统上用 CRLF
        *.bat|*.cmd|*.ps1|*.psm1) want="crlf" ;;
        *)                        want="lf" ;;
    esac

    if has_cr "$f"; then
        actual="crlf"
    else
        actual="lf"
    fi

    checked=$((checked + 1))
    if [[ "$actual" == "$want" ]]; then
        [[ "$CHECK_ONLY" == "1" ]] && printf '  OK    %-40s (%s)\n' "$f" "$actual"
        continue
    fi

    if [[ "$CHECK_ONLY" == "1" ]]; then
        printf '  NEED  %-40s %s -> %s\n' "$f" "$actual" "$want"
    else
        convert "$f" "$want"
        printf '  FIXED %-40s %s -> %s\n' "$f" "$actual" "$want"
    fi
    fixed=$((fixed + 1))
# 排除 .git 与 logs/（logs/ 下是运行期生成的临时脚本）
done < <(find . -path ./.git -prune -o -path ./logs -prune -o -type f \
            \( -name '*.sh' -o -name '*.bat' -o -name '*.cmd' \
               -o -name '*.ps1' -o -name '*.psm1' \
               -o -name '*.md' -o -name '*.txt' -o -name '*.in' \
               -o -name '*.conf' -o -name '*.example' \
               -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' \
               -o -name '*.cmake' \
               -o -name 'Dockerfile' -o -name '.gitignore' -o -name '.gitattributes' \) \
            -print0 | sort -z)

printf '\n已检查 %d 个文件' "$checked"
if [[ "$CHECK_ONLY" == "1" ]]; then
    printf '，需要修正 %d 个\n' "$fixed"
    if [[ "$STRICT" == "1" && "$fixed" -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi
printf '，修正 %d 个\n' "$fixed"
