# Bookdrop for KOReader

Bookdrop turns KOReader into an e-ink-friendly, cover-first browser for public
ebook libraries. It combines maintained OPDS feeds with Internet Archive's
public search and metadata APIs in a single native Lua interface.

## Install

1. Extract `bookdrop.koplugin` into KOReader's `plugins` directory.
2. Restart KOReader.
3. From KOReader's file manager menu, open **Bookdrop**.

## Features

- Search by title, author, ISBN, or keyword.
- Browse fiction, non-fiction, comics, and magazines.
- Search Project Gutenberg, Standard Ebooks, textos.info, Gallica,
  and Internet Archive from one results screen.
- Filter by library, content type, format, and language.
- Rank exact title and author matches globally, using curated-library priority
  to break otherwise comparable matches before Internet Archive.
- Sort the combined catalog by best match, title, or publication date.
- Open a network-free Kindle-style home screen with fiction, non-fiction,
  comics, magazines, Spanish, and French shelves. A small hand-curated catalog
  and its real cover images are bundled with the plugin, with three titles per
  category, so a fresh install is populated immediately; opening a category
  runs a normal catalog search.
- Browse cover-led result rows designed for grayscale e-ink displays.
- Return to the twelve most recently viewed editions.
- View title, author, source library, language, every available format, size,
  year, subjects, description, rights, and edition metadata.
- Choose among the compatible public formats exposed by each library and save
  the selected file to KOReader's download directory.
- Cache up to 80 small JPEG/PNG cover images locally. The home screen itself
  never waits for catalog requests, and its bundled SVG covers are unaffected
  by clearing the downloaded-cover cache.

## Notes

Each library remains an independent service. A temporarily unavailable source
does not prevent results from the other selected libraries from loading.
Internet Archive uses its Advanced Search and Metadata APIs; the other sources
use their public OPDS feeds. Catalog responses are size-limited, cover responses
are capped at 1.5 MiB, and compressed responses are disabled for predictable
memory use on e-readers.

## Tests

The provider unit tests run the Lua module outside KOReader via
[lupa](https://github.com/scoder/lupa). Set up once:

    python3 -m venv .venv
    .venv/bin/pip install lupa

Run them with:

    .venv/bin/python tests/test_provider.py

## License

MIT.
