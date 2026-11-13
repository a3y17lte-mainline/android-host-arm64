FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    git git-lfs repo python3 python-is-python3 ccache rsync zip unzip zstd lz4 \
    libssl-dev libxml2-utils xsltproc bc build-essential cmake ninja-build clang lld \
    fontconfig ca-certificates curl locales sudo file tmux xz-utils nano musl \
 && locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*
ARG UID=1000
RUN userdel -r ubuntu 2>/dev/null; useradd -M -d /build/home -u $UID -s /bin/bash builder \
 && echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder
ENV LANG=en_US.UTF-8 HOME=/build/home USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/build/ccache
USER builder
WORKDIR /build
