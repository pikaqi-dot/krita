#!/usr/bin/env bash
# =============================================================================
#  60-docker-build.sh —— 在 Docker 容器里执行构建（可选方式，默认不走 Docker）
#
#  为什么需要：
#    * 官方要求用 Linux 构建；Docker 提供可复现的干净工具链环境；
#    * 适合 CI、或在没有 WSL 的机器上做同样的事。
#
#  设计要点：
#    * 镜像只提供编译工具链（见 docker/Dockerfile），SDK/NDK、源码、依赖缓存、
#      ccache、Gradle 缓存全部以 volume 形式复用宿主机，避免重复下载。
#    * 容器内使用"与宿主机完全相同的绝对路径"（-v /path:/path），
#      这样 env 文件、CMake 缓存、绝对路径符号链接都不会错乱。
#    * 构建流仍是同一套脚本：容器内执行 ./scripts/90-build-all.sh <参数>。
#    * 宿主机与容器编译器不同（gcc 版本）时，40-build-krita.sh 会自动清空
#      _build 重配（见 .krita-compiler 标记），不会出现"混编"错误。
#
#  用法:
#    ./build-android.sh docker                      # 完整流程（默认不开）
#    ./build-android.sh docker --from 5 --jobs 8
#    ./build-android.sh docker --build-image        # 顺便构建/更新镜像
#    ./scripts/60-docker-build.sh --shell ./scripts/50-build-package.sh
#
#  Windows（Git Bash）下请用 build-android.sh docker，它会自动转给 WSL2。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-env.sh
source "$SCRIPT_DIR/lib/android-env.sh"
load_config

IMAGE="${KRITA_DOCKER_IMAGE:-krita-android-build:local}"
DOCKERFILE="$PROJECT_ROOT/docker/Dockerfile"
BUILD_IMAGE=0
FORCE_BUILD_IMAGE=0
NO_CACHE=0
STEP_SCRIPT="./scripts/90-build-all.sh"
PASSTHRU=()

usage() {
    cat <<'EOF'
用法: 60-docker-build.sh [选项] [-- 透传给 90-build-all.sh 的参数]

选项:
  --image NAME         指定镜像（默认 $KRITA_DOCKER_IMAGE 或 krita-android-build:local）
  --build-image        构建镜像后立即使用（镜像已存在则复用）
  --force-build-image  强制重建镜像（相当于 --build-image --no-cache）
  --no-cache           docker build 时不使用缓存
  --shell SCRIPT       容器内执行的脚本（默认 ./scripts/90-build-all.sh）
  --dry-run            只打印将执行的 docker 命令
  -h, --help           显示帮助

环境变量:
  KRITA_DOCKER_IMAGE   镜像名（默认 krita-android-build:local）
  KRITA_DOCKER_EXTRA   追加给 docker run 的额外参数（空格分隔，例如 "-m 16g"）

说明:
  * 默认**不走 Docker**；只有显式执行 `docker` 子命令才会用容器。
  * 宿主机的 SDK/NDK、源码、依赖缓存都会挂进容器，不会重复下载。
  * 首次使用镜像不存在时，脚本会提示先执行 --build-image（不会擅自下载基础镜像）。
EOF
}

require_docker() {
    if ! have_cmd docker; then
        err "未找到 docker 命令"
        printf '  WSL 里安装： sudo apt install -y docker.io   （或用 Docker Desktop 的 WSL 集成）\n'
        printf '  安装后确认： docker info\n'
        die "Docker 不可用"
    fi
    if ! docker info >/dev/null 2>&1; then
        err "docker 守护进程不可用（docker info 失败）"
        printf '  WSL（无 Docker Desktop）： sudo service docker start\n'
        printf '  或用 Docker Desktop：在设置里启用 WSL Integration\n'
        die "Docker 守护进程未运行"
    fi
}

image_exists() {
    docker image inspect "$1" >/dev/null 2>&1
}

build_image() {
    [[ -f "$DOCKERFILE" ]] || die "未找到 Dockerfile: $DOCKERFILE"

    local args=(build -t "$IMAGE" -f "$DOCKERFILE")
    if (( NO_CACHE == 1 )); then
        args+=(--no-cache)
    fi

    # 国内网络：Docker Hub / archive.ubuntu.com 常被墙，可换镜像源
    if [[ -n "${KRITA_DOCKER_BASE_IMAGE:-}" ]]; then
        args+=(--build-arg "BASE_IMAGE=$KRITA_DOCKER_BASE_IMAGE")
    fi
    if [[ -n "${KRITA_DOCKER_APT_MIRROR:-}" ]]; then
        args+=(--build-arg "APT_MIRROR=$KRITA_DOCKER_APT_MIRROR")
    fi
    args+=("$(dirname "$DOCKERFILE")")

    hr
    info "构建镜像: $IMAGE"
    log "docker ${args[*]}"

    if [[ "${KRITA_DRY_RUN:-0}" == "1" ]]; then
        run docker "${args[@]}"
        ok "DRY-RUN: 跳过镜像构建"
        return 0
    fi

    local logf="$PROJECT_ROOT/logs/docker-build.log"
    mkdir -p "$PROJECT_ROOT/logs"
    local rc=0

    # 注意：脚本开了 pipefail + set -e，直接 `docker | tee` 会在失败时立刻退出，
    # 所以这里临时关掉 errexit，自己用 PIPESTATUS 取 docker 的真实退出码。
    set +e
    docker "${args[@]}" 2>&1 | tee "$logf"
    rc=${PIPESTATUS[0]}

    # Docker Hub 被墙时自动改用国内镜像源重试一次（仅当用户没有显式指定时）
    if (( rc != 0 )) && [[ -z "${KRITA_DOCKER_BASE_IMAGE:-}" ]] &&
        grep -qiE 'registry-1\.docker\.io|failed to resolve source metadata|authorization failed' "$logf"; then
        warn "访问 Docker Hub 失败（registry-1.docker.io），自动改用国内镜像源重试"
        args+=("--build-arg" "BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04")
        log "docker ${args[*]}"
        docker "${args[@]}" 2>&1 | tee "$logf"
        rc=${PIPESTATUS[0]}
        if (( rc == 0 )); then
            ok "已通过镜像源完成构建（下次可直接设 KRITA_DOCKER_BASE_IMAGE 免去探测）"
        fi
    fi
    set -e

    if (( rc != 0 )); then
        err "镜像构建失败（完整日志: $logf）"
        printf '  常见原因与处理：\n'
        printf '   1) 拉不到 ubuntu:24.04（Docker Hub 被墙 / 需要代理）\n'
        printf '      %sKRITA_DOCKER_BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04 \\\n' "$C_BOLD"
        printf '      ./build-android.sh docker --build-image%s\n' "$C_RESET"
        printf '   2) apt 慢或超时：加 KRITA_DOCKER_APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu\n'
        printf '   3) 磁盘空间不足： docker system prune -a\n'
        printf '   4) Docker Desktop 用代理：Settings → Resources → Proxies 里配置并 Apply\n'
        die "镜像构建失败"
    fi
    ok "镜像已就绪: $IMAGE"
}

# 需要与宿主机保持一致的目录（绝对路径挂载，容器内路径完全相同）
collect_mounts() {
    local -a mounts=("$PROJECT_ROOT" "$WORKDIR" "$ANDROID_ROOT")

    # Gradle 缓存（避免每次重新下载 Maven 依赖）；不存在就创建
    mkdir -p "$HOME/.gradle" 2>/dev/null || true
    [[ -d "$HOME/.gradle" ]] && mounts+=("$HOME/.gradle")

    # 桌面目录：打包后要往这里复制 APK（不挂载的话容器内不可写）
    if [[ "${KRITA_COPY_TO_DESKTOP:-1}" != "0" && -n "${KRITA_DESKTOP_DIR:-}" && -d "$KRITA_DESKTOP_DIR" ]]; then
        mounts+=("$KRITA_DESKTOP_DIR")
    fi

    printf '%s\n' "${mounts[@]}" | awk '!seen[$0]++'
}

collect_env_args() {
    local -a out=()
    local v val
    for v in \
        ANDROID_ABI ANDROID_API ANDROID_PLATFORM ANDROID_NDK_VERSION ANDROID_BUILD_TOOLS \
        ANDROID_EXTRA_PACKAGES ANDROID_ROOT \
        WORKDIR SRCDIR ENVDIR \
        KRITA_BRANCH KRITA_CMAKE_BUILD_TYPE KRITA_JOB_COUNT KRITA_FETCH_FULL_DEPS \
        KRITA_MIN_FREE_GB KRITA_COPY_TO_DESKTOP KRITA_EXPORT_DIRS KRITA_DESKTOP_DIR \
        KRITA_ANDROID_CONFIG KRITA_DEPS_RETRIES \
        KDECI_ANDROID_ABI KDECI_ANDROID_SDK_ROOT KDECI_ANDROID_NDK_ROOT \
        KDECI_WORKDIR_PATH KDECI_SHARED_INSTALL_PATH KDECI_CACHE_PATH \
        http_proxy https_proxy all_proxy no_proxy \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
        val="${!v-}"
        [[ -n "$val" ]] && out+=(-e "$v=$val")
    done
    # venv 与宿主机分开：Ubuntu 24.04 是 python 3.12，宿主 Debian 是 3.13，
    # 复用同一个 venv 会拿到失效的解释器符号链接
    out+=(-e "VENVDIR=$WORKDIR/PythonEnv-docker")

    # 容器内不再挂窗口；避免 .bat 那套"失败保持窗口"
    out+=(-e "KRITA_HOLD=0" -e "KRITA_DOCKER=1")
    printf '%s\n' "${out[@]}"
}

run_container() {
    local -a args=(run --rm)

    # 交互终端（手动在终端里跑时）：允许 Ctrl+C、能看到彩色输出
    if [[ -t 0 && -t 1 ]]; then
        args+=(-it)
    fi

    # Linux 上用 host 网络，容器可直接访问宿主机代理（172.x.x.x:7890）
    if is_linux; then
        args+=(--network host)
    fi

    if [[ -n "${KRITA_DOCKER_EXTRA:-}" ]]; then
        # shellcheck disable=SC2206
        args+=(${KRITA_DOCKER_EXTRA})
    fi

    # 用当前 uid/gid 运行，保证挂载目录里的文件属主正确
    args+=(--user "$(id -u):$(id -g)" -e "HOME=$HOME")

    local m
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        args+=(-v "$m:$m")
    done < <(collect_mounts)

    local e
    while IFS= read -r e; do
        [[ -n "$e" ]] || continue
        args+=("$e")
    done < <(collect_env_args)

    args+=(-w "$PROJECT_ROOT" "$IMAGE")
    args+=(bash "$STEP_SCRIPT" ${PASSTHRU[@]+"${PASSTHRU[@]}"})

    hr
    printf '  %s在 Docker 容器内构建%s\n' "$C_BOLD" "$C_RESET"
    printf '    镜像   : %s\n' "$IMAGE"
    printf '    脚本   : %s %s\n' "$STEP_SCRIPT" "${PASSTHRU[*]-}"
    printf '    项目   : %s\n' "$PROJECT_ROOT"
    printf '    依赖/源码: %s\n' "$WORKDIR"
    printf '    SDK/NDK: %s\n' "$ANDROID_ROOT"
    hr

    log "docker ${args[*]}"
    run docker "${args[@]}"
}

main() {
    local image_set=0
    while (($#)); do
        case "$1" in
            --image)
                shift
                [[ $# -gt 0 ]] || die "--image 需要一个镜像名"
                IMAGE="$1"; image_set=1
                ;;
            --build-image)       BUILD_IMAGE=1 ;;
            --force-build-image) BUILD_IMAGE=1; FORCE_BUILD_IMAGE=1; NO_CACHE=1 ;;
            --no-cache)          NO_CACHE=1 ;;
            --shell)
                shift
                [[ $# -gt 0 ]] || die "--shell 需要一个脚本路径"
                STEP_SCRIPT="$1"
                ;;
            --dry-run)           KRITA_DRY_RUN=1 ;;
            -h|--help)           usage; exit 0 ;;
            --)                  shift; PASSTHRU=("$@"); break ;;
            *)                   PASSTHRU+=("$1") ;;
        esac
        shift
    done
    export KRITA_DRY_RUN="${KRITA_DRY_RUN:-0}"
    (( image_set == 1 )) && export KRITA_DOCKER_IMAGE="$IMAGE"

    hr
    printf '  %sDocker 构建 Krita（Android / %s）%s\n' "$C_BOLD" "$KDECI_ANDROID_ABI" "$C_RESET"

    if [[ "${KRITA_DRY_RUN:-0}" != "1" ]]; then
        require_docker
    fi

    if (( BUILD_IMAGE == 1 )); then
        build_image
    elif [[ "${KRITA_DRY_RUN:-0}" != "1" ]]; then
        if (( FORCE_BUILD_IMAGE == 1 )); then
            build_image
        elif ! image_exists "$IMAGE"; then
            warn "本地没有镜像: $IMAGE"
            printf '  先构建（约 1~2 分钟，需要网络拉取 ubuntu:24.04 与 apt 包）：\n'
            printf '    %s./build-android.sh docker --build-image%s\n' "$C_BOLD" "$C_RESET"
            printf '  或使用你自己的镜像：\n'
            printf '    %sKRITA_DOCKER_IMAGE=你的镜像 ./build-android.sh docker%s\n' "$C_BOLD" "$C_RESET"
            die "镜像不存在"
        fi
    fi

    run_container

    hr
    ok "Docker 构建流程结束"
    if [[ -d "$PROJECT_ROOT/dist" ]]; then
        printf '  产物目录: %s\n' "$PROJECT_ROOT/dist"
    fi
}

main "$@"
