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
# Per project: if the commits on top of the manifest revision (repo's m/ ref)
# are exactly our series, nothing to do. Otherwise (fresh sync, or an older
# version of the series) reset to the manifest revision and apply the series.
apply_patches() {
	local d proj base want have
	while IFS= read -r d; do
		proj=${d#"$HERE/patches/"}
		[ -e "$proj/.git" ] || die "project $proj missing"
		base=$(git -C "$proj" for-each-ref --count=1 --format='%(objectname)' refs/remotes/m/)
		[ -n "$base" ] || die "$proj: no manifest ref (refs/remotes/m/*); is this a repo checkout?"
		want=$(cat "$d"/*.patch | git patch-id --stable | cut -d' ' -f1)
		have=$(git -C "$proj" log --reverse -p --no-color "$base..HEAD" | git patch-id --stable | cut -d' ' -f1)
		if [ "$want" = "$have" ]; then
			echo "   up to date: $proj"
			continue
		fi
		if [ "$(git -C "$proj" rev-parse HEAD)" != "$base" ]; then
			[ -z "$(git -C "$proj" status --porcelain --untracked-files=no)" ] \
				|| die "$proj has uncommitted changes"
			echo "   $proj: dropping $(git -C "$proj" rev-list --count "$base..HEAD") old local commit(s)"
			git -C "$proj" reset -q --hard "$base"
		fi
		echo "   applying: $proj ($(ls "$d"/*.patch | wc -l) patches)"
		if ! git -C "$proj" -c user.name="${GIT_COMMITTER_NAME:-$(git config user.name || echo builder)}" \
			-c user.email="${GIT_COMMITTER_EMAIL:-$(git config user.email || echo builder@localhost)}" \
			am -q --3way --keep-cr "$d"/*.patch; then
			git -C "$proj" am --abort || true
			die "patches/$proj do not apply: rebase them"
		fi
	done < <(find "$HERE/patches" -name '*.patch' -printf '%h\n' | sort -u)
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
# The release config can override the default (LineageOS cp2a: clang-r596125),
# so every version named by Soong or the release flags must exist.
say "clang"
CLANG=$(sed -n 's/^\s*ClangDefaultVersion\s*=\s*"\(.*\)"/\1/p' build/soong/cc/config/global.go)
REL=$(sed -n 's/^aosp_target_release=//p' vendor/lineage/vars/aosp_target_release 2>/dev/null || true)
CVERS="$CLANG"
if [ -n "$REL" ]; then
	CVERS+=" $(cat build/release/flag_values/"$REL"/RELEASE_BUILD_CLANG_VERSION.textproto \
		vendor/lineage/release/flag_values/"$REL"/RELEASE_BUILD_CLANG_VERSION.textproto 2>/dev/null \
		| sed -n 's/.*string_value: *"\(clang-r[^"]*\)".*/\1/p')"
fi
CDIR=prebuilts/clang/host/linux-arm64
[ -d "$CDIR" ] || die "$CDIR missing: add local_manifests/host-arm64.xml and repo sync"
[ ! -e "$CDIR/Android.bp" ] || die "$CDIR/Android.bp exists: it uses module types this Soong lacks; pin the commit from local_manifests/host-arm64.xml"
for v in $(echo $CVERS | tr ' ' '\n' | sort -u); do
	if [ ! -e "$CDIR/$v" ]; then
		[ -d "$CDIR/${v}b" ] || die "no arm64 build of $v (or ${v}b) in $CDIR"
		ln -s "${v}b" "$CDIR/$v"
	fi
	echo "   $v -> $(readlink -f "$CDIR/$v" | xargs basename)"
done

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
	[1.93.1:rust]=34f0ffb0cd3e334aeae344daae09984f951eeb842386406d4bdf11cd0b4c2b36
	[1.93.1:src]=7ade6b2ef03a3b7a614d54df6637a97d18144690bd49daab63bd4b22e0e6bac0
)
# The rustc must run on musl: Soong builds host code, proc-macros included, for
# aarch64-unknown-linux-musl, and rustc only loads proc-macros built for its
# own host triple (a glibc rustc fails with E0463 on serde_derive). Like
# Android's linux-musl-x86 toolchain, but from rust-lang.org: it needs the
# system musl loader and a musl libgcc_s.so.1 (Alpine's, in third_party/).
RFLAVOR="rust-lang $RUST aarch64-unknown-linux-musl"
[ -e /lib/ld-musl-aarch64.so.1 ] || die "/lib/ld-musl-aarch64.so.1 missing: sudo apt-get install musl"
if [ "$(cat "$RDIR/.android-host-arm64" 2>/dev/null)" != "$RFLAVOR" ]; then
	[ -n "${RSUM[$RUST:rust]:-}" ] || die "no checksums for Rust $RUST: add them to RSUM"
	rm -rf "$RDIR" "$CACHE/rust-x" && mkdir -p "$CACHE/rust-x"
	for c in "rust-$RUST-aarch64-unknown-linux-musl:rust" "rust-src-$RUST:src"; do
		t=$(fetch "https://static.rust-lang.org/dist/${c%%:*}.tar.xz" "${RSUM[$RUST:${c##*:}]}")
		tar -xJf "$t" -C "$CACHE/rust-x"
		"$CACHE/rust-x/${c%%:*}/install.sh" --prefix="$TOP/$RDIR" --disable-ldconfig \
			--without=rust-docs,rust-docs-json-preview >/dev/null 2>&1 \
			|| "$CACHE/rust-x/${c%%:*}/install.sh" --prefix="$TOP/$RDIR" --disable-ldconfig >/dev/null
	done
	rm -rf "$CACHE/rust-x"
	echo "369aaa6e9d099a737bad6dd3e6c2fe7bb1547ca26d22b94ee0411228f709b403  $HERE/third_party/libgcc-15.2.0-r5-aarch64.apk" \
		| sha256sum -c --quiet - || die "third_party/libgcc apk checksum mismatch"
	tar -xzf "$HERE/third_party/libgcc-15.2.0-r5-aarch64.apk" -C "$RDIR/lib" --strip-components=2 \
		usr/lib/libgcc_s.so.1 2>/dev/null
	[ -f "$RDIR/lib/libgcc_s.so.1" ] || die "could not install libgcc_s.so.1"
	echo "$RFLAVOR" > "$RDIR/.android-host-arm64"
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
# Soong passes -Z flags. Android's own toolchain accepts them; a rust-lang.org
# stable build only with RUSTC_BOOTSTRAP=1. Soong runs rustc with a cleared
# environment (soong_env -i), so set it in a wrapper next to the binary.
for t in rustc rustdoc clippy-driver; do
	[ -f "$RDIR/bin/$t" ] || continue
	if [ ! -e "$RDIR/bin/$t.real" ]; then
		mv "$RDIR/bin/$t" "$RDIR/bin/$t.real"
		printf '#!/bin/sh\n# android-host-arm64: allow -Z flags on the stable toolchain\nexport RUSTC_BOOTSTRAP=1\nexec "${0%%/*}/%s.real" "$@"\n' "$t" > "$RDIR/bin/$t"
		chmod +x "$RDIR/bin/$t"
	fi
done
echo "   $("$RDIR/bin/rustc" --version), -Z enabled via RUSTC_BOOTSTRAP wrapper"

# --- 6. No x86 binaries where the build looks for host tools ----------------
say "x86 check"
# Only what runs on the host: tool dirs and host libraries. Not target
# runtimes (clang ships x86_64 Android libs, NDK lldb-server) or test data.
C=prebuilts/clang/host/linux-arm64/$CLANG/
hostbins() {
	find "$C"bin "$C"libexec prebuilts/go/linux-arm64/bin prebuilts/go/linux-arm64/pkg/tool \
		prebuilts/jdk/jdk21/linux-arm64/bin prebuilts/jdk/jdk21/linux-arm64/lib \
		"$RDIR"/bin prebuilts/build-tools/linux-arm64 prebuilts/build-tools/path/linux-arm64 \
		-type f -print0 2>/dev/null
	find "$C"lib "$RDIR"/lib -maxdepth 1 -type f -print0 2>/dev/null
}
bad=$(hostbins | xargs -0 -r file -L | grep -E 'ELF 64-bit.*x86-64' || true)
[ -z "$bad" ] || die "x86-64 binaries in arm64 prebuilts:"$'\n'"$bad"
if ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qiE 'x86|amd64'; then
	die "an x86 binfmt_misc handler is registered: x86 binaries would run emulated"
fi
echo "   clean"

say "done: source build/envsetup.sh && source ${HERE#"$TOP/"}/env.sh"
