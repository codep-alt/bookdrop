#!/usr/bin/env bash
# Package Bookdrop into a single zip that works on any device.
#
# The zip includes all Lua code plus pre-installed manga sources (.aix).
# The Rust server binary is NOT included — it is downloaded on first use
# when the user taps the Manga tab (see manga_downloader.lua).
#
# Usage:
#   dev/package.sh          # builds Bookdrop-latest.zip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT="${ROOT_DIR}/Bookdrop-latest.zip"
PLUGIN_DIR="${ROOT_DIR}/bookdrop.koplugin"

echo "=== Fetching manga sources (.aix files) ==="
"${SCRIPT_DIR}/fetch-popular-sources.sh"

echo "=== Packaging Bookdrop ==="
cd "${ROOT_DIR}"

# Always build from an empty archive. Updating an existing ZIP can leave files
# that were deleted from the plugin or newly added to the exclusion list.
rm -f "${OUTPUT}"

# Exclude: Rust binaries (downloaded on first use), gitignore housekeeping,
# macOS turds, and the l10n template directory.
zip -r "${OUTPUT}" bookdrop.koplugin \
  -x "bookdrop.koplugin/manga/server" \
  -x "bookdrop.koplugin/manga/cbz_metadata_reader" \
  -x "bookdrop.koplugin/manga/.gitignore" \
  -x "bookdrop.koplugin/manga/l10n/.gitignore" \
  -x "bookdrop.koplugin/manga/l10n/templates/*" \
  -x "*.DS_Store" \
  -x "*/.DS_Store" \
  -x "*/._*" \
  -x "._*"

echo "=== Done: ${OUTPUT} ==="
ls -lh "${OUTPUT}"
