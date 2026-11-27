#!/usr/bin/env bash
# =============================================================================
#  build-android.sh —— Krita for Android 构建脚本统一入口
#
#  用法:
#    ./build-android.sh <命令> [参数]
#
#  命令:
#    check      环境前置检查            -> scripts/00-check-prereqs.sh
#    sdk        安装 Android SDK / NDK  -> scripts/10-setup-sdk.sh
#    sources    克隆 Krita 源码与仓库   -> scripts/20-fetch-sources.sh
#    deps       准备构建环境            -> scripts/30-fetch-deps.sh
#    build      cmake 配置 + 编译安装   -> scripts/40-build-krita.sh
#    apk        打包 APK（--aab 亦可）  -> scripts/50-build-package.sh
#    dev        迭代重建 + 安装 + 启动  -> scripts/70-dev-rebuild.sh
#    all        一键完整流程            -> scripts/90-build-all.sh
#    docker     在 Docker 容器内构建（可选）-> scripts/60-docker-build.sh
#    wsl        Windows 下用 WSL2 执行  -> scripts/99-wsl-build.sh
#    wsl-install WSL 发行版内装工具链   -> scripts/95-wsl-install-deps.sh
#    wsl-network WSL 网络/代理修复      -> scripts/94-wsl-network.sh
#    wsl-oneclick 一键：环境准备 + 构建 -> scripts/96-wsl-oneclick.sh
#    clean      清理产物/缓存           -> scripts/clean.sh
#    clean-logs 删除所有 *.log / *.txt  -> scripts/clean-logs.sh
#    env        打印当前解析出的所有变量
#
#  典型流程:
#    ./build-android.sh check
#    ./build-android.sh sdk
#    ./build-android.sh sources
#    ./build-android.sh deps
#    ./build-android.sh build
#    ./build-android.sh apk
#
#  Windows 用户（Git Bash）推荐:
#    ./build-android.sh wsl --check
#    ./build-android.sh wsl all
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/android-env.sh
source "$SCRIPT_DIR/scripts/lib/android-env.sh"

# Windows 上双击 .sh（或 cmd 里直接跑）时，失败也保持窗口，避免"闪退"
install_failure_hold

usage() {
    cat <<'EOF'
Krita for Android 构建脚本

用法:
  ./build-android.sh <命令> [参数]

命令:
  check      环境前置检查（Java 17 / Python >= 3.10 / cmake / 磁盘空间等）
  sdk        安装 Android cmdline-tools、NDK r22b、SDK 组件
  sources    克隆 krita / krita-deps-management / krita-ci-utilities
  deps       创建 Python venv、生成 base-env 与 env 构建环境
  build      cmake 配置并编译安装 Krita（make -jN install）
  apk        打包 APK（--aab 同时生成 AAB，--release 打 release 包，
             --archive-artifacts 保留中间产物）
  sign       给 APK 做 release 签名（zipalign + apksigner；--verify 只校验）
  dev        增量重建 + gradlew installDebug + 自动启动（需连接真机）
  deb        构建 Linux 桌面版 Krita 并打成 .deb（WSL 里跑；与 Android 流程独立）
  report     构建产物与增量状态报告（体积 / ABI / HEAD / stamp / 剩余磁盘，只读）
  all        一键：check -> sdk -> sources -> deps -> build -> apk
  docker     在 Docker 容器内跑完整流程（可选，默认不用 Docker；需已装 docker）
  wsl        在 Windows 上通过 WSL2 执行上述流程
  wsl-install 在 WSL 发行版内安装构建工具链（apt，免 sudo 密码；会自动先修网络）
  wsl-network 诊断并修复 WSL2 网络/代理（apt、git 超时的根因）
  wsl-oneclick 一键：修网络 + 装工具链 + 完整构建（Windows 上推荐）
  clean      清理构建产物 / 缓存 / SDK
  clean-logs 删除所有 *.log / *.txt（默认跳过 git 跟踪的文件；先列表再确认）
             --list 只看、--keep N 保留最近 N 个、--dirs "A B" 额外目录、-y 不再询问
  env        打印配置文件解析结果

全局环境变量:
  KRITA_ANDROID_CONFIG   指定配置文件（默认 config/android-build.conf）
  KRITA_DRY_RUN=1        只打印命令不执行
  NO_COLOR=1             关闭彩色输出
  KRITA_COPY_TO_DESKTOP  1=打包后额外复制一份 APK 到 Windows 桌面（默认 1）
  KRITA_EXPORT_DIRS      额外复制产物的目录（空格分隔）
  ANDROID_ABI            目标架构（默认 arm64-v8a 真机；armeabi-v7a / x86_64 亦可）
                         ⚠ 切换 ABI 会重新获取该架构依赖并全量重编

常用开关（加在子命令之后，会透传给对应脚本）:
  --resume          自动从"第一个未完成的步骤"继续（中断续跑，已完成的不重做）
  --from N          从第 N 步开始（2=SDK 3=源码 4=依赖 5=编译 6=打包）
  --only N          只执行第 N 步
  --jobs N          并行编译任务数
  --force           忽略增量标记：强制重新编译 + 重新打包
                    （默认 build / apk 会比对"增量指纹"，源码与配置没变化就直接跳过）
  --full-deps       第 4 步完整获取依赖（去掉 --only-env）
  --force-download  强制重新下载已存在的 SDK / NDK 压缩包（默认不重复下载）
  --force-reclone   删除源码目录后重新克隆（默认只做增量更新）
  --clean-build     删除 _build 后全量重编（最彻底；比 --force 慢得多）
  --aab             打包时同时生成 AAB
  --release         打包成 release（gradlew assembleRelease；产物带 -unsigned，需 sign）
  --nightly         打包成 nightly（gradlew assembleNightly）
  --sign            all 跑完后给 APK 签名（release 包必需；等价于再执行 sign）
  --dry-run         只打印命令，不执行

示例:
  ./build-android.sh check --strict
  ./build-android.sh sdk
  ./build-android.sh all --jobs 12
  ./build-android.sh apk --aab
  ./build-android.sh dev --skip-run
  ./build-android.sh docker --build-image        # 首次：构建镜像并开始
  ./build-android.sh docker --from 5 --jobs 8    # 之后：只用容器编译
  ./build-android.sh wsl-install
  ./build-android.sh clean --build --deps
EOF
}

main() {
    local cmd="${1:-help}"
    if [[ $# -gt 0 ]]; then
        shift
    fi

    case "$cmd" in
        check)    exec bash "$SCRIPT_DIR/scripts/00-check-prereqs.sh" "$@" ;;
        sdk)      exec bash "$SCRIPT_DIR/scripts/10-setup-sdk.sh" "$@" ;;
        sources)  exec bash "$SCRIPT_DIR/scripts/20-fetch-sources.sh" "$@" ;;
        deps)     exec bash "$SCRIPT_DIR/scripts/30-fetch-deps.sh" "$@" ;;
        build)    exec bash "$SCRIPT_DIR/scripts/40-build-krita.sh" "$@" ;;
        apk|package) exec bash "$SCRIPT_DIR/scripts/50-build-package.sh" "$@" ;;
        sign)     exec bash "$SCRIPT_DIR/scripts/55-sign-apk.sh" "$@" ;;
        deb|linux-deb)
                  if is_windows_shell; then
                      # Linux 桌面构建必须在 Linux 里做；Windows 上自动转给 WSL
                      exec bash "$SCRIPT_DIR/scripts/99-wsl-build.sh" \
                          --shell ./scripts/65-build-linux-deb.sh "$@"
                  fi
                  exec bash "$SCRIPT_DIR/scripts/65-build-linux-deb.sh" "$@"
                  ;;
        dev)      exec bash "$SCRIPT_DIR/scripts/70-dev-rebuild.sh" "$@" ;;
        report|status) exec bash "$SCRIPT_DIR/scripts/report.sh" "$@" ;;
        all)      exec bash "$SCRIPT_DIR/scripts/90-build-all.sh" "$@" ;;
        docker)
                  # Windows/Git Bash 上没有可用的 docker 路径语义，统一交给 WSL2
                  if is_windows_shell; then
                      exec bash "$SCRIPT_DIR/scripts/99-wsl-build.sh" \
                          --shell ./scripts/60-docker-build.sh "$@"
                  fi
                  exec bash "$SCRIPT_DIR/scripts/60-docker-build.sh" "$@"
                  ;;
        wsl)      exec bash "$SCRIPT_DIR/scripts/99-wsl-build.sh" "$@" ;;
        wsl-install|wsl-deps)
                  exec bash "$SCRIPT_DIR/scripts/95-wsl-install-deps.sh" "$@" ;;
        wsl-network|wsl-net)
                  exec bash "$SCRIPT_DIR/scripts/94-wsl-network.sh" "$@" ;;
        wsl-oneclick|wsl-build|oneclick)
                  exec bash "$SCRIPT_DIR/scripts/96-wsl-oneclick.sh" "$@" ;;
        clean)    exec bash "$SCRIPT_DIR/scripts/clean.sh" "$@" ;;
        clean-logs|clean-logs-*|logs-clean)
                  exec bash "$SCRIPT_DIR/scripts/clean-logs.sh" "$@" ;;
        env)
            load_config
            print_env
            ;;
        help|-h|--help) usage ;;
        *)
            err "未知命令: $cmd"
            printf '\n'
            usage
            exit 1
            ;;
    esac
}

main "$@"
