#!/usr/bin/env bash
# =============================================================================
#  55-sign-apk.sh —— 给已打好的 APK 做 release 签名（zipalign + apksigner）
#
#  为什么不在 Gradle 里签：
#    官方 build-android-package.py 对 release 只跑 `./gradlew assembleRelease`，
#    krita_build_apk/build.gradle 里**没有 signingConfigs**；官方 CI 的签名是
#    在打包之后由外部 notary 服务（ci-notary-service/signapk.py）完成的，
#    并把 *-unsigned.apk 重命名回 *.apk。所以本地要做同样的事：
#       zipalign -> apksigner sign -> apksigner verify
#
#  用法:
#    ./build-android.sh sign                      # 签 _packaging 里最新的 apk
#    ./build-android.sh sign --apk dist/xxx.apk
#    ./build-android.sh sign --keystore my.jks --alias mykey
#    ./build-android.sh sign --verify  --apk dist/xxx-signed.apk
#    ./build-android.sh sign --generate-only      # 只创建本地 keystore
#
#  口令: 优先环境变量 KRITA_KEYSTORE_PASS / KRITA_KEY_PASS，
#        其次 --store-pass / --key-pass，都没有则用内置本地默认值。
#        ⚠ 内置默认值只适合本地调试；对外发布请自带 keystore 并设环境变量。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

FORCE=0
GENERATE_ONLY=0
VERIFY_ONLY=0
APK_IN=""
OUT_PATH=""
KS_PATH=""
ALIAS_NAME="krita"
STORE_PASS="${KRITA_KEYSTORE_PASS:-}"
KEY_PASS="${KRITA_KEY_PASS:-}"
DIALOG_CN="CN=Krita Local Release, OU=Local Build, O=Krita Build Scripts, L=Local, ST=Local, C=CN"
SIGN_WORKDIR=""

usage() {
    cat <<'EOF'
用法: 55-sign-apk.sh [选项]

选项:
  --apk PATH         要签名的 APK（默认：_packaging 下最新的 *.apk）
  --keystore PATH    keystore 路径（默认 config/krita-release.keystore）
  --alias NAME       密钥别名（默认 krita）
  --store-pass PASS  keystore 口令（默认读环境变量 KRITA_KEYSTORE_PASS）
  --key-pass PASS    密钥口令（默认同 store-pass）
  --out PATH         输出文件（默认 dist/<原名>-signed.apk）
  --generate-only    只创建 keystore，不签名
  --verify           只校验签名（可与 --apk 同用）
  --force            keystore / 输出文件已存在时覆盖
  --dry-run          只打印将执行的命令
  -h, --help         显示帮助

签名流程:
  1) zipalign -p -f 4 <输入> <临时文件>     4 字节对齐，.so 页对齐
  2) apksigner sign --ks … --out <输出>     v1+v2+v3 默认全开，替换原签名
  3) apksigner verify --print-certs <输出>  打印签名者与证书指纹

说明:
  官方 release 打包（assembleRelease）产出的名字里带 -unsigned，
  Gradle 里没有 signingConfigs，所以签名必须在这一步补上。
EOF
}

# ---------------------------------------------------------------------------
# 定位工具
# ---------------------------------------------------------------------------
find_apksigner() {
    local v
    # 1) 配置里指定的 build-tools 版本
    v="$KDECI_ANDROID_SDK_ROOT/build-tools/${ANDROID_BUILD_TOOLS:-}/apksigner"
    if [[ -n "${ANDROID_BUILD_TOOLS:-}" && -x "$v" ]]; then
        printf '%s\n' "$v"
        return 0
    fi
    # 2) build-tools 下版本最高的那个
    v="$(ls -1d "$KDECI_ANDROID_SDK_ROOT"/build-tools/*/ 2>/dev/null |
        sort -V | while read -r d; do
            [[ -x "$d/apksigner" ]] && printf '%s\n' "${d%/}/apksigner"
        done | tail -n 1)"
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
    return 1
}

find_zipalign() {
    local signer="$1" d
    d="$(dirname -- "$signer")"
    [[ -x "$d/zipalign" ]] && { printf '%s\n' "$d/zipalign"; return 0; }
    return 1
}

find_keytool() {
    local k java_real
    if k="$(command -v keytool 2>/dev/null)"; then printf '%s\n' "$k"; return 0; fi
    # JDK 装了但 keytool 没进 PATH：跟着 java 找同目录
    java_real="$(command -v java 2>/dev/null || true)"
    if [[ -n "$java_real" ]]; then
        java_real="$(readlink -f "$java_real" 2>/dev/null || printf '%s' "$java_real")"
        k="$(dirname -- "$java_real")/keytool"
        [[ -x "$k" ]] && { printf '%s\n' "$k"; return 0; }
    fi
    # 常见 JDK 安装位置
    for k in /opt/jdk*/bin/keytool /usr/lib/jvm/*/bin/keytool "$HOME"/.sdkman/candidates/java/*/bin/keytool; do
        [[ -x "$k" ]] && { printf '%s\n' "$k"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# 选输入 APK / 输出路径
# ---------------------------------------------------------------------------
pick_apk() {
    if [[ -n "$APK_IN" ]]; then
        [[ -f "$APK_IN" ]] || die "APK 不存在: $APK_IN"
        return 0
    fi
    local f
    f="$(ls -1t "$PACKAGING_DIR"/*.apk 2>/dev/null | head -n 1 || true)"
    if [[ -z "$f" ]]; then
        f="$(ls -1t "$PROJECT_ROOT"/dist/*.apk 2>/dev/null | head -n 1 || true)"
    fi
    [[ -n "$f" ]] || die "找不到任何 APK，请先 ./build-android.sh apk（或用 --apk 指定）"
    APK_IN="$f"
}

default_out() {
    local base dir
    base="$(basename -- "$APK_IN" .apk)"
    dir="$PROJECT_ROOT/dist"
    mkdir -p "$dir" 2>/dev/null || dir="$(dirname -- "$APK_IN")"
    printf '%s/%s-signed.apk\n' "$dir" "$base"
}

# 临时目录放在输出同目录：mv 是原子改名，不会跨文件系统复制 170MB
make_workdir() {
    local parent
    parent="$(dirname -- "$OUT_PATH")"
    mkdir -p "$parent" 2>/dev/null || true
    SIGN_WORKDIR="$(mktemp -d "$parent/.krita-sign.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$SIGN_WORKDIR" ]]; then
        SIGN_WORKDIR="$(mktemp -d 2>/dev/null || printf '%s/krita-sign-%s' "${TMPDIR:-/tmp}" "$$")"
        mkdir -p "$SIGN_WORKDIR"
        warn "无法在输出目录创建临时目录，改用 $SIGN_WORKDIR（mv 可能较慢）"
    fi
    # 注意：不能直接 trap EXIT（会顶掉库里的 krita_on_exit 兜底），要链式调用
    # shellcheck disable=SC2064
    trap 'rm -rf "${SIGN_WORKDIR:-}"; krita_on_exit $?' EXIT
}

# ---------------------------------------------------------------------------
# keystore
# ---------------------------------------------------------------------------
ensure_keystore() {
    local keytool="$1"
    if [[ -f "$KS_PATH" ]]; then
        log "复用已有 keystore: $KS_PATH"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$KS_PATH")" 2>/dev/null || true
    info "创建本地 release keystore（RSA 4096，10000 天）"
    log "路径: $KS_PATH"
    log "别名: $ALIAS_NAME"
    # keytool 只接受命令行口令；apksigner 那一步改用 env: 形式
    run "$keytool" -genkeypair -v \
        -keystore "$KS_PATH" \
        -alias "$ALIAS_NAME" \
        -keyalg RSA -keysize 4096 -validity 10000 \
        -storepass "$STORE_PASS" -keypass "$KEY_PASS" \
        -dname "$DIALOG_CN"
    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        warn "dry-run：未真正创建 keystore"
        return 0
    fi
    [[ -f "$KS_PATH" ]] || die "keystore 创建失败: $KS_PATH"
    chmod 600 "$KS_PATH" 2>/dev/null || true
    ok "keystore 已创建（口令来自环境变量或内置默认值，请自行妥善保管）"
}

verify_apk() {
    local apksigner="$1" apk="$2"
    [[ -f "$apk" ]] || die "要校验的 APK 不存在: $apk"
    "$apksigner" verify --verbose --print-certs "$apk"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
do_sign() {
    local apksigner="$1" zipalign="$2" keytool="$3"
    local aligned tmp_out size

    pick_apk
    [[ -n "$OUT_PATH" ]] || OUT_PATH="$(default_out)"
    [[ "$APK_IN" == "$OUT_PATH" ]] && die "--out 不能和 --apk 相同（会破坏原文件）"

    if [[ -e "$OUT_PATH" ]] && (( FORCE == 0 )) && [[ "$OUT_PATH" -nt "$APK_IN" ]]; then
        warn "输出已存在且比输入新，直接复用: $OUT_PATH"
        warn "（要重新签名请加 --force）"
        if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
            return 0
        fi
        verify_apk "$apksigner" "$OUT_PATH"
        return 0
    fi

    ensure_keystore "$keytool"
    [[ "${KRITA_DRY_RUN:-0}" == "1" ]] || [[ -f "$KS_PATH" ]] || die "缺少 keystore: $KS_PATH"

    make_workdir
    aligned="$SIGN_WORKDIR/aligned.apk"
    tmp_out="$SIGN_WORKDIR/$(basename -- "$OUT_PATH")"

    info "1/3 对齐（zipalign -p -f 4）"
    log "输入: $APK_IN"
    if [[ -n "$zipalign" ]]; then
        run "$zipalign" -p -f 4 "$APK_IN" "$aligned"
    else
        warn "没找到 zipalign，跳过对齐（apksigner 仍可签名）"
        aligned="$APK_IN"
    fi

    info "2/3 签名（apksigner sign）"
    log "keystore: $KS_PATH   别名: $ALIAS_NAME"
    # 用 env: 形式传口令，避免出现在进程命令行里
    export KRITA_KEYSTORE_PASS="$STORE_PASS"
    export KRITA_KEY_PASS="$KEY_PASS"
    run "$apksigner" sign \
        --ks "$KS_PATH" \
        --ks-key-alias "$ALIAS_NAME" \
        --ks-pass env:KRITA_KEYSTORE_PASS \
        --key-pass env:KRITA_KEY_PASS \
        --out "$tmp_out" \
        "$aligned"

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        warn "dry-run：未真正签名"
        return 0
    fi
    [[ -f "$tmp_out" ]] || die "签名失败：没有生成 $tmp_out"

    mv -f "$tmp_out" "$OUT_PATH"
    size="$(du_size "$OUT_PATH" 2>/dev/null || printf '?')"
    ok "已签名: $OUT_PATH（$size）"

    info "3/3 校验（apksigner verify）"
    verify_apk "$apksigner" "$OUT_PATH"

    if [[ -d "$PROJECT_ROOT/dist" && "$(dirname -- "$OUT_PATH")" != "$PROJECT_ROOT/dist" ]]; then
        cp -f "$OUT_PATH" "$PROJECT_ROOT/dist/" 2>/dev/null &&
            log "已复制到 dist/: $(basename -- "$OUT_PATH")"
    fi

    hr
    printf '  安装:\n'
    printf '    adb install -r %s\n' "$(native_path "$OUT_PATH" 2>/dev/null || printf '%s' "$OUT_PATH")"
    printf '  再看签名信息:\n'
    printf '    ./build-android.sh sign --verify --apk %s\n' "$OUT_PATH"
    hr
}

main() {
    while (($#)); do
        case "$1" in
            --apk)           shift; [[ $# -gt 0 ]] || die "--apk 需要路径"; APK_IN="$1" ;;
            --keystore)      shift; [[ $# -gt 0 ]] || die "--keystore 需要路径"; KS_PATH="$1" ;;
            --alias)         shift; [[ $# -gt 0 ]] || die "--alias 需要名字"; ALIAS_NAME="$1" ;;
            --store-pass)    shift; [[ $# -gt 0 ]] || die "--store-pass 需要口令"; STORE_PASS="$1" ;;
            --key-pass)      shift; [[ $# -gt 0 ]] || die "--key-pass 需要口令"; KEY_PASS="$1" ;;
            --out)           shift; [[ $# -gt 0 ]] || die "--out 需要路径"; OUT_PATH="$1" ;;
            --generate-only) GENERATE_ONLY=1 ;;
            --verify)        VERIFY_ONLY=1 ;;
            --force)         FORCE=1 ;;
            --dry-run)       KRITA_DRY_RUN=1 ;;
            -h|--help)       usage; exit 0 ;;
            *) die "未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    [[ -n "$KS_PATH" ]] || KS_PATH="$PROJECT_ROOT/config/krita-release.keystore"
    [[ -n "$STORE_PASS" ]] || STORE_PASS="krita-local"
    [[ -n "$KEY_PASS" ]] || KEY_PASS="$STORE_PASS"

    hr
    printf '  %sAPK 签名（release）%s\n' "$C_BOLD" "$C_RESET"

    local apksigner zipalign keytool
    apksigner="$(find_apksigner)" || die "找不到 apksigner —— 请先 ./build-android.sh sdk 装 build-tools"
    zipalign="$(find_zipalign "$apksigner" || true)"
    keytool="$(find_keytool || true)"

    log "apksigner : $apksigner"
    log "zipalign  : ${zipalign:-(未找到，将跳过对齐)}"
    log "keytool   : ${keytool:-(未找到，无法创建 keystore)}"

    if (( VERIFY_ONLY == 1 )); then
        [[ -n "$OUT_PATH" && -f "$OUT_PATH" ]] && APK_IN="$OUT_PATH"
        pick_apk
        verify_apk "$apksigner" "$APK_IN"
        ok "签名有效: $APK_IN"
        return 0
    fi

    if (( GENERATE_ONLY == 1 )); then
        [[ -n "$keytool" ]] || die "找不到 keytool —— 需要 JDK（./build-android.sh check 可看）"
        ensure_keystore "$keytool"
        return 0
    fi

    [[ -n "$keytool" ]] || warn "找不到 keytool：已有 keystore 仍可签名，但无法自动创建"
    do_sign "$apksigner" "$zipalign" "$keytool"
}

main "$@"
