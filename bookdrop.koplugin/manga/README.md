# Bundled manga (RakuYomi)

This folder is the RakuYomi plugin (tachibana-shin/rakuyomi, AGPL-3.0 — see
`LICENSE-AGPL-3.0`) vendored into Bookdrop so Bookdrop is the single plugin
users install, with manga included. Bookdrop's `main.lua` boots it and the
store's **Manga** tab opens its library/search.

**Modifications to the vendored code (both documented inline):**
1. `gettext+.lua` derives its l10n directory from its own file location instead
   of upstream's hardcoded `plugins/rakuyomi.koplugin/l10n` path, so translations
   resolve when the plugin is nested under `bookdrop.koplugin/manga/`.
2. `main.lua` suppresses the plugin's own main-menu entry (`addToMainMenu` is a
   no-op): the Bookdrop store's **Manga** tab is the single entry point.

## Getting the binaries (no Rust toolchain needed)

RakuYomi publishes prebuilt plugin zips per device family on every GitHub
release. Fetch the two runtime binaries with:

```bash
./dev/fetch-manga-binaries.sh latest macos     # macOS (emulator)
./dev/fetch-manga-binaries.sh latest kindle    # Kindle
./dev/fetch-manga-binaries.sh latest desktop   # Linux desktop
# also: kindlehf, kindlea9, aarch64
```

This downloads `server` + `cbz_metadata_reader` into this folder (gitignored).
`uds_http_request` is not needed — this fork's Lua talks to the server over a
Unix domain socket directly.

Without the binaries the plugin still boots — the Manga tab shows a friendly
message instead of the library.

## Updating

Re-vendor the frontend from the matching release tag (keep the two patches
above), then re-run the fetch script for each device family. Keep the AGPL-3.0
license and this README with it.
