#!/usr/bin/env bash
# =============================================================================
#  check-docs.sh —— 文档与代码的一致性检查
#
#  抓的是"文档漂移"这一类问题：
#    * 脚本/批处理存在，但 README 的目录结构 / .bat 表里没有它
#    * README 命令表里写了某个命令，但 build-android.sh 根本不认
#    * FAQ 编号断号或重复
#    * README 里提到的开关，脚本里没有解析
#
#  别名（package=apk、status=report …）只作为提示，不算失败。
#
#  用法:
#    bash scripts/check-docs.sh          # 有错误时 exit 1
#    bash scripts/check-docs.sh -v       # 同时显示别名提示
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
README="$ROOT/README.md"
ENTRY="$ROOT/build-android.sh"

VERBOSE=0
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE=1

[[ -f "$README" ]] || { echo "找不到 README.md"; exit 1; }
[[ -f "$ENTRY" ]] || { echo "找不到 build-android.sh"; exit 1; }

tmp="$(mktemp -d 2>/dev/null || printf '%s/krita-docs-%s' "${TMPDIR:-/tmp}" "$$")"
mkdir -p "$tmp"
# shellcheck disable=SC2064
trap "rm -rf '$tmp'" EXIT

ERRORS=0
WARNS=0
err()  { printf '  \033[31m[错误]\033[0m %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
warn() { printf '  \033[33m[提示]\033[0m %s\n' "$*"; WARNS=$((WARNS + 1)); }
ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }

echo "文档一致性检查"
echo "  README : $README"
echo "  入口   : $ENTRY"
echo "-------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# 1) 子命令：文档写了但代码不认（真正过时）
# ---------------------------------------------------------------------------
awk '/case "\$cmd" in/,/^    esac/' "$ENTRY" |
    grep -oE '^[[:space:]]+[^)]+\)' | sed 's/)[[:space:]]*$//' |
    tr '|' '\n' | tr -d ' ' |
    grep -vE '^$|^\*|^-h$|^--help$|^help$' | sort -u >"$tmp/cmds_code"

sed -n '/^## 四、命令一览/,/^### 常用开关/p' "$README" |
    grep -oE '^\| `[^`]+`' | sed 's/^| `//; s/`$//' | sort -u >"$tmp/cmds_doc"

stale="$(comm -13 "$tmp/cmds_code" "$tmp/cmds_doc" | grep -v '^$' || true)"
if [[ -n "$stale" ]]; then
    while IFS= read -r c; do err "命令表里的 '$c' 在 build-android.sh 里没有对应分支"; done <<<"$stale"
else
    ok "命令表没有过时条目"
fi

# 别名（只提示）
alias_hints="$(comm -23 "$tmp/cmds_code" "$tmp/cmds_doc" | grep -v '^$' |
    grep -vE '\*$' || true)"
if [[ -n "$alias_hints" ]]; then
    if (( VERBOSE == 1 )); then
        while IFS= read -r a; do
            grep -qF -- "\`$a\`" "$README" &&
                warn "别名 '$a' 文档里提到了（正文只用主名，可接受）" ||
                warn "别名 '$a' 文档里完全没提"
        done <<<"$alias_hints"
    fi
fi

# ---------------------------------------------------------------------------
# 2) Windows 双击入口（根目录与 entrypoints/ 下的 .bat）是否都在 §〇 提到
# ---------------------------------------------------------------------------
{ ls -1 "$ROOT"/*.bat "$ROOT"/entrypoints/*.bat 2>/dev/null || true; } |
    xargs -n1 basename | sort -u >"$tmp/bat_fs"
sed -n '/^## 〇、/,/^---$/p' "$README" |
    grep -oE '`[a-zA-Z0-9_-]+\.bat`' | tr -d '`' | sort -u >"$tmp/bat_doc"
missing_bat="$(comm -23 "$tmp/bat_fs" "$tmp/bat_doc" | grep -v '^$' || true)"
if [[ -n "$missing_bat" ]]; then
    while IFS= read -r b; do err "存在 $b，但 §〇 的 .bat 表里没写"; done <<<"$missing_bat"
else
    ok "§〇 覆盖了所有 .bat 入口"
fi

# ---------------------------------------------------------------------------
# 3) scripts/ 下的脚本是否都在 §二 目录结构里
# ---------------------------------------------------------------------------
ls -1 "$ROOT"/scripts/*.sh "$ROOT"/scripts/*.ps1 2>/dev/null |
    xargs -n1 basename | sort -u >"$tmp/scripts_fs"
sed -n '/^## 二、目录结构/,/^## 三、/p' "$README" |
    grep -oE '[0-9a-zA-Z_-]+\.(sh|ps1)' | sort -u >"$tmp/scripts_doc"
missing_scripts="$(comm -23 "$tmp/scripts_fs" "$tmp/scripts_doc" | grep -v '^$' || true)"
if [[ -n "$missing_scripts" ]]; then
    while IFS= read -r s; do err "scripts/$s 没有出现在 §二 目录结构里"; done <<<"$missing_scripts"
else
    ok "§二 覆盖了所有 scripts/*.sh|*.ps1"
fi

# ---------------------------------------------------------------------------
# 4) FAQ 编号连续性（§七 到 §八 之间）
# ---------------------------------------------------------------------------
faq_bad="$(sed -n '/^## 七、常见问题/,/^## 八、/p' "$README" |
    grep -oE '^### [0-9]+\.' | grep -oE '[0-9]+' |
    awk 'NR==1{p=$1; first=$1}
         NR>1 && $1 != p {print $1; bad=1}
         {p=$1+1; last=$1}
         END{if (!bad) printf ""}' || true)"
if [[ -n "$faq_bad" ]]; then
    while IFS= read -r n; do err "FAQ 编号断号/重复：出现 $n"; done <<<"$faq_bad"
else
    faq_range="$(sed -n '/^## 七、常见问题/,/^## 八、/p' "$README" |
        grep -oE '^### [0-9]+\.' | grep -oE '[0-9]+' |
        awk 'NR==1{f=$1} {l=$1; n++} END{printf "%s..%s（%d 条）", f, l, n}')"
    ok "FAQ 编号连续：$faq_range"
fi

# ---------------------------------------------------------------------------
# 5) README 提到的关键开关，脚本里是否真的解析
# ---------------------------------------------------------------------------
OPTS="--check-deps --install-deps --deps-only --pack-only --qt6 --no-deb --prefix
      --release --nightly --sign --aab --force --clean-build --older-than
      --skip-optional --jobs --dry-run --from --only --resume"
bad_opts=0
for o in $OPTS; do
    if ! grep -qF -- "$o" "$ROOT"/scripts/*.sh 2>/dev/null; then
        err "README 提到 $o，但 scripts/ 里没有任何脚本解析它"
        bad_opts=1
    fi
done
(( bad_opts == 0 )) && ok "README 里的关键开关都能在脚本里找到"

# ---------------------------------------------------------------------------
# 6) config 示例里的变量是否都在 §五 配置表里
# ---------------------------------------------------------------------------
if [[ -f "$ROOT/config/android-build.conf.example" ]]; then
    grep -oE '^#?[A-Z][A-Z0-9_]+=' "$ROOT/config/android-build.conf.example" |
        tr -d '#=' | sort -u >"$tmp/cfg_example"
    sed -n '/^## 五、配置项/,/^## 六、/p' "$README" |
        grep -oE '^\| `[A-Z][A-Z0-9_]+`' | tr -d '|` ' | sort -u >"$tmp/cfg_doc"
    miss_cfg="$(comm -23 "$tmp/cfg_example" "$tmp/cfg_doc" | grep -v '^$' || true)"
    if [[ -n "$miss_cfg" ]]; then
        while IFS= read -r v; do err "config 示例里的 $v 没写进 §五 配置表"; done <<<"$miss_cfg"
    else
        ok "§五 配置表覆盖了 config 示例里的所有变量"
    fi
fi

# ---------------------------------------------------------------------------
# 7) 脚本读取的 KRITA_* 环境变量是否在 README 提过
#    （纯内部/派生变量列入白名单，避免噪音）
# ---------------------------------------------------------------------------
INTERNAL_ENV="KRITA_OS KRITA_SHELL_FLAVOR KRITA_CI_SCRIPTS_DIR KRITA_TOOLCHAIN_FILE KRITA_EXIT_SOFT KRITA_FORCE_DOWNLOAD"
grep -rhoE '\$\{?KRITA_[A-Z0-9_]+' "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh |
    sed 's/^\${\?//' | sort -u >"$tmp/env_used"
miss_env=""
while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    skip=0
    for i in $INTERNAL_ENV; do
        [[ "$v" == "$i" ]] && skip=1
    done
    (( skip == 1 )) && continue
    grep -qF -- "$v" "$README" || miss_env="$miss_env $v"
done <"$tmp/env_used"
if [[ -n "$miss_env" ]]; then
    warn "这些环境变量脚本会读、README 没提:$miss_env"
else
    ok "README 覆盖了脚本读取的 KRITA_* 环境变量"
fi

# ---------------------------------------------------------------------------
echo "-------------------------------------------------------------------"
if (( ERRORS > 0 )); then
    printf '  结果: \033[31m%d 个错误\033[0m' "$ERRORS"
    if (( WARNS > 0 )); then
        printf '，%d 个提示' "$WARNS"
    fi
    printf '\n'
    exit 1
fi
(( WARNS > 0 )) && printf '  结果: 通过（%d 个提示）\n' "$WARNS"
(( WARNS == 0 )) && printf '  结果: 通过\n'
exit 0
