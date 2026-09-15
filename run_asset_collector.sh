#!/bin/bash

set -euo pipefail

echo -e "\033[36mIP Collector - One-Click Runner\033[0m"

# Standardized 2026-09-14 (audit DP-01/DP-03/DP-06/W2-03/W2-05/W2-09):
#   - SHA256 verification REQUIRED before execution (fail-closed; escape hatch:
#     ASSET_DEPLOY_ALLOW_UNVERIFIED=1 warns loudly and skips verification, or pin
#     ASSET_DEPLOY_SHA256, or publish "<binary>.sha256" next to the binary).
#   - Binary cached in ~/.cache/asset-collector; outputs land there (visible), no /tmp litter.
#   - Exit code propagated via exec. Minimum-size gate on downloads (W2-09).
#   - SMART data / serial numbers need root, so the runner asks for it by default (sudo)
#     and elevates ONLY the already-verified binary.  A refused or unavailable sudo falls
#     back to a rootless run.  ASSET_DEPLOY_ELEVATE=0 turns the request off.
# NOTE: keep the URL list identical to run_asset_collector.bat / run_asset_collector.ps1.

DEFAULT_RAW_BASE_URL="https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/linux"
DEFAULT_GH_PROXY_ORG_BASE_URL="https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/linux"
DEFAULT_CDN_GH_PROXY_BASE_URL="https://cdn.gh-proxy.org/https://github.com/IT95278/asset-deploy/raw/main/bin/linux"
DEFAULT_HK_GH_PROXY_BASE_URL="https://hk.gh-proxy.org/https://github.com/IT95278/asset-deploy/raw/main/bin/linux"
DEFAULT_CDN_BASE_URL="https://cdn.jsdelivr.net/gh/IT95278/asset-deploy@main/bin/linux"
DEFAULT_GHPROXY_BASE_URL="https://ghproxy.com/${DEFAULT_RAW_BASE_URL}"

if [ -n "${ASSET_DEPLOY_RELEASE_URL:-}" ]; then
    BASE_URLS=("${ASSET_DEPLOY_RELEASE_URL}")
else
    useCdn="${ASSET_DEPLOY_USE_CDN:-1}"
    useCdn="$(echo "$useCdn" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [ "$useCdn" = "0" ] || [ "$useCdn" = "false" ] || [ "$useCdn" = "no" ]; then
        BASE_URLS=("${DEFAULT_GH_PROXY_ORG_BASE_URL}" "${DEFAULT_CDN_GH_PROXY_BASE_URL}" "${DEFAULT_HK_GH_PROXY_BASE_URL}" "${DEFAULT_RAW_BASE_URL}" "${DEFAULT_CDN_BASE_URL}" "${DEFAULT_GHPROXY_BASE_URL}")
    else
        BASE_URLS=("${DEFAULT_GH_PROXY_ORG_BASE_URL}" "${DEFAULT_CDN_GH_PROXY_BASE_URL}" "${DEFAULT_HK_GH_PROXY_BASE_URL}" "${DEFAULT_CDN_BASE_URL}" "${DEFAULT_RAW_BASE_URL}" "${DEFAULT_GHPROXY_BASE_URL}")
    fi
fi

BINARY_NAME="asset-collector"
BASE_DIR="${HOME}/.cache/asset-collector"
BINARY_PATH="$BASE_DIR/$BINARY_NAME"

mkdir -p "$BASE_DIR"

# ---- Determine expected SHA256 (fail-closed; audit W2-03: the escape hatch
# warns loudly and proceeds without verification instead of refusing) ----
EXPECTED_SHA=""
EXPECTED_SRC=""
if [ -n "${ASSET_DEPLOY_SHA256:-}" ]; then
    EXPECTED_SHA="$(echo "$ASSET_DEPLOY_SHA256" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    EXPECTED_SRC="ASSET_DEPLOY_SHA256"
elif [ "${ASSET_DEPLOY_ALLOW_UNVERIFIED:-0}" != "1" ]; then
    for base in "${BASE_URLS[@]}"; do
        if [ -n "$EXPECTED_SHA" ]; then break; fi
        echo "  - Trying hash: $base/$BINARY_NAME.sha256"
        hash_text="$(curl -fsSL --connect-timeout 8 "$base/$BINARY_NAME.sha256" 2>/dev/null || true)"
        candidate="$(echo "$hash_text" | head -n1 | awk '{print tolower($1)}')"
        # audit W2-08: accept only a full 64-hex-char digest
        if echo "$candidate" | grep -Eq '^[0-9a-f]{64}$'; then
            EXPECTED_SHA="$candidate"
        fi
    done
    if [ -z "$EXPECTED_SHA" ]; then
        echo
        echo "SECURITY REFUSAL: no SHA256 available for $BINARY_NAME."
        echo "  - publish $BINARY_NAME.sha256 (sha256sum format) next to the binary, or"
        echo "  - set ASSET_DEPLOY_SHA256=<hash>, or"
        echo "  - set ASSET_DEPLOY_ALLOW_UNVERIFIED=1 to accept an unverified binary explicitly."
        exit 2
    fi
    EXPECTED_SRC="published .sha256"
fi

actual_sha_of() {
    # sha256sum is missing on busybox-based images (audit W2-22); fall back to openssl.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 -r "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

# ---- Download only when the cached binary does not match the expected hash ----
need_download=1
if [ -f "$BINARY_PATH" ] && [ -n "$EXPECTED_SHA" ]; then
    actual_sha="$(actual_sha_of "$BINARY_PATH")"
    if [ "$actual_sha" = "$EXPECTED_SHA" ]; then
        echo "Cached binary matches expected SHA256; skipping download."
        need_download=0
    else
        echo "Cached binary hash mismatch; re-downloading."
    fi
fi

if [ "$need_download" -eq 1 ]; then
    echo "Downloading $BINARY_NAME..."
    ok=0
    for base in "${BASE_URLS[@]}"; do
        echo "  - Trying: $base/$BINARY_NAME"
        for i in 1 2 3; do
            # -# shows a progress bar for large downloads so users can see activity.
            # speed-time/speed-limit help fail fast on very slow/stalled links.
            if curl -fL -# \
                --connect-timeout 8 \
                --retry 2 \
                --retry-delay 1 \
                --speed-time 20 \
                --speed-limit 10240 \
                -o "$BINARY_PATH" \
                "$base/$BINARY_NAME"; then
                # Audit W2-09: some transports (notably file:// with a missing
                # source) exit 0 with an empty file — gate on a minimum size.
                size="$(wc -c < "$BINARY_PATH" 2>/dev/null || echo 0)"
                if [ "${size:-0}" -ge 1000000 ]; then
                    ok=1
                    echo "    Downloaded: ${size} bytes"
                    break
                fi
                echo "    Downloaded only ${size:-0} bytes; treating as failure"
                rm -f "$BINARY_PATH"
            fi
            echo "    Download attempt $i/3 failed"
            sleep 1
        done
        if [ "$ok" -eq 1 ]; then
            break
        fi
    done
    if [ "$ok" -ne 1 ]; then
        echo -e "\033[31mDownload failed after 3 attempts\033[0m"
        exit 1
    fi

    # ---- Verify BEFORE executing (audit DP-01; skipped only by ALLOW_UNVERIFIED) ----
    if [ -n "$EXPECTED_SHA" ]; then
        actual_sha="$(actual_sha_of "$BINARY_PATH")"
        if [ "$actual_sha" != "$EXPECTED_SHA" ]; then
            echo -e "\033[31mSHA256 MISMATCH (source: $EXPECTED_SRC)\033[0m"
            echo "  expected: $EXPECTED_SHA"
            echo "  actual:   $actual_sha"
            rm -f "$BINARY_PATH"
            exit 2
        fi
        echo -e "\033[32mSHA256 verified ($EXPECTED_SRC).\033[0m"
    fi
fi

echo "Adding execute permission..."
chmod +x "$BINARY_PATH"

echo "Working directory: $BASE_DIR"
echo -e "\033[32mStarting IP Collector...\033[0m"
cd "$BASE_DIR"

# ---- Elevation: SMART data / serial numbers need root (see README) ----
# Only the already-verified binary is elevated; this script stays user-level, so the
# download + verify step above never holds the privilege.  ASSET_DEPLOY_ELEVATE=0 opts
# out; a refused or unavailable sudo falls back to an un-elevated run.
ELEVATE="$(echo "${ASSET_DEPLOY_ELEVATE:-1}" | tr '[:upper:]' '[:lower:]')"
if [ "$ELEVATE" != "0" ] && [ "$ELEVATE" != "false" ] && [ "$ELEVATE" != "no" ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "Requesting root for SMART/serial collection (sudo)..."
        # stdin may be the script itself ("curl | bash"), so let sudo read the password
        # from the terminal.  -E keeps HOME, so the cache dir stays the invoking user's.
        if sudo -n true 2>/dev/null; then
            exec sudo -E "./$BINARY_NAME" "$@"
        elif [ -r /dev/tty ]; then
            exec sudo -E "./$BINARY_NAME" "$@" </dev/tty
        fi
        echo "sudo needs a password but no terminal is available; continuing without root."
    else
        echo "sudo not found; continuing without root."
    fi
    echo "SMART/serial fields will be empty.  Set ASSET_DEPLOY_ELEVATE=0 to silence this."
fi

exec "./$BINARY_NAME" "$@"
