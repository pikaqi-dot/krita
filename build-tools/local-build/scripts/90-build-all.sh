#!/usr/bin/env bash
# =============================================================================
#  90-build-all.sh —— 一键执行完整构建流程
#
#  按顺序执行：
#    1) 00-check-prereqs.sh   环境检查
#    2) 10-setup-sdk.sh       安装 SDK / NDK / cmdline-tools
#    3) 20-fetch-sources.sh   克隆 Krita 与其管理仓库
#    4) 30-fetch-deps.sh      生成构建环境（base-env / env）
#    5) 40-build-krita.sh     cmake 配置 + make install
#    6) 50-build-package.sh   打包 APK（可选 AAB）
#
#  用法:
#    ./scripts/90-build-all.sh [--from N|名字] [--only N|名字]
#                              [--skip-check] [--full-deps] [--aab]
#                              [--jobs N] [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

STEPS=(
    "00-check-prereqs.sh|环境检查"
    "10-setup-sdk.sh|安装 Android SDK / NDK"
    "20-fetch-sources.sh|获取 Krita 源码与管理仓库"
    "30-fetch-deps.sh|准备构建环境（Python venv / env）"
    "40-build-krita.sh|配置并编译 Krita"
    "50-build-package.sh|打包 APK"
)

FROM=1
ONLY=""
SKIP_CHECK=0
FULL_DEPS=0
WITH_AAB=0
RESUME=0
FORCE_DOWNLOAD=0
FORCE_RECLONE=0
CLEAN_BUILD=0
FORCE=0
# debug | release | nightly —— 第 6 步的 Gradle 打包类型
PACKAGE_TYPE="debug"
# --sign：第 6 步之后调用 55-sign-apk.sh 给 APK 签名
DO_SIGN=0

usage() {
    cat <<'EOF'
用法: 90-build-all.sh [选项]

选项:
  --from N|名字    从第 N 步（或步骤名/编号前缀，如 40）开始
  --only N|名字    只执行指定的单步
  --skip-check     跳过第 1 步环境检查
  --resume         自动检测第一个未完成的步骤并从那里继续（中断续跑）
  --full-deps      第 4 步去掉 --only-env（完整获取依赖，耗时很长）
  --aab            第 6 步同时生成 AAB
  --release        第 6 步打 release 包（gradlew assembleRelease，产物带 -unsigned）
  --nightly        第 6 步打 nightly 包（gradlew assembleNightly）
  --debug          第 6 步打 debug 包（默认）
  --sign           全部跑完后给 APK 签名（等价于再执行 ./build-android.sh sign）
  --force          第 5/6 步忽略增量标记，强制重新编译 + 重新打包
                   （默认：源码/配置没变化且产物存在时，这两步会直接跳过）
  --force-download 重新下载已存在的 SDK/NDK 压缩包（默认不重复下载）
  --force-reclone  删除已存在的源码目录后重新克隆（默认只做增量更新）
  --clean-build    删除 _build 后全量重编（最彻底，比 --force 更慢）
  --jobs N         并行编译任务数
  --dry-run        各步骤只打印命令
  -h, --help       显示帮助

增量说明:
  build / apk 两步各自记录"增量指纹"（源码 HEAD + 未提交改动 + ABI + NDK +
  编译器 + 工具链文件 + 安装前缀）。指纹没变且产物还在 → 直接跳过，不再编译/打包。
  想强制重来：--force；想连 _build 一起清掉：--clean-build。
EOF
}

resolve_index() {
    local v="$1" i n
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$v"
        return 0
    fi
    for i in "${!STEPS[@]}"; do
        n="${STEPS[$i]%%|*}"
        if [[ "$n" == "$v" || "$n" == "$v.sh" || "${n%%-*}" == "$v" ]]; then
            printf '%s\n' "$((i + 1))"
            return 0
        fi
    done
    return 1
}

# 检测第一个"未完成"的步骤编号（用于 --resume）
detect_resume_step() {
    # 2) SDK / NDK
    if [[ ! -f "$KDECI_ANDROID_NDK_ROOT/source.properties" ]]; then
        printf '2\n'; return 0
    fi
    if ! android_tool_path sdkmanager >/dev/null 2>&1; then
        printf '2\n'; return 0
    fi
    if [[ ! -d "$KDECI_ANDROID_SDK_ROOT/platforms" ]]; then
        printf '2\n'; return 0
    fi

    # 3) 源码
    if [[ ! -f "$KRITA_TOOLCHAIN_FILE" || ! -f "$CI_UTILS_DIR/run-ci-build.py" ]]; then
        printf '3\n'; return 0
    fi

    # 4) 构建环境（env 不存在，或依赖是另一个 ABI 的 → 需要重新准备依赖）
    if [[ ! -f "$KRITA_SRC/env" ]]; then
        printf '4\n'; return 0
    fi
    local dep_abi
    dep_abi="$(installed_abi)"
    if [[ -n "$dep_abi" && "$dep_abi" != "$ANDROID_ABI" ]]; then
        printf '4\n'; return 0
    fi

    # 5) 编译安装（构建目录若是另一个 ABI 配的，也要回到第 5 步重配）
    if ! compgen -G "$KRITA_INSTALL_DIR/lib/libkrita*.so*" >/dev/null 2>&1; then
        printf '5\n'; return 0
    fi

    # 6) 打包
    if ! compgen -G "$PACKAGING_DIR/*.apk" >/dev/null 2>&1; then
        printf '6\n'; return 0
    fi

    # 全部完成：默认回到第 5 步做增量重编
    printf '5\n'
}

print_plan() {
    local i=0 entry name desc
    hr
    printf '  %s构建计划（ABI=%s）%s\n' "$C_BOLD" "$KDECI_ANDROID_ABI" "$C_RESET"
    for entry in "${STEPS[@]}"; do
        i=$((i + 1))
        name="${entry%%|*}"
        desc="${entry#*|}"
        if [[ -n "$ONLY" ]]; then
            if (( i == ONLY )); then
                printf '   %s-> [%d] %-22s %s%s\n' "$C_GREEN" "$i" "$name" "$desc" "$C_RESET"
            else
                printf '      [%d] %-22s %s\n' "$i" "$name" "$desc"
            fi
        else
            if (( i < FROM )) || { (( i == 1 )) && (( SKIP_CHECK == 1 )); }; then
                printf '      [%d] %-22s %s  (跳过)\n' "$i" "$name" "$desc"
            else
                printf '   %s-> [%d] %-22s %s%s\n' "$C_GREEN" "$i" "$name" "$desc" "$C_RESET"
            fi
        fi
    done
    hr
}

run_step() {
    local name="$1" desc="$2"
    shift 2

    hr
    printf '%s[步骤]%s %s  (%s)\n' "$C_BOLD$C_BLUE" "$C_RESET" "$desc" "$name"
    hr

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        export KRITA_DRY_RUN
    fi

    if ! bash "$SCRIPT_DIR/$name" "$@"; then
        die "步骤失败: $name（可单独重跑该脚本继续）"
    fi
    ok "步骤完成: $desc"
}

main() {
    while (($#)); do
        case "$1" in
            --from)
                shift
                [[ $# -gt 0 ]] || die "--from 需要一个值"
                FROM="$(resolve_index "$1")" || die "无法识别的步骤: $1"
                ;;
            --only)
                shift
                [[ $# -gt 0 ]] || die "--only 需要一个值"
                ONLY="$(resolve_index "$1")" || die "无法识别的步骤: $1"
                ;;
            --skip-check) SKIP_CHECK=1 ;;
            --full-deps)  FULL_DEPS=1 ;;
            --aab)        WITH_AAB=1 ;;
            --release)    PACKAGE_TYPE=release ;;
            --nightly)    PACKAGE_TYPE=nightly ;;
            --debug)      PACKAGE_TYPE=debug ;;
            --sign)       DO_SIGN=1 ;;
            --jobs)
                shift
                [[ $# -gt 0 ]] || die "--jobs 需要一个数值参数"
                KRITA_JOB_COUNT="$1"
                export KRITA_JOB_COUNT
                ;;
            --dry-run)    KRITA_DRY_RUN=1; export KRITA_DRY_RUN ;;
            --resume)     RESUME=1 ;;
            --force|--rebuild) FORCE=1 ;;
            --force-download) FORCE_DOWNLOAD=1 ;;
            --force-reclone)  FORCE_RECLONE=1 ;;
            --clean-build)    CLEAN_BUILD=1 ;;
            -h|--help)    usage; exit 0 ;;
            all|build|pipeline)
                # 兼容外层 dispatcher 的子命令一起被传进来的情况
                # （如 build-android.sh wsl all / wsl-oneclick 会把 "all" 透传到这里）
                warn "忽略多余的位置参数 '$1'（90-build-all.sh 本身就是完整流程）"
                ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    if (( RESUME == 1 )); then
        FROM="$(detect_resume_step)"
        SKIP_CHECK=1
        if (( FROM == 5 )) && compgen -G "$PACKAGING_DIR/*.apk" >/dev/null 2>&1; then
            if (( FORCE == 1 )); then
                log "--resume：所有步骤均已完成；--force → 强制重编 + 重打包"
            else
                log "--resume：所有步骤均已完成；第 5/6 步会先比对增量指纹，无变化则跳过"
            fi
        else
            log "--resume：检测到从第 $FROM 步继续（已完成的部分不会重做）"
        fi
    fi

    case "$PACKAGE_TYPE" in
        release) log '打包类型: release（第 6 步跑 gradlew assembleRelease，产物带 -unsigned）' ;;
        nightly) log '打包类型: nightly（第 6 步跑 gradlew assembleNightly）' ;;
    esac

    print_plan

    local i=0 entry name desc
    for entry in "${STEPS[@]}"; do
        i=$((i + 1))
        name="${entry%%|*}"
        desc="${entry#*|}"

        if [[ -n "$ONLY" ]]; then
            (( i == ONLY )) || continue
        else
            (( i >= FROM )) || continue
            if (( i == 1 && SKIP_CHECK == 1 )); then
                warn "跳过步骤 [1] $desc（--skip-check）"
                continue
            fi
        fi

        local args=()
        case "$i" in
            2) (( FORCE_DOWNLOAD == 1 )) && args+=(--force) ;;
            3) (( FORCE_RECLONE == 1 ))  && args+=(--force-reclone) ;;
            4) (( FULL_DEPS == 1 ))      && args+=(--full-deps) ;;
            5)
                (( CLEAN_BUILD == 1 )) && args+=(--clean-build)
                (( FORCE == 1 )) && args+=(--force)
                ;;
            6)
                (( WITH_AAB == 1 )) && args+=(--aab)
                if [[ "$PACKAGE_TYPE" != "debug" ]]; then
                    args+=("--$PACKAGE_TYPE")
                fi
                (( FORCE == 1 )) && args+=(--force)
                ;;
        esac

        run_step "$name" "$desc" ${args[@]+"${args[@]}"}
    done

    # --sign：在最后补一步签名（release 包默认是 -unsigned）
    if (( DO_SIGN == 1 )); then
        if [[ -n "$ONLY" && "$ONLY" != "6" ]]; then
            warn "--sign 需要第 6 步的产物，本次只跑了第 $ONLY 步 → 跳过签名"
        elif ! compgen -G "$PACKAGING_DIR/*.apk" >/dev/null 2>&1; then
            warn "--sign：还没找到 APK → 跳过签名"
        else
            hr
            printf '  %s附加步骤: APK 签名（sign）%s\n' "$C_BOLD" "$C_RESET"
            local -a sign_args=()
            if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
                sign_args+=(--dry-run)
            fi
            bash "$SCRIPT_DIR/55-sign-apk.sh" ${sign_args[@]+"${sign_args[@]}"} ||
                die "签名失败（详见上方输出）"
            ok "签名完成"
        fi
    fi

    hr
    ok "全部步骤执行完毕"
    if [[ -d "$PACKAGING_DIR" ]]; then
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            printf '  产物: %s\n' "$f"
        done < <(find "$PACKAGING_DIR" -maxdepth 2 -type f \( -name '*.apk' -o -name '*.aab' \) 2>/dev/null | sort)
    fi
    hr
}

main "$@"
