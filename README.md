# android-host-arm64

Native LineageOS 24.0 (Android 17, `android-17.0.0_r1`) builds on an arm64
Linux host (DGX Spark, Ubuntu 24.04 arm64 container). No x86 emulation.

## Use

```
# once: put local_manifests/host-arm64.xml into .repo/local_manifests/, then
repo sync -c -j8 --no-tags

# after every repo sync
tools/android-host-arm64/setup.sh

# per shell
source build/envsetup.sh
source tools/android-host-arm64/env.sh
```

repo syncs this repo to `tools/android-host-arm64` along with the arm64
clang and Go prebuilts.

`docker/` has the Dockerfile and compose.yaml for `/opt/los`.

## What setup.sh does

1. Applies `patches/<project>/*.patch` with `git am` (skips applied ones).
   `repo sync` drops these local commits, so run it again after a sync.
2. clang: the tree pins `clang-r584948`; AOSP publishes the arm64 build as
   `clang-r584948b`; LineageOS cp2a overrides it to `clang-r596125`. The pinned
   arm64 commit has both; setup.sh links the unsuffixed name.
3. Go: checks `prebuilts/go/linux-arm64` (go1.25.4, same as linux-x86).
4. JDK 21: Temurin 21.0.4+7 aarch64 (the tree's x86 JDK is 21.0.4) into
   `prebuilts/jdk/jdk21/linux-arm64`, sha256-pinned. AOSP has no arm64 JDK 21.
   JDK 8 is only used for its jars: `jdk8/linux-arm64 -> linux-x86`.
5. Rust 1.93.1 from rust-lang.org into `prebuilts/rust-toolchain/linux-arm64`:
   the `aarch64-unknown-linux-musl` toolchain (rustc must run on musl: Soong
   builds host proc-macros for that triple and rustc only loads proc-macros
   for its own host) plus rust-src, and an `Android.bp` for the host `libstd`.
   The AOSP linux-arm64 Rust project is empty. This rustc needs the system
   musl loader (`musl` package, in the Dockerfile) and a musl `libgcc_s.so.1`,
   taken from Alpine's `libgcc` package in `third_party/` (sha256-checked).
   `rustc`, `rustdoc` and `clippy-driver` get a wrapper that sets
   `RUSTC_BOOTSTRAP=1`: Soong passes `-Z` flags, which a stable rust-lang.org
   build rejects, and runs rustc with a cleared environment.
6. Links `prebuilts/clang/host/linux-x86/linux-arm64 -> ../linux-arm64` for the
   patched clang Soong plugin.
7. Fails on any x86-64 binary in the arm64 prebuilts and on an x86
   binfmt_misc handler.

Downloads are cached in `$HOME/.cache/android-host-arm64` (inside `/opt/los`).

## Patches

| Project | Patch | Why |
|---|---|---|
| build/make | envsetup: detect arm64 Linux build hosts | `get_host_prebuilt_prefix` returned linux-x86; `HOST_ARCH` empty |
| build/make | core: use the host's clang prebuilt | `$(BUILD_OS)-x86`/`linux-x86` hardcoded in clang paths; adds `clang/HOST_arm64.mk` |
| build/soong | ui: host's nsjail prebuilt | nsjail path hardcoded to linux-x86, sandbox silently disabled |
| build/soong | rust: host stdlib prebuilt on arm64 | no `linux_musl_arm64` mapping for `rust_stdlib_prebuilt_host`; preferred over the source-built sysroot `libstd` (else both go to Make: `RLIB_LIBRARIES.libstd already defined`) |
| build/soong | android: install under linux-arm64 | host jars installed in `linux_musl-x86` while make reads `linux-arm64` |
| build/soong | android: stage libc_musl.so | built musl host tools could not load libc in the sandbox |
| build/soong | genrule: skip host_second_srcs without a 32-bit host | analysis panic in `art_common_host_test_libs_zip` |
| build/soong | android: stage build-tools libraries in the sandbox | sandboxed bison could not find `libc_musl.so` |
| build/soong | cc: stage m4 as a tool in yacc rules | m4 (an input) did not find the staged `libc_musl.so` |
| build/soong | cc: drop x86 instruction set flags from arm64 host modules | Cronet's generated `-msse3` on every host module |
| build/soong | rust: prebuilt selection sees rlib/dylib srcs | `force_use_prebuilt` never applied, so cc's static `libstd` (`rust_static_std`) got the source-built std while Rust modules got the prebuilt: E0464/E0152 in dex2oatd's generated Rust staticlib |
| prebuilts/build-tools | enable bison/flex/m4/make on arm64 | modules were x86_64-only |
| prebuilts/jdk/jdk21 | enable javap on arm64 | module was x86_64-only |
| system/sepolicy | getopt() results in an int | `char` is unsigned on arm64: `-1` became 255 |
| frameworks/libs/binary_translation | dummy intrinsics generator on arm64 hosts | Berberis disables arm64, so a genrule needed a disabled host tool |
| prebuilts/clang/host/linux-x86 | Soong plugin: llvm tools from linux-arm64 on arm64 hosts | `llvm_prebuilt_build_tool` (llvm-objdump, ...) and `llvm-tools` pointed at x86 binaries |

Checked against LineageOS 24.0 sources (2026-11-13): every patch applies with
`git am`; the Soong changes build with Go 1.25.4 and pass the `android`,
`rust` and `ui/build` package tests (`TestForbiddenVendorLinkage` in `rust`
fails on unpatched LineageOS too). None of this has run a full build yet.

Starting point: Actinis, "Building AOSP on ARM64" (June 2026), which built
AOSP 17 natively on a DGX Spark. Their patches were not published; these are
written against the LineageOS tree from the errors they describe.

## env.sh

- `SKIP_ABI_CHECKS=true`: `prebuilts/clang-tools` (header-abi-dumper) has no
  linux-arm64 build.
- `THINLTO_USE_MLGO=false`: as in the Actinis build.
- ccache from Ubuntu.

## Known open items (fix when the build hits them)

- **Cronet** (`external/cronet`): its `-msse3` is filtered in Soong (above).
  Actinis' x86 `llvm-objdump`/`llvm-nm` finding is covered by the clang
  plugin patch: no Cronet or Connectivity build file or genrule script calls
  them by path in LineageOS 24.0 (checked 2026-11-13).
- **Kernel**: `vendor/lineage` kernel build paths are x86 (`kernel-build-tools`,
  gcc sysroot). Not used with `TARGET_PREBUILT_KERNEL`.
- `vendor/lineage/build/tasks/dt_image.mk` uses `prebuilts/tools-lineage/linux-x86/bin/lz4`
  (only with `BOARD_KERNEL_SEPARATED_DT`).
