#!/usr/bin/env bash
# =============================================================================
#  40-build-krita.sh —— 配置并编译 Krita（Android）
#
#  对应官方文档 "Configure Krita" + "Then build Krita as usual"：
#
#    cd $SRCDIR/krita/_build
#    cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
#          -DHIDE_SAFE_ASSERTS=OFF \
#          -DBUILD_TESTING=OFF \
#          -DCMAKE_INSTALL_PREFIX=$SRCDIR/krita/_install \
#          -DCMAKE_TOOLCHAIN_FILE=.../android-toolchain-krita.cmake \
#          -DANDROID_ENABLE_STDIO_FORWARDING=ON \
#          $SRCDIR/krita/
#    make -j8 install
#
#  注意（官方警告）：
#    * Android 上必须设置 KDECI_WORKDIR_PATH 对应的工作目录，
#      不要在源码树内随意更改 _build 位置；
#    * CMAKE_INSTALL_PREFIX 必须指向依赖所在目录（宿主机流程为 _install）。
#
#  用法:
#    ./scripts/40-build-krita.sh [--reconfigure] [--force] [--jobs N] [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

RECONFIGURE=0
CLEAN_BUILD=0
FORCE=0

usage() {
    cat <<'EOF'
用法: 40-build-krita.sh [选项]

选项:
  --force         忽略增量标记，强制重新编译（源码没变也编）
  --reconfigure   强制重新运行 cmake 配置（保留已有编译产物，仍是增量）
  --clean-build   删除 _build 后从零全量编译（最彻底）
  --jobs N        并行编译任务数（默认取 CPU 核心数）
  --dry-run       只将执行的命令打印出来
  -h, --help      显示帮助

说明:
  默认行为是"智能增量"：
    * _build 存在则跳过 cmake 配置；
    * 若源码 HEAD / 未提交改动 / ABI / NDK / 编译器 / 工具链文件 / 安装前缀
      全都与上次成功编译时一致，且 _install 里有 libkrita*.so →
      整步直接跳过（打印"无变化"），一秒结束；
    * 有任何一项变化 → 正常增量编译（只重编改动部分）。
  中断后直接重跑同一条命令即可继续。
EOF
}

preflight() {
    [[ -d "$KRITA_SRC" ]] || die "未找到 Krita 源码: $KRITA_SRC（执行 ./build-android.sh sources）"
    if [[ ! -f "$KRITA_TOOLCHAIN_FILE" ]]; then
        die "未找到 Android 工具链文件: $KRITA_TOOLCHAIN_FILE（执行 ./build-android.sh sources）"
    fi
    if [[ ! -f "$KRITA_SRC/env" ]]; then
        warn "未找到构建环境文件 $KRITA_SRC/env（建议先执行 ./build-android.sh deps）"
    fi
    if [[ ! -f "$KDECI_ANDROID_NDK_ROOT/source.properties" ]]; then
        warn "未找到 NDK: $KDECI_ANDROID_NDK_ROOT（执行 ./build-android.sh sdk）"
    fi
    if [[ ! -d "$KDECI_ANDROID_SDK_ROOT" ]]; then
        warn "未找到 SDK: $KDECI_ANDROID_SDK_ROOT（执行 ./build-android.sh sdk）"
    fi
    # 依赖没装到 _install 时，cmake 会以晦涩的 "Could not find ECM" 失败，这里提前拦住
    if [[ ! -f "$KRITA_INSTALL_DIR/share/ECM/cmake/ECMConfig.cmake" ]] &&
        [[ ! -d "$KRITA_INSTALL_DIR/lib/cmake/KF5" ]]; then
        hr
        err "依赖目录为空: $KRITA_INSTALL_DIR"
        printf '  cmake 会因为找不到 ECM 而失败。请先安装依赖（会优先使用本地缓存）：\n\n'
        printf '    %s./build-android.sh deps --full-deps%s\n' "$C_BOLD" "$C_RESET"
        printf '    （或 ./build-android.sh wsl --shell ./scripts/30-fetch-deps.sh --full-deps）\n\n'
        hr
        die "依赖未安装"
    fi
}

configure() {
    info "1/2 CMake 配置"
    cd "$BUILD_DIR"

    # 注意：只有"缓存 + 构建文件"都在才跳过——上次 configure 失败会留下 CMakeCache.txt
    # 但没有 Makefile/build.ninja，此时必须重新配置
    # 另外：构建目录的 ABI 必须与当前一致（check_abi_of_build_dir 已保证），
    # 标记文件由本次成功配置后写入，这里不再补写，避免把错误 ABI 记成正确的。
    if [[ -f CMakeCache.txt && "${RECONFIGURE:-0}" != "1" ]] &&
        { [[ -f Makefile ]] || [[ -f build.ninja ]]; }; then
        ok "检测到已有的 cmake 配置，跳过配置（--reconfigure 可强制重配）"
        return 0
    fi

    log "构建类型        : $KRITA_CMAKE_BUILD_TYPE"
    log "安装前缀        : $KRITA_INSTALL_DIR"
    log "工具链文件      : $KRITA_TOOLCHAIN_FILE"
    log "目标 ABI        : $KDECI_ANDROID_ABI"

    # 两个 Android 专有开关的说明：
    #   CMAKE_INSTALL_PREFIX         -> 与依赖同目录，APK 打包脚本无法跨目录查找
    #   ANDROID_ENABLE_STDIO_FORWARDING -> 把 stdout/stderr 转发到 logcat
    run cmake \
        -DCMAKE_BUILD_TYPE="$KRITA_CMAKE_BUILD_TYPE" \
        -DHIDE_SAFE_ASSERTS=OFF \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_PREFIX="$KRITA_INSTALL_DIR" \
        -DCMAKE_PREFIX_PATH="$KRITA_INSTALL_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$KRITA_TOOLCHAIN_FILE" \
        -DANDROID_ABI="$KDECI_ANDROID_ABI" \
        -DANDROID_NDK="$KDECI_ANDROID_NDK_ROOT" \
        -DANDROID_ENABLE_STDIO_FORWARDING=ON \
        "$KRITA_SRC"

    [[ -f CMakeCache.txt ]] && ok "CMake 配置完成"
    record_built_abi
    record_built_compiler
}

# 切换 ABI 后旧的 _build 里全是另一套架构的目标文件，必须清空重配
# （旧目标文件与新的 aarch64/arm 工具链混用会报：
#    ld.lld: error: xxx.o is incompatible with aarch64linux）
check_abi_of_build_dir() {
    [[ -d "$BUILD_DIR" ]] || return 0
    # 还没配置过（没有构建文件）就不用管
    if [[ ! -f "$BUILD_DIR/Makefile" && ! -f "$BUILD_DIR/build.ninja" ]]; then
        return 0
    fi

    local old
    old="$(built_abi)"

    if [[ "$old" != "$ANDROID_ABI" ]]; then
        if [[ -z "$old" ]]; then
            warn "构建目录没有 ABI 标记（可能是旧版本脚本产生的），为安全起见清空后重配"
        else
            warn "构建目录是为 $old 配置的，当前 ABI=$ANDROID_ABI → 删除 $BUILD_DIR 后重配（需重编）"
        fi
        run rm -rf -- "$BUILD_DIR"
        return 0
    fi

    # 同一 ABI，但换了编译器（宿主机 ↔ Docker 容器）也要重配
    local old_cc cur_cc
    old_cc="$(built_compiler)"
    cur_cc="$(current_compiler_id)"
    if [[ -n "$old_cc" && -n "$cur_cc" && "$old_cc" != "$cur_cc" ]]; then
        warn "编译器变了：$old_cc → $cur_cc"
        warn "（宿主机与 Docker 容器混用时会这样）→ 删除 $BUILD_DIR 后重配"
        run rm -rf -- "$BUILD_DIR"
        return 0
    fi

    ok "构建目录匹配: ABI=$old"
}

build_and_install() {
    info "2/2 编译并安装（-j$KRITA_JOB_COUNT）"
    cd "$BUILD_DIR"

    local generator=""
    if [[ -f build.ninja ]]; then
        generator="ninja"
    elif [[ -f Makefile ]]; then
        generator="make"
    else
        die "未找到 build.ninja/Makefile，CMake 配置可能失败"
    fi

    local retry_jobs=4
    [[ "$KRITA_JOB_COUNT" -lt "$retry_jobs" ]] && retry_jobs="$KRITA_JOB_COUNT"

    # 首轮：全并发（失败不直接退出，要留出重试机会）
    local rc=0
    if [[ "$generator" == "ninja" ]]; then
        run ninja -j "$KRITA_JOB_COUNT" install || rc=$?
    else
        run make -j "$KRITA_JOB_COUNT" install || rc=$?
    fi

    if (( rc != 0 )); then
        # Qt5 AUTOMOC 在 -j 高并发下偶发竞态：
        #   mocs_compilation.cpp 抢在 moc_xxx.cpp 生成之前被编译
        #   -> fatal error: 'XXXXXX/moc_xxx.cpp' file not found
        # 属已知问题，降低并发重跑（增量编译，只补缺的部分）通常即可通过。
        warn "首次编译失败（退出码 $rc）"
        warn "若是 'moc_xxx.cpp: file not found'，属于 Qt5 AUTOMOC 并发竞态，重跑即可"
        warn "以较低并发 -j$retry_jobs 重试一次..."
        if [[ "$generator" == "ninja" ]]; then
            run ninja -j "$retry_jobs" install
        else
            run make -j "$retry_jobs" install
        fi
    fi

    hr
    if [[ -d "$KRITA_INSTALL_DIR" ]]; then
        ok "安装目录: $KRITA_INSTALL_DIR"
        if compgen -G "$KRITA_INSTALL_DIR/lib/libkrita*.so*" >/dev/null 2>&1; then
            ok "已找到 libkrita 相关库"
        fi
    fi
    printf '  下一步: %s./build-android.sh apk%s\n' "$C_BOLD" "$C_RESET"
}

main() {
    while (($#)); do
        case "$1" in
            --force|--rebuild) FORCE=1 ;;
            --reconfigure) RECONFIGURE=1 ;;
            --clean-build) CLEAN_BUILD=1 ;;
            --jobs)
                shift
                [[ $# -gt 0 ]] || die "--jobs 需要一个数值参数"
                KRITA_JOB_COUNT="$1"
                ;;
            --dry-run) KRITA_DRY_RUN=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    hr
    printf '  %s编译 Krita（Android / %s）%s\n' "$C_BOLD" "$KDECI_ANDROID_ABI" "$C_RESET"

    preflight
    activate_generated_env

    if (( CLEAN_BUILD == 1 )); then
        warn "--clean-build：删除 $BUILD_DIR 并全量重编"
        run rm -rf -- "$BUILD_DIR"
    else
        check_abi_of_build_dir
    fi

    # ---- 增量判定：源码/配置都没变，且产物还在 → 整步跳过 ----
    local fp=""
    fp="$(krita_build_fingerprint)"
    if (( FORCE == 0 && CLEAN_BUILD == 0 )) &&
        stamp_matches "$BUILD_STAMP_FILE" "$fp" &&
        build_artifacts_present; then
        hr
        ok "自上次编译以来源码与配置均无变化 → 跳过编译（省掉一次全量扫描/构建）"
        log "增量指纹: $fp"
        log "强制重编: ./build-android.sh build --force     全量重编: ./build-android.sh build --clean-build"
        hr
        ok "安装目录: $KRITA_INSTALL_DIR"
        printf '  下一步: %s./build-android.sh apk%s\n' "$C_BOLD" "$C_RESET"
        return 0
    fi
    if (( FORCE == 1 )); then
        warn "--force：忽略增量标记，强制重新编译"
    fi
    if (( CLEAN_BUILD == 1 )); then
        clear_stamp "$BUILD_STAMP_FILE"
    fi

    run mkdir -p "$BUILD_DIR"
    configure
    build_and_install

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        warn "--dry-run：不写入增量标记"
    else
        write_stamp "$BUILD_STAMP_FILE" "$fp"
        ok "已记录增量标记（下次无改动会直接跳过编译）"
    fi
}

main "$@"
