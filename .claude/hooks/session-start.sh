#!/usr/bin/env bash
# SessionStart hook
#
# 1. Zig 0.16.0 + host x86 QEMU: (repo setup.sh)
# 2. host AArch64 QEMU 8.2 + AAVMF firmware
# 3. the Zig package cache
# 4. ZLS matched to Zig
# 5. the gitignored codesign keypair
# 6. the Rust bare-metal target
# 7. Zig + ZLS on PATH for every session shell
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

ZIG_VERSION="0.16.0"
ZLS_VERSION="0.16.0" # keep in lockstep with ZIG_VERSION
TOOLS="$PWD/.tools"
ZIG_DIR="$TOOLS/zig-$ZIG_VERSION"
ZLS_DIR="$TOOLS/zls"
SENTINEL="$TOOLS/.cloud-bootstrap-done"

mkdir -p "$TOOLS"

log() { printf '[session-start] %s\n' "$*"; }

CA=""
for candidate in "${CURL_CA_BUNDLE:-}" /root/.ccr/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
    if [ -n "$candidate" ] && [ -s "$candidate" ]; then
        CA="$candidate"
        break
    fi
done
CURL_CA_OPTS=()
if [ -n "$CA" ]; then
    CURL_CA_OPTS=(--cacert "$CA")
    log "using CA bundle: $CA"
else
    log "no CA bundle found; using curl's default trust store"
fi

# 1. Zig toolchain
if [ ! -x "$ZIG_DIR/zig" ]; then
    log "installing Zig toolchain"
    curl -L https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz \
        -o "$TOOLS/zig.tar.xz"
    mkdir -p "$ZIG_DIR"
    tar -xf "$TOOLS/zig.tar.xz" -C "$ZIG_DIR" --strip-components=1
    rm "$TOOLS/zig.tar.xz"
fi
export PATH="$ZIG_DIR:$ZLS_DIR:$PATH"

# 1b. Host x86-64 QEMU
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    log "installing x86-64 QEMU"
    apt-get install -y qemu-system-x86 qemu-utils >/dev/null 2>&1 \
        || { apt-get update -qq && apt-get install -y qemu-system-x86 qemu-utils >/dev/null 2>&1; } \
        || log "WARN: could not install x86-64 QEMU; the default verify gate will be unavailable"
fi

# 2. Best? QEMU: host distro 8.2 for both arches + host AAVMF
if ! command -v qemu-system-aarch64 >/dev/null 2>&1 || [ ! -f /usr/share/AAVMF/AAVMF_CODE.fd ]; then
    log "installing AArch64 QEMU + AAVMF firmware"
    apt-get install -y qemu-system-arm qemu-efi-aarch64 >/dev/null 2>&1 \
        || { apt-get update -qq && apt-get install -y qemu-system-arm qemu-efi-aarch64 >/dev/null 2>&1; } \
        || log "WARN: could not install AArch64 QEMU; the --arm gate will be unavailable"
fi

# 2b. swtpm: TPM 2.0 emulator backend for QEMU's tpm-crb, used by the
#     Secure Boot / TPM test path (docs/secure-boot.md, SB-1+).
if ! command -v swtpm >/dev/null 2>&1; then
    log "installing swtpm (TPM 2.0 emulator)"
    apt-get install -y swtpm swtpm-tools >/dev/null 2>&1 \
        || { apt-get update -qq && apt-get install -y swtpm swtpm-tools >/dev/null 2>&1; } \
        || log "WARN: could not install swtpm; the TPM/Secure Boot test path will be unavailable"
fi

# helpers
# Download one dependency and store it in the Zig global cache. `zig fetch`
# infers the format from the extension, so the temp file must keep it.
fetch_one() {
    local url="$1" tmp sfx target rest sha path owner repo
    case "$url" in
        *.tar.xz)  sfx=.tar.xz ;;
        *.tar.zst) sfx=.tar.zst ;;
        *.zip)     sfx=.zip ;;
        *)         sfx=.tar.gz ;;
    esac
    case "$url" in
        git+https://github.com/*)
            rest="${url#git+https://github.com/}"
            sha="${rest##*#}"
            path="${rest%%#*}"; path="${path%%\?*}"; path="${path%.git}"
            owner="${path%%/*}"; repo="${path#*/}"; repo="${repo%%/*}"
            target="https://codeload.github.com/$owner/$repo/tar.gz/$sha" ;;
        https://*) target="$url" ;;
        *)         return 0 ;;
    esac
    tmp="$(mktemp --suffix="$sfx")"
    curl -fsSL "${CURL_CA_OPTS[@]}" -o "$tmp" "$target"
    zig fetch "$tmp" >/dev/null
    rm -f "$tmp"
}

# Prefetch every non-lazy dependency declared in a build.zig.zon.
prefetch_zon() {
    local zon="$1" url
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        log "  fetch $url"
        fetch_one "$url"
    done < <(awk '
        /\.url[ \t]*=[ \t]*"/   { if (match($0, /"[^"]+"/)) { url = substr($0, RSTART + 1, RLENGTH - 2); lazy = 0 } }
        /\.lazy[ \t]*=[ \t]*true/ { lazy = 1 }
        /}/                     { if (url != "") { if (!lazy) print url; url = ""; lazy = 0 } }
    ' "$zon")
}

# 3. Zig package cache
if [ ! -f "$SENTINEL" ]; then
    log "pre-populating Zig package cache from build.zig.zon"
    prefetch_zon build.zig.zon
fi

# 4. ZLS matched to Zig
if ! { [ -x "$ZLS_DIR/zls" ] && "$ZLS_DIR/zls" --version 2>/dev/null | grep -qx "$ZLS_VERSION"; }; then
    log "building ZLS $ZLS_VERSION"
    src="$TOOLS/zls-src"
    rm -rf "$src"; mkdir -p "$src"
    tmp="$(mktemp --suffix=.tar.gz)"
    curl -fsSL "${CURL_CA_OPTS[@]}" -o "$tmp" \
        "https://codeload.github.com/zigtools/zls/tar.gz/refs/tags/$ZLS_VERSION"
    tar -xzf "$tmp" -C "$src" --strip-components=1; rm -f "$tmp"
    prefetch_zon "$src/build.zig.zon"
    ( cd "$src" && zig build -Doptimize=ReleaseSafe >/dev/null )
    mkdir -p "$ZLS_DIR"; install -m 0755 "$src/zig-out/bin/zls" "$ZLS_DIR/zls"
    rm -rf "$src"
fi
# Put zls on a standard PATH dir too, so the in-repo zig-lsp plugin's
# `command: zls` resolves in the LSP subprocess regardless of shell PATH.
ln -sf "$ZLS_DIR/zls" /usr/local/bin/zls 2>/dev/null || true

# ZLS editor config: build-on-save off, style + global-var lints on.
mkdir -p "$HOME/.config/zls"
if [ ! -f "$HOME/.config/zls/zls.json" ]; then
    cat > "$HOME/.config/zls/zls.json" <<'JSON'
{
  "enable_build_on_save": false,
  "warn_style": true,
  "highlight_global_var_declarations": true
}
JSON
fi

# 5. Rust bare-metal target for the sample apps
if command -v rustup >/dev/null 2>&1; then
    rustup target add x86_64-unknown-none >/dev/null 2>&1 || true
fi

# 6. Codesign keypair (private half is gitignored)
if [ ! -f keys/codesign_private.key ]; then
    log "generating codesign keypair"
    zig build codesign -- keygen >/dev/null
fi

# 7. Put Zig + ZLS on PATH for every session shell
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    printf 'export PATH="%s:%s:$PATH"\n' "$ZIG_DIR" "$ZLS_DIR" >> "$CLAUDE_ENV_FILE"
fi

touch "$SENTINEL"
log "ready"
