#!/usr/bin/env bash
# =============================================================================
#  check-syntax.sh —— 对仓库内所有 shell 脚本做语法检查
#
#  用法:
#    ./scripts/check-syntax.sh
#
#  行为:
#    1) 对每个 *.sh 执行 bash -n（语法检查）
#    2) 若系统安装了 shellcheck，则额外运行 shellcheck -S warning
#
#  退出码: 0 全部通过 / 1 存在语法错误
# =============================================================================
set -uo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

files=()
while IFS= read -r -d '' f; do
    files+=("$f")
# 排除 .git 与 logs/（logs/ 下是运行期生成的临时脚本）
done < <(find . -name '*.sh' -not -path './.git/*' -not -path './logs/*' -print0 | sort -z)

printf '项目根目录: %s\n' "$PROJECT_ROOT"
printf 'bash 版本  : %s\n\n' "$(bash --version | head -n 1)"

fail=0
count=0
errlog="$(mktemp 2>/dev/null || echo /tmp/bash-n.$$.err)"

for f in "${files[@]}"; do
    count=$((count + 1))
    if bash -n "$f" 2>"$errlog"; then
        printf '  OK    %s\n' "$f"
    else
        printf '  FAIL  %s\n' "$f"
        sed 's/^/        /' "$errlog"
        fail=1
    fi
done

printf '\n共检查 %d 个脚本\n' "$count"

if command -v shellcheck >/dev/null 2>&1; then
    printf '\n运行 shellcheck -S warning ...\n'
    if shellcheck -S warning "${files[@]}"; then
        printf 'shellcheck: 无警告\n'
    else
        printf 'shellcheck: 存在告警（不视为失败）\n'
    fi
else
    printf '\n未安装 shellcheck，跳过静态检查（可选: apt install shellcheck）\n'
fi

if (( fail == 0 )); then
    printf '\n结果: 全部通过\n'
else
    printf '\n结果: 存在语法错误\n'
fi
exit "$fail"
