FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    git git-lfs repo python3 python-is-python3 ccache rsync zip unzip zstd lz4 \
    libssl-dev libxml2-utils xsltproc bc build-essential cmake ninja-build clang lld \
    fontconfig ca-certificates curl locales sudo file tmux xz-utils nano musl \
    pkg-config libpng-dev zlib1g-dev \
    python3-pip python3-mako python3-yaml bison flex glslang-tools libdrm-dev libexpat1-dev \
    libelf-dev dwarves kmod \
    llvm-18-dev libclang-18-dev libclang-cpp18-dev libllvmspirvlib-18-dev spirv-tools \
 && locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*
# Mesa (external/mesa) needs meson >= 1.4; Ubuntu 24.04 has 1.3. Its Android.mk runs meson
# from /usr/bin:/usr/local/bin, past the build's PATH restrictions.
RUN pip3 install --break-system-packages --no-cache-dir meson==1.7.2
ARG UID=1000
RUN userdel -r ubuntu 2>/dev/null; useradd -M -d /build/home -u $UID -s /bin/bash builder \
 && echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder
ENV LANG=en_US.UTF-8 HOME=/build/home USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/build/ccache
USER builder
WORKDIR /build
