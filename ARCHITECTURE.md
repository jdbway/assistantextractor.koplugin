# Architecture

Internals and design rationale. For what this plugin is and how to use it,
see [README.md](README.md).

## Purpose

An "Extractor" plugin for AnnotationSync's proposed cross-device sync
interface ([AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93)).
It turns assistant.koplugin's notebook markdown files into a portable record
shape another sync system can reason about, the same role
[vocabdeckextractor.koplugin](https://github.com/jdbway/vocabdeckextractor.koplugin)
plays for VocabDeck.

## Module map

| File | Responsibility |
|---|---|
| `main.lua` | Plugin entry point. Registers the debug menu (Tools > Assistant Extractor). Owns the real push call into AnnotationSync and the sync-event hook. |
| `extractor_assistant.lua` | The core pipeline: find notebook files (fixed locations + a cached filesystem walk), read only what's new since last time, return records. |
| `writeback_assistant.lua` | The other half: appends any merged entry not already known locally (by Merge Key) onto the real notebook file, in the same format the app itself writes. Purely additive — nothing to update in place, since every field here is `write_once`. |
| `notebook_parser.lua` | Splits one notebook file's raw markdown into individual entries. Pure function, no I/O. |
| `extraction_state.lua` | Persists, per notebook file, the file size and set of entry keys already extracted, plus the cached result of the last filesystem walk. |
| `fs_walk.lua` | Generic bounded recursive directory walk (find files matching a predicate, skip directories matching another). No notebook-specific knowledge — see its own header comment on why it's deliberately kept this narrow. |

## Why this is structurally simpler than the VocabDeck extractor

VocabDeck's cards get mutated in place (a review, a re-enrichment, a note
edit), tracked by one coarse row-level timestamp — that's what forced
[vocabdeckextractor.koplugin](https://github.com/jdbway/vocabdeckextractor.koplugin)
to build its own snapshot/diffing machinery to recover per-field freshness.

assistant.koplugin's notebook entries are **append-only and never mutate
once written** (confirmed directly in its source: entries are written via
`io.open(path, "a")`, and no code path anywhere rewrites an existing entry).
An entry, once saved, is permanent. That means:

- Every field is `write_once` — there's no "latest value" question, because
  there's only ever one value.
- There's no per-field diffing to build at all. The only question is "have I
  already seen this entry," which `extraction_state.lua` answers with a file
  size gate (unchanged size means nothing new — nothing ever shrinks or
  rewrites an append-only file) plus a set of already-seen entry keys.

## Finding notebook files

General notebooks live in one discoverable folder (configured, or a default
under assistant.koplugin's base directory) — cheap to check directly, every
time, no caching needed.

Per-book notebooks are a harder case: KOReader core's own
`BookInfo:getNotebookFile()` (which assistant.koplugin calls into) resolves
a book's notebook path to that book's own `doc_path` plus an extension,
unless overridden — meaning the file defaults to sitting **right next to
whatever book it belongs to**, wherever that book happens to live. There's
no single folder to check the way general notebooks have one, and no
central index of "every book this device knows about" to query instead.

Rather than resolving each book's `doc_settings` to compute its exact
notebook path, this walks the filesystem (`fs_walk.lua`, from `home_dir`
when set, else a broader fallback root) for `.md` files and confirms each
one is actually a notebook **by content** — does it start with the `# [`
entry header `notebook_parser.lua` also keys on — rather than by guessing at
library layout or requiring a specific home-screen/library plugin. That
walk is the expensive part, so its result is cached in
`extraction_state.lua` and only redone on an explicit rescan (the "Rescan
for notebooks" debug action, or a newly-added book's notebook won't be
picked up until one runs).

## Data flow

1. `main.lua`'s debug menu (eventually: AnnotationSync's broadcast sync event) calls `Extractor.extractAll()`.
2. `extractor_assistant.lua:listNotebookFiles()` combines the always-fresh fixed-location check with the (usually cached) filesystem walk above.
3. For each file: if its size matches what's recorded from last time, skip it entirely (append-only guarantees nothing changed). Otherwise, read the whole file, split it into entries (`notebook_parser.lua`), and keep only the entries whose merge key hasn't been emitted before.
4. New entries become records with every field tagged `write_once`, `changed_at` set to the entry's own embedded creation timestamp.
5. Save the updated file size and known-entry-keys back to `extraction_state.lua`.

## Invariants

- **Entry boundaries are detected by matching `# [` at the start of a line.** This is assistant.koplugin's own convention (`assistant_quicknote.lua` and `assistant_viewer.lua`'s `saveToNotebook` both write this exact heading shape) — if a future assistant.koplugin version changes it, this parser needs the matching change.
- **Markdown inside a body is preserved verbatim, never stripped or restructured.** The point is round-tripping exactly what a future renderer needs (blockquotes, bold, etc. all survive as literal markdown syntax in the field value), not producing a "cleaner" derived version.
- **Timestamps are the extracting device's own local time**, matching how assistant.koplugin writes them (`os.date("%Y-%m-%d %H:%M:%S")`, no UTC conversion). Fine as an ordering/identity aid; not an authoritative cross-timezone value.
- **`extraction_state.lua`'s `State.flush()` must be called on every real extraction, not just the debug-menu path.** `State.saveForFile()` only updates the in-memory `LuaSettings` object; `flush()` persists it to disk. This was originally only called at the end of `Extractor.extractAll()` — see [vocabdeckextractor.koplugin](https://github.com/jdbway/vocabdeckextractor.koplugin)'s ARCHITECTURE.md for the real bug this caused there (VocabDeck's `last_write_wins` fields made it a correctness bug; here, since every field is `write_once`, the same gap is lower-stakes — a restart just forces a full file re-parse next time instead of using the cached fast path, since the real embedded per-entry timestamps get preserved either way — but it's fixed the same way regardless, for consistency and because a future field here might not stay `write_once` forever.

## Decisions and why

- **Merge Key is `timestamp string + body length`, not a real hash.** Same-second saves are rare but possible, and this is enough to disambiguate them without pulling in a hashing dependency. Only needs to be unique within one file's push, not globally — see the VocabDeck extractor's ARCHITECTURE.md for why cross-extractor field/key uniqueness isn't a requirement in this design at all.
- **The whole body is kept as one field rather than sub-parsed into "highlighted text" vs "response."** The two call sites that write entries (`assistant_quicknote.lua`, `assistant_viewer.lua`) format that split slightly differently, and splitting it here would mean re-deriving a distinction a markdown renderer can already show correctly (a blockquote renders as a blockquote) without this extractor needing to understand assistant.koplugin's exact internal formatting conventions.
- **Extraction state tracks file size, not a byte offset to resume from.** Re-parsing the whole file on any real change is cheap for a personal notes file, and re-deriving "what's new" by diffing against known entry keys is more robust than trusting a byte-offset slice to always land exactly on an entry boundary.
- **`known_keys` stores each entry's full fields, not just a seen-flag, and extraction can return either "new since last time" or "everything known" (`want_all`). The real push to AnnotationSync uses `want_all=true`, not the new-only default.** "Extracted locally" and "pushed to AnnotationSync" are different facts — conflating them caused two separate real bugs during testing: (1) running the debug "Extract now" action before "Dump to file" made the dump come back empty, since the extract call had already marked everything as seen; (2) worse, the *real push* used new-only extraction at first, so entries already marked seen by earlier debug testing looked like nothing was left to push, even on their first-ever real sync. `want_all` fixes both: debug dumps always show the full picture, and the push always sends everything currently known. Every field here is `write_once`, so resending an already-synced entry is a harmless no-op on the merge side.

## Status / non-goals

Tracked against [AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).

- **Working and tested end-to-end, including writeback, across two real, independently-editing KOReader instances** — the physical Kindle plus a Docker container running KOReader's official Linux desktop build, syncing against the same server. A note added on one device correctly appears, via real writeback, in the other device's actual notebook file on its next sync. Also includes everything under "Data flow" above: the filesystem walk finding real per-book notebooks sitting next to their books on a real library, with no `default_folder_for_logs` configured.
- **New per-book notebooks aren't picked up automatically** between rescans — the walk result is cached, so a book added (or first annotated) after the last rescan won't show up until "Rescan for notebooks" runs again. Everything else about it (fixed-location files, already-known per-book files) stays fresh every extraction regardless.
- **Sharing code with [vocabdeckextractor.koplugin](https://github.com/jdbway/vocabdeckextractor.koplugin) is deliberately partial right now.** `fs_walk.lua` is a good candidate for a shared suite-level utility later (it has zero notebook-specific knowledge), but the two repos can't actually share a file today without a real package to host it in — copy-pasting the same file into two still-standalone repos isn't reuse, just duplication with extra steps. The `main.lua` debug-menu boilerplate is duplicated between the two repos for the same reason. Both are expected to collapse into one shared core once the suite (see the roadmap in README.md) actually exists — not before, since we don't yet have a third extractor to confirm what's genuinely common versus specific to these first two.
