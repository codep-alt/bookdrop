#!/usr/bin/env bash
# Fetches popular Aidoku source files from the community repository and drops
# them into bookdrop.koplugin/manga/sources/ so they ship pre-installed with
# Bookdrop. Source IDs are pinned; re-run after an upstream index update.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${SCRIPT_DIR}/../bookdrop.koplugin/manga/sources"
BASE="https://raw.githubusercontent.com/tachibana-shin/aidoku-community-sources/gh-pages"

# (source_id  file_version) pairs.  Current as of the latest community index.
SOURCES=(
  "multi.mangadex:multi.mangadex-v8.aix"
  "multi.webtoon:multi.webtoon-v3.aix"
  "en.mangapill:en.mangapill-v2.aix"
  "en.weebcentral:en.weebcentral-v5.aix"
  "en.asurascans:en.asurascans-v8.aix"
  "multi.batoto:multi.batoto-v5.aix"
  "en.tcbscans:en.tcbscans-v5.aix"
)

mkdir -p "${TARGET_DIR}"

for entry in "${SOURCES[@]}"; do
  IFS=: read -r id file <<< "$entry"
  dest="${TARGET_DIR}/${id}.aix"
  url="${BASE}/sources/${file}"
  if [ -f "${dest}" ]; then
    echo "  skip  ${id}.aix (already present)"
  else
    echo "  fetch ${id}  <-  ${url}"
    curl -L -sS -o "${dest}" "${url}"
  fi
done

source_count="$(find "${TARGET_DIR}" -maxdepth 1 -type f -name '*.aix' | wc -l | tr -d ' ')"
echo "Popular sources synced to ${TARGET_DIR} (${source_count} files)"
