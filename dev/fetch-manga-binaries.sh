#!/usr/bin/env bash
# Fetches the prebuilt RakuYomi binaries (server + cbz_metadata_reader) from the
# upstream GitHub release and drops them into bookdrop.koplugin/manga/.
#
# No Rust toolchain needed: RakuYomi publishes compiled plugin zips per device
# family on every release. Usage:
#   dev/fetch-manga-binaries.sh [version] [platform]
#     version  latest (default) or a tag like v1.39.6
#     platform macos | desktop | kindle | kindlehf | kindlea9 | aarch64
set -euo pipefail

REPO="tachibana-shin/rakuyomi"
VERSION="${1:-latest}"
PLATFORM="${2:-macos}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "${SCRIPT_DIR}/../bookdrop.koplugin/manga" && pwd)"

if [ "${VERSION}" = "latest" ]; then
    VERSION="$(curl -sS "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -m1 '"tag_name"' | sed 's/.*: "\(.*\)",*/\1/')"
fi

URL="https://github.com/${REPO}/releases/download/${VERSION}/rakuyomi-${PLATFORM}.zip"
echo "Fetching RakuYomi ${VERSION} (${PLATFORM}) from:"
echo "  ${URL}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
curl -L -sS -o "${TMP}/rakuyomi.zip" "${URL}"
unzip -o -q "${TMP}/rakuyomi.zip" -d "${TMP}/out"

SERVER="${TMP}/out/rakuyomi.koplugin/server"
CBZ="${TMP}/out/rakuyomi.koplugin/cbz_metadata_reader"
if [ ! -f "${SERVER}" ] || [ ! -f "${CBZ}" ]; then
    echo "ERROR: the ${PLATFORM} zip does not contain server/cbz_metadata_reader" >&2
    exit 1
fi

cp "${SERVER}" "${CBZ}" "${TARGET_DIR}/"
chmod +x "${TARGET_DIR}/server" "${TARGET_DIR}/cbz_metadata_reader"
echo "Installed binaries into ${TARGET_DIR}:"
ls -l "${TARGET_DIR}/server" "${TARGET_DIR}/cbz_metadata_reader"
