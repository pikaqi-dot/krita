#!/usr/bin/env bash
# =============================================================================
#  70-dev-rebuild.sh —— 修改代码后迭代重建 + 安装 + 启动
#
#  对应官方文档 "Iteratively rebuild Krita and its package after making changes"：
#
#    export ANDROID_ABI=$KDECI_ANDROID_ABI
#    export KRITA_INSTALL_PREFIX=$KDECI_SHARED_INSTALL_PATH
#    cd $SRCDIR/krita/_build/krita_build_apk
#    make -j8 install -C .. && ./gradlew installDebug && \
#        adb shell am start -n "org.krita.debug/org.krita.android.MainActivity"
#
#  用法:
#    ./scripts/70-dev-rebuild.sh [--jobs N] [--task installDebug]
#                                [--skip-build] [--skip-gradle] [--skip-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

SKIP_BUILD=0
SKIP_GRADLE=0
SKIP_RUN=0
GRADLE_TASK="$KRITA_GRADLE_TASK"
ANDROID_APK_DIR="$BUILD_DIR/krita_build_apk"

usage() {
    cat <<'EOF'
用法: 70-dev-rebuild.sh [选项]

选项:
  --jobs N         并行编译任务数
  --task NAME      Gradle 任务（默认 installDebug）
  --skip-build     跳过 native 重新编译与 install
  --skip-gradle    跳过 gradle 打包/安装
  --skip-run       安装后不自动启动 Krita
  --dry-run        只打印将执行的命令
  -h, --help       显示帮助
EOF
}

gradlew_path() {
    local dir="$ANDROID_APK_DIR"
    if [[ -x "$dir/gradlew" ]]; then
        printf '%s\n' "$dir/gradlew"
    elif [[ -f "$dir/gradlew.bat" ]]; then
        printf '%s\n' "$dir/gradlew.bat"
    elif [[ -f "$dir/gradlew" ]]; then
        printf '%s\n' "$dir/gradlew"
    else
        return 1
    fi
}

preflight() {
    ANDROID_APK_DIR="$BUILD_DIR/krita_build_apk"
    if [[ ! -d "$ANDROID_APK_DIR" ]]; then
        warn "未找到 $ANDROID_APK_DIR"
        die "请先执行: ./build-android.sh apk --archive-artifacts"
    fi
    if [[ ! -d "$BUILD_DIR" ]]; then
        die "未找到构建目录: $BUILD_DIR"
    fi
}

rebuild_native() {
    info "1/3 重新编译并 install"
    # 官方文档要求这两个变量在 gradle 打包前设置
    export ANDROID_ABI="$KDECI_ANDROID_ABI"
    export KRITA_INSTALL_PREFIX="$KRITA_INSTALL_DIR"
    log "ANDROID_ABI          = $ANDROID_ABI"
    log "KRITA_INSTALL_PREFIX = $KRITA_INSTALL_PREFIX"

    if [[ -f "$BUILD_DIR/build.ninja" ]]; then
        run ninja -C "$BUILD_DIR" -j "$KRITA_JOB_COUNT" install
    elif [[ -f "$BUILD_DIR/Makefile" ]]; then
        run make -j "$KRITA_JOB_COUNT" install -C "$BUILD_DIR"
    else
        die "未找到 $BUILD_DIR 下的 build.ninja/Makefile"
    fi
}

gradle_install() {
    info "2/3 Gradle 打包并安装调试版"
    cd "$ANDROID_APK_DIR"

    local gw
    gw="$(gradlew_path)" || die "未找到 gradlew/gradlew.bat（$ANDROID_APK_DIR）"

    run "$gw" "$GRADLE_TASK"
}

run_app() {
    info "3/3 在设备上启动 Krita"
    run adb_cmd wait-for-device
    run adb_cmd shell am start -n "$KRITA_APP_ID/$KRITA_MAIN_ACTIVITY"
    ok "已发送启动命令: $KRITA_APP_ID/$KRITA_MAIN_ACTIVITY"
    printf '  查看日志: %sadb logcat -s krita:V AndroidRuntime:E%s\n' "$C_BOLD" "$C_RESET"
}

main() {
    while (($#)); do
        case "$1" in
            --jobs)
                shift
                [[ $# -gt 0 ]] || die "--jobs 需要一个数值参数"
                KRITA_JOB_COUNT="$1"
                ;;
            --task)
                shift
                [[ $# -gt 0 ]] || die "--task 需要一个任务名"
                GRADLE_TASK="$1"
                ;;
            --skip-build)  SKIP_BUILD=1 ;;
            --skip-gradle) SKIP_GRADLE=1 ;;
            --skip-run)    SKIP_RUN=1 ;;
            --dry-run)     KRITA_DRY_RUN=1 ;;
            -h|--help)     usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    hr
    printf '  %s迭代重建并部署（%s）%s\n' "$C_BOLD" "$KDECI_ANDROID_ABI" "$C_RESET"

    preflight
    activate_generated_env

    if (( SKIP_BUILD == 0 )); then
        rebuild_native
    else
        warn "已跳过 native 编译（--skip-build）"
    fi

    if (( SKIP_GRADLE == 0 )); then
        gradle_install
    else
        warn "已跳过 gradle 打包（--skip-gradle）"
    fi

    if (( SKIP_RUN == 0 )); then
        run_app
    else
        warn "未自动启动 Krita（--skip-run）"
    fi
}

main "$@"
