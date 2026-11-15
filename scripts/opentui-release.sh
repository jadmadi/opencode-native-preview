#!/usr/bin/env bash
# OpenTUI's native library for one Rust target from an OpenTUI release zip, instead of a source build.
#
# Usage: scripts/opentui-release.sh tag <header-fnv1a64> <pin-commit>
#          Prints the release whose zips hold what the pin builds: its opentui.h hashes to <header-fnv1a64> (the pin's
#          OPENTUI_HEADER_FNV1A64), and the pin's packages/native is the release commit's apart from the version in
#          package.json and build.zig.zon. Prints nothing when no release in the tables below qualifies; then build
#          from source (scripts/opentui-native.sh). The header alone is not enough: a pin after a release can change
#          a library and not the header (#2140 changed opentui-static.lib under v0.9.0's header).
#        scripts/opentui-release.sh fetch <tag> <rust-target> <out-dir> <header-fnv1a64>
#          Downloads opentui-native-<tag>-<platform>.zip, checks it against its sha256 below and its opentui.h
#          against <header-fnv1a64>, and installs opentui.h, the libraries opentui-sys reads, every licence and
#          source-notice file the zip ships (under <out-dir>/licenses) and STAMP into <out-dir>.
#
# The zips carry no attestation, so the sha256 table is the control: add a release's rows from
# `gh release view <tag> -R anomalyco/opentui --json assets`, and its commit to the releases table, in the change that
# moves to it.
set -euo pipefail

die() { echo "opentui-release: $*" >&2; exit 1; }

# tag, and the commit its zips were built from.
releases() {
  cat <<'EOF'
v0.9.0 0c48678dddcc6a371c0783f26735f5ed788f8ccb
EOF
}

# tag, header FNV-1a 64 of its opentui.h, platform, sha256 of opentui-native-<tag>-<platform>.zip.
table() {
  cat <<'EOF'
v0.9.0 0xfcf352f7f1c874b8 linux-x64 12106d9a5998f0d6273866bdcfb587c12da67622712aeb3600e3ca4411d0ffd5
v0.9.0 0xfcf352f7f1c874b8 linux-arm64 74eb85b88b332b3ef90b0775ec06fe67eca8709ec47c37985b37ff52bcfd4f1c
v0.9.0 0xfcf352f7f1c874b8 darwin-x64 9b292afe6134c620e0f3286e5a2c2babe16c15f17d32a5d8b351dcca4d1a632e
v0.9.0 0xfcf352f7f1c874b8 darwin-arm64 c9c39f379bc5f749e9627b6992c55f700a0e373dd7f5aa559c7ecb2448982abd
v0.9.0 0xfcf352f7f1c874b8 windows-x64 84f5bdee3393124f268206e5e78adbfdddce7001f327c35ce3d2fa483e09c365
v0.9.0 0xfcf352f7f1c874b8 windows-arm64 11e7361f5ec5d183419f6d953bc767cf3a209002c108c9e7a49627652f241237
EOF
}

# The licence and source-notice files of a native zip, by name: OpenTUI's own and those of everything its library
# carries (FFmpeg, zlib, Ghostty, libwebp, Wuffs, stb, Little CMS in v0.9.0; a release may add more, such as the
# toolchain runtimes a static Windows library carries). Every archive ships them all under licenses/opentui.
is_notice() {
  case $1 in LICENSE* | COPYING* | NOTICE* | AUTHORS* | PATENTS* | *-SOURCE.md) return 0 ;; *) return 1 ;; esac
}

fnv1a64() {
  python3 -I -c '
import sys
h = 0xCBF29CE484222325
for b in open(sys.argv[1], "rb").read():
    h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
print(f"{h:#018x}")' "$1"
}

# Whether packages/native, which the zips are built from, is the same at commits $1 and $2, apart from the version
# that a release commit bumps in package.json and build.zig.zon. Trees only: a blobless fetch, two blobs read on demand.
same_native() {
  local repo same=0
  repo=$(mktemp -d)
  git init -q "$repo"
  git -C "$repo" remote add origin https://github.com/anomalyco/opentui
  git -C "$repo" fetch -q --depth 1 --filter=blob:none origin "$1" "$2"
  git -C "$repo" diff --quiet "$1" "$2" -- packages/native ':!packages/native/package.json' \
    ':!packages/native/build.zig.zon' || same=1
  if [ "$same" = 0 ]; then
    zon() { git -C "$repo" show "$1:packages/native/build.zig.zon" | grep -v '^ *\.version *='; }
    [ "$(zon "$1")" = "$(zon "$2")" ] || same=1
  fi
  rm -rf "$repo"
  return "$same"
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

case ${1:-} in
  tag)
    [ $# -eq 3 ] || die "usage: $0 tag <header-fnv1a64> <pin-commit>"
    header=$2 pin=$3
    for tag in $(table | awk -v header="$header" '$2 == header { print $1 }' | uniq); do
      commit=$(releases | awk -v tag="$tag" '$1 == tag { print $2 }')
      [ -n "$commit" ] || die "no commit for $tag in the releases table"
      if same_native "$commit" "$pin"; then
        echo "$tag"
        exit 0
      fi
      echo "opentui-release: $tag ($commit) has the pin's header, but its packages/native differs from $pin's" >&2
    done
    ;;
  fetch)
    [ $# -eq 5 ] || die "usage: $0 fetch <tag> <rust-target> <out-dir> <header-fnv1a64>"
    tag=$2 target=$3 out=$4 header=$5
    # The files opentui-sys may read: on Windows the DLL and its import library (D85, v0.9.0's opentui-sys) and
    # opentui-static.lib, which an opentui-sys that links statically on MSVC reads instead; whichever the zip has.
    case $target in
      x86_64-unknown-linux-gnu) platform=linux-x64 files="opentui.h libopentui.a" ;;
      aarch64-unknown-linux-gnu) platform=linux-arm64 files="opentui.h libopentui.a" ;;
      x86_64-apple-darwin) platform=darwin-x64 files="opentui.h libopentui.a" ;;
      aarch64-apple-darwin) platform=darwin-arm64 files="opentui.h libopentui.a" ;;
      x86_64-pc-windows-msvc) platform=windows-x64 files="opentui.h" optional="opentui.dll opentui.lib opentui-static.lib" ;;
      aarch64-pc-windows-msvc) platform=windows-arm64 files="opentui.h" optional="opentui.dll opentui.lib opentui-static.lib" ;;
      *) die "unsupported target $target" ;;
    esac
    row=$(table | awk -v tag="$tag" -v platform="$platform" '$1 == tag && $3 == platform')
    [ -n "$row" ] || die "no sha256 for $tag $platform in the table"
    read -r _ known _ expected <<<"$row"
    [ "$known" = "$header" ] || die "$tag's opentui.h hashes to $known, not $header"
    name=opentui-native-$tag-$platform.zip
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    curl -fsSL --retry 3 -o "$work/$name" "https://github.com/anomalyco/opentui/releases/download/$tag/$name"
    got=$(sha256 "$work/$name")
    [ "$got" = "$expected" ] || die "$name has sha256 $got, not $expected"
    mkdir "$work/zip"
    unzip -q "$work/$name" -d "$work/zip"
    built=$(fnv1a64 "$work/zip/opentui.h")
    [ "$built" = "$header" ] || die "$name's opentui.h hashes to $built, not $header"
    for f in ${optional:-}; do
      if [ -f "$work/zip/$f" ]; then files="$files $f"; fi
    done
    case $files in
      *opentui-static.lib* | *libopentui.a* | *opentui.dll*opentui.lib*) ;;
      *) die "$name has no library to link: $(cd "$work/zip" && printf '%s ' *)" ;;
    esac
    for f in $files; do [ -f "$work/zip/$f" ] || die "$name has no $f"; done
    notices=$(for path in "$work/zip"/*; do
      if [ -f "$path" ] && is_notice "${path##*/}"; then echo "${path##*/}"; fi
    done)
    [ -n "$notices" ] || die "$name has no licence files"
    printf '%s\n' "$notices" | grep -qx LICENSE || die "$name has no LICENSE (OpenTUI's own)"
    rm -rf "$out"
    mkdir -p "$out/licenses"
    for f in $files; do cp "$work/zip/$f" "$out/$f"; done
    for f in $notices; do cp "$work/zip/$f" "$out/licenses/$f"; done
    cat >"$out/STAMP" <<EOF
release=$tag
zip=$name
sha256=$got
target=$target
header_fnv1a64=$built
EOF
    echo "opentui-release: installed $files and licenses/ ($(printf '%s' "$notices" | tr '\n' ' ')) from $name into $out"
    ;;
  *) die "usage: $0 tag <header-fnv1a64> <pin-commit> | fetch <tag> <rust-target> <out-dir> <header-fnv1a64>" ;;
esac
