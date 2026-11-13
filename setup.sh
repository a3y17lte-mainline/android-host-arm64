#!/bin/bash
# Prepare a synced LineageOS 24.0 tree for native builds on an arm64 Linux host.
#
#   setup.sh [TREE]            patches + prebuilts + checks (TREE defaults to $PWD)
#   setup.sh --patches-only [TREE]
#
# Idempotent: applied patches and installed prebuilts are skipped. Run it again
# after every `repo sync` (sync drops local commits on the detached projects).
# Downloads are cached in ${XDG_CACHE_HOME:-$HOME/.cache}/android-host-arm64.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCHES_ONLY=0
if [ "${1:-}" = --patches-only ]; then PATCHES_ONLY=1; shift; fi
TOP=$(cd "${1:-$PWD}" && pwd)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/android-host-arm64

die() { echo "setup.sh: $*" >&2; exit 1; }
say() { echo "== $*"; }

[ -f "$TOP/build/make/envsetup.sh" ] || die "$TOP is not an Android tree"
cd "$TOP"

# --- 1. Patch series ---------------------------------------------------------
apply_patches() {
	local p proj
	while IFS= read -r p; do
		proj=$(dirname "${p#"$HERE/patches/"}")
		[ -d "$proj/.git" ] || [ -f "$proj/.git" ] || die "project $proj missing"
		if git -C "$proj" apply -R --check "$p" 2>/dev/null; then
			echo "   applied already: $proj/$(basename "$p")"
			continue
		fi
		echo "   applying: $proj/$(basename "$p")"
		if ! git -C "$proj" -c user.name="${GIT_COMMITTER_NAME:-$(git config user.name || echo builder)}" \
			-c user.email="${GIT_COMMITTER_EMAIL:-$(git config user.email || echo builder@localhost)}" \
			am -q --3way --keep-cr "$p"; then
			git -C "$proj" am --abort || true
			die "$p does not apply to $proj: rebase it"
		fi
	done < <(find "$HERE/patches" -name '*.patch' | sort)
}
say "patches"
apply_patches
[ $PATCHES_ONLY = 1 ] && exit 0

[ "$(uname -s)-$(uname -m)" = Linux-aarch64 ] || die "prebuilt setup needs an aarch64 Linux host"
command -v file >/dev/null || die "install 'file'"
mkdir -p "$CACHE"

fetch() { # url sha256 -> path in cache
	local url=$1 sum=$2 out="$CACHE/$(basename "${1//%2B/+}")"
	if [ ! -f "$out" ] || ! echo "$sum  $out" | sha256sum -c --quiet - 2>/dev/null; then
		echo "   downloading $(basename "$out")" >&2
		curl -fsSL --retry 4 -o "$out.part" "$url"
		echo "$sum  $out.part" | sha256sum -c --quiet - || die "checksum mismatch: $url"
		mv "$out.part" "$out"
	fi
	echo "$out"
}

# --- 2. clang: the tree pins clang-rNNN, arm64 is built as clang-rNNNb ------
say "clang"
CLANG=$(sed -n 's/^\s*ClangDefaultVersion\s*=\s*"\(.*\)"/\1/p' build/soong/cc/config/global.go)
CDIR=prebuilts/clang/host/linux-arm64
[ -d "$CDIR" ] || die "$CDIR missing: add local_manifests/host-arm64.xml and repo sync"
if [ ! -e "$CDIR/$CLANG" ]; then
	[ -d "$CDIR/${CLANG}b" ] || die "no arm64 build of $CLANG (or ${CLANG}b) in $CDIR"
	ln -s "${CLANG}b" "$CDIR/$CLANG"
fi
echo "   $CLANG -> $(readlink -f "$CDIR/$CLANG" | xargs basename)"

# --- 3. Go ------------------------------------------------------------------
say "go"
GO_X86=$(head -1 prebuilts/go/linux-x86/VERSION)
GO_ARM=$(head -1 prebuilts/go/linux-arm64/VERSION 2>/dev/null || true)
[ -d prebuilts/go/linux-arm64/pkg/linux_arm64 ] || die "prebuilts/go/linux-arm64 missing or incomplete"
[ "$GO_X86" = "$GO_ARM" ] || echo "   WARNING: go linux-x86 $GO_X86 vs linux-arm64 $GO_ARM"
echo "   $GO_ARM"

# --- 4. JDKs ----------------------------------------------------------------
say "jdk"
J21=prebuilts/jdk/jdk21/linux-arm64
if [ ! -x "$J21/bin/java" ]; then
	# Temurin 21.0.4+7: the tree's linux-x86 JDK is 21.0.4. A real directory,
	# not a symlink: Soong's finder does not follow it.
	t=$(fetch "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.4%2B7/OpenJDK21U-jdk_aarch64_linux_hotspot_21.0.4_7.tar.gz" \
		d768eecddd7a515711659e02caef8516b7b7177fa34880a56398fd9822593a79)
	rm -rf "$J21.tmp" && mkdir -p "$J21.tmp"
	tar -xzf "$t" -C "$J21.tmp" --strip-components=1
	mv "$J21.tmp" "$J21"
fi
echo "   jdk21: $("$J21/bin/java" -version 2>&1 | head -1)"
# JDK 8 is only used for its jars (rt.jar, jce.jar, tools.jar), which are
# architecture independent.
[ -e prebuilts/jdk/jdk8/linux-arm64 ] || ln -s linux-x86 prebuilts/jdk/jdk8/linux-arm64
echo "   jdk8: linux-arm64 -> $(readlink prebuilts/jdk/jdk8/linux-arm64)"

# --- 5. Rust ----------------------------------------------------------------
say "rust"
RUST=$(sed -n 's/^\s*RustDefaultVersion\s*=\s*"\(.*\)"/\1/p' build/soong/rust/config/global.go)
RBASE=prebuilts/rust-toolchain/linux-arm64
RDIR=$RBASE/$RUST
declare -A RSUM=(
	[1.93.1:rust]=701d55b62286bed013ceb2393ff7687d0953205605afaa15c62e2cd18024c32c
	[1.93.1:musl]=d4db571644ffd89f02c3ae33cc9dbfbfadf97f9be60e12d23e08550d5563e475
	[1.93.1:src]=7ade6b2ef03a3b7a614d54df6637a97d18144690bd49daab63bd4b22e0e6bac0
)
if [ ! -x "$RDIR/bin/rustc" ] || [ ! -d "$RDIR/lib/rustlib/aarch64-unknown-linux-musl" ] \
	|| [ ! -d "$RDIR/lib/rustlib/src/rust/library" ]; then
	[ -n "${RSUM[$RUST:rust]:-}" ] || die "no checksums for Rust $RUST: add them to RSUM"
	# rust-lang.org builds: rustc for the glibc host, the musl std (Soong's host
	# triple on arm64 is aarch64-unknown-linux-musl) and the stdlib sources that
	# Soong compiles the device sysroot from.
	rm -rf "$RDIR" "$CACHE/rust-x" && mkdir -p "$CACHE/rust-x"
	for c in "rust-$RUST-aarch64-unknown-linux-gnu:rust" "rust-std-$RUST-aarch64-unknown-linux-musl:musl" "rust-src-$RUST:src"; do
		t=$(fetch "https://static.rust-lang.org/dist/${c%%:*}.tar.xz" "${RSUM[$RUST:${c##*:}]}")
		tar -xJf "$t" -C "$CACHE/rust-x"
		"$CACHE/rust-x/${c%%:*}/install.sh" --prefix="$TOP/$RDIR" --disable-ldconfig >/dev/null
	done
	rm -rf "$CACHE/rust-x"
fi
if [ ! -f "$RBASE/Android.bp" ]; then
	cat > "$RBASE/Android.bp" <<-'EOF'
	// Written by android-host-arm64/setup.sh. The sysroot crates themselves
	// are defined by prebuilts/rust-toolchain/linux-x86/Android.bp.
	rust_stdlib_prebuilt_host {
	    name: "libstd",
	    crate_name: "std",
	    sysroot: true,
	}
	EOF
fi
echo "   $("$RDIR/bin/rustc" --version)"

# --- 6. No x86 binaries where the build looks for host tools ----------------
say "x86 check"
bad=$(find prebuilts/clang/host/linux-arm64/"$CLANG"/ prebuilts/go/linux-arm64 \
	prebuilts/jdk/jdk21/linux-arm64 "$RDIR" prebuilts/build-tools/linux-arm64 \
	prebuilts/build-tools/path/linux-arm64 -type f -perm -u+x -print0 2>/dev/null \
	| xargs -0 -r file -L | grep -E 'ELF 64-bit.*x86-64' || true)
[ -z "$bad" ] || die "x86-64 binaries in arm64 prebuilts:"$'\n'"$bad"
if ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qiE 'x86|amd64'; then
	die "an x86 binfmt_misc handler is registered: x86 binaries would run emulated"
fi
echo "   clean"

say "done: source build/envsetup.sh && source ${HERE#"$TOP/"}/env.sh"
