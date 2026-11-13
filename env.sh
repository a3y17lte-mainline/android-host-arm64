# Source after build/envsetup.sh on an arm64 build host.

# prebuilts/clang-tools (header-abi-dumper/linker/diff) has no linux-arm64
# build. Skipping ABI checks also skips creating the dumps.
export SKIP_ABI_CHECKS=true

# Per Actinis' Android 17 arm64-host bring-up: the arm64 clang prebuilt is
# used without the MLGO inliner models. Only changes inlining for -Oz code.
export THINLTO_USE_MLGO=false

# Ubuntu's arm64 ccache; the cache lives in the mounted tree.
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
