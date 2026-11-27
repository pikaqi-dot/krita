#!/usr/bin/env bash
# =============================================================================
#  50-build-package.sh —— 打包 APK / AAB
#
#  对应官方文档 "Building the APK package"：
#    cd $SRCDIR/krita
#    python build-tools/ci-scripts/build-android-package.py
#    # AAB:
#    python build-tools/ci-scripts/build-android-package.py --archive-artifacts
#    python build-tools/ci-scripts/build-android-appbundle.py
#
#  产物目录：$PACKAGING_DIR
#    * 直接产物      : $PACKAGING_DIR/*.apk
#    * 归档产物      : $PACKAGING_DIR/krita_build_apk/
#
#  注意：宿主机流程下 _build / _install 必须位于 Krita 源码树中。
#        build-android-package.py 的目录定位规则是：
#            base = $KDECI_WORKDIR_PATH/krita   （设置了该变量时）
#            base = os.getcwd()                 （未设置时）
#            buildPath = base/_build,  packagingFolder = base/_packaging
#        我们的 _build 在 $KRITA_SRC/_build，所以必须让 base == $KRITA_SRC。
#        早期版本 KDECI_WORKDIR_PATH=$SRCDIR 恰好满足；后来为了不与
#        deps 构建的 scratch 目录撞车改成 $WORKDIR/krita-workdir，
#        结果打包脚本跑去空的 workdir 里找 Makefile，报：
#            gmake: Makefile: No such file or directory
#            ## Failed to build apk
#        因此这里显式校正（unset 该变量 → 用 cwd 定位）。
#
#  用法:
#    ./scripts/50-build-package.sh [--aab] [--force] [--archive-artifacts] [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

WITH_AAB=0
ARCHIVE_ARTIFACTS=0
FORCE=0
# debug | release | nightly（对应官方 --package-type）
PACKAGE_TYPE="debug"

usage() {
    cat <<'EOF'
用法: 50-build-package.sh [选项]

选项:
  --force               忽略增量标记，强制重新打包（默认无变化会跳过 Gradle）
  --aab                 同时生成 AAB（等价于 --archive-artifacts + appbundle）
  --release             打 release 包（gradlew assembleRelease）
  --nightly             打 nightly 包（gradlew assembleNightly）
  --debug               打 debug 包（默认）
  --archive-artifacts   只保留 APK 打包产物到 _packaging/krita_build_apk/
  --dry-run             只将执行的命令打印出来
  -h, --help            显示帮助

关于 --release:
  Krita 的 build.gradle 里没有 signingConfigs，assembleRelease 产出的是
  *-unsigned.apk（官方 CI 也是打包后用 notary 服务补签）。签名请接着执行：
      ./build-android.sh sign

说明:
  默认行为是"智能增量"：若编译输入（源码/ABI/NDK/编译器/工具链/安装前缀）
  与上次成功打包时完全一致，且 _packaging 里已有对应 APK（要 AAB 时也要有 AAB），
  就跳过 Gradle，只做产物导出；复制到 dist/ 与桌面时也会跳过已是最新的副本。
EOF
}

preflight() {
    [[ -d "$KRITA_SRC" ]] || die "未找到 Krita 源码: $KRITA_SRC（执行 ./build-android.sh sources）"
    [[ -f "$KRITA_CI_SCRIPTS_DIR/build-android-package.py" ]] \
        || die "未找到 $KRITA_CI_SCRIPTS_DIR/build-android-package.py（源码不完整？）"

    if [[ ! -d "$KRITA_INSTALL_DIR" ]]; then
        die "未找到安装目录 $KRITA_INSTALL_DIR（请先执行 ./build-android.sh build）"
    fi
    if [[ ! -d "$BUILD_DIR" ]]; then
        die "未找到构建目录 $BUILD_DIR（请先执行 ./build-android.sh build）"
    fi
}

# build-android-package.py 只用 KDECI_WORKDIR_PATH 推导 _build / _packaging 的位置。
# 当它指向的不是 $KRITA_SRC 的父目录时，打包目录会算错 → Makefile 找不到。
prepare_package_workdir() {
    local expected_workdir
    expected_workdir="$(dirname "$KRITA_SRC")"

    if [[ -z "${KDECI_WORKDIR_PATH:-}" ]]; then
        ok "打包脚本用 cwd 定位构建目录: $BUILD_DIR"
        return 0
    fi
    if [[ "$KDECI_WORKDIR_PATH" == "$expected_workdir" ]]; then
        ok "打包脚本用 KDECI_WORKDIR_PATH 定位构建目录: $BUILD_DIR"
        return 0
    fi

    warn "KDECI_WORKDIR_PATH=$KDECI_WORKDIR_PATH → 打包脚本会去 '$KDECI_WORKDIR_PATH/krita/_build' 找产物"
    warn "实际构建目录是 $BUILD_DIR，本次打包改用 cwd 定位（不影响 create-apk 本身）"
    unset KDECI_WORKDIR_PATH
    ok "已校正，打包脚本将使用: $KRITA_SRC/_build"
}

# Gradle 是 Java 程序，**不会**读取 http_proxy/https_proxy 环境变量。
# 在需要代理的环境（Clash fake-IP 等）里必须写 systemProp.*，
# 否则下载 Maven 依赖会报：
#   "The server may not support the client's requested TLS protocol versions"
#   "Remote host terminated the handshake"
prepare_gradle_proxy() {
    local proxy="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
    if [[ -z "$proxy" ]]; then
        ok "未检测到代理环境变量，跳过 Gradle 代理配置"
        return 0
    fi
    proxy="${proxy#*://}"
    proxy="${proxy%/}"
    if [[ "$proxy" != *:* ]]; then
        warn "无法解析代理地址: $proxy"
        return 0
    fi

    local host="${proxy%%:*}" port="${proxy##*:}"
    local dir="$HOME/.gradle"
    local f="$dir/gradle.properties"
    mkdir -p "$dir"

    if grep -q '^# >>> krita-android proxy' "$f" 2>/dev/null; then
        ok "Gradle 代理已配置: $host:$port（$f）"
    else
        {
            printf '\n# >>> krita-android proxy (由 50-build-package.sh 写入)\n'
            printf 'systemProp.http.proxyHost=%s\n'      "$host"
            printf 'systemProp.http.proxyPort=%s\n'      "$port"
            printf 'systemProp.https.proxyHost=%s\n'     "$host"
            printf 'systemProp.https.proxyPort=%s\n'     "$port"
            printf 'systemProp.http.nonProxyHosts=localhost|127.0.0.1\n'
            printf 'systemProp.https.nonProxyHosts=localhost|127.0.0.1\n'
            printf '# <<< krita-android proxy\n'
        } >>"$f"
        ok "已写入 Gradle 代理: $f ($host:$port)"
    fi

    # 双保险：JAVA_TOOL_OPTIONS 会被 Gradle wrapper / androiddeployqt 的 JVM 读取
    export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=$host -Dhttp.proxyPort=$port -Dhttps.proxyHost=$host -Dhttps.proxyPort=$port${JAVA_TOOL_OPTIONS:+ $JAVA_TOOL_OPTIONS}"
    log "JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS"
}

prepare_python() {
    if activate_venv 2>/dev/null; then
        ok "使用 venv Python: $(command -v python)"
    else
        local py
        py="$(python_cmd)" || die "未找到 python（>= 3.10）"
        warn "未找到 venv，直接使用: $py"
    fi
}

build_apk() {
    info "1/2 构建 APK"
    cd "$KRITA_SRC"

    local args=()
    if (( ARCHIVE_ARTIFACTS == 1 )) || (( WITH_AAB == 1 )); then
        args+=(--archive-artifacts)
    fi
    if [[ "$PACKAGE_TYPE" != "debug" ]]; then
        # 官方脚本支持 debug/release/nightly；release 会跑 gradlew assembleRelease
        # （产物名带 -unsigned，因为 build.gradle 里没有 signingConfigs）
        args+=(--package-type "$PACKAGE_TYPE")
    fi

    if ((${#args[@]} > 0)); then
        run python build-tools/ci-scripts/build-android-package.py "${args[@]}"
    else
        run python build-tools/ci-scripts/build-android-package.py
    fi
}

build_aab() {
    info "2/2 构建 AAB"
    cd "$KRITA_SRC"
    run python build-tools/ci-scripts/build-android-appbundle.py
}

# 把 APK/AAB 复制到：
#   1) 项目根目录的 dist/
#   2) Windows 桌面（KRITA_COPY_TO_DESKTOP=1 时，Git Bash / WSL 自动探测）
#   3) KRITA_EXPORT_DIRS 里列出的额外目录（空格分隔）
export_artifacts() {
    local -a targets=("$PROJECT_ROOT/dist")
    local t f n total skipped skipped_all

    if [[ "${KRITA_COPY_TO_DESKTOP:-1}" != "0" ]]; then
        if [[ -n "${KRITA_DESKTOP_DIR:-}" ]]; then
            targets+=("$KRITA_DESKTOP_DIR")
        else
            warn "未探测到 Windows 桌面目录，跳过桌面复制（可用 KRITA_EXPORT_DIRS 指定）"
        fi
    fi
    for t in ${KRITA_EXPORT_DIRS:-}; do
        targets+=("$t")
    done

    local -a files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        files+=("$f")
    done < <(find "$PACKAGING_DIR" -maxdepth 2 -type f \( -name '*.apk' -o -name '*.aab' \) 2>/dev/null)

    if ((${#files[@]} == 0)); then
        warn "没有可复制的产物（$PACKAGING_DIR 下没有 APK/AAB）"
        return 0
    fi

    total=0
    skipped_all=0
    for t in "${targets[@]}"; do
        [[ -n "$t" ]] || continue
        if ! mkdir -p "$t" 2>/dev/null; then
            warn "无法创建目录，跳过: $t"
            continue
        fi
        n=0
        skipped=0
        for f in "${files[@]}"; do
            local dst="$t/$(basename -- "$f")" ssz="" dsz=""
            if [[ -f "$dst" ]]; then
                ssz="$(wc -c <"$f" 2>/dev/null || echo 0)"
                dsz="$(wc -c <"$dst" 2>/dev/null || echo 0)"
                # 大小一致且目标不比源旧 → 当成同一份，跳过（避免每次重拷 180MB）
                if [[ "$ssz" == "$dsz" && ! "$f" -nt "$dst" ]]; then
                    skipped=$((skipped + 1))
                    total=$((total + 1))
                    continue
                fi
            fi
            if cp -f -- "$f" "$t/"; then
                n=$((n + 1))
                total=$((total + 1))
            else
                warn "复制失败: $f -> $t"
            fi
        done
        if (( n > 0 )); then
            ok "已复制 $n 个产物到 $t"
        fi
        if (( skipped > 0 )); then
            ok "已是最新，跳过 $skipped 个副本（$t）"
            skipped_all=$((skipped_all + skipped))
        fi
    done

    if (( total == 0 )); then
        warn "所有目标目录均复制失败"
    elif (( skipped_all > 0 )); then
        log "产物副本无需更新（$skipped_all 个已是最新）"
    fi
}

list_artifacts() {
    hr
    info "产物清单"
    if [[ -d "$PACKAGING_DIR" ]]; then
        local found=0 f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            found=1
            printf '  %-12s %s\n' "$(du_size "$f")" "$f"
        done < <(find "$PACKAGING_DIR" -maxdepth 2 -type f \( -name '*.apk' -o -name '*.aab' \) 2>/dev/null | sort)
        if (( found == 0 )); then
            warn "未在 $PACKAGING_DIR 找到 APK/AAB"
        fi
    else
        die "产物目录不存在: $PACKAGING_DIR"
    fi
    hr
    if [[ -n "${KRITA_DESKTOP_DIR:-}" && "${KRITA_COPY_TO_DESKTOP:-1}" != "0" ]]; then
        printf '  桌面副本  : %s\n' "$KRITA_DESKTOP_DIR"
    fi
    printf '  安装到真机: %sadb install -r dist/<apk>%s\n' "$C_BOLD" "$C_RESET"
    printf '  迭代开发  : %s./build-android.sh dev%s\n' "$C_BOLD" "$C_RESET"
}

main() {
    while (($#)); do
        case "$1" in
            --force|--rebuild)   FORCE=1 ;;
            --aab)               WITH_AAB=1; ARCHIVE_ARTIFACTS=1 ;;
            --release)           PACKAGE_TYPE=release ;;
            --nightly)           PACKAGE_TYPE=nightly ;;
            --debug)             PACKAGE_TYPE=debug ;;
            --archive-artifacts) ARCHIVE_ARTIFACTS=1 ;;
            --dry-run)           KRITA_DRY_RUN=1 ;;
            -h|--help)           usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    hr
    printf '  %s打包 Krita Android 应用（%s）%s\n' "$C_BOLD" "$KDECI_ANDROID_ABI" "$C_RESET"

    preflight
    activate_generated_env
    prepare_package_workdir

    # ---- 增量判定：编译输入没变 + 产物还在 → 跳过 Gradle ----
    local fp=""
    fp="$(krita_package_fingerprint "$WITH_AAB" "$PACKAGE_TYPE")"

    if (( FORCE == 0 )) && stamp_matches "$PACKAGE_STAMP_FILE" "$fp" &&
        package_artifacts_present "$WITH_AAB"; then
        hr
        ok "编译输入与上次打包时一致，且产物已存在 → 跳过 Gradle 打包"
        log "增量指纹: $fp"
        log "强制重打: ./build-android.sh apk --force"
        hr
    else
        if (( FORCE == 1 )); then
            warn "--force：忽略增量标记，强制重新打包"
        fi
        prepare_gradle_proxy
        prepare_python
        build_apk
        if (( WITH_AAB == 1 )); then
            build_aab
        fi
        if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
            warn "--dry-run：不写入增量标记"
        else
            write_stamp "$PACKAGE_STAMP_FILE" "$fp"
            ok "已记录打包增量标记（下次无改动会直接跳过 Gradle）"
        fi
    fi

    export_artifacts
    list_artifacts
}

main "$@"
