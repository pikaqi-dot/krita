#!/usr/bin/env bash
# =============================================================================
#  wsl.sh —— WSL2 相关公共逻辑（供 94/95/99 使用）
#
#  用法：
#      source "<repo>/scripts/lib/android-env.sh"
#      load_config
#      source "<repo>/scripts/lib/wsl.sh"
#
#  重要经验（踩过的坑）：
#    * 从 Git Bash 调用 wsl.exe 时，命令行**含引号会被丢弃**，导致
#      `export PATH=$JAVA_HOME/bin:$PATH` 之类被提前展开、文件写坏。
#      因此凡是有引号 / 变量的操作，一律走 wsl_run_script：
#      先把脚本写到 logs/ 下，再让发行版里的 bash 执行这个文件。
#    * 所有 wsl.exe 调用都带 WSL_UTF8=1，避免 UTF-16 乱码。
#    * 直接以 argv 形式传参（不拼接字符串），因此项目路径不要含空格。
# =============================================================================

if [[ -n "${_KRITA_WSL_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_KRITA_WSL_LOADED=1

# 基础工具链（apt）与 JDK 说明
#  * gettext-base：envsubst/gettext，git submodule 需要（否则 envsubst: not found）
#  * gettext：msgfmt/msgcat 等，KF5I18n 的 pofiles 目标需要（否则
#    "failed generating /path/to/po"）
#  * ccache：run-ci-build.py 在 use-ccache 时会执行 `ccache -M 20G`，缺它直接报
#    CalledProcessError: 'ccache -M 20G' returned non-zero exit status 127
WSL_APT_PACKAGES="build-essential cmake ninja-build pkgconf git curl unzip gettext-base gettext ccache python3 python3-pip python3-venv"
WSL_JDK_APT="openjdk-17-jdk"
WSL_TEMURIN_DIR="/opt/jdk17"
WSL_TEMURIN_URL="https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"

DISTRO="${DISTRO:-}"
WSL_ROOT="${WSL_ROOT:-}"

# 由 wsl_analyze_probe 填充
MISSING_LIST=()
CRITICAL_LIST=()
JAVAC_MAJOR=""
VENV_STATE=""
PIP_STATE=""
PROJECT_STATE=""

# ---------------------------------------------------------------------------
# 调用封装
# ---------------------------------------------------------------------------
wsl_exe() {
    WSL_UTF8=1 MSYS_NO_PATHCONV=1 wsl.exe "$@"
}

# 以普通用户执行（argv 直接传递，不做字符串拼接）
wsl_inner() {
    WSL_UTF8=1 MSYS_NO_PATHCONV=1 wsl.exe -d "$DISTRO" -- "$@"
}

# 以 root 执行
wsl_root() {
    WSL_UTF8=1 MSYS_NO_PATHCONV=1 wsl.exe -u root -d "$DISTRO" -- "$@"
}

list_distros() {
    local raw=""
    raw="$(WSL_UTF8=1 wsl.exe -l -q 2>&1 | tr -d '\000\r')" || true
    printf '%s\n' "$raw" | awk 'NF { print }'
}

get_field() {
    printf '%s\n' "$1" | awk -v k="$2" -F= '$1 == k { sub("^" k "=", ""); print; exit }'
}

# ---------------------------------------------------------------------------
# 生成脚本并执行（解决引号丢失问题）
#   wsl_run_script [--root] <文件名> [参数...]   <<'EOS' ... EOS
# ---------------------------------------------------------------------------
wsl_run_script() {
    local as_root=0
    if [[ "${1:-}" == "--root" ]]; then
        as_root=1
        shift
    fi
    local name="$1"
    shift

    local dir="$PROJECT_ROOT/logs"
    local file="$dir/$name"
    mkdir -p "$dir"
    cat >"$file"

    wsl_ensure_root
    local target="$WSL_ROOT/logs/$name"

    if (( as_root == 1 )); then
        wsl_root bash "$target" "$@" 2>&1 | tr -d '\r'
    else
        wsl_inner bash "$target" "$@" 2>&1 | tr -d '\r'
    fi
}

wsl_ensure_root() {
    if [[ -z "$WSL_ROOT" ]]; then
        WSL_ROOT="$(wsl_project_path)"
    fi
}

# 在发行版内运行项目里的某个脚本（构建流水线入口）
#   $1 = 项目在 WSL 中的路径, $2 = 要执行的脚本（相对路径）, 其余为参数
#   参数以独立 argv 传递，完全避免拼字符串 / 引号丢失问题
wsl_run_pipeline() {
    local root="$1"
    local script="$2"
    shift 2
    wsl_run_script wsl-run-pipeline.sh "$root" "$script" "$@" <<'EOS'
set -e
root="$1"; shift
script="$1"; shift
cd "$root"

# 非登录 shell 不会加载 /etc/profile.d/*，这里显式载入 wsl-install / wsl-network
# 写入的 JDK 与代理配置（sdkmanager 等 Java 程序也依赖这些环境变量）
for f in /etc/profile.d/jdk17.sh /etc/profile.d/99-krita-proxy.sh; do
  if [ -r "$f" ]; then . "$f"; fi
done

exec bash "$script" "$@"
EOS
}

# ---------------------------------------------------------------------------
# 发行版解析
# ---------------------------------------------------------------------------
resolve_distro() {
    if ! have_cmd wsl.exe; then
        die "未找到 wsl.exe：请先安装 WSL2（管理员 PowerShell 执行 wsl --install -d Debian）"
    fi
    if [[ -z "$DISTRO" ]]; then
        DISTRO="${WSL_DISTRO:-}"
    fi
    if [[ -z "$DISTRO" ]]; then
        DISTRO="$(list_distros | head -n 1)"
    fi
    if [[ -z "$DISTRO" ]]; then
        printf '  已安装的发行版列表（可能为空）:\n' >&2
        list_distros >&2 || true
        die "未检测到已安装的 WSL 发行版，请执行: wsl --install -d Debian"
    fi
    if ! list_distros | grep -qx "$DISTRO"; then
        warn "发行版 '$DISTRO' 不在已安装列表中，实际列表："
        list_distros >&2 || true
    fi
    export DISTRO
    ok "使用 WSL 发行版: $DISTRO"
}

wsl_project_path() {
    local p=""
    p="$(wsl_exe -d "$DISTRO" -- wslpath -a -u "$(to_win_path "$PROJECT_ROOT")" 2>/dev/null | tr -d '\r')" || true
    if [[ -z "$p" ]]; then
        die "无法把 $PROJECT_ROOT 转换为 WSL 路径（wslpath 失败）"
    fi
    printf '%s\n' "$p"
}

check_config_paths() {
    local cfg
    cfg="$(config_file)"
    [[ -f "$cfg" ]] || return 0
    if grep -qE '^[A-Za-z_]+="?[A-Za-z]:/' "$cfg"; then
        warn "配置文件 $cfg 中存在 Windows 盘符路径（如 C:/...）"
        warn "WSL2 中这些路径不可用，请改成 Linux 路径，例如 /home/<用户名>/android"
        warn "（在 WSL 中访问 Windows 盘为 /mnt/c/...）"
    fi
}

# ---------------------------------------------------------------------------
# 发行版工具链探测
# ---------------------------------------------------------------------------
WSL_INNER_PROBE='set +e
[ -r /etc/os-release ] && . /etc/os-release
printf "OS=%s\n" "${PRETTY_NAME:-unknown}"
printf "KERNEL=%s\n" "$(uname -srm)"
printf "HOME=%s\n" "$HOME"
printf "CPUS=%s\n" "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
if [ -d "$1" ]; then printf "PROJECT=OK\n"; else printf "PROJECT=MISSING\n"; fi
for t in git curl unzip envsubst cmake make ninja gcc g++ pkg-config python3 java javac; do
  if command -v "$t" >/dev/null 2>&1; then
    if [ "$t" = "unzip" ]; then
      v="$(unzip -v 2>&1 | head -n 1)"
    else
      v="$("$t" --version 2>&1 | head -n 1)"
    fi
    printf "TOOL:%s=OK:%s\n" "$t" "$v"
  else
    printf "TOOL:%s=MISSING\n" "$t"
  fi
done
if command -v javac >/dev/null 2>&1; then
  vj="$(javac -version 2>&1 | head -n 1)"
  vj="${vj##* }"
  case "$vj" in 1.*) vj="${vj#1.}" ;; esac
  printf "JAVAC_MAJOR=%s\n" "${vj%%.*}"
fi
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import venv" >/dev/null 2>&1 && printf "VENV=OK\n" || printf "VENV=MISSING\n"
  printf "PIP=%s\n" "$(python3 -m pip --version 2>/dev/null | head -n 1)"
fi
printf "SUDO=%s\n" "$(command -v sudo >/dev/null 2>&1 && echo OK || echo MISSING)"
exit 0'

wsl_probe_distro() {
    local wsl_root="$1"
    local probe_dir="$PROJECT_ROOT/logs"
    local probe_file="$probe_dir/wsl-probe.sh"
    mkdir -p "$probe_dir"
    printf '%s\n' "$WSL_INNER_PROBE" >"$probe_file"
    wsl_inner bash "$wsl_root/logs/wsl-probe.sh" "$wsl_root" 2>&1 | tr -d '\r'
}

wsl_analyze_probe() {
    local out="$1"
    local line rest name val n

    MISSING_LIST=()
    CRITICAL_LIST=()
    JAVAC_MAJOR="$(get_field "$out" JAVAC_MAJOR)"
    VENV_STATE="$(get_field "$out" VENV)"
    PIP_STATE="$(get_field "$out" PIP)"
    PROJECT_STATE="$(get_field "$out" PROJECT)"

    printf '    %-11s : %s\n' "distro" "$(get_field "$out" OS)"
    printf '    %-11s : %s\n' "kernel" "$(get_field "$out" KERNEL)"
    printf '    %-11s : %s\n' "home" "$(get_field "$out" HOME)"
    printf '    %-11s : %s\n' "cpus" "$(get_field "$out" CPUS)"

    while IFS= read -r line; do
        case "$line" in
            TOOL:*)
                rest="${line#TOOL:}"
                name="${rest%%=*}"
                val="${rest#*=}"
                if [[ "$val" == "MISSING" ]]; then
                    printf '    %-11s : %s缺失%s\n' "$name" "$C_RED" "$C_RESET"
                    MISSING_LIST+=("$name")
                else
                    printf '    %-11s : %s\n' "$name" "${val#OK:}"
                fi
                ;;
        esac
    done <<<"$out"

    if [[ -n "$PIP_STATE" ]]; then
        printf '    %-11s : %s\n' "pip" "$PIP_STATE"
    fi
    if [[ -n "$JAVAC_MAJOR" ]]; then
        printf '    %-11s : %s\n' "javac" "$JAVAC_MAJOR"
    fi

    for n in ${MISSING_LIST[@]+"${MISSING_LIST[@]}"}; do
        case "$n" in
            git|curl|cmake|g++|gcc|python3|java|javac|unzip|pkg-config|envsubst)
                CRITICAL_LIST+=("$n")
                ;;
            make)
                if printf '%s\n' "$out" | grep -q '^TOOL:ninja=OK'; then
                    warn "发行版内缺少 make，但有 ninja（CMake 会用 Ninja 生成器）"
                else
                    CRITICAL_LIST+=("$n")
                fi
                ;;
        esac
    done

    if [[ -n "$JAVAC_MAJOR" && "$JAVAC_MAJOR" != "17" ]]; then
        warn "发行版内 javac 主版本为 $JAVAC_MAJOR，官方要求精确的 17"
        CRITICAL_LIST+=("openjdk-17-jdk / Temurin 17")
    fi
    if [[ "$VENV_STATE" == "MISSING" ]]; then
        warn "发行版内 python3-venv 不可用（python3 -c 'import venv' 失败）"
        CRITICAL_LIST+=("python3-venv")
    fi
    if [[ "$PROJECT_STATE" == "MISSING" ]]; then
        die "发行版内看不到项目目录（/mnt/c 挂载异常）"
    fi
}

wsl_print_apt_hint() {
    printf '\n  请在 WSL 中执行以下命令补齐依赖（或在 Windows 上运行 ./build-android.sh wsl-install）：\n\n'
    printf '    wsl -d %s\n' "$DISTRO"
    printf '    sudo apt update\n'
    printf '    sudo apt install -y %s %s\n\n' "$WSL_APT_PACKAGES" "$WSL_JDK_APT"
    printf '  说明：Debian 13 (trixie) 等新发行版仓库里没有 %s，\n' "$WSL_JDK_APT"
    printf '        ./build-android.sh wsl-install 会自动改用 Adoptium Temurin 17。\n'
    if ((${#CRITICAL_LIST[@]} > 0)); then
        printf '\n  当前判定缺失/不合规: %s%s%s\n' "$C_YELLOW" "${CRITICAL_LIST[*]}" "$C_RESET"
    fi
}

wsl_prepare() {
    resolve_distro
    check_config_paths
    WSL_ROOT="$(wsl_project_path)"
    ok "项目路径映射: $PROJECT_ROOT  ->  $WSL_ROOT"
    export WSL_ROOT
    WSL_PROBE_OUT="$(wsl_probe_distro "$WSL_ROOT")"
}

# ---------------------------------------------------------------------------
# 安装动作（全部经生成脚本执行，避免引号问题）
# ---------------------------------------------------------------------------
# 只安装（不 update）；包名以独立 argv 传入
wsl_apt_install_pkgs() {
    # shellcheck disable=SC2086
    wsl_run_script --root wsl-apt-install.sh $* <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y "$@"
EOS
}

# apt-get update + 安装
wsl_apt_install() {
    local pkgs="$1"
    wsl_run_script --root wsl-apt-update.sh <<'EOS' || return 1
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
EOS
    # shellcheck disable=SC2086
    wsl_apt_install_pkgs $pkgs
}

# 安装 Temurin 17 到 $WSL_TEMURIN_DIR，并让全系统可用
wsl_install_jdk_temurin() {
    local url="$WSL_TEMURIN_URL" dir="$WSL_TEMURIN_DIR"

    info "下载 Temurin 17（约 190MB，需联网）"
    if ! wsl_run_script --root wsl-jdk-download.sh "$url" <<'EOS'
set -e
if [ -s /tmp/jdk17.tar.gz ] && tar -tzf /tmp/jdk17.tar.gz >/dev/null 2>&1; then
  echo "reuse cached /tmp/jdk17.tar.gz ($(stat -c %s /tmp/jdk17.tar.gz) bytes)"
else
  curl -fL --retry 3 --connect-timeout 30 -o /tmp/jdk17.tar.gz "$1"
  tar -tzf /tmp/jdk17.tar.gz >/dev/null
  echo "downloaded: $(stat -c %s /tmp/jdk17.tar.gz) bytes"
fi
EOS
    then
        return 1
    fi

    info "解压并配置 JDK 17"
    if ! wsl_run_script --root wsl-jdk-install.sh "$dir" <<'EOS'
set -e
dir="$1"
rm -rf "$dir"
mkdir -p "$dir"
tar -xzf /tmp/jdk17.tar.gz -C "$dir" --strip-components=1

# 登录 shell 通过 profile.d 生效
cat > /etc/profile.d/jdk17.sh <<EOF
export JAVA_HOME=$dir
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
chmod 0644 /etc/profile.d/jdk17.sh

# 非登录 shell 通过 /usr/local/bin 软链接生效（优先级高于 /usr/bin）
for b in java javac jar jlink jcmd; do
  if [ -x "$dir/bin/$b" ]; then
    ln -sf "$dir/bin/$b" /usr/local/bin/"$b"
  fi
done

"$dir/bin/javac" --version
EOS
    then
        return 1
    fi
    ok "Temurin 17 已安装到 $dir（/etc/profile.d/jdk17.sh + /usr/local/bin 软链接）"
    return 0
}

# apt 装上了 17 但系统默认 javac 仍指向别的版本时，切换 alternatives
wsl_fix_java_alternatives() {
    [[ "${JAVAC_MAJOR:-}" == "17" ]] && return 0
    wsl_run_script --root wsl-java-alternatives.sh <<'EOS' >/dev/null 2>&1 || true
set +e
jdk=/usr/lib/jvm/java-17-openjdk-amd64
if [ -x "$jdk/bin/javac" ]; then
  update-alternatives --set javac "$jdk/bin/javac"
  update-alternatives --set java "$jdk/bin/java"
fi
exit 0
EOS
}

# ---------------------------------------------------------------------------
# 网络：代理 / 镜像网络
# ---------------------------------------------------------------------------
win_system_proxy() {
    local raw=""
    if have_cmd reg.exe; then
        raw="$(MSYS_NO_PATHCONV=1 reg.exe query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyServer 2>/dev/null | tr -d '\r' | awk '/ProxyServer/ { print $3; exit }')" || true
    fi
    [[ -z "$raw" ]] && return 0
    if [[ "$raw" == *"="* ]]; then
        raw="$(printf '%s' "$raw" | tr ';' '\n' | awk -F= '/^https?=/ { print $2; exit }')"
    fi
    printf '%s\n' "$raw"
}

wsl_host_ip() {
    wsl_run_script wsl-hostip.sh <<'EOS' 2>/dev/null | awk -F= '/^HOSTIP=/ { sub(/^HOSTIP=/, ""); print; exit }'
set +e
ip route show default 2>/dev/null | awk '/^default/ { print "HOSTIP=" $3; exit }'
exit 0
EOS
}

wsl_net_check() {
    local proxy="${1:-}"
    wsl_run_script wsl-netcheck.sh "$proxy" <<'EOS'
set +e
p=""
[ -n "$1" ] && p="-x http://$1"
for u in https://deb.debian.org https://security.debian.org https://invent.kde.org https://api.adoptium.net; do
  code="$(curl -sS -m 12 $p -o /dev/null -w "%{http_code}" "$u" 2>/dev/null)"
  case "${code:-000}" in
    2*|3*|403) printf "NET:%s=OK:%s\n" "$u" "$code" ;;
    *)         printf "NET:%s=FAIL:%s\n" "$u" "${code:-timeout}" ;;
  esac
done
exit 0
EOS
}

wsl_net_ok() {
    local out
    out="$(wsl_net_check "${1:-}")"
    printf '%s\n' "$out" | grep -q '=FAIL' && return 1
    printf '%s\n' "$out" | grep -q '=OK' || return 1
    return 0
}

wsl_proxy_ok() {
    wsl_net_ok "$1"
}

wsl_net_report() {
    local proxy="${1:-}" out line url state code
    out="$(wsl_net_check "$proxy")"
    while IFS= read -r line; do
        case "$line" in
            NET:*)
                url="${line#NET:}"
                state="${url#*=}"
                url="${url%%=*}"
                code="${line##*:}"
                if [[ "$state" == OK:* ]]; then
                    printf '    %-32s %sOK%s (%s)\n' "$url" "$C_GREEN" "$C_RESET" "$code"
                else
                    printf '    %-32s %sFAIL%s (%s)\n' "$url" "$C_RED" "$C_RESET" "$code"
                fi
                ;;
        esac
    done <<<"$out"
    printf '%s\n' "$out" | grep -q '=FAIL' && return 1
    printf '%s\n' "$out" | grep -q '=OK' || return 1
    return 0
}

wsl_networking_mode() {
    local cfg="$HOME/.wslconfig"
    if [[ -f "$cfg" ]] && ! grep -qU $'\000' "$cfg" 2>/dev/null; then
        awk -F= 'tolower($1) ~ /networkingmode/ { gsub(/[ \t\r]/, "", $2); print $2; exit }' "$cfg"
    fi
}

# 在发行版内写入 apt 代理与 shell 代理（root）
wsl_write_proxy_config() {
    local proxy="$1" hostip="${2:-}"
    local noproxy="localhost,127.0.0.1,::1"
    [[ -n "$hostip" ]] && noproxy="$noproxy,$hostip"

    wsl_run_script --root wsl-proxy-apt.sh "$proxy" <<'EOS' >/dev/null
set -e
printf 'Acquire::http::Proxy "http://%s";\nAcquire::https::Proxy "http://%s";\n' "$1" "$1" \
    > /etc/apt/apt.conf.d/99-krita-proxy
EOS

    wsl_run_script --root wsl-proxy-env.sh "$proxy" "$noproxy" <<'EOS' >/dev/null
set -e
cat > /etc/profile.d/99-krita-proxy.sh <<EOF
export http_proxy=http://$1
export https_proxy=http://$1
export all_proxy=http://$1
export HTTP_PROXY=http://$1
export HTTPS_PROXY=http://$1
export ALL_PROXY=http://$1
export no_proxy=$2
export NO_PROXY=$2
EOF
chmod 0644 /etc/profile.d/99-krita-proxy.sh
EOS

    ok "已写入 /etc/apt/apt.conf.d/99-krita-proxy 与 /etc/profile.d/99-krita-proxy.sh"
}

wsl_enable_mirrored() {
    local cfg="$HOME/.wslconfig"
    if grep -qiE '^[[:space:]]*networkingMode[[:space:]]*=' "$cfg" 2>/dev/null; then
        warn ".wslconfig 已包含 networkingMode（未修改）: $cfg"
        return 1
    fi
    if [[ -f "$cfg" ]]; then
        if grep -qi '^\[wsl2\]' "$cfg"; then
            awk '/^\[wsl2\]/ && !done { print; print "networkingMode=mirrored"; done=1; next } { print }' "$cfg" >"$cfg.new" &&
                mv -f "$cfg.new" "$cfg"
        else
            printf '\n[wsl2]\nnetworkingMode=mirrored\n' >>"$cfg"
        fi
    else
        printf '[wsl2]\nnetworkingMode=mirrored\n' >"$cfg"
    fi
    ok "已写入 $cfg（networkingMode=mirrored）"
    return 0
}

wsl_ensure_network() {
    local mode proxy hostip ptest pport

    info "网络检查"
    if wsl_net_ok; then
        ok "发行版可访问全部所需站点"
        return 0
    fi

    warn "发行版无法访问部分所需站点（apt / git 会超时）"
    wsl_net_report || true

    mode="$(wsl_networking_mode)"
    proxy="$(win_system_proxy)"
    hostip="$(wsl_host_ip)"
    log "networkingMode : ${mode:-未设置（NAT 模式）}"
    log "宿主机 IP      : ${hostip:-未知}"
    log "Windows 代理   : ${proxy:-未检测到}"

    # 1) 代理可达 -> 在发行版内配置代理（不改动 Windows 配置）
    if [[ -n "$proxy" ]]; then
        pport="${proxy##*:}"
        ptest="$proxy"
        if [[ "$proxy" == 127.0.0.1:* || "$proxy" == localhost:* ]]; then
            if [[ -n "$hostip" ]]; then
                ptest="$hostip:$pport"
            fi
        fi
        if [[ -n "$hostip" ]] && wsl_proxy_ok "$ptest"; then
            ok "检测到宿主机代理可用: $ptest"
            wsl_write_proxy_config "$ptest" "$hostip"
            if wsl_net_ok; then
                ok "代理配置生效"
                return 0
            fi
            warn "写入代理后仍有站点不可达"
        else
            warn "代理 $ptest 在发行版内不可达（代理软件多半未开启 Allow LAN / 允许局域网）"
        fi
    fi

    # 2) 退回镜像网络模式
    if [[ "$mode" != "mirrored" ]]; then
        warn "尝试改用镜像网络模式（.wslconfig: networkingMode=mirrored）"
        if wsl_enable_mirrored; then
            log "执行 wsl --shutdown 使其生效（会重启所有发行版）"
            WSL_UTF8=1 MSYS_NO_PATHCONV=1 wsl.exe --shutdown || true
            sleep 3
            if wsl_net_ok; then
                ok "镜像网络模式生效，发行版已可访问所需站点"
                return 0
            fi
            warn "镜像网络模式下仍有站点不可达"
            wsl_net_report || true
        fi
    fi

    return 1
}

wsl_print_network_hint() {
    local proxy="$1" hostip="$2"
    hr
    printf '  WSL 网络仍不可用。请在下面三条里选一条处理：\n\n'
    printf '  A) 打开代理软件的“允许局域网连接 / Allow LAN”，然后让脚本写入代理：\n'
    printf '       ./build-android.sh wsl-network --proxy %s\n\n' "${proxy:-<主机IP:端口>}"
    printf '  B) 启用镜像网络（WSL2 官方推荐，需 Windows 11 22H2+）：\n'
    printf '       在 %s 中写入 [wsl2] / networkingMode=mirrored，然后 wsl --shutdown\n' "$HOME/.wslconfig"
    printf '       也可以直接执行: ./build-android.sh wsl-network --mirrored\n\n'
    printf '  C) 手工在发行版内配置代理：\n'
    printf '       ./build-android.sh wsl-network --proxy %s\n\n' "${hostip:-<主机IP>}:${proxy##*:}"
    printf '  参考: 宿主机 IP=%s，Windows 代理=%s\n' "${hostip:-未知}" "${proxy:-未检测到}"
    hr
}
