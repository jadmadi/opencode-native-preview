#!/usr/bin/env bash
# Install or update the OpenCode native CLI preview build.
#
#   curl -fsSL https://raw.githubusercontent.com/simonklee/opencode-native-preview/main/install.sh | bash
#
# Installs the newest prerelease of simonklee/opencode-native-preview: opencode-native and the TypeScript opencode
# server it runs into ~/.local/lib/opencode-native (or $OPENCODE_NATIVE_LIB_DIR), and a link to opencode-native in
# ~/.local/bin (or $OPENCODE_NATIVE_INSTALL_DIR). The bundled opencode stays off PATH, so it never shadows your own.
# Set OPENCODE_NATIVE_VERSION (for example 0.0.0-native-12) to install that build.
set -euo pipefail

REPO=simonklee/opencode-native-preview
TS_MIN=2.2.7
GLIBC_MIN=2.17
dir=${OPENCODE_NATIVE_INSTALL_DIR:-${OPENCODE_RS_INSTALL_DIR:-$HOME/.local/bin}} # the second name is the old one
lib=${OPENCODE_NATIVE_LIB_DIR:-$HOME/.local/lib/opencode-native}

die() { printf 'opencode-native install: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
# Whether version $1 is at least $2.
at_least() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }

case $(uname -s) in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  MINGW* | MSYS* | CYGWIN*) die "on Windows, download the x86_64-pc-windows-msvc (or aarch64-pc-windows-msvc) zip from https://github.com/$REPO/releases and extract it (see the README)" ;;
  *) die "unsupported OS $(uname -s); previews exist for Linux and macOS, x64 and arm64" ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) die "unsupported CPU $(uname -m); previews exist for x86_64 and arm64" ;;
esac

if [ "$os" = darwin ]; then
  # A Rosetta shell reports x86_64 on Apple silicon, which takes the arm64 build.
  if [ "$arch" = aarch64 ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    target=aarch64-apple-darwin
  else
    target=x86_64-apple-darwin
  fi
else
  if ls /lib/ld-musl-* >/dev/null 2>&1 || (ldd --version 2>&1 | grep -qi musl); then
    # Alpine and other musl systems: a build linked against musl dynamically, as OpenTUI ships one.
    target=$arch-unknown-linux-musl
  else
    glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    [ -n "$glibc" ] || die "could not find the glibc version; the preview needs glibc $GLIBC_MIN or newer"
    at_least "$glibc" "$GLIBC_MIN" ||
      die "glibc $glibc is too old; the preview needs glibc $GLIBC_MIN or newer (CentOS 7, Ubuntu 14.04, Debian 8 and later)"
    target=$arch-unknown-linux-gnu
  fi
fi

if [ -n "${OPENCODE_NATIVE_VERSION:-}" ]; then
  version=${OPENCODE_NATIVE_VERSION#v}
else
  # The newest release first; every preview is a prerelease, so /releases/latest would find none.
  version=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1" |
    sed -nE 's/^ *"tag_name": *"v([^"]+)".*/\1/p' | head -n 1)
  [ -n "$version" ] || die "found no release in $REPO"
fi

base=https://github.com/$REPO/releases/download/v$version
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "could not download $base/SHA256SUMS"
# Releases published before the rename (up to v0.0.0-rs-2) name the archive and the binary opencode-rs. Later ones
# use opencode-native, also when the version is 0.0.0-rs-<run> (a client built from a commit before the rename).
name=opencode-native
grep -q "opencode-native-$version-$target.tar.gz" "$tmp/SHA256SUMS" || name=opencode-rs
# A target that is new, or failed in this build, has no archive in it.
grep -q "$name-$version-$target.tar.gz" "$tmp/SHA256SUMS" || die "v$version has no build for $target"
archive=$name-$version-$target.tar.gz
echo "Downloading opencode-native $version ($target)"
curl -fsSL -o "$tmp/$archive" "$base/$archive" || die "could not download $base/$archive"

expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f {print $1}' "$tmp/SHA256SUMS")
[ -n "$expected" ] || die "SHA256SUMS has no entry for $archive"
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
fi
[ "$actual" = "$expected" ] || die "checksum mismatch for $archive: got $actual, expected $expected"

# Builds since bundle-server carry the TypeScript server beside the client; older ones carry the client alone.
bundled=false
listing=$(tar -tzf "$tmp/$archive")
grep -qx opencode <<<"$listing" && bundled=true
if [ "$bundled" = true ]; then
  tar -xzf "$tmp/$archive" -C "$tmp" "$name" opencode
else
  tar -xzf "$tmp/$archive" -C "$tmp" "$name"
fi
mkdir -p "$dir" "$lib"
# Replace by rename, so a running opencode-native, and a running service, keep their old files.
install_file() { # install_file <source> <target>
  cp "$1" "$2.new"
  chmod 755 "$2.new"
  mv -f "$2.new" "$2"
}
if [ "$bundled" = true ]; then
  install_file "$tmp/opencode" "$lib/opencode"
  install_file "$tmp/$name" "$lib/opencode-native"
  # The link on PATH; the client finds the bundled server beside the link's target.
  ln -sfn "$lib/opencode-native" "$dir/.opencode-native.new"
  mv -f "$dir/.opencode-native.new" "$dir/opencode-native"
  echo "Installed $("$dir/opencode-native" --version 2>/dev/null || echo "opencode-native $version") and its server to $lib"
  echo "Linked $dir/opencode-native"
else
  install_file "$tmp/$name" "$dir/opencode-native"
  echo "Installed $("$dir/opencode-native" --version 2>/dev/null || echo "opencode-native $version") to $dir/opencode-native"
fi
if [ -e "$dir/opencode-rs" ]; then
  echo "The client is now called opencode-native; you can remove the old $dir/opencode-rs."
fi

case ":$PATH:" in
  *":$dir:"*) ;;
  *) warn "$dir is not on PATH; add it, or run $dir/opencode-native" ;;
esac

if [ "$bundled" = true ]; then
  # Bun's musl build, the bundled server's, needs libstdc++ and libgcc, as OpenCode's own Docker image installs them.
  case $target in
    *-musl)
      if ! ls /usr/lib/libstdc++.so.6 /lib/libstdc++.so.6 >/dev/null 2>&1; then
        warn "the bundled server needs libstdc++ and libgcc; install them with: apk add libstdc++ libgcc"
      fi
      ;;
  esac
  # A service of the previous build keeps running until the next start of the TUI restarts it on this build.
  exit 0
fi

# A build without the server runs the TypeScript opencode on PATH for it.
if ! command -v opencode >/dev/null; then
  warn "opencode (the TypeScript CLI) is not on PATH; this build of opencode-native needs it. Install it with: npm i -g @opencode/cli"
else
  ts=$(opencode --version 2>/dev/null | head -n 1 | awk '{print $NF}')
  ts=${ts#v}
  case $ts in
    0.0.0-*) ;; # a dev or beta build, newer than any release it is based on
    *) at_least "$ts" "$TS_MIN" || warn "opencode $ts is older than $TS_MIN, the oldest version opencode-native is tested with; update it with: opencode upgrade" ;;
  esac
fi
