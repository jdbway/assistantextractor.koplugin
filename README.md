# Assistant Extractor

An "Extractor" plugin for [AnnotationSync.koplugin](https://github.com/dani84bs/AnnotationSync.koplugin),
built against the design proposed in
[AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).
It reads [assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin)'s
notebook markdown files and turns new entries into Extractor Records — data
AnnotationSync (once its side of this interface exists) can sync across
devices.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how this actually works
internally, the module map, and the design decisions behind it — in
particular why this one is structurally simpler than the companion
[VocabDeck extractor](https://github.com/jdbway/vocabdeckextractor.koplugin).

## Status

**Working today:** finding assistant.koplugin's notebook files, parsing
entries out of their markdown format, and extracting only what's new since
the last run. Verified against real device data — see
[ARCHITECTURE.md](ARCHITECTURE.md#status--non-goals) for what's been tested
and how.

**Not implemented yet:** actually pushing to AnnotationSync — tracked on
[AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).

Finds both general notebooks and per-book notebooks (which default to
sitting next to their book, wherever that is — no `default_folder_for_logs`
setup required). The per-book search is cached for speed, so a newly-added
book's notebook needs one "Rescan for notebooks" tap to be picked up — see
[ARCHITECTURE.md](ARCHITECTURE.md#finding-notebook-files) for why.

## Installation

1. Download or clone this repository.
2. Copy the folder named `assistantextractor.koplugin` into KOReader's
   `plugins` directory.
3. Restart KOReader.
4. Requires [assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin)
   to already have some notebook entries saved — this plugin only reads its
   data files, it doesn't need assistant.koplugin's own plugin to be running.

## Debug menu (Tools > Assistant Extractor)

- **Extract now (debug)** — runs the real extraction pipeline, shows how
  many new entries were found per notebook file.
- **Rescan for notebooks (debug)** — forces a fresh filesystem search for
  per-book notebooks, picking up any added since the last scan.
- **Dump extraction to file (debug)** — writes the full extracted record set
  to `<KOReader data dir>/assistantextractor_dump.lua` as a plain Lua table
  literal, for inspection while there's no real downstream consumer yet.
- **Push to AnnotationSync** — currently a placeholder; shows a message
  explaining what's pending.

## Roadmap

Same plan as [vocabdeckextractor.koplugin](https://github.com/jdbway/vocabdeckextractor.koplugin):
this is meant to eventually fold into a single installed "suite" plugin
that auto-detects which source plugins are present and activates the
matching extractor internally, rather than a separate install per source.
This repo stays standalone until that suite's shared core exists — see
[ARCHITECTURE.md](ARCHITECTURE.md#status--non-goals) for what's already
shareable versus what's still duplicated on purpose.

## Contributing

Issues and pull requests are welcome — this is early and still evolving
alongside AnnotationSync's own design work on the Extractor interface (see
[AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93)),
so it's worth reading [ARCHITECTURE.md](ARCHITECTURE.md) first to see what's
settled versus still in flux, and worth opening an issue before a large
change so the approach can be agreed on first. Small fixes and clarifications
don't need that — just open a PR.

## License

GPLv3 (see [LICENSE](LICENSE)) — matching
[assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin)'s own
license.
