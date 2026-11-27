#!/usr/bin/env bash
# =============================================================================
#  common.sh —— Krita Android 构建脚本通用函数库
#
#  只提供函数/常量，不产生破坏性副作用。
#  用法： source "<repo>/scripts/lib/common.sh"
#
#  兼容： Linux / macOS / Windows(Git Bash, MSYS2)
# =============================================================================

if [[ -n "${_KRITA_COMMON_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_KRITA_COMMON_LOADED=1

# 不在此处 set -e，由调用方决定；但打开 pipefail 便于捕获管道中的失败。
set -o pipefail

# ---------------------------------------------------------------------------
# 颜色与日志
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_BOLD=''
fi
export C_RESET C_RED C_GREEN C_YELLOW C_BLUE C_CYAN C_BOLD

log()  { printf '%s[%s]%s %s\n' "$C_CYAN" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
info() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "$C_RESET"; }
ok()   { printf '    %s[ok]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '    %s[err]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

hr() { printf '%s\n' '---------------------------------------------------------------------------'; }

# ---------------------------------------------------------------------------
# 退出时保持窗口（解决 Windows 上双击 .sh / .bat 时"闪退"看不到错误的问题）
#
#   规则：
#     KRITA_HOLD=0  永不等待（脚本化调用、CI）
#     KRITA_HOLD=1  总是等待
#     未设置(auto)  仅当：Windows(MSYS/Cygwin) 且 stdin 是交互式终端
#   另外：KRITA_HOLD_ALWAYS=1 时，即使成功也等待（便于看结果）
# ---------------------------------------------------------------------------
hold_enabled() {
    case "${KRITA_HOLD:-auto}" in
        0|false|no)  return 1 ;;
        1|true|yes)  return 0 ;;
    esac
    is_windows_shell || return 1
    [[ -t 0 ]] || return 1
    return 0
}

krita_on_exit() {
    local rc="${1:-0}"
    # KRITA_EXIT_SOFT=1 —— 非 0 退出是"正常语义"，不是失败。
    #   report 用 1 表示"需要重新编译/打包"，这是有用的信息而不是错误，
    #   所以不打 "执行失败"，避免污染 --json 的 stderr。
    if (( rc != 0 )) && [[ "${KRITA_EXIT_SOFT:-0}" != "1" ]]; then
        printf '\n' >&2
        err "执行失败（退出码 $rc）"
        printf '        提示: ./build-android.sh check    查看环境问题\n' >&2
        printf '        提示: 完整日志见 logs/latest.log\n' >&2
    fi
    if hold_enabled; then
        if (( rc != 0 )) || [[ "${KRITA_HOLD_ALWAYS:-0}" == "1" ]]; then
            printf '\n  --- 按 Enter 键关闭窗口（设 KRITA_HOLD=0 可关闭此等待）--- ' >&2
            read -r _ || true
        fi
    fi
    return 0
}

install_failure_hold() {
    if [[ -n "${_KRITA_HOLD_INSTALLED:-}" ]]; then
        return 0
    fi
    _KRITA_HOLD_INSTALLED=1
    trap 'krita_on_exit $?' EXIT
    trap 'printf "\n"; exit 130' INT
}

# ---------------------------------------------------------------------------
# 平台探测
# ---------------------------------------------------------------------------
detect_platform() {
    if [[ -n "${KRITA_OS:-}" ]]; then
        return 0
    fi
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo unknown)"
    case "$uname_s" in
        Linux*)               KRITA_OS=linux ;;
        Darwin*)              KRITA_OS=macos ;;
        MINGW*|MSYS*|CYGWIN*) KRITA_OS=windows ;;
        *)                    KRITA_OS=unknown ;;
    esac
    KRITA_SHELL_FLAVOR="$uname_s"
    export KRITA_OS KRITA_SHELL_FLAVOR
}

is_windows_shell() { [[ "${KRITA_OS:-}" == "windows" ]]; }
is_linux()         { [[ "${KRITA_OS:-}" == "linux" ]]; }

# ---------------------------------------------------------------------------
# 定位 Windows 桌面目录（用于把 APK 复制一份到桌面）
#   1) 项目本身就在桌面上：PROJECT_ROOT = <Desktop>/krita_android
#   2) Git Bash：$USERPROFILE/Desktop
#   3) WSL：/mnt/c/Users/<用户>/Desktop
# 找不到时返回非零，调用方应视为"不需要复制"
# ---------------------------------------------------------------------------
windows_desktop_dir() {
    local p="" u="" d=""

    if [[ -n "${PROJECT_ROOT:-}" ]]; then
        p="${PROJECT_ROOT%/*}"
        if [[ "$(basename -- "$p")" =~ ^[Dd]esktop$ && -d "$p" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    fi

    if is_windows_shell; then
        p="${USERPROFILE:-$HOME}/Desktop"
        [[ -d "$p" ]] && { printf '%s\n' "$p"; return 0; }
        return 1
    fi

    if [[ -d /mnt/c/Users ]]; then
        u="$(cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r\n')"
        if [[ -n "$u" && -d "/mnt/c/Users/$u/Desktop" ]]; then
            printf '%s\n' "/mnt/c/Users/$u/Desktop"
            return 0
        fi
        for d in /mnt/c/Users/*/Desktop; do
            [[ -d "$d" ]] && { printf '%s\n' "$d"; return 0; }
        done
    fi

    return 1
}

# ---------------------------------------------------------------------------
# 命令检测
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
    local missing=0 c
    for c in "$@"; do
        if ! have_cmd "$c"; then
            err "缺少必需命令: $c"
            missing=1
        fi
    done
    return "$missing"
}

# ---------------------------------------------------------------------------
# 校验和（用于"增量构建指纹"）
#   优先 sha256sum（Linux/Git Bash），macOS 用 shasum，再退化到 openssl/cksum。
#   输出始终是单行字符串，可直接拼进指纹。
# ---------------------------------------------------------------------------
hash_stdin() {
    if have_cmd sha256sum; then
        sha256sum | awk '{print $1}'
    elif have_cmd shasum; then
        shasum -a 256 | awk '{print $1}'
    elif have_cmd openssl; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        cksum | awk '{print $1"-"$2}'
    fi
}

hash_file() {
    if [[ ! -f "$1" ]]; then
        printf 'missing\n'
        return 0
    fi
    hash_stdin <"$1"
}

# ---------------------------------------------------------------------------
# 增量标记（stamp）读写
#   stamp 文件里只有一行"指纹"；内容一致即认为输入没变，可以跳过重编/重打包。
# ---------------------------------------------------------------------------
stamp_matches() {
    local file="$1" want="$2"
    [[ -n "$file" && -f "$file" ]] || return 1
    [[ "$(cat -- "$file" 2>/dev/null)" == "$want" ]]
}

write_stamp() {
    local file="$1" value="$2"
    [[ -n "$file" ]] || return 0
    mkdir -p -- "$(dirname -- "$file")" 2>/dev/null || true
    printf '%s\n' "$value" >"$file" 2>/dev/null || warn "无法写入增量标记: $file"
}

clear_stamp() {
    local file="$1"
    [[ -n "$file" && -e "$file" ]] && rm -f -- "$file"
    return 0
}

# ---------------------------------------------------------------------------
# 路径处理
# ---------------------------------------------------------------------------
# 在 Git Bash / Cygwin 下做 win<->posix 路径转换；其它平台原样返回
to_posix_path() {
    if have_cmd cygpath; then
        cygpath -u "$1"
    else
        printf '%s\n' "$1"
    fi
}

# 转为 "C:/foo/bar" 形式（Windows 原生程序可以接受）
to_win_path() {
    if have_cmd cygpath; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# 把 Windows 反斜杠路径统一成正斜杠，避免 \a \t 之类被转义
normalize_slashes() {
    printf '%s\n' "${1//\\//}"
}

# 安全地 source 外部生成的脚本（venv 的 activate、KDE 工具生成的 base-env/env 等）
#   * 临时关闭 nounset/errexit：这些文件常引用尚未定义的变量，在 set -u 下会让
#     bash 直接退出（实测报错：base-env: line 1: KDECI_CACHE_PATH: unbound variable）
#   * 失败只返回非零，由调用方决定是否告警
safe_source() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        return 1
    fi

    local had_u=0 had_e=0
    [[ -o nounset ]] && had_u=1
    [[ -o errexit ]] && had_e=1

    set +u
    set +e
    # shellcheck disable=SC1090
    source "$f"
    local rc=$?

    (( had_u )) && set -u
    (( had_e )) && set -e
    return "$rc"
}

# 执行命令并回显（KRITA_DRY_RUN=1 时只打印不执行）
run() {
    printf '    %s$%s %s\n' "$C_CYAN" "$C_RESET" "$*"
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# 文件/解压/下载
# ---------------------------------------------------------------------------
# 在目录中查找可执行文件，兼容 Windows 的 .exe/.bat/.cmd
find_exe() {
    local dir="$1" name="$2" cand
    for cand in "$name" "$name.exe" "$name.bat" "$name.cmd"; do
        if [[ -f "$dir/$cand" ]]; then
            printf '%s\n' "$dir/$cand"
            return 0
        fi
    done
    return 1
}

# 解压 zip：unzip -> bsdtar -> python zipfile
extract_zip() {
    local zip="$1" dest="$2"
    [[ -f "$zip" ]] || die "文件不存在，无法解压: $zip"
    mkdir -p "$dest"
    if have_cmd unzip; then
        run unzip -q -o "$zip" -d "$dest"
    elif tar --version 2>/dev/null | grep -qi bsdtar; then
        run tar -xf "$zip" -C "$dest"
    elif have_cmd python3 || have_cmd python; then
        local py
        if have_cmd python3; then py=python3; else py=python; fi
        run "$py" -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$dest"
    else
        die "无法解压 $zip：请安装 unzip（或确保 tar/python 可用）"
    fi
}

# 下载文件（curl 优先，其次 wget），带临时文件与原子改名
download_file() {
    local url="$1" out="$2"
    if [[ -z "$url" ]]; then
        die "下载地址为空: $out"
    fi
    if [[ "${KRITA_DRY_RUN:-0}" != "1" ]]; then
        mkdir -p "$(dirname -- "$out")"
    fi
    if [[ -s "$out" ]]; then
        if [[ "${KRITA_FORCE_DOWNLOAD:-0}" == "1" ]]; then
            warn "强制重新下载: $out"
            rm -f -- "$out"
        else
            ok "已存在，跳过下载（--force-download 可强制重下）: $out"
            return 0
        fi
    fi
    log "下载: $url"
    if have_cmd curl; then
        run curl -fL --retry 3 --connect-timeout 30 -o "$out.part" "$url"
    elif have_cmd wget; then
        run wget -c -O "$out.part" "$url"
    else
        die "需要 curl 或 wget 才能下载依赖"
    fi
    if [[ "${KRITA_DRY_RUN:-0}" != "1" ]]; then
        mv -f "$out.part" "$out"
    fi
}

# 剩余磁盘空间（单位 GB，取整）
free_space_gb() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        path="$(dirname -- "$path")"
    fi
    df -Pk "$path" 2>/dev/null | awk 'NR==2 { printf "%d", $4/1024/1024 }'
}

# 打印文件/目录体积（若存在）
du_size() {
    local p="$1"
    if [[ -e "$p" ]]; then
        du -sh "$p" 2>/dev/null | awk '{print $1}'
    else
        printf '%s\n' '-'
    fi
}
