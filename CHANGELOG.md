# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once a 1.0 ships.

## [Unreleased]

(Nothing yet. Planned: `to edn`; see CLAUDE.md roadmap.)

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
