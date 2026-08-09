# Bookdrop

All-in-one reading for KOReader — search and download from public libraries, Z-Library, and manga sources without leaving the app.

## Install

Copy the `bookdrop.koplugin` folder into KOReader's `plugins` directory and restart KOReader.

## What's inside

**Public libraries** — Project Gutenberg, Standard Ebooks, textos.info, Gallica, and Internet Archive. Search by title, author, ISBN, or keyword across all of them at once. Filter by format, language, content type, and library. Results are ranked by relevance with curated-library priority.

**Z-Library** — Sign in with your Z-Library account to search and download directly. Disabled by default; enable it in Settings → Libraries.

**Manga** — Full manga reader powered by a bundled RakuYomi runtime. Comes with seven pre-installed sources (MangaDex, WEBTOON, MangaPill, Weeb Central, Asura Scans, Bato.to, TCB Scans). Install more from the Aidoku community catalog from inside the app.

**Curated home** — A network-free browse screen with hand-picked books across fiction, non-fiction, comics, magazines, Spanish, and French shelves. Three titles per category with real cover art bundled in the plugin.

## Building the manga runtime

The manga tab needs a Rust server binary. Build it from [RakuYomi](https://github.com/tachibana-shin/rakuyomi) and place it at `bookdrop.koplugin/manga/server`, or run:

```
dev/fetch-manga-binaries.sh
```

Popular manga sources are bundled as `.aix` files in `bookdrop.koplugin/manga/sources/`. To refresh them after an upstream source update:

```
dev/fetch-popular-sources.sh
```

## Tests

```
python3 -m venv .venv
.venv/bin/pip install lupa
.venv/bin/python tests/test_provider.py
```

## License

MIT. The bundled RakuYomi runtime is AGPL-3.0 (see `bookdrop.koplugin/LICENSE-AGPL-3.0`). The pre-installed manga sources are from the Aidoku community catalog and carry their own licenses.
