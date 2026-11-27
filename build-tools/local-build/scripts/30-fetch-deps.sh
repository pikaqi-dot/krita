
#!/usr/bin/env bash
# =============================================================================
#  30-fetch-deps.sh —— 准备 Python 虚拟环境并生成 Krita 构建环境
#
#  对应官方文档 "Fetch Krita Deps" 一节，依次执行：
#    1. python3 -m venv --upgrade-deps $WORKDIR/PythonEnv
#    2. pip install -r krita-deps-management/requirements.txt
#    3. python krita-deps-management/tools/setup-env.py -v <venv> \
#             --android-abi <abi> --root $WORKDIR
#    4. source $WORKDIR/base-env
#    5. python krita-deps-management/tools/generate-deps-file.py \
#             -s latest/krita-deps.yml -o .kde-ci.yml
#    6. python krita-deps-management/ci-utilities/run-ci-build.py \
#             --project krita --branch <branch> \
#             --platform Android/<abi> [--only-env]
#
#  说明：run-ci-build.py 生成 $KRITA_SRC/env，后续脚本会自动 source 它。
#        若需要真正下载/构建依赖（而不是只生成 env），请设置
#        KRITA_FETCH_FULL_DEPS=1 或使用 --full-deps。
#
#  用法:
#    ./scripts/30-fetch-deps.sh [--full-deps] [--skip-pip] [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

SKIP_PIP=0
GENERATE_DEPS=0
ONLY_DEPS=0

usage() {
    cat <<'EOF'
用法: 30-fetch-deps.sh [选项]

选项:
  --full-deps     去掉 --only-env，完整获取/构建依赖（耗时很长、占用磁盘多）
  --generate-deps 按 CI 方式重新生成 .kde-ci.yml（默认使用仓库自带的，避免 schema 冲突）
  --skip-pip      跳过 pip install 步骤
  --dry-run       只打印将执行的命令
  -h, --help      显示帮助
EOF
}

require_sources() {
    [[ -d "$KRITA_SRC" ]] || die "未找到 Krita 源码: $KRITA_SRC（请先执行 ./build-android.sh sources）"
    [[ -f "$DEPS_MGMT_DIR/requirements.txt" ]] || die "未找到 $DEPS_MGMT_DIR/requirements.txt"
    [[ -f "$DEPS_MGMT_DIR/tools/setup-env.py" ]] || die "未找到 $DEPS_MGMT_DIR/tools/setup-env.py"
    [[ -f "$CI_UTILS_DIR/run-ci-build.py" ]] || die "未找到 $CI_UTILS_DIR/run-ci-build.py"
}

ensure_venv() {
    info "1/6 Python 虚拟环境"
    local py
    py="$(resolve_python)" || die "未找到 python3（需要 >= 3.10）"

    if [[ -x "$VENVDIR/bin/python" || -f "$VENVDIR/Scripts/python.exe" ]]; then
        ok "复用已有 venv: $VENVDIR"
    else
        run mkdir -p "$(dirname -- "$VENVDIR")"
        run "$py" -m venv --upgrade-deps "$VENVDIR"
        ok "已创建 venv: $VENVDIR"
    fi

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        ok "DRY-RUN: 跳过 venv 激活（venv 尚未真正创建）"
        return 0
    fi
    activate_venv || die "venv 激活脚本缺失: $VENVDIR"
}

install_requirements() {
    info "2/6 安装 Python 依赖"
    if (( SKIP_PIP == 1 )); then
        warn "已跳过 pip install（--skip-pip）"
        return 0
    fi
    run python -m pip install --upgrade pip
    run python -m pip install -r "$DEPS_MGMT_DIR/requirements.txt"
    ok "Python 依赖安装完成"
}

run_setup_env() {
    info "3/6 setup-env.py（生成 $WORKDIR/base-env）"
    cd "$KRITA_SRC"
    run python "$DEPS_MGMT_DIR/tools/setup-env.py" \
        -v "$VENVDIR" \
        --android-abi "$KDECI_ANDROID_ABI" \
        --root "$WORKDIR"

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        ok "DRY-RUN: 跳过 base-env 存在性校验"
        return 0
    fi

    if [[ ! -f "$WORKDIR/base-env" ]]; then
        die "未生成 $WORKDIR/base-env，setup-env.py 可能执行失败"
    fi
    ok "已生成: $WORKDIR/base-env"
    # 注意：base-env 由 KDE 工具生成，第一行就可能引用尚未定义的变量；
    # 在 set -u 下直接 source 会让 bash 退出（实测 KDECI_CACHE_PATH: unbound variable）
    if safe_source "$WORKDIR/base-env"; then
        ok "已激活 base-env"
    else
        warn "base-env 内部有告警（已尽量应用），继续"
    fi
}

# 准备 $KRITA_SRC/.kde-ci.yml
#
# 官方文档让我们用 generate-deps-file.py 生成它，但实测有坑：
#   * .kde-ci.yml 本来就是 krita 仓库自带的文件（git ls-files 能看到）；
#   * 用 latest/krita-deps.yml 直接覆盖后，其 schema 与 ci-utilities 的
#     global.yml / global-config.yml 不一致，run-ci-build.py 合并配置时抛
#     TypeError: list indices must be integers or slices, not str。
# 因此默认：使用仓库自带版本（若被改过就恢复）；需要生成时走 CI 的方式
# （先 replace-branch-in-seed-file.py 再 generate-deps-file.py）。
prepare_kde_ci_yml() {
    info "4/6 准备 .kde-ci.yml"
    local f="$KRITA_SRC/.kde-ci.yml"

    if [[ "${GENERATE_DEPS:-0}" == "1" ]]; then
        local seed="$DEPS_MGMT_DIR/latest/krita-deps.yml"
        local corrected="$KRITA_SRC/branch-corrected-deps.yml"
        [[ -f "$seed" ]] || die "未找到依赖种子文件: $seed"
        log "按 CI 的方式生成（replace-branch-in-seed-file.py -> generate-deps-file.py）"
        run python "$DEPS_MGMT_DIR/tools/replace-branch-in-seed-file.py" \
            "$seed" -p -o "$corrected" -d "$KRITA_BRANCH"
        run python "$DEPS_MGMT_DIR/tools/generate-deps-file.py" -s "$corrected" -o "$f"
        ok "已生成: $f"
        return 0
    fi

    if [[ -f "$f" ]]; then
        ok "使用仓库自带的 .kde-ci.yml: $f"
        if git -C "$KRITA_SRC" ls-files --error-unmatch .kde-ci.yml >/dev/null 2>&1; then
            if ! git -C "$KRITA_SRC" diff --quiet -- .kde-ci.yml 2>/dev/null; then
                warn ".kde-ci.yml 曾被改动，恢复为仓库版本（避免 schema 冲突）"
                run git -C "$KRITA_SRC" checkout -- .kde-ci.yml
            fi
        fi
        return 0
    fi

    warn "仓库里没有 .kde-ci.yml，改用 CI 方式生成"
    GENERATE_DEPS=1
    prepare_kde_ci_yml
}

# --only-deps / --full-deps 需要 .kde-ci.yml 里有 Dependencies 段。
#
# krita 仓库自带的 .kde-ci.yml 只有 Options / PostInstallScripts，**没有 Dependencies**，
# 于 run-ci-build.py 解析出 0 个依赖并返回 0 —— 看起来"成功"，实际一个包都没下载，
# 直到 5.5 校验才发现 ECM 缺失（现象：日志里只有一行 "## Disable ECM's ..." 就结束）。
# 所以真正要 fetch 依赖之前，这里强制生成一份含依赖清单的版本。
ensure_deps_manifest() {
    local f="$KRITA_SRC/.kde-ci.yml"
    if [[ -f "$f" ]] && grep -q '^Dependencies:' "$f"; then
        return 0
    fi
    warn ".kde-ci.yml 没有 Dependencies 段（krita 仓库自带版本本来就没有）"
    warn "→ 按 CI 方式重新生成，否则 --only-deps 会装 0 个依赖却返回成功"
    GENERATE_DEPS=1
    prepare_kde_ci_yml
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        warn "dry-run：跳过 Dependencies 段校验（未真正生成）"
        return 0
    fi
    if ! grep -q '^Dependencies:' "$f" 2>/dev/null; then
        die "生成后 .kde-ci.yml 仍无 Dependencies 段（检查 $DEPS_MGMT_DIR/latest/krita-deps.yml）"
    fi
    ok "已生成含依赖清单的 .kde-ci.yml"
    warn "该文件已改写（git status 会显示 dirty）；恢复用: git -C \"$KRITA_SRC\" checkout -- .kde-ci.yml"
}

run_ci_build() {
    info "5/6 run-ci-build.py（生成构建环境 $KRITA_SRC/env）"
    cd "$KRITA_SRC"

    # 关键：KDE CI 的 KDECI_GLOBAL_CONFIG_OVERRIDE_PATH 指向
    #   krita-deps-management/global-config.yml
    # 该文件的 PostInstallScripts 是 list，而 ci-utilities 的 global.yml 是 dict，
    # run-ci-build.py 合并时必然抛
    #   TypeError: list indices must be integers or slices, not str
    # 宿主机/WSL 流程下必须去掉它（实测去掉后配置合并立即通过）。
    if [[ -n "${KDECI_GLOBAL_CONFIG_OVERRIDE_PATH:-}" ]]; then
        warn "忽略 KDECI_GLOBAL_CONFIG_OVERRIDE_PATH=$KDECI_GLOBAL_CONFIG_OVERRIDE_PATH"
        warn "（其 schema 与 ci-utilities 不兼容，见脚本注释）"
        unset KDECI_GLOBAL_CONFIG_OVERRIDE_PATH
    fi

    # run-ci-build.py 会在 $KDECI_WORKDIR_PATH/krita 下建 build 目录，必须可写
    run mkdir -p "$KDECI_WORKDIR_PATH"
    export KDECI_WORKDIR_PATH

    # 真正要装依赖时，必须先保证 .kde-ci.yml 有 Dependencies 段
    # （否则 run-ci-build.py 会"成功地"装 0 个包）
    if (( ONLY_DEPS == 1 )) || [[ "${KRITA_FETCH_FULL_DEPS:-0}" == "1" ]]; then
        ensure_deps_manifest
    fi

    local args=(--project krita --branch "$KRITA_BRANCH" --platform "Android/$KDECI_ANDROID_ABI"
        --skip-publishing)
    if (( ONLY_DEPS == 1 )); then
        # 只安装依赖：优先命中 $KDECI_CACHE_PATH 里的预编译包，解包到 $KDECI_SHARED_INSTALL_PATH
        warn "只安装依赖（--only-deps，优先使用本地缓存，不重复下载）"
        args+=(--only-deps)
    elif [[ "${KRITA_FETCH_FULL_DEPS:-0}" == "1" ]]; then
        warn "KRITA_FETCH_FULL_DEPS=1：完整模式（会从源码构建依赖，耗时长）"
    else
        args+=(--only-env)
    fi

    # 下载预编译依赖走 GitLab Packages，经代理时单个大包可能被截断：
    #   requests.exceptions.ChunkedEncodingError: Connection broken: IncompleteRead(...)
    # 已下载完成的包会被本地缓存复用，因此失败后重试即可继续，不会从头再来。
    local tries="${KRITA_DEPS_RETRIES:-4}" attempt rc=0
    for ((attempt = 1; attempt <= tries; attempt++)); do
        rc=0
        run python "$CI_UTILS_DIR/run-ci-build.py" "${args[@]}" || rc=$?
        if (( rc == 0 )); then
            break
        fi
        if (( attempt < tries )); then
            warn "run-ci-build.py 第 $attempt 次失败（退出码 $rc）"
            warn "5 秒后重试（已下载的包会复用，只补缺）"
            sleep 5
        fi
    done
    if (( rc != 0 )); then
        die "run-ci-build.py 连续 $tries 次失败（退出码 $rc）；多为网络/代理截断，稍后重跑即可"
    fi

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        ok "DRY-RUN: 跳过 env 存在性校验"
        return 0
    fi

    # run-ci-build.py 把 env 写到 $KDECI_WORKDIR_PATH/krita/env（类似 CI 的 /tmp/wd），
    # 这里同步到源码树，保持文档里 `source ./env` 的用法
    local alt_env="$KDECI_WORKDIR_PATH/krita/env"
    if [[ -f "$alt_env" ]]; then
        if [[ "${KRITA_DRY_RUN:-0}" != "1" ]]; then
            mkdir -p "$KRITA_SRC"
            cp -f "$alt_env" "$KRITA_SRC/env"
            ok "已同步 env 到 $KRITA_SRC/env"
        fi
    fi

    if [[ -f "$KRITA_SRC/env" ]]; then
        ok "已生成: $KRITA_SRC/env"
    else
        die "未生成 $KRITA_SRC/env（也未找到 $alt_env），run-ci-build.py 可能执行失败"
    fi
}

# 依赖是否真的落到 $KRITA_INSTALL_DIR（ECM 是 Krita configure 阶段必需的）
deps_installed() {
    [[ -f "$KRITA_INSTALL_DIR/share/ECM/cmake/ECMConfig.cmake" ]] ||
        [[ -d "$KRITA_INSTALL_DIR/lib/cmake/KF5" ]]
}

# 从缓存里的预编译包离线安装依赖（每个依赖一个 ext_<名>-master.tar）
install_deps_from_cache() {
    local cache="${KDECI_CACHE_PATH:-$WORKDIR/cache}"
    local n=0 f
    if ! compgen -G "$cache/ext_*-master.tar" >/dev/null 2>&1; then
        warn "缓存里没有预编译包: $cache/ext_*-master.tar"
        return 1
    fi
    info "从本地缓存离线安装依赖: $cache"
    run mkdir -p "$KRITA_INSTALL_DIR"
    for f in "$cache"/ext_*-master.tar; do
        if tar -xf "$f" -C "$KRITA_INSTALL_DIR"; then
            n=$((n + 1))
        else
            warn "解包失败: $f"
        fi
    done
    ok "已解包 $n 个依赖包到 $KRITA_INSTALL_DIR"
    deps_installed
}

# ---------------------------------------------------------------------------
# ABI 切换检查
#   _install 里的预编译依赖是与 ABI 绑定的（x86_64 的 Qt 不能链接进 arm64 的 APK）。
#   切换 ABI 时，旧依赖与本地缓存包（ext_*.tar）都是另一套架构，必须清掉重取。
# ---------------------------------------------------------------------------
prepare_abi_switch() {
    info "3.5/6 ABI 一致性检查（当前 $ANDROID_ABI）"

    local old
    old="$(installed_abi)"

    if [[ -z "$old" ]]; then
        if deps_installed; then
            warn "依赖目录存在但没有 ABI 标记（旧版本脚本安装的），按当前 ABI=$ANDROID_ABI 记录"
            record_installed_abi
        else
            ok "依赖尚未安装，稍后按 $ANDROID_ABI 获取"
        fi
        return 0
    fi

    if [[ "$old" == "$ANDROID_ABI" ]]; then
        ok "依赖架构匹配: $old"
        return 0
    fi

    # 1) 如果之前为当前 ABI 备过份，直接恢复（秒切回，不用重新下载）
    local backup="${KRITA_INSTALL_DIR}.${ANDROID_ABI}"
    if [[ -d "$backup" ]]; then
        warn "发现 $ANDROID_ABI 的依赖备份，恢复: $backup -> $KRITA_INSTALL_DIR"
        run rm -rf "$KRITA_INSTALL_DIR"
        run mv "$backup" "$KRITA_INSTALL_DIR"
        ok "已恢复到 $ANDROID_ABI（无需重新下载依赖）"
        return 0
    fi

    # 2) 把旧架构的依赖与缓存包挪到一边（而不是直接删，便于以后切回）
    warn "依赖目录是为 $old 构建的，当前需要 $ANDROID_ABI"
    warn "旧依赖移动到: ${KRITA_INSTALL_DIR}.${old}（切回 $old 时会自动恢复）"
    run rm -rf "${KRITA_INSTALL_DIR}.${old}"
    run mv "$KRITA_INSTALL_DIR" "${KRITA_INSTALL_DIR}.${old}"

    local cache="${KDECI_CACHE_PATH:-$WORKDIR/cache}"
    if compgen -G "$cache/ext_*.tar" >/dev/null 2>&1; then
        warn "旧架构缓存包移动到: $cache/backup-${old}（新架构需要重新下载）"
        run mkdir -p "$cache/backup-${old}"
        run mv "$cache"/ext_*.tar "$cache"/ext_*.json "$cache/backup-${old}/"
    fi
}

# 若依赖目录为空（例如被 clean 掉了），自动装回来（优先本地缓存）
ensure_deps_installed() {
    info "5.5/6 校验依赖安装目录"
    if deps_installed; then
        ok "依赖已在 $KRITA_INSTALL_DIR"
        return 0
    fi
    warn "依赖目录为空或缺少 ECM"
        # 1) 优先：$KDECI_CACHE_PATH 里的预编译包，离线解包（不联网、不重复下载）
        if install_deps_from_cache && deps_installed; then
            return 0
        fi
    
        # 2) 次选：让 KDE CI 工具去下载/安装（需要 GitLab 访问权限，可能较慢）
        warn "本地缓存不可用，改用 run-ci-build.py --only-deps 尝试下载安装"
        ONLY_DEPS=1
        run_ci_build || true
        if deps_installed; then
            ok "依赖已安装: $KRITA_INSTALL_DIR"
            return 0
        fi
        die "依赖仍缺失: $KRITA_INSTALL_DIR/share/ECM/cmake/ECMConfig.cmake（可尝试 ./build-android.sh deps --full-deps）"
    }

verify() {
    info "6/6 校验"
    if [[ -d "$KDECI_SHARED_INSTALL_PATH" ]]; then
        ok "依赖安装目录存在: $KDECI_SHARED_INSTALL_PATH"
    else
        warn "依赖安装目录不存在: $KDECI_SHARED_INSTALL_PATH"
        warn "当前使用了 --only-env，只生成环境文件而不会下载依赖"
        warn "若 CMake 找不到 Qt/依赖，请执行: ./build-android.sh deps --full-deps"
    fi

    hr
    printf '  下次进入新终端时，只需：\n\n'
    printf '    %ssource %s%s\n' "$C_BOLD" "$KRITA_SRC/env" "$C_RESET"
    printf '\n  （本套脚本会自动 source base-env 与 env，无需手工操作）\n'
    hr
    printf '  下一步: %s./build-android.sh build%s\n' "$C_BOLD" "$C_RESET"
}

main() {
    while (($#)); do
        case "$1" in
            --full-deps) KRITA_FETCH_FULL_DEPS=1 ;;
            --generate-deps) GENERATE_DEPS=1 ;;
            --skip-pip)  SKIP_PIP=1 ;;
            --dry-run)   KRITA_DRY_RUN=1 ;;
            -h|--help)   usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done
    export KRITA_FETCH_FULL_DEPS

    hr
    printf '  %s准备 Krita 构建依赖%s\n' "$C_BOLD" "$C_RESET"
    log "ABI      = $KDECI_ANDROID_ABI"
    log "WORKDIR  = $WORKDIR"
    log "VENVDIR  = $VENVDIR"

    require_sources
    ensure_venv
    install_requirements
    run_setup_env
    prepare_kde_ci_yml
    prepare_abi_switch
    run_ci_build
    ensure_deps_installed
    if deps_installed; then
        record_installed_abi
        ok "已记录依赖 ABI: $ANDROID_ABI"
    fi
    verify
}

main "$@"
