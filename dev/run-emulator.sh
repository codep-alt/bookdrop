#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KOReader's macOS build expects GNU userland tools ahead of the BSD variants.
export PATH="/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/util-linux/bin:/opt/homebrew/opt/util-linux/sbin:/opt/homebrew/bin:${PATH}"

# Resolve the symlink physically so KOReader never sees the workspace's space.
cd -P "${SCRIPT_DIR}/koreader"
exec ./kodev run -W 758 -H 1024 -D 212 "$@"
