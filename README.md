# OpenCode native CLI preview builds

The OpenCode native CLI, `opencode-native`, is a Rust client for [OpenCode](https://github.com/anomalyco/opencode),
built from its `oc-rust` branch. Each build is an unsigned
[prerelease](https://github.com/simonklee/opencode-native-preview/releases) for Linux x64, Linux arm64, macOS arm64,
and Windows x64, for testers. macOS x64, Windows arm64 and the Linux musl builds (x64 and arm64, for Alpine) are
new: a release has them when they passed their smoke tests.

## Startup and memory

![opencode 2.2.7 and opencode-native side by side, attaching to a running server and answering one prompt](docs/demo-7e86153a.gif)

[Watch as video](docs/demo-2a83f6c8.mp4) (MP4, 1080p).

The client alone, against a TypeScript server that is already running (median of 8 runs):

| | `opencode` 2.2.7 | `opencode-native` 0.0.0-rs-2 |
|---|---|---|
| time to first frame | 118 ms | 5.8 ms |
| client peak memory, 20 prompts | 319 MB | 44 MB |
| client CPU time, 20 prompts | 3.92 s | 0.17 s |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/client-dark-6333b461.svg">
  <img alt="Client only, server already running. Startup: Native 5.8 ms, TypeScript 118 ms. Memory: Native 44 MB, TypeScript 319 MB. CPU: Native 0.17 s, TypeScript 3.92 s." src="docs/client-a83396f7.svg">
</picture>

The client starts its own server (`--standalone`):

| | `opencode` 2.2.7 | `opencode-native` 0.0.0-rs-2 |
|---|---|---|
| time to first frame | 314 ms | 219 ms |
| client + server peak memory | 604 MB | 410 MB |
| client + server CPU time, 20 prompts | 6.93 s | 2.79 s |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/standalone-dark-7e0503a0.svg">
  <img alt="Client starts its own server. Startup: Native 219 ms, TypeScript 314 ms. Memory: Native 44 MB client, 410 MB with the server; TypeScript 306 MB client, 604 MB with the server." src="docs/standalone-f00f005b.svg">
</picture>

`opencode-native` replaces only the client: the TypeScript server holds 374 of its 410 MB. The method, raw data, and
machine (AMD Ryzen 7 9800X3D, Linux) are in [docs/benchmark.md](docs/benchmark.md).

## How it works

`opencode-native` uses OpenTUI's Rust bindings, which drive the same native library as the TypeScript CLI's
`@opentui/core`. So the screens, keys, and themes match, and a parity harness compares the two clients. It talks to
the same TypeScript server: it finds or starts the background service, `--server <url>` attaches to one, and
`--standalone` starts a private one. Sessions and `cli.json` are shared.

Each build bundles that server: the TypeScript `opencode` built from the same commit at the same version sits beside
`opencode-native` in every archive, the `.deb` and the install script's directory. The client runs it for the service
and the standalone server, and delegates `serve`, `plugin` and remote access to it. It takes `OPENCODE_TS_BIN` when
set, else the bundled `opencode`, else `opencode` on `PATH`. When the TUI finds a background service of another
version, as after an update, it restarts it on the bundled server and says `Restarting background server (version
mismatch)...`, as the TypeScript TUI does.

What differs:

- Server plugins run in the TypeScript server and work as before.
- TypeScript TUI plugins run on a JS host beside the client, on the bundled server's Bun.
- Native TUI plugins (`.so`, `.dylib`) load instead: see the
  [quick start](https://github.com/anomalyco/opencode/blob/oc-rust/packages/cli-rs/crates/plugin-abi/README.md).
- `opencode-native upgrade` does not update a preview build; re-run the install script.
- There is no `/restart`; use `opencode-native service restart`.
- HTTPS trusts the system's root certificates; `NODE_EXTRA_CA_CERTS` is ignored.
- 35 languages are syntax-highlighted. Others show as plain text, among them Kotlin, OCaml and F#, which the
  TypeScript client highlights.

The full list is in
[`parity/deviations`](https://github.com/anomalyco/opencode/tree/oc-rust/packages/cli-rs/parity/deviations).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/simonklee/opencode-native-preview/main/install.sh | bash
```

This checks the newest build against `SHA256SUMS` and installs `opencode-native` and its bundled `opencode` into
`~/.local/lib/opencode-native` (or `$OPENCODE_NATIVE_LIB_DIR`), with a link to `opencode-native` in `~/.local/bin` (or
`$OPENCODE_NATIVE_INSTALL_DIR`). The bundled `opencode` stays off `PATH`, so your own `opencode`, if you have one, is
untouched. Run the script again to update both; the next start of the TUI restarts a service of the old version.
Linux builds need glibc 2.17 or newer (OpenTUI's floor). On Alpine and other musl systems the script installs the musl
build: the client is fully static and runs on any Linux, but loads no native plugins and has no Zed editor context; the
bundled server's Bun needs `apk add libstdc++ libgcc`, as OpenCode's own Docker image installs. To verify an archive's build attestation:
`gh attestation verify opencode-native-<version>-<target>.tar.gz --repo simonklee/opencode-native-preview`.

On Debian and Ubuntu, download the `.deb` from the [latest release](https://github.com/simonklee/opencode-native-preview/releases)
and run `sudo apt install ./opencode-native_*.deb`. It installs both binaries in `/usr/lib/opencode-native` and links
`/usr/bin/opencode-native`.

Each download is about 135 to 155 MB: the server is most of it (230 to 265 MB unpacked, against 80 to 120 MB for the
client).

Each archive holds OpenCode's `LICENSE`, `THIRD-PARTY-NOTICES.txt` (the licences of the Rust crates in the binary,
the tree-sitter grammars among them, and of the sources of its highlight queries) and `licenses/opentui/` (OpenTUI's licence and those of what its native library
carries, as its release ships them: FFmpeg under the LGPL with its source in `FFMPEG-SOURCE.md`, zlib, Ghostty,
libwebp, Wuffs, stb, Little CMS and others).
The `.deb` installs them in `/usr/share/doc/opencode-native`. The install script installs only the binary.

## Requirements

Nothing beyond the download: the server is bundled. The bundled server is built for the channel `latest`, which the
client uses when `OPENCODE_CHANNEL` is unset, so it shares `service.json` and your sessions with a TypeScript install of
a release; when both run, each client restarts a service of another version, as two TypeScript versions do. To run
another TypeScript server instead, set `OPENCODE_TS_BIN` to it. To keep the client's tabs apart from `opencode`'s, set
`OPENCODE_TUI_CHANNEL=native-preview`.

## macOS

Both binaries have only an ad-hoc signature. If you downloaded an archive with a browser, extract it and run
`xattr -dr com.apple.quarantine <the extracted directory>`, which clears both. The install script needs none of this.

## Windows

Download `opencode-native-<version>-x86_64-pc-windows-msvc.zip` (or `aarch64-pc-windows-msvc` on Arm) from the
[latest release](https://github.com/simonklee/opencode-native-preview/releases) and extract it; keep `opencode.exe`, the
bundled server, next to `opencode-native.exe` (and `opentui.dll`, if the zip holds one). Put the folder on `PATH` only if
you have no other `opencode` there, since its `opencode.exe` would shadow it; running `opencode-native.exe` by its path
works either way. If Windows blocks the download, run `Unblock-File` on the zip before extracting, which clears both
files. Before extracting an update over the old files, run `opencode-native service stop`: Windows does not replace a
running `opencode.exe`. The first start of the 265 MB server can take several seconds while Defender scans it. Each build
is tested on GitHub's Windows Server 2025 runner (Arm: Windows 11 Arm), with the TUI on a pseudoconsole (ConPTY); no
other terminal is tested.

## Reporting bugs

Include the output of `opencode-native --version` and the end of `~/.local/share/opencode/log/opencode.log`.
