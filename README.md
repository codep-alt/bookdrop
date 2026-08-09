# Bookdrop

All-in-one reading for KOReader — search and download from public libraries, Z-Library, and manga sources without leaving the app.

[![Ko-fi](https://img.shields.io/badge/Support-ko--fi-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/davidc465)

## Install

Copy the `bookdrop.koplugin` folder into KOReader's `plugins` directory and restart KOReader.

## What's inside

**Public libraries** — Project Gutenberg, Standard Ebooks, textos.info, Gallica, and Internet Archive. Search by title, author, ISBN, or keyword across all of them at once. Filter by format, language, content type, and library. Results are ranked by relevance with curated-library priority.

**Z-Library** — Sign in with your Z-Library account to search and download directly. Disabled by default; enable it in Settings → Libraries.

**Manga** — Full manga reader powered by a bundled RakuYomi runtime. Comes with seven pre-installed sources (MangaDex, WEBTOON, MangaPill, Weeb Central, Asura Scans, Bato.to, TCB Scans). Install more from the Aidoku community catalog from inside the app.

**Curated home** — A network-free browse screen with hand-picked books across fiction, non-fiction, comics, magazines, Spanish, and French shelves. Three titles per category with real cover art bundled in the plugin.

## Manga runtime

The Manga tab needs a small Rust server binary (~25 MB). On first use, Bookdrop detects your device and downloads the correct binary automatically — no manual steps required. A Wi-Fi connection is needed for the one-time download.

## Building a release zip

```
dev/package.sh
```

This runs `fetch-popular-sources.sh` to refresh the bundled `.aix` manga sources, then creates `Bookdrop-latest.zip`. The zip includes everything except the Rust server binary (downloaded on first use by each device).

## Developer scripts

```
dev/fetch-manga-binaries.sh latest macos     # Pre-install binaries for local testing
dev/fetch-popular-sources.sh                 # Refresh bundled .aix source files
dev/run-emulator.sh                          # Launch the KOReader emulator
```

## Tests

```
python3 -m venv .venv
.venv/bin/pip install lupa
.venv/bin/python tests/test_provider.py
```

## Credits

Bookdrop incorporates code from these projects:

- **[RakuYomi](https://github.com/tachibana-shin/rakuyomi)** (AGPL-3.0) — manga reader, bundled under `bookdrop.koplugin/manga/`
- **[Z-Library plugin](https://github.com/ZlibraryKO/zlibrary.koplugin)** (AGPL-3.0) — eAPI client, ported into `bookdrop.koplugin/bookdrop_zlibrary_provider.lua`

The pre-installed manga sources are from the [Aidoku community catalog](https://github.com/tachibana-shin/aidoku-community-sources).

## License

AGPL-3.0. See [LICENSE](LICENSE) and [NOTICE](bookdrop.koplugin/NOTICE).
