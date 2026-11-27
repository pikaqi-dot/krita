# =============================================================================
#  docker/Dockerfile —— Krita for Android 的构建容器（可选）
#
#  说明：
#    * 这个镜像只提供"编译工具链"，不含 Android SDK/NDK，也不含预编译依赖；
#      SDK/NDK、源码、依赖缓存都通过 volume 从宿主机挂进来复用。
#    * 运行时建议用 `--user <uid>:<gid>` 覆盖默认用户，避免挂载目录权限错乱。
#
#  构建：
#    docker build -t krita-android-build:local -f docker/Dockerfile docker
#    （或直接 ./build-android.sh docker --build-image）
#
#  国内网络（Docker Hub / archive.ubuntu.com 不通）时可指定镜像源：
#    docker build -t krita-android-build:local -f docker/Dockerfile docker \
#      --build-arg BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04 \
#      --build-arg APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
#    （或设置 KRITA_DOCKER_BASE_IMAGE / KRITA_DOCKER_APT_MIRROR 后用脚本事）
# =============================================================================
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# 可选：替换 apt 源（留空则保持官方源）
ARG APT_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN set -eux; \
    if [ -n "$APT_MIRROR" ]; then \
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
            sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" \
                /etc/apt/sources.list.d/ubuntu.sources; \
        fi; \
        if [ -f /etc/apt/sources.list ]; then \
            sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" \
                /etc/apt/sources.list; \
        fi; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        git \
        curl \
        ca-certificates \
        unzip \
        xz-utils \
        tar \
        gzip \
        gettext \
        gettext-base \
        ccache \
        python3 \
        python3-pip \
        python3-venv \
        openjdk-17-jdk-headless \
        file \
        less; \
    rm -rf /var/lib/apt/lists/*

# 构建期检查：缺任何一个都会让流水线在很后面才报错
RUN cmake --version && ninja --version && javac -version && python3 --version

WORKDIR /workspace
