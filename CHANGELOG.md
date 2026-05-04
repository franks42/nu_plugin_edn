# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once a 1.0 ships.

## [Unreleased]

(Active dev cycle. `plugin-release` is `0.112.2-3-SNAPSHOT`. Drop the suffix before tagging the next release.)

### Added

- **`to edn --duration-ns`** — opt into lossless Duration emission as integer nanoseconds. Default stays integer milliseconds (matches conventional EDN-API units). Catches the case where Nushell sub-millisecond Durations would otherwise truncate (`1234567ns` → `1` ms vs `1234567` ns).
- README: new "Type quirks to watch for" section documenting Duration / Filesize / Binary / keyword / set / record-key conventions explicitly so they don't surprise users round-tripping with bb-side scripts.

### Tests

- Three ecosystem equivalence tests verifying that `nu | to edn | ^cedn | sha256sum` produces the same canonical bytes (and therefore hash) as `^cedn --edn '<equivalent literal>'`. Catches structural drift between the plugin's `to edn` output and the EDN literal a Clojure programmer would write for the same value. Skipped when `^cedn` is not on PATH.

## [0.112.2-2] — 2026-05-04 — flag-pair completion + spans + drift fix

Second plugin-only patch on the `0.112.2` line. Substantial dev window: keyword-fidelity round-trip, string keys for non-Clojure consumers, Clojure reader metadata, source-span error labels, mid-stream error surfacing, and a fix for the long-broken nushell-drift watcher.

### Added

- **Mid-stream parse errors in `from edn --lines` over a ByteStream now surface inline.** Previously a parse failure mid-stream was logged to stderr and the stream was silently truncated (the protocol can't switch a ListStream response into an Error response mid-flight). The plugin now emits a `Value::Error` as the final list element instead — downstream sees the error as either a top-level error or via `try/catch`. ShellError serializes as LabeledError, so the `:error` map matches our top-level error shape.
- **`from edn --keep-keyword-prefix`** + **`to edn --keep-keyword-prefix`** — paired flags for keyword/string round-trip fidelity. From-side keeps the leading `:` as a marker on the Nushell string (`:foo` → `":foo"`); to-side re-emits strings matching the keyword shape as EDN keywords. One-way fidelity loss documented: plain strings starting with `:` will coerce to keywords on the to-edn side.
- **`to edn --string-keys`** — emit record keys as EDN strings (`{"name" "alice"}`) instead of the default keyword keys (`{:name "alice"}`). For pipelines feeding non-Clojure consumers (Python/JS/Go) that don't speak keyword keys. Combines with `--keep-keyword-prefix`: `--string-keys` wins for keys, `--keep-keyword-prefix` still applies to values.
- **`to edn --meta <record>`** — prefix the emitted top-level form with Clojure reader metadata (`^{...} <form>`). Useful for attaching provenance/context that a bb consumer reads via `(meta v)`. **Non-portable**: `^{...}` is Clojure-reader syntax, not EDN spec — Python/JS/Go EDN parsers will reject it. Mutually exclusive with `--lines`/`--objects`; rejects non-record arguments.
- **Source-span labels on `from edn` parse errors**. Nushell now underlines the offending position in the user's source when an EDN literal fails to parse. Implementation wraps the input in a `clojure.lang.LineNumberingPushbackReader`, runs `clojure.edn/read` against it, and on exception queries the reader for line/column — translated to a UTF-8 byte offset and added to the source span's `:start`. Single-form and buffered multi-form (`--lines` over a Value) paths both carry labels. ByteStream input has no script-level span and emits the message without a label, as before. Five new error tests cover the matrix.
- **`to edn --pprint`** (`-p`): pretty-print output via `clojure.pprint` instead of compact `pr-str`. Mutually exclusive with `--lines` / `--objects`.
- **`from edn --set2record`** + **`to edn --record2set`** — paired flags for round-tripping keyword/string EDN sets through Nushell records in mirror form (`{k: k}`). Default behaviour (set → list) is unchanged. Loss-free for keyword/string sets only; int and composite-element sets degrade since Nushell record keys are always strings.
- **`#inst` / `#uuid` tagged-literal handling in `from edn`**: `#inst "..."` now produces a Nushell `Date` (was: stringified Java Date through `:else`); `#uuid "..."` produces a Nushell `String` (Nushell has no UUID type — use the `^uuidv7` CLI for UUIDv7-aware operations).
- **`:examples` populated** in both `from edn` and `to edn` Signatures (5 each, surfacing in `help from edn` / `help to edn`). Includes cross-tool composition examples with `^cedn` and `^uuidv7`.
- **Ecosystem integration tests** (conditional): exercises `^cedn` and `^uuidv7` composition. Skipped silently when the CLIs aren't on PATH; runs 7 extra tests when they are. The tests caught the `#inst` bug above on first run — exactly the kind of cross-tool regression they're meant to detect.
- README sections: `pprint-edn` Nushell `def` for ad-hoc pretty-printing, EDN-set conversion options, ecosystem composition examples.

### Fixed

- **`nushell-drift` workflow**: had been silently failing to parse since the workflow first landed. Two distinct bugs: (1) multi-line bash strings inside `run: |` blocks were dedented to column 1, terminating the YAML literal block scalar early — fixed by indenting continuation lines to the block-indent level. (2) The `CURRENT` version-extraction regex assumed a single-line `(def nushell-target ...)` but ours spans two lines, so extraction returned empty and drift was falsely detected on every run. Replaced with `awk -F'"' '/NU_PLUGIN_EDN_NU_VERSION/ {print $4; exit}'`. Manually verified via `workflow_dispatch` after the fix.

## [0.112.2-1] — 2026-05-04 — `to edn --lines/--objects` + chained-pipeline fix

First plugin-only patch on the `0.112.2` line. No Nushell anchor change; same Nushell-target as v0.112.2.

### Added
- **`to edn --lines` / `to edn --objects`** — multi-form output. Mirrors `from edn --lines` / `from edn --objects` on the input side, but with a deliberate asymmetry: the two flags are **synonyms** on `from edn` (parsing is whitespace-agnostic) but have **different separator semantics** on `to edn`:
  - `--lines` (`-l`) emits each item with a trailing newline (`<form>\n`). Line-discipline output that plays with `head`, `tail`, `wc -l`, line-buffered consumers.
  - `--objects` (`-o`) emits each item with a trailing single space (`<form> `). Compact concatenated-objects output, since EDN forms self-delimit and the parser doesn't care about whitespace shape.
  - For a list/table input, items are the elements. For a scalar/record input, the single value is treated as one item. Empty list → empty string.
  - `from edn --objects | to edn --lines` is the natural normalizer: turn any-whitespace EDN streams into NDJSON-style line-separated EDN.

### Fixed
- **Chained plugin calls in the same pipeline now work end-to-end**, including with incremental ByteStream input on the leading `from edn`. Pipelines like `bb produce.clj | from edn --lines | to edn --lines | from edn --lines | get i | math sum` now produce correct results without `| collect` workarounds. Nushell pipelines plugin Calls concurrently — Call(B) arrives while we're still in Call(A) along with `:Data` for B's input stream — so the plugin now routes those messages: `:Call`s into a `pending-calls` queue (drained by the main loop after the current Call finishes), and foreign `:Data`/`:End` into per-stream `stream-buffers` (consulted by future readers). Implemented as a unified `pull-stream-msg` helper used by all three stream readers (`read-byte-stream`, `read-list-stream`, `refill-stream-input!`). Single-threaded, no concurrency primitives. Added a regression test (`to edn --lines: bb-streamed round-trip via chained plugin Calls`).

### Changed
- **Roadmap reframed** around the typed-value boundary principle: `--pretty` and `--canonical` were dropped from the plugin's planned-flags list. They're better realised as standalone bb-script filters in their reference libraries' repos, composing via Unix pipes. The `cedn` CLI now exists in [canonical-edn](https://github.com/franks42/canonical-edn) as the reference example. CLAUDE.md has the full architectural rationale.
- CI action versions bumped: `actions/checkout@v4 → @v6`, `DeLaGuardo/setup-clojure@13.0 → @13.6.0`. Eliminates the Node 20 deprecation warning on every workflow run.

### Tests
61/61 integration tests passing on Nushell 0.112.2 (was 47 in v0.112.2). 14 new cases covering the two new flags, the chained-Call round-trip, and edge cases.

### Planned for the next milestone
- Source spans on `from edn` parse errors (the biggest remaining UX gap).
- `:examples` populated in both Signatures.
- `to edn --meta`, `--keep-keyword-prefix`, `--string-keys` (still in scope per the boundary principle — they affect the typed walk, not output text).
- See CLAUDE.md §2 and §4.

## [0.112.2] — 2026-05-03 — Nushell-aligned versioning + CI

Versioning scheme change. Same code as v0.3.0, but renumbered to align with the Nushell release the plugin targets — the convention used by `nu_plugin_endecode`, `nu_plugin_kdl`, and Nushell's own bundled plugins. From here on:

- **Plugin version = Nushell version it's anchored to.** When Nushell 0.113.0 ships and we verify compat, the plugin gets re-released as 0.113.0. v0.3.0 / v0.2.0 / v0.1.0 stay browsable for historical context but won't have successors.
- **Plugin-only patches between Nushell minors** (when needed) get a `-N` suffix: `0.112.2-1`, `0.112.2-2`, etc.
- **Dev windows** carry a `-SNAPSHOT` suffix on `plugin-release` (visible via `plugin list | get version`) so users can tell tagged releases from in-flight code.

### Added
- Two version constants in the plugin source: `nushell-target` (sent in Hello — must match running Nushell) and `plugin-release` (sent in :Metadata — our own release identity, with optional `-SNAPSHOT`). The split makes CI version-sweeps possible without rewriting the source.
- `NU_PLUGIN_EDN_NU_VERSION` env var override for `nushell-target`. Used by CI to test the plugin against multiple Nushell versions from a single source tree.
- `bb release-check` task — refuses to ship a SNAPSHOT version. Run before tagging.
- **GitHub Actions workflows**:
  - `test.yml` — matrix CI on every push/PR. Currently sweeps `nushell: ['0.112.2']`; extend the matrix as we anchor against new Nushell minors.
  - `nushell-drift.yml` — weekly cron (Mondays 06:00 UTC) that fetches the latest Nushell tag, tests the plugin against it, and **opens a PR** if green or **opens an issue** if red.
  - `release.yml` — on `v*.*.*` tag push: validates the source's `plugin-release` matches the tag, refuses SNAPSHOTs, builds a version-suffixed asset, creates the GitHub Release.
- README CI badge.

### Changed
- Asset filename convention: `nu_plugin_edn-vX.Y.Z` (no separate `-nu...` suffix anymore — the plugin version *is* the Nushell version under the new scheme).

## [0.3.0] — 2026-05-03 — `to edn` shipped, round-trip works

The other half of the plugin: emit Nushell values as EDN text. With this milestone, the cljsh use case round-trips end-to-end — `bb produce.clj | from edn | where ... | to edn | bb consume.clj` Just Works.

### Added
- **`to edn` command** — serialize Nushell values back to EDN text.
  - Records emit as maps with **keyword keys** by default (`{:name "alice"}`), matching Clojure idiom and what bb-side consumers expect.
  - Lists and tables emit as vectors of maps.
  - Date emits as `#inst "..."` literal (round-trips).
  - Nushell-native types without an EDN equivalent fall back to primitives: durations → ms ints, filesizes → byte ints, binary → base64 strings. Lossy by design — README has the full type-mappings table.
  - Closures, cell paths, ranges, custom values, and errors emit as `#<TypeName>` placeholder strings so the user sees what was lost.
  - Accepts `Value`, `ListStream` (collected first — so `where ... | to edn` works), and `Empty` inputs. Rejects `ByteStream` with a clear error.
- ListStream input handling on the plugin side, used by `to edn` to consume upstream filtered/transformed streams.
- 13 new integration tests covering `to edn` shapes, native-type fallbacks, and the full cljsh round-trip. Suite is now 47 cases.
- README: `to edn` examples, end-to-end round-trip example, full type-mappings table.

### Planned for the next milestone
- `to edn --pretty` — pprint output instead of `pr-str` compact.
- `to edn --meta <record>` — Clojure-reader-style metadata prefix for the emitted top-level form (Clojure-only consumers; `^{...}` isn't EDN-spec).
- `to edn --keep-keyword-prefix` and `from edn --keep-keyword-prefix` — paired flags for round-trip keyword fidelity.
- `to edn --string-keys` — string-keyed maps for non-Clojure consumers.
- `to edn --lines` — emit each list element as its own top-level form (mirror of `from edn --lines`).

## [0.2.0] — 2026-05-03 — `from edn` feature-complete

This is the milestone where the parsing direction of the plugin is considered done. Every shape in the cljsh use case — scalar in, table out, bb pipe in, large input, unbounded streaming, early termination — works without workarounds.

### Added
- **ByteStream input.** `bb produce.clj | from edn` now works directly. The plugin consumes `:Data` messages until `:End`, acknowledging each chunk for backpressure. Previously this required an explicit `| collect` because the plugin only handled the in-memory `Value` input variant.
- **Multi-form input mode** via `--lines` (`-l`) or `--objects` (`-o`) flags. Either flag parses the input as a sequence of top-level EDN forms and emits each as a separate value through a `ListStream`. Form boundaries come from the EDN reader (matched brackets, quoted strings, comments stripped) — not newlines — so multi-line forms and `;` comments work transparently. Downstream commands like `| first 10` see a real stream and can short-circuit.
- **True input-side streaming** for `--lines` over a `ByteStream`. A custom `InputStream` proxy pulls bytes on demand from `:Data` messages, `clojure.edn/read` parses one form at a time across chunk boundaries, parsed values are emitted immediately, and a downstream `:Drop` on our output triggers a `:Drop` on the input — so unbounded producers (`tail -f`, infinite `(while true (prn ...))`) flow through without buffering and don't keep running once downstream is done. Single-form mode and `--lines` over an in-memory `Value` keep the existing buffered fast path.
- `bb` task entries for linting and formatting: `bb lint` (clj-kondo), `bb fmt` (apply cljfmt), `bb fmt-check` (verify), and `bb check` (lint + fmt-check together — the "always run before committing" task).
- 15 new integration tests covering ByteStream input, multi-form mode, streaming, comments, multi-line forms, alias equivalence, and large-producer + early-termination correctness. Suite is now 34 cases.

### Changed
- All Clojure source passes `clj-kondo` clean and `cljfmt check`. Three indentation issues were fixed in the lint/format pass.
- CLAUDE.md refreshed end-to-end: keyword stringification marked DONE, streaming sections updated, signature/metadata status documented, testing section reflects current 34-case suite, planned `--meta` and `--keep-keyword-prefix` flags on `to edn` recorded.

### Known limitations carried forward
- No `to edn` direction yet (the next milestone).
- Single-form parse errors return without source spans (`labels []` empty).
- Multi-form mid-stream parse errors are logged to stderr only (the protocol doesn't allow switching from a `ListStream` response to an `Error` response once the stream has been opened).
- Tagged literals beyond what `edn/read-string` handles natively (`#inst`, `#uuid`) are not supported.
- bb itself doesn't die on EPIPE, so a bb producer ignored by `| first N` keeps running after the engine closes the pipe. Other Unix producers (`tail -f`, `cat`, `grep --line-buffered`) honour EPIPE and exit cleanly. This is a bb quirk, not a plugin issue.

## [0.1.0] — 2026-05-03 — first working prototype

Initial registered release. Anchored to Nushell 0.112.2.

### Added
- `from edn` for EDN scalars (int, float, bool, string, nil, keyword, symbol), vectors, maps, sets (rendered as Nushell lists), lists, and arbitrarily nested structures.
- Plugin protocol handshake (encoding declaration, Hello, Metadata, Signature, Run, Goodbye).
- Keyword stringification: leading colon dropped, namespace preserved (`:file` → `"file"`, `:foo/bar` → `"foo/bar"`).
- Nushell integration test suite (`nu_plugin_edn.tests.nu`) — 19 cases.
- `bb.edn` with `test`, `register` task entries.

### Notes
- Anchored Nushell version moved from 0.110.0 to 0.112.2 during initial development after verifying no wire-protocol changes in the intervening releases.
