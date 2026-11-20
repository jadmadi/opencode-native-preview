#!/usr/bin/env bash
# Checks a Linux build of opencode-native against the floors it ships with (O-164), from its dynamic section alone.
#
# Usage: scripts/check-linux.sh <binary> <gnu|musl>
#   gnu:  every GLIBC_ symbol version at or below 2.17, OpenTUI's own floor; no C++ runtime (libstdc++, GLIBCXX_,
#         CXXABI_), which the static OpenTUI archive and the Zig link carry inside the binary.
#   musl: fully static (O-188): no program interpreter and no needed library, so it runs on any Linux. It loads no
#         native plugins, which the client compiles out of a static musl build.
# Prints what the binary needs, for the job summary, and exits 1 on the first broken floor.
set -euo pipefail

die() { echo "check-linux: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <binary> <gnu|musl>"
bin=$1 libc=$2
floor=2.17

needed=$(readelf -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ' | sed 's/ $//')
interp=$(readelf -l "$bin" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
versions=$(readelf -W --dyn-syms "$bin" | { grep -o '@[A-Z_]*[0-9][0-9.]*' || true; } | sed 's/^@*//' | sort -u)
echo "needs: ${needed:-nothing}; interpreter: ${interp:-none}"

case $libc in
  gnu)
    top=$(sed -n 's/^GLIBC_\([0-9.]*\)$/\1/p' <<<"$versions" | sort -V | tail -1)
    echo "highest GLIBC: ${top:-none}"
    above=$(sed -n 's/^GLIBC_\([0-9.]*\)$/\1/p' <<<"$versions" | while read -r v; do
      [ "$(printf '%s\n%s\n' "$v" "$floor" | sort -V | tail -1)" = "$floor" ] || printf '%s ' "$v"
    done)
    if [ -n "$above" ]; then
      pattern=$(tr ' ' '|' <<<"${above% }")
      readelf -W --dyn-syms "$bin" | grep -E "@GLIBC_($pattern)( |$)" | awk '{print $8}' | head -20 >&2
      die "symbols above GLIBC_$floor: ${above% }"
    fi
    if grep -qE '^(GLIBCXX|CXXABI)_' <<<"$versions" || grep -q 'libstdc++' <<<"$needed"; then
      die "needs a C++ runtime: $(grep -E '^(GLIBCXX|CXXABI)_' <<<"$versions" | tr '\n' ' ')$needed"
    fi
    ;;
  musl)
    [ -z "$interp" ] || die "not static: it requests the program interpreter $interp"
    [ -z "$needed" ] || die "not static: it needs $needed"
    ;;
  *) die "unknown libc $libc" ;;
esac
echo "check-linux: $bin keeps the $libc floor"
