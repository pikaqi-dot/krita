#!/usr/bin/env bash
# =============================================================================
#  65-build-linux-deb.sh —— 构建 Linux 桌面版 Krita 并打成 .deb
#
#  与 Android 流水线（00→50）完全独立：
#    * Android 用 NDK 交叉编译、产物是 APK
#    * 这里用系统 gcc/clang + 发行版的 Qt5/KF5，产物是 /usr/bin/krita + .deb
#
#  官方仓库只提供 appimage / flatpak / snap（packaging/linux/ 下没有 deb），
#  所以 deb 是这里自己组装的：
#      cmake configure -> ninja -> DESTDIR install 到 staging
#      -> 生成 DEBIAN/control -> dpkg-deb --build
#
#  用法:
#    ./build-android.sh deb --check-deps          # 只看缺什么
#    ./build-android.sh deb --install-deps        # apt 装齐依赖（需要 sudo）
#    ./build-android.sh deb                       # 编译 + 打包（增量）
#    ./build-android.sh deb --clean --jobs 12     # 从零重编
#
#  Windows 上会被自动转给 WSL（build-android.sh deb -> 99-wsl-build.sh）。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

# ---------------------------------------------------------------------------
# 关键：绝对不能带着 Android 的工具链环境去 configure Linux 构建
#   env.bat / env 里会把 CC/CXX 指向 NDK 的 clang，CMAKE_SYSTEM_NAME 也会是 Android。
#   这里显式清掉，并强制用系统编译器。
# ---------------------------------------------------------------------------
unset CC CXX CPP CFLAGS CXXFLAGS LDFLAGS CPPFLAGS 2>/dev/null || true
unset ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_ROOT ANDROID_NDK_HOME 2>/dev/null || true
unset ANDROID_TOOLCHAIN_ROOT ANDROID_API ANDROID_ABI KDECI_ANDROID_ABI 2>/dev/null || true
unset KDECI_SHARED_INSTALL_PATH CMAKE_TOOLCHAIN_FILE 2>/dev/null || true

LINUX_BUILD_DIR="${KRITA_LINUX_BUILD_DIR:-$KRITA_SRC/_build_linux}"
LINUX_STAMP="$LINUX_BUILD_DIR/.krita-linux-stamp"
# 允许外部指定 staging（--pack-only 重打包、或测试打包逻辑时用）
STAGING="${KRITA_LINUX_STAGING:-$LINUX_BUILD_DIR/staging}"
OUT_DIR="${KRITA_LINUX_DEB_OUT:-$PROJECT_ROOT/dist}"
BUILD_TYPE="${KRITA_LINUX_BUILD_TYPE:-RelWithDebInfo}"
PREFIX="/usr"
JOBS="${KRITA_JOB_COUNT:-$(nproc 2>/dev/null || echo 4)}"
QT6=0
FORCE=0
CLEAN=0
CHECK_ONLY=0
INSTALL_DEPS=0
NO_DEB=0
PACK_ONLY=0
SKIP_OPTIONAL=0
NO_UPDATE=0
VERSION_OVERRIDE=""
PKG_NAME="krita"

usage() {
    cat <<'EOF'
用法: 65-build-linux-deb.sh [选项]

依赖:
  --check-deps       只检查构建依赖，缺什么打印 apt 命令后退出（2=有缺失）
  --install-deps     用 apt-get 装齐构建依赖（需要 sudo；会自动 apt-get update）
  --no-update        配合 --install-deps：跳过 apt-get update
  --skip-optional    配合 --install-deps：不装可选依赖（KSeExpr/MLT/JPEGXL/PyQt5 等）

构建:
  --build-type T     RelWithDebInfo（默认）/ Release / Debug
  --qt6              走 Qt6 路线（-DBUILD_WITH_QT6=ON，需要 KF6 + ECM 6；当前源码是 6.x-prealpha）
  --jobs N           并行任务数（默认 CPU 核数）
  --prefix PATH      安装前缀，写进 deb 的路径（默认 /usr）
  --version V        覆盖包版本（默认从构建产物 kritaversion.h 读，转成 Debian 版本号）
  --force            忽略增量标记，强制重新编译
  --clean            先删掉 _build_linux 再配置（最彻底）
  --no-deb           只编译并安装到 staging，不生成 .deb（调试用）
  --pack-only        跳过配置/编译/安装，只用现有 staging 重新生成 .deb
                     （配合环境变量 KRITA_LINUX_STAGING=/some/staging）
  --out DIR          输出目录（默认 dist/）
  --dry-run          只打印将执行的命令
  -h, --help         显示帮助

说明:
  * 与 Android 流水线互不干扰：Linux 用 <源码>/_build_linux，Android 用 _build
  * 需要发行版的 Qt5 + KF5 开发包（Debian 13 trixie 已实测：qtbase5-dev 5.15.15、
    libkf5* 5.116、libkseexpr-dev 4.0.4）
  * 一次完整编译大约 30~60 分钟（16 核），之后增量很快
EOF
}

# ---------------------------------------------------------------------------
# 依赖清单
#   必需：没有它们 cmake 直接失败
#   可选：Krita 里 find_package 标成 OPTIONAL/RECOMMENDED，缺了只是少功能
# ---------------------------------------------------------------------------
required_packages() {
    cat <<'EOF'
build-essential
cmake
ninja-build
pkg-config
gettext
extra-cmake-modules
qtbase5-dev
qtbase5-dev-tools
qtbase5-private-dev
qtdeclarative5-dev
qtmultimedia5-dev
libqt5svg5-dev
libqt5x11extras5-dev
qttools5-dev
qttools5-dev-tools
libqt5opengl5-dev
libkf5archive-dev
libkf5completion-dev
libkf5config-dev
libkf5configwidgets-dev
libkf5coreaddons-dev
libkf5crash-dev
libkf5filemetadata-dev
libkf5guiaddons-dev
libkf5i18n-dev
libkf5iconthemes-dev
libkf5itemviews-dev
libkf5kdcraw-dev
libkf5kio-dev
libkf5notifications-dev
libkf5widgetsaddons-dev
libkf5windowsystem-dev
libkf5xmlgui-dev
libboost-dev
libeigen3-dev
libexiv2-dev
libfftw3-dev
libgsl-dev
libheif-dev
libimath-dev
libfontconfig1-dev
libfreetype-dev
libfribidi-dev
libgif-dev
libharfbuzz-dev
libjpeg-dev
liblcms2-dev
libopenexr-dev
libopenjp2-7-dev
libpng-dev
libpoppler-qt5-dev
libqca-qt5-2-dev
libquazip5-dev
libraw-dev
libtiff-dev
libunibreak-dev
libwebp-dev
libxsimd-dev
libimmer-dev
libzug-dev
libcurl4-openssl-dev
libgpgme-dev
libgpgmepp-dev
zlib1g-dev
shared-mime-info
EOF
}

optional_packages() {
    cat <<'EOF'
libkseexpr-dev
libmlt-dev
libmlt++-dev
libopencolorio-dev
libjxl-dev
python3-pyqt5
libsdl2-dev
EOF
}

# 去注释/空行，压成一行
packages_flat() {
    local with_optional="${1:-1}"
    {
        required_packages
        (( with_optional == 1 )) && optional_packages
    } | grep -vE '^\s*(#|$)' | tr '\n' ' '
}

# ---------------------------------------------------------------------------
# 依赖检查 / 安装
# ---------------------------------------------------------------------------
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

check_deps() {
    local with_optional=1
    (( SKIP_OPTIONAL == 1 )) && with_optional=0
    local p missing=() ok_count=0
    info "检查 Linux 构建依赖"
    for p in $(packages_flat "$with_optional"); do
        if pkg_installed "$p"; then
            ok_count=$((ok_count + 1))
        else
            missing+=("$p")
        fi
    done
    log "已安装 $ok_count 个，缺失 ${#missing[@]} 个"
    if ((${#missing[@]} == 0)); then
        ok "依赖齐全"
        return 0
    fi
    warn "缺少下列包："
    printf '   %s\n' "${missing[*]}"
    hr
    printf '  一条命令装齐：\n'
    printf '    sudo apt-get update && sudo apt-get install -y \\\n      %s\n' "${missing[*]}"
    printf '  或直接：%s./build-android.sh deb --install-deps%s\n' "$C_BOLD" "$C_RESET"
    hr
    return 2
}

run_sudo() {
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        printf '    %s$ sudo%s %s\n' "$C_CYAN" "$C_RESET" "$*"
        return 0
    fi
    if [[ "$(id -u)" == "0" ]]; then
        "$@"
    elif have_cmd sudo; then
        sudo "$@"
    else
        die "需要 root 权限安装依赖，但没找到 sudo（可用 root 直接运行，或手工安装）"
    fi
}

install_deps() {
    local with_optional=1
    (( SKIP_OPTIONAL == 1 )) && with_optional=0
    have_cmd apt-get || die "只支持 Debian/Ubuntu（需要 apt-get）"
    if (( NO_UPDATE == 0 )); then
        info "apt-get update"
        run_sudo apt-get update
    fi
    info "安装构建依赖（约 1~2 GB）"
    # shellcheck disable=SC2046
    run_sudo apt-get install -y --no-install-recommends $(packages_flat "$with_optional")
    ok "依赖安装完成"
}

# ---------------------------------------------------------------------------
# 增量指纹 / 版本
# ---------------------------------------------------------------------------
linux_fingerprint() {
    local src_head="nogit" src_dirty="nogit" cc="none"
    if have_cmd git && [[ -d "$KRITA_SRC/.git" ]]; then
        src_head="$(git -C "$KRITA_SRC" rev-parse HEAD 2>/dev/null || echo nogit)"
        src_dirty="$(git -C "$KRITA_SRC" status --porcelain --untracked-files=no 2>/dev/null | hash_stdin)"
    fi
    if have_cmd gcc; then
        cc="$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion 2>/dev/null || echo gcc)"
    fi
    printf 'linux1|src=%s|dirty=%s|cc=%s|btype=%s|qt=%s|prefix=%s' \
        "$src_head" "$src_dirty" "$cc" "$BUILD_TYPE" \
        "$([[ $QT6 == 1 ]] && echo 6 || echo 5)" "$PREFIX"
}

linux_artifacts_present() {
    [[ -f "$LINUX_BUILD_DIR/libs/version/kritaversion.h" ]] || return 1
    compgen -G "$LINUX_BUILD_DIR/bin/krita" >/dev/null 2>&1
}

# 从构建产物读版本（configure 之后才有）
detect_version() {
    local h="$LINUX_BUILD_DIR/libs/version/kritaversion.h"
    if [[ -f "$h" ]]; then
        awk -F'"' '/KRITA_VERSION_STRING/ { print $2; exit }' "$h"
        return 0
    fi
    return 1
}

# 5.4.0-prealpha -> 5.4.0~prealpha（~ 让预发布排在正式版之前）
to_debian_version() {
    local v="$1"
    v="${v/-/\~}"
    # Debian 版本号不允许下划线以外的奇怪字符，这里只保留安全集合
    printf '%s' "$(printf '%s' "$v" | tr -c 'A-Za-z0-9.+~' '.' | sed 's/\.*$//')"
}

# ---------------------------------------------------------------------------
# 配置 / 编译 / 安装到 staging
# ---------------------------------------------------------------------------
preflight() {
    [[ -d "$KRITA_SRC" ]] || die "未找到 Krita 源码: $KRITA_SRC（先执行 ./build-android.sh sources）"
    [[ -f "$KRITA_SRC/CMakeLists.txt" ]] || die "源码不完整：$KRITA_SRC/CMakeLists.txt 不存在"
    have_cmd cmake || die "缺少 cmake（./build-android.sh deb --install-deps）"
    if have_cmd ninja; then :; else die "缺少 ninja（./build-android.sh deb --install-deps）"; fi
    if have_cmd gcc && have_cmd g++; then :; else die "缺少 gcc/g++（./build-android.sh deb --install-deps）"; fi
    if (( QT6 == 1 )); then
        warn "Qt6 路线：需要 KF6 + ECM 6；当前源码的 Qt6 分支是 6.x-prealpha（实验性）"
    fi
}

configure_linux() {
    info "1/4 cmake 配置（$BUILD_TYPE，Qt$([[ $QT6 == 1 ]] && echo 6 || echo 5)）"
    if (( CLEAN == 1 )) && [[ -d "$LINUX_BUILD_DIR" ]]; then
        warn "--clean：删除 $LINUX_BUILD_DIR"
        run rm -rf "$LINUX_BUILD_DIR"
    fi
    mkdir -p "$LINUX_BUILD_DIR"

    local -a args=(
        -S "$KRITA_SRC"
        -B "$LINUX_BUILD_DIR"
        -G Ninja
        "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
        "-DCMAKE_INSTALL_PREFIX=$PREFIX"
        -DBUILD_TESTING=OFF
        -DKDE_SKIP_TEST_SETTINGS=ON
        -DKRITA_ENABLE_PCH=OFF
    )
    (( QT6 == 1 )) && args+=(-DBUILD_WITH_QT6=ON)

    log "编译器: $(command -v gcc) / $(command -v g++)"
    run cmake "${args[@]}"
}

build_linux() {
    info "2/4 编译（-j$JOBS，约 30~60 分钟首次）"
    run cmake --build "$LINUX_BUILD_DIR" --parallel "$JOBS"
}

install_staging() {
    info "3/4 安装到 staging（DESTDIR）"
    [[ "${KRITA_DRY_RUN:-0}" == "1" ]] || rm -rf "$STAGING"
    run env DESTDIR="$STAGING" cmake --install "$LINUX_BUILD_DIR"
    if [[ "${KRITA_DRY_RUN:-0}" != "1" ]]; then
        [[ -d "$STAGING/usr" ]] || die "staging 里没有 usr/，安装可能失败了"
        log "staging: $STAGING（$(du_size "$STAGING")）"
    fi
}

# ---------------------------------------------------------------------------
# 依赖计算（写进 DEBIAN/control 的 Depends）
#   1) dpkg-shlibdeps（标准做法，最准）
#   2) ldd + dpkg -S（回退）
#   3) 固定列表（最后兜底）
# ---------------------------------------------------------------------------
FALLBACK_DEPS="libc6, libstdc++6, libqt5core5a, libqt5gui5, libqt5widgets5, libqt5svg5, libkf5coreaddons5, libkf5i18n5, libkf5widgetsaddons5, libkf5completion5, libkf5configcore5, libkf5configgui5, libkf5crash5, libkf5guiaddons5, libkf5itemviews5, libkf5windowsystem5, libkf5xmlgui5, liblcms2-2, libopenexr-3-1-30, libpng16-16t64, libtiff6, libwebp7, libheif1, libraw23, libgsl28, libfftw3-double3, libexiv2-28, libquazip5-1, libqca-qt5-2, libpoppler-qt5-1t64, libcurl4t64, libgpgme11t64, libgpgmepp6t64, libkseexpr4, libmlt7, libmlt++7"

is_elf() {
    [[ -f "$1" ]] || return 1
    [[ "$(head -c 4 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]
}

deps_via_shlibdeps() {
    local work
    work="$(mktemp -d 2>/dev/null || printf '%s/krita-deb-%s' "${TMPDIR:-/tmp}" "$$")"
    mkdir -p "$work/debian"
    {
        printf 'Source: %s\nSection: graphics\nPriority: optional\n\n' "$PKG_NAME"
        printf 'Package: %s\nArchitecture: any\nDepends: ${shlibs:Depends}\nDescription: local build\n local build\n' "$PKG_NAME"
    } >"$work/debian/control"

    local -a eargs=()
    local f
    while IFS= read -r -d '' f; do
        is_elf "$f" && eargs+=(-e"$f")
    done < <(find "$STAGING" -type f -print0 2>/dev/null)
    if ((${#eargs[@]} == 0)); then
        rm -rf "$work"
        return 1
    fi

    local out=""
    out="$(cd "$work" && dpkg-shlibdeps -O "${eargs[@]}" 2>/dev/null |
        sed -n 's/^shlibs:Depends=//p' | head -n 1)" || out=""
    rm -rf "$work"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

deps_via_ldd() {
    local -A pkgs=()
    local f line lib pkg
    local -a scan=()
    [[ -d "$STAGING/usr/bin" ]] && scan+=("$STAGING/usr/bin")
    [[ -d "$STAGING/usr/lib" ]] && scan+=("$STAGING/usr/lib")
    ((${#scan[@]})) || return 1

    while IFS= read -r -d '' f; do
        is_elf "$f" || continue
        while IFS= read -r line; do
            lib="${line##*=> }"
            lib="${lib%% (*}"
            [[ "$lib" == /* ]] || continue
            pkg="$(dpkg -S "$lib" 2>/dev/null | head -n 1 | cut -d: -f1)"
            [[ -n "$pkg" ]] && pkgs["$pkg"]=1
        done < <(ldd -- "$f" 2>/dev/null)
    done < <(find "${scan[@]}" -type f -print0 2>/dev/null)

    ((${#pkgs[@]})) || return 1
    printf '%s' "$(printf '%s\n' "${!pkgs[@]}" | sort | paste -sd, -)"
}

# 注意：本函数是"命令替换"调用的（deps="$(compute_depends)"），
# 所以里面任何提示都必须写 stderr，否则会污染 Depends 字段
# （曾导致 dpkg-deb 报 invalid package name '[00'）。
compute_depends() {
    local deps=""
    deps="$(deps_via_shlibdeps || true)"
    if [[ -n "$deps" ]]; then
        printf '    [info] Depends 来源: dpkg-shlibdeps（自动计算）\n' >&2
        printf '%s' "$deps"
        return 0
    fi
    deps="$(deps_via_ldd || true)"
    if [[ -n "$deps" ]]; then
        warn "dpkg-shlibdeps 不可用，改用 ldd + dpkg -S 计算 Depends"
        printf '%s' "$deps"
        return 0
    fi
    warn "无法自动计算 Depends，使用内置列表（可能需要手工调整）"
    printf '%s' "$FALLBACK_DEPS"
}

# ---------------------------------------------------------------------------
# 组装 .deb
# ---------------------------------------------------------------------------
make_deb() {
    info "4/4 生成 .deb"
    local ver_raw ver arch size_kb deps deb
    ver_raw="${VERSION_OVERRIDE:-$(detect_version || true)}"
    if [[ -z "$ver_raw" ]]; then
        if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
            ver_raw="0.0.0-dryrun"
            warn "dry-run：读不到 kritaversion.h，用占位版本 $ver_raw"
        else
            die "无法确定版本（可加 --version 5.4.0，或先完成一次编译）"
        fi
    fi
    ver="$(to_debian_version "$ver_raw")"
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    size_kb="$(du -sk --exclude=DEBIAN "$STAGING" 2>/dev/null | awk '{print $1}')"
    deps="$(compute_depends)"
    deb="$OUT_DIR/${PKG_NAME}_${ver}_${arch}.deb"

    log "版本: $ver_raw -> $ver"
    log "架构: $arch"
    log "体积: ${size_kb:-?} KB（未压缩）"
    log "输出: $deb"

    mkdir -p "$STAGING/DEBIAN" "$OUT_DIR"
    {
        printf 'Package: %s\n' "$PKG_NAME"
        printf 'Version: %s\n' "$ver"
        printf 'Architecture: %s\n' "$arch"
        printf 'Maintainer: Krita Build Scripts <noreply@localhost>\n'
        printf 'Installed-Size: %s\n' "${size_kb:-0}"
        printf 'Section: graphics\n'
        printf 'Priority: optional\n'
        printf 'Depends: %s\n' "$deps"
        printf 'Description: Krita digital painting application (locally built)\n'
        printf ' Krita is a professional free and open source painting program.\n'
        printf ' .\n'
        printf ' This package was built locally by the krita_android build scripts\n'
        printf ' (Linux deb target); it is not an official distribution package.\n'
    } >"$STAGING/DEBIAN/control"

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        warn "dry-run：不生成 $deb"
        return 0
    fi

    # 让文件属主统一成 root:root（dpkg-deb 10+ 支持 --root-owner-group）
    if ! run dpkg-deb --build --root-owner-group "$STAGING" "$deb" 2>/dev/null; then
        warn "--root-owner-group 不可用，改用 fakeroot/dpkg-deb 普通模式"
        if have_cmd fakeroot; then
            run fakeroot dpkg-deb --build "$STAGING" "$deb"
        else
            run dpkg-deb --build "$STAGING" "$deb"
        fi
    fi

    [[ -f "$deb" ]] || die "dpkg-deb 没有生成 $deb"
    ok "已生成: $deb（$(du_size "$deb")）"
    hr
    printf '  安装:\n    sudo apt install %s\n' "$(native_path "$deb" 2>/dev/null || printf '%s' "$deb")"
    printf '  看包信息:\n    dpkg-deb -I %s\n' "$deb"
    printf '  列文件:\n    dpkg-deb -c %s | head\n' "$deb"
    hr
    printf '  %s\n' "--- control ---"
    sed 's/^/  /' "$STAGING/DEBIAN/control"
    hr
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    while (($#)); do
        case "$1" in
            --check-deps)     CHECK_ONLY=1 ;;
            --install-deps|--deps-only) INSTALL_DEPS=1 ;;
            --no-update)      NO_UPDATE=1 ;;
            --skip-optional)  SKIP_OPTIONAL=1 ;;
            --build-type|--build_type)
                shift; [[ $# -gt 0 ]] || die "--build-type 需要一个值"
                BUILD_TYPE="$1" ;;
            --qt6)            QT6=1 ;;
            --jobs)
                shift; [[ $# -gt 0 ]] || die "--jobs 需要一个数值"
                JOBS="$1" ;;
            --prefix)
                shift; [[ $# -gt 0 ]] || die "--prefix 需要一个路径"
                PREFIX="$1" ;;
            --version)
                shift; [[ $# -gt 0 ]] || die "--version 需要一个版本号"
                VERSION_OVERRIDE="$1" ;;
            --force)          FORCE=1 ;;
            --clean)          CLEAN=1 ;;
            --no-deb)         NO_DEB=1 ;;
            --pack-only)      PACK_ONLY=1 ;;
            --out)
                shift; [[ $# -gt 0 ]] || die "--out 需要目录"
                OUT_DIR="$1" ;;
            --dry-run)        KRITA_DRY_RUN=1 ;;
            -h|--help)        usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    [[ "$PREFIX" == /* ]] || die "--prefix 必须是绝对路径（如 /usr 或 /usr/local）"

    hr
    printf '  %s构建 Linux 桌面版 Krita -> .deb%s\n' "$C_BOLD" "$C_RESET"
    log "源码      : $KRITA_SRC"
    log "构建目录  : $LINUX_BUILD_DIR"
    log "前缀      : $PREFIX"
    log "构建类型  : $BUILD_TYPE（Qt$([[ $QT6 == 1 ]] && echo 6 || echo 5)）"

    if (( CHECK_ONLY == 1 )); then
        check_deps
        return $?
    fi
    if (( INSTALL_DEPS == 1 )); then
        install_deps
        # 装完顺手复查一次
        check_deps || warn "仍有包未装好，请检查 apt 输出"
        return 0
    fi

    local fp
    fp="$(linux_fingerprint)"

    if (( PACK_ONLY == 1 )); then
        warn "--pack-only：跳过配置/编译/安装，直接用 staging 打包"
        log "staging: $STAGING"
        [[ -d "$STAGING/usr" ]] || die "staging 里没有 usr/：$STAGING（先跑一次完整构建，或用 KRITA_LINUX_STAGING 指定）"
    else
        preflight
        if (( FORCE == 0 && CLEAN == 0 )) && stamp_matches "$LINUX_STAMP" "$fp" && linux_artifacts_present; then
            hr
            ok "源码与配置没变，且 krita 已编译 → 跳过编译"
            log "增量指纹: $fp"
            log "强制重编: ./build-android.sh deb --force"
            hr
        else
            if (( FORCE == 1 )); then
                warn "--force：忽略增量标记"
            fi
            configure_linux
            build_linux
        fi

        install_staging
    fi

    if (( NO_DEB == 1 )); then
        warn "--no-deb：只装了 staging，没有生成 .deb"
        return 0
    fi

    make_deb

    # --pack-only 只重打包，不代表编译产物是最新的，因此不写增量标记
    if [[ "${KRITA_DRY_RUN:-0}" != "1" ]] && (( PACK_ONLY == 0 )); then
        write_stamp "$LINUX_STAMP" "$fp"
        ok "已记录增量标记（下次无改动会跳过编译）"
    fi
}

main "$@"
