#!/usr/bin/env bash
# =============================================================================
#  report.sh —— 构建产物 / 增量状态一览（只读）
#
#  回答两个日常问题：
#    1) 现在手上的 APK 是不是最新的？
#    2) 下一步该跑什么（dev 迭代 / build / apk）？
#
#  完全只读：不编译、不下载、不写任何文件（只读 git、du、unzip -l）。
#
#  用法:
#    ./build-android.sh report             # 人类可读
#    ./build-android.sh report --json      # 机器可读（CI 用）
#    ./build-android.sh report --quiet     # 只看增量状态 + 产物
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 退出码 1 表示"需要重新编译/打包"（正常语义），不要让全局 trap 报"执行失败"
export KRITA_EXIT_SOFT=1

# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

JSON=0
QUIET=0

usage() {
    cat <<'EOF'
用法: report.sh [选项]

选项:
  --json      输出 JSON（供脚本 / CI 消费）
  --quiet     只输出增量状态与产物清单
  -h, --help  显示帮助

报告包含:
  配置        ABI / API / 构建类型 / 并行任务 / 分支
  路径        源码、_build、_install、_packaging、dist
  源码状态    krita HEAD、deps HEAD、未提交改动数量
  工具链      NDK、编译器、_install 里实际的 ABI（并与配置比对）
  增量状态    build / package 的 stamp 是否命中，产物是否齐全
  产物        APK / AAB 的大小、.so 数量、是否已签名、mtime
  体积与磁盘  _build / _install / _packaging / dist，以及剩余空间

退出码:
  0  一切就绪（stamp 命中且产物齐全）
  1  需要重新编译或重新打包（stamp 未命中 / 产物缺失）
EOF
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
jstr() {
    # JSON 字符串转义（路径里可能出现反斜杠）
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

short_val() {
    local v="$1"
    if [[ ${#v} -gt 28 ]]; then
        printf '%s…' "${v:0:28}"
    else
        printf '%s' "$v"
    fi
}

mtime_of() {
    local f="$1"
    [[ -e "$f" ]] || { printf -- '-'; return 0; }
    date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null && return 0
    stat -c '%y' "$f" 2>/dev/null | cut -d. -f1 && return 0
    printf -- '-'
}

bytes_of() {
    local p="$1"
    [[ -e "$p" ]] || { printf '0'; return 0; }
    du -sb "$p" 2>/dev/null | awk '{print $1}' && return 0
    du -sk "$p" 2>/dev/null | awk '{printf "%d", $1 * 1024}' && return 0
    printf '0'
}

size_of() {
    local p="$1"
    [[ -e "$p" ]] || { printf -- '-'; return 0; }
    du -sh "$p" 2>/dev/null | awk '{print $1}'
}

git_head_of() {
    local dir="$1"
    if have_cmd git && [[ -d "$dir/.git" ]]; then
        git -C "$dir" log -1 --format='%h %ad %s' --date=short 2>/dev/null | cut -c1-72
    else
        printf '（非 git 仓库）'
    fi
}

git_branch_of() {
    local dir="$1"
    if have_cmd git && [[ -d "$dir/.git" ]]; then
        git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?'
    else
        printf -- '-'
    fi
}

git_dirty_of() {
    local dir="$1"
    if have_cmd git && [[ -d "$dir/.git" ]]; then
        git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' '
    else
        printf '0'
    fi
}

# 指纹逐段对比：fp1|abi=…|api=…|… 只打印不同的键
fp_diff() {
    local old="$1" new="$2"
    local -a o n
    local IFS='|'
    read -r -a o <<< "$old"
    read -r -a n <<< "$new"
    local i k ov nv
    for (( i = 0; i < ${#n[@]}; i++ )); do
        ov="${o[i]:-}"
        nv="${n[i]:-}"
        [[ "$ov" == "$nv" ]] && continue
        k="${nv%%=*}"
        printf '  - %s: %s -> %s\n' \
            "$k" "$(short_val "${ov#*=}")" "$(short_val "${nv#*=}")"
    done
}

apk_so_count() {
    local apk="$1"
    if have_cmd unzip; then
        unzip -l "$apk" 2>/dev/null | awk '/lib\/.*\.so$/{ n++ } END { printf "%d", n + 0 }'
    else
        printf -- '-'
    fi
}

# 找 apksigner（与 55-sign-apk.sh 同样的逻辑：配置指定的版本优先，否则取最高版）
find_apksigner_bin() {
    local v
    v="$KDECI_ANDROID_SDK_ROOT/build-tools/${ANDROID_BUILD_TOOLS:-}/apksigner"
    if [[ -n "${ANDROID_BUILD_TOOLS:-}" && -x "$v" ]]; then
        printf '%s\n' "$v"
        return 0
    fi
    v="$(ls -1d "$KDECI_ANDROID_SDK_ROOT"/build-tools/*/ 2>/dev/null |
        sort -V | while read -r d; do
            [[ -x "$d/apksigner" ]] && printf '%s\n' "${d%/}/apksigner"
        done | tail -n 1)"
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
    return 1
}

# 是否已签名
#   ⚠ 不能只看 META-INF/*.RSA：minSdkVersion >= 24 时 Gradle / apksigner 默认
#   只写 v2/v3 签名块（在 zip 中央目录之前，不是 META-INF 里的文件），
#   那样 v1 检测会把"已签名"误判成"未签名"。所以优先用 apksigner verify。
apk_signed() {
    local apk="$1" signer
    signer="$(find_apksigner_bin 2>/dev/null || true)"
    if [[ -n "$signer" ]]; then
        if "$signer" verify "$apk" >/dev/null 2>&1; then
            printf 'yes'
        else
            printf 'no'
        fi
        return 0
    fi
    # 没有 apksigner 时退回 v1 检测（可能漏判 v2-only，故标为 unknown）
    have_cmd unzip || { printf 'unknown'; return 0; }
    if unzip -l "$apk" 2>/dev/null | grep -Eq 'META-INF/[^ ]*\.(RSA|DSA|EC)$'; then
        printf 'yes'
    else
        printf 'unknown'
    fi
}

# ---------------------------------------------------------------------------
# 收集产物
# ---------------------------------------------------------------------------
ARTIFACT_LIST=()

collect_artifacts() {
    local d f
    for d in "$PACKAGING_DIR" "$PROJECT_ROOT/dist"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            ARTIFACT_LIST+=("$f")
        done < <(find "$d" -maxdepth 1 -type f \
            \( -iname '*.apk' -o -iname '*.aab' \) -print0 2>/dev/null)
    done
}

# ---------------------------------------------------------------------------
# 计算状态
# ---------------------------------------------------------------------------
compute_state() {
    CUR_FP="$(krita_build_fingerprint)"

    BUILD_STAMP_OK=0
    if stamp_matches "$BUILD_STAMP_FILE" "$CUR_FP"; then BUILD_STAMP_OK=1; fi

    # 打包 stamp 的内容是 "<编译指纹>|aab=N"，比较前必须剥掉后缀
    # （否则永远判为未命中 —— 这个坑已经踩过一次）
    PACKAGE_STAMP_OK=0
    PACKAGE_STAMP_RAW=""
    PACKAGE_STAMP_AAB="-"
    PACKAGE_STAMP_TYPE="-"
    if [[ -s "$PACKAGE_STAMP_FILE" ]]; then
        PACKAGE_STAMP_RAW="$(cat -- "$PACKAGE_STAMP_FILE" 2>/dev/null || true)"
        # 后缀可能是 "|aab=0" 或 "|aab=0|type=release"，都要能解析
        case "$PACKAGE_STAMP_RAW" in
            *'|aab=1'*) PACKAGE_STAMP_AAB=1 ;;
            *'|aab=0'*) PACKAGE_STAMP_AAB=0 ;;
        esac
        case "$PACKAGE_STAMP_RAW" in
            *'|type=nightly'*) PACKAGE_STAMP_TYPE=nightly ;;
            *'|type=release'*) PACKAGE_STAMP_TYPE=release ;;
            *'|aab='*)         PACKAGE_STAMP_TYPE=debug ;;
        esac
        if [[ "$(krita_stamp_base_fingerprint "$PACKAGE_STAMP_RAW")" == "$CUR_FP" ]]; then
            PACKAGE_STAMP_OK=1
        fi
    fi

    BUILD_ART_OK=0
    if build_artifacts_present; then BUILD_ART_OK=1; fi

    # stamp 里记录要过 AAB 时，AAB 也必须还在
    # 注意：set -e 下不能写 "cmd && VAR=1"（cmd 失败会让脚本直接退出）
    PACKAGE_ART_OK=0
    local want_aab=0
    if [[ "$PACKAGE_STAMP_AAB" == "1" ]]; then
        want_aab=1
    fi
    if package_artifacts_present "$want_aab"; then
        PACKAGE_ART_OK=1
    fi

    INST_ABI="$(installed_abi 2>/dev/null || true)"
    [[ -n "$INST_ABI" ]] || INST_ABI='（未安装）'

    COMPILER="$(current_compiler_id 2>/dev/null || echo unknown)"
    SRC_HEAD="$(git_head_of "$KRITA_SRC")"
    SRC_BRANCH="$(git_branch_of "$KRITA_SRC")"
    SRC_DIRTY="$(git_dirty_of "$KRITA_SRC")"
    DEPS_HEAD="$(git_head_of "$DEPS_MGMT_DIR")"
    DISK_FREE="$(free_space_gb "$PROJECT_ROOT")"

    BUILD_DIR_SIZE="$(size_of "$BUILD_DIR")"
    INSTALL_SIZE="$(size_of "$KRITA_INSTALL_DIR")"
    PACKAGING_SIZE="$(size_of "$PACKAGING_DIR")"
    DIST_SIZE="$(size_of "$PROJECT_ROOT/dist")"
}

# ---------------------------------------------------------------------------
# JSON 输出
# ---------------------------------------------------------------------------
print_json() {
    local first=1 a size so signed
    printf '{\n'
    printf '  "time": "%s",\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '  "config": {"abi": "%s", "api": "%s", "platform": "%s", "build_type": "%s", "jobs": %s, "branch": "%s"},\n' \
        "$(jstr "$KDECI_ANDROID_ABI")" "$(jstr "$ANDROID_API")" \
        "$(jstr "${ANDROID_PLATFORM:-}")" "$(jstr "$KRITA_CMAKE_BUILD_TYPE")" \
        "${KRITA_JOB_COUNT:-0}" "$(jstr "$KRITA_BRANCH")"
    printf '  "paths": {"source": "%s", "build": "%s", "install": "%s", "packaging": "%s", "dist": "%s"},\n' \
        "$(jstr "$KRITA_SRC")" "$(jstr "$BUILD_DIR")" "$(jstr "$KRITA_INSTALL_DIR")" \
        "$(jstr "$PACKAGING_DIR")" "$(jstr "$PROJECT_ROOT/dist")"
    printf '  "source": {"krita_head": "%s", "branch": "%s", "dirty_count": %s, "deps_head": "%s"},\n' \
        "$(jstr "$SRC_HEAD")" "$(jstr "$SRC_BRANCH")" "${SRC_DIRTY:-0}" "$(jstr "$DEPS_HEAD")"
    printf '  "toolchain": {"ndk": "%s", "compiler": "%s", "installed_abi": "%s", "abi_match": %s},\n' \
        "$(jstr "${KDECI_ANDROID_NDK_ROOT:-}")" "$(jstr "$COMPILER")" \
        "$(jstr "$INST_ABI")" "$([[ "$INST_ABI" == "$KDECI_ANDROID_ABI" ]] && echo true || echo false)"
    printf '  "incremental": {"build_stamp_match": %s, "build_artifacts": %s, "package_stamp_match": %s, "package_artifacts": %s, "up_to_date": %s},\n' \
        "$([[ $BUILD_STAMP_OK == 1 ]] && echo true || echo false)" \
        "$([[ $BUILD_ART_OK == 1 ]] && echo true || echo false)" \
        "$([[ $PACKAGE_STAMP_OK == 1 ]] && echo true || echo false)" \
        "$([[ $PACKAGE_ART_OK == 1 ]] && echo true || echo false)" \
        "$([[ $BUILD_STAMP_OK == 1 && $BUILD_ART_OK == 1 && $PACKAGE_STAMP_OK == 1 && $PACKAGE_ART_OK == 1 ]] && echo true || echo false)"
    printf '  "sizes": {"build_dir": "%s", "install": "%s", "packaging": "%s", "dist": "%s"},\n' \
        "$(jstr "$BUILD_DIR_SIZE")" "$(jstr "$INSTALL_SIZE")" \
        "$(jstr "$PACKAGING_SIZE")" "$(jstr "$DIST_SIZE")"
    printf '  "disk_free_gb": %s,\n' "${DISK_FREE:-0}"
    printf '  "artifacts": ['
    local f
    for f in ${ARTIFACT_LIST[@]+"${ARTIFACT_LIST[@]}"}; do
        size="$(bytes_of "$f")"
        so="$(apk_so_count "$f")"
        signed="$(apk_signed "$f")"
        [[ $first == 1 ]] || printf ','
        first=0
        printf '\n    {"path": "%s", "size_bytes": %s, "mtime": "%s", "so_count": %s, "signed": "%s"}' \
            "$(jstr "$f")" "$size" "$(mtime_of "$f")" \
            "$([[ "$so" == "-" ]] && echo null || echo "$so")" "$signed"
    done
    [[ $first == 1 ]] || printf '\n  '
    printf ']\n'
    printf '}\n'
}

# ---------------------------------------------------------------------------
# 人类可读输出
# ---------------------------------------------------------------------------
print_human() {
    hr
    printf '  %s构建产物报告%s   %s\n' "$C_BOLD" "$C_RESET" "$(date '+%Y-%m-%d %H:%M:%S')"
    hr

    if (( QUIET == 0 )); then
        printf '%s配置%s\n' "$C_BOLD" "$C_RESET"
        printf '  ABI              : %s\n' "$KDECI_ANDROID_ABI"
        printf '  API / 平台       : %s / %s\n' "$ANDROID_API" "${ANDROID_PLATFORM:-?}"
        printf '  构建类型         : %s\n' "$KRITA_CMAKE_BUILD_TYPE"
        printf '  并行任务         : %s\n' "${KRITA_JOB_COUNT:-?}"
        printf '  分支             : %s\n' "$KRITA_BRANCH"
        printf '\n%s路径%s\n' "$C_BOLD" "$C_RESET"
        printf '  源码             : %s\n' "$KRITA_SRC"
        printf '  _build           : %s\n' "$BUILD_DIR"
        printf '  _install         : %s\n' "$KRITA_INSTALL_DIR"
        printf '  _packaging       : %s\n' "$PACKAGING_DIR"
        printf '  dist             : %s\n' "$PROJECT_ROOT/dist"
        printf '\n%s源码状态%s\n' "$C_BOLD" "$C_RESET"
        printf '  krita HEAD       : %s\n' "$SRC_HEAD"
        if [[ "${SRC_DIRTY:-0}" == "0" ]]; then
            printf '  未提交改动       : 无\n'
        else
            printf '  未提交改动       : %s 个文件（会触发重新编译）\n' "$SRC_DIRTY"
        fi
        printf '  deps HEAD        : %s\n' "$DEPS_HEAD"
        printf '\n%s工具链%s\n' "$C_BOLD" "$C_RESET"
        printf '  NDK              : %s\n' "${KDECI_ANDROID_NDK_ROOT:-（未找到）}"
        printf '  编译器           : %s\n' "$COMPILER"
        if [[ "$INST_ABI" == "$KDECI_ANDROID_ABI" ]]; then
            printf '  _install 的 ABI  : %s  %s[与配置一致]%s\n' "$INST_ABI" "$C_GREEN" "$C_RESET"
        else
            printf '  _install 的 ABI  : %s  %s[与配置 %s 不一致 → 需重新 deps]%s\n' \
                "$INST_ABI" "$C_YELLOW" "$KDECI_ANDROID_ABI" "$C_RESET"
        fi
        printf '\n'
    fi

    printf '%s增量状态%s\n' "$C_BOLD" "$C_RESET"
    if (( BUILD_STAMP_OK == 1 )); then
        printf '  编译指纹         : %s命中%s（源码/配置未变，build 会跳过）\n' "$C_GREEN" "$C_RESET"
    else
        printf '  编译指纹         : %s未命中%s（build 会重新编译）\n' "$C_YELLOW" "$C_RESET"
        if [[ -s "$BUILD_STAMP_FILE" ]]; then
            fp_diff "$(cat "$BUILD_STAMP_FILE")" "$CUR_FP" || true
        else
            printf '  - 没有 stamp 文件（从未成功编译过，或执行过 clean）\n'
        fi
    fi
    if (( BUILD_ART_OK == 1 )); then
        printf '  编译产物         : %s齐全%s（_install/lib/libkrita*.so）\n' "$C_GREEN" "$C_RESET"
    else
        printf '  编译产物         : %s缺失%s（_install/lib 里没有 libkrita*.so）\n' "$C_RED" "$C_RESET"
    fi

    if (( PACKAGE_STAMP_OK == 1 )); then
        printf '  打包指纹         : %s命中%s（apk 会跳过 Gradle；stamp 记录 aab=%s type=%s）\n' \
            "$C_GREEN" "$C_RESET" "$PACKAGE_STAMP_AAB" "$PACKAGE_STAMP_TYPE"
    else
        printf '  打包指纹         : %s未命中%s（apk 会重新打包）\n' "$C_YELLOW" "$C_RESET"
        if [[ -n "$PACKAGE_STAMP_RAW" ]]; then
            fp_diff "$(krita_stamp_base_fingerprint "$PACKAGE_STAMP_RAW")" "$CUR_FP" || true
        else
            printf '  - 没有 stamp 文件\n'
        fi
    fi
    if (( PACKAGE_ART_OK == 1 )); then
        printf '  打包产物         : %s存在%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '  打包产物         : %s缺失%s（_packaging 下没有 apk）\n' "$C_RED" "$C_RESET"
    fi

    printf '\n%s产物%s\n' "$C_BOLD" "$C_RESET"
    if ((${#ARTIFACT_LIST[@]} == 0)); then
        printf '  %s（没有任何 APK / AAB）%s\n' "$C_YELLOW" "$C_RESET"
    else
        local f so signed
        for f in "${ARTIFACT_LIST[@]}"; do
            so="$(apk_so_count "$f")"
            signed="$(apk_signed "$f")"
            printf '  %s\n' "$(basename -- "$f")"
            printf '    大小 %-8s  .so %-5s  签名 %-4s  %s\n' \
                "$(size_of "$f")" "$so" \
                "$(case "$signed" in yes) echo 已签 ;; no) echo 未签 ;; *) echo 未知 ;; esac)" \
                "$(mtime_of "$f")"
            printf '    路径 %s\n' "$f"
        done
    fi

    if (( QUIET == 0 )); then
        printf '\n%s体积 / 磁盘%s\n' "$C_BOLD" "$C_RESET"
        printf '  _build           : %s\n' "$BUILD_DIR_SIZE"
        printf '  _install         : %s\n' "$INSTALL_SIZE"
        printf '  _packaging       : %s\n' "$PACKAGING_SIZE"
        printf '  dist             : %s\n' "$DIST_SIZE"
        printf '  剩余磁盘         : %s GB\n' "${DISK_FREE:-?}"
    fi

    hr
    if (( BUILD_STAMP_OK == 1 && BUILD_ART_OK == 1 && PACKAGE_STAMP_OK == 1 && PACKAGE_ART_OK == 1 )); then
        printf '  结论: %s一切都是最新的%s —— 迭代改代码后直接 %s./build-android.sh dev%s\n' \
            "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    elif (( BUILD_ART_OK == 1 )); then
        printf '  结论: %s需要重新打包%s —— 直接 %s./build-android.sh apk%s（编译可复用）\n' \
            "$C_YELLOW" "$C_RESET" "$C_BOLD" "$C_RESET"
    else
        printf '  结论: %s需要完整编译%s —— %s./build-android.sh all%s（或 build 后 apk）\n' \
            "$C_YELLOW" "$C_RESET" "$C_BOLD" "$C_RESET"
    fi
    hr
}

main() {
    while (($#)); do
        case "$1" in
            --json)    JSON=1 ;;
            --quiet|-q) QUIET=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    compute_state
    collect_artifacts

    if (( JSON == 1 )); then
        print_json
    else
        print_human
    fi

    if (( BUILD_STAMP_OK == 1 && BUILD_ART_OK == 1 && \
          PACKAGE_STAMP_OK == 1 && PACKAGE_ART_OK == 1 )); then
        return 0
    fi
    return 1
}

main "$@"
