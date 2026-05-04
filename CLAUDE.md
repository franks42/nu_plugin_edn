# nu_plugin_edn — project brief for Claude Code

## What this is

A Nushell plugin that converts between [EDN](https://github.com/edn-format/edn) (Extensible Data Notation, the Clojure data format) and Nushell's structured-data values. The goal is to make EDN a first-class format alongside Nushell's existing `from json` / `from yaml` / `from toml` / etc. commands, so that values flowing between Nushell pipelines and Clojure/babashka scripts can round-trip without text-parsing intermediaries.

## Why this exists

Nushell has commands for parsing and emitting JSON, YAML, TOML, CSV, MessagePack, and several others. EDN was previously available through `nu_plugin_formats` in older releases, but is no longer in the bundled plugin (current bundled formats: csv, eml, ics, ini, json, msgpack, msgpackz, nuon, ods, plist, ssv, toml, tsv, url). Issue [#6415](https://github.com/nushell/nushell/issues/6415) has been open since 2022 requesting EDN support; this plugin closes that gap.

## Project goals — the user-facing commands

The plugin provides two pipeline commands:

```nushell
# Parse EDN text into Nushell values
'{:name "alice" :age 30}' | from edn
# → {name: alice, age: 30}

'[{:filename "a.txt" :size 100} {:filename "b.txt" :size 200}]' | from edn
# → ╭───┬──────────┬──────╮
#    │ # │ filename │ size │
#    ├───┼──────────┼──────┤
#    │ 0 │ a.txt    │  100 │
#    │ 1 │ b.txt    │  200 │
#    ╰───┴──────────┴──────╯

# Emit Nushell values as EDN text
{name: "alice" age: 30} | to edn
# → {:name "alice" :age 30}

# Round-trip through bb (this is the real motivation — see "use case" below)
bb my-script.clj | from edn | where size > 1000 | sort-by size | to edn | bb other-script.clj
```

## The motivating use case (why this matters beyond just supporting EDN)

The bigger picture this plugin enables: **using Nushell as the shell for Clojure-fluent users (especially LLM agents like Claude Code) by replacing the brittle bash↔babashka boundary**.

Today, when Claude Code runs a babashka script, the invocation goes through bash. Bash's quoting and escape rules corrupt args before bb sees them — backticks, `$`, single vs double quotes, history expansion (`!`). This is a recurring source of silent failures for LLM-driven workflows.

With Nushell as the shell, plus this plugin:
- Bb scripts emit EDN, which flows through Nushell pipelines without corruption.
- Nushell's quoting rules are regular and well-defined.
- Structured data flows end-to-end; the parsing-as-text round-trip disappears.
- Other bb scripts in the same pipeline receive EDN directly, no escaping concerns.

This is more important than just "support another format." It enables a working architecture for LLM agents doing shell-pipeline work.

## Implementation language: babashka

**Use babashka**, not Rust. Reasons:

1. **Fits the audience.** Anyone using this plugin is by definition an EDN/Clojure user. Requiring bb for the plugin runtime is essentially the same audience as requiring bb for the scripts the plugin enables.

2. **Iteration speed.** The Nushell plugin protocol changes between minor versions (we've seen plugin protocol rewrites in 0.91, 0.92, ongoing). Bb makes protocol updates a sed-fix, not a recompile cycle.

3. **Single executable file.** A bb script is itself a self-contained executable on systems with bb installed. No cargo, no compilation, no platform-specific binaries.

4. **The example serves the community.** A working bb-based plugin demonstrates the protocol clearly enough that other Clojure-shaped plugins (`nu_plugin_kindly`, `nu_plugin_datalog`, etc.) become easy to write.

**The trade-off being accepted:** end users need bb installed (one extra dependency). Startup is ~30ms vs Rust's ~5ms — irrelevant for one-shot pipeline use, mildly noticeable in tight loops.

If this plugin gets traction and the bb startup cost or dependency becomes a real concern, the bb implementation is the reference for a future Rust port. Don't pre-emptively rewrite in Rust; ship bb first.

## What's in the box

- `nu_plugin_edn` — the plugin itself, executable bb script. Two commands registered (`from edn`, `to edn`), full protocol handshake, ByteStream input + ListStream input/output, multi-form mode with true incremental streaming. Latest tag: `v0.112.2` (Nushell-aligned versioning — see "Versioning scheme" below).
- `nu_plugin_edn.tests.nu` — Nushell integration tests (47 cases, all passing on Nushell 0.112.2).
- `bb.edn` — bb task entry points: `bb register`, `bb test`, `bb lint`, `bb fmt`, `bb fmt-check`, `bb check` (lint + fmt-check; the pre-commit task), `bb release-check` (refuses to ship a SNAPSHOT version — run before `git tag`). No external `:deps` — the plugin uses only libraries bundled with babashka (`clojure.edn`, `cheshire`).
- `.github/workflows/` — three CI workflows: `test.yml` (matrix CI on push/PR), `nushell-drift.yml` (weekly compat watcher; opens PR on green, issue on red), `release.yml` (auto-builds asset and creates GitHub Release on `v*.*.*` tag push).
- `bb-prototype-notes.md` — protocol-level findings: handshake gotchas, ByteStream input, ListStream input/output, incremental-streaming machinery, bb-proxy quirks. Living document — append to it as you learn.
- `README.md` — user-facing docs, install instructions, `to edn` type-mappings table, CI badge.
- `LICENSE` — MIT.
- `CHANGELOG.md` — Keep-a-Changelog format, `[Unreleased]` section heading carries the SNAPSHOT version during dev windows.

## What's working

### Protocol layer
- Handshake (encoding declaration, Hello, Metadata, Signature, Run, Goodbye).
- ByteStream input (buffered single-form path; truly incremental for `--lines`/`--objects`).
- ListStream input (collected to a list before serialization in `to edn`).
- ListStream output (forms emitted as they're parsed in `from edn --lines`).

### `from edn`
- All standard EDN shapes: maps, vectors, lists, sets (default: rendered as Nushell lists; opt into `{k: k}` mirror records via `--set2record`), strings, ints, floats, booleans, nil, symbols (as strings), keywords, nested.
- **Tagged literals**: `#inst "..."` becomes a Nushell `Date` (so downstream `format date`, comparisons, and date filters Just Work); `#uuid "..."` becomes a Nushell `String` (Nushell has no native UUID type — the `^uuidv7` CLI provides UUIDv7-aware operations on top).
- **Keyword stringification**: leading colon dropped, namespace preserved (`:file` → `"file"`, `:foo/bar` → `"foo/bar"`). Implemented as `(subs (str v) 1)` — deliberately not `(name v)`, which would silently strip namespaces.
- **`--set2record`** (opt-in): renders an EDN set as a Nushell record in mirror form (`{a: a, b: b, c: c}` for `#{:a :b :c}`). Pairs with `to edn --record2set` for round-trip. Loss-free for keyword/string sets only — Nushell record keys are strings, so int/composite-keyed sets degrade.
- **Input shapes**: `Empty`, `Value` (literal string), `ByteStream` (piped external stdout). For single-form mode `ByteStream` is buffered to a string; for `--lines`/`--objects` it's consumed truly incrementally.
- **Multi-form mode** via `--lines` (`-l`) or `--objects` (`-o`): parses every top-level form, emits each through a `ListStream`. Form boundaries come from the EDN reader — not newlines — so multi-line forms and `;` comments work transparently.
- **`open file.edn`** auto-parses via the registered command; no explicit `from edn` needed.

### `to edn`
- Records → maps with **keyword keys** (`{:name "alice"}`), the chosen default for cljsh ergonomics.
- Lists / tables → vectors of maps.
- `Nothing` → `nil`. `Date` → `#inst "..."` (round-trips).
- Nushell-native types without an EDN equivalent fall back to primitives:
  - Duration → integer milliseconds (lossy: ns precision dropped).
  - Filesize → integer bytes (unit dropped).
  - Binary → base64 string (not a tagged literal).
- Range, Closure, CellPath, CustomValue, Error → `#<TypeName>` placeholder string so the user sees what was lost.
- **Input shapes**: `Empty`, `Value`, `ListStream` (collected). `ByteStream` rejected with a clear error (raw bytes don't make sense for serialization).
- Built on `pr-str` — no custom serializer, no puget dependency.

## What's not working / needs implementing

In rough priority order:

### 1. Keyword stringification — DONE

Resolved: drop the leading colon by default, preserve namespace. `:file` → `"file"`, `:foo/bar` → `"foo/bar"`. Implemented as `(subs (str v) 1)` — `(name v)` would silently strip namespaces, which is wrong.

Tradeoff accepted: round-trip fidelity is lost in the default mode (a Nushell `"file"` could have started life as either an EDN string or an EDN keyword). The opt-in fidelity escape hatch shipped as the paired `--keep-keyword-prefix` flag on both `from edn` and `to edn`: keywords carry their `:` as a marker through the Nushell value (`:foo` → `":foo"`), and emit back as keywords. One-way fidelity loss documented: plain strings starting with `:` will coerce to keywords on the to-edn side.

### 2. `to edn` (reverse direction) — DONE (basic)

Shipped. Records emit as maps with keyword keys (`{:name "alice"}`); lists/tables become vectors; `Nothing` → `nil`; `Date` → `#inst`. Built on `pr-str` — no custom serializer, no puget dependency. Accepts `Value`, `ListStream` (collected first), and `Empty` inputs.

Type fallback policy chosen for Nushell-native types without an EDN equivalent:
- Duration (nanoseconds) → integer milliseconds.
- Filesize → integer bytes.
- Binary → base64 string.
- Range / Closure / CellPath / CustomValue / Error → `#<TypeName>` placeholder string so the user sees what was lost.

Lossy by design — round-tripping these specific types isn't supported and isn't planned. A user who needs them can wrap manually before `to edn`.

Shipped flags (all those needing plugin-side typed-value access — see "Plugin scope" below for the boundary principle):
- `--lines` / `--objects` — emit each list element as its own top-level form. Shipped in v0.112.2-1.
- `--pprint` — pretty-print via `clojure.pprint`. Mutually exclusive with `--lines`/`--objects`.
- `--record2set` (paired with `from edn --set2record`) — emit a mirror-form record (`{k: k}`) as an EDN set. Round-trip pair for keyword/string sets.
- `--keep-keyword-prefix` (paired with `from edn --keep-keyword-prefix`) — keep the leading `:` as a marker through Nushell strings; re-emit `:`-prefixed strings as keywords. One-way fidelity loss: plain strings starting with `:` coerce to keywords on the emit side.
- `--string-keys` — emit record keys as EDN strings (`{"name" ...}`) instead of keywords (`{:name ...}`). For pipelines feeding Python/JS/Go EDN parsers. Combines with `--keep-keyword-prefix`: `--string-keys` wins for keys; `--keep-keyword-prefix`'s value-side effect is independent.
- `--meta <record>` — prefix the emitted top-level form with Clojure-reader-style metadata: `{a: 1} | to edn --meta {source: "nu"}` emits `^{:source "nu"} {:a 1}`. A bb consumer reads it back via `(meta v)`. **Non-portable**: `^{...}` is Clojure-reader syntax, not EDN spec — Python/JS/Go EDN parsers will reject it. For consumers that may not be Clojure, the portable alternative is to wrap manually: `{context: {...} data: $val} | to edn`. Mutually exclusive with `--lines`/`--objects`; rejects non-record arguments.

### Why `--pretty` and `--canonical` are NOT in the plugin

These were planned earlier; we then realised they violate the **typed-value boundary principle** (see "Plugin scope" below). Both are pure text-on-text transformations of the EDN bytes the plugin already emits — they don't need access to Nushell typed values. Better realised as standalone bb-script filters in their own repos:

- **Pretty-print**: a `pprint-edn` bb filter (`<edn> | pprint-edn`) wrapping `clojure.pprint`. Could live as a one-liner in user docs or as a small standalone tool.
- **Canonical**: shipped as the `cedn` CLI in the [canonical-edn](https://github.com/franks42/canonical-edn) repo (single bb script wrapping the cedn library). Compose via Unix pipes: `data | to edn | ^cedn | from edn` round-trips through canonical form; `data | to edn | ^cedn | sha256sum` produces a deterministic content hash. Released alongside the cedn library on GitHub Releases as a versioned asset. Reusable in any pipeline that produces EDN bytes — not just Nushell-driven ones.

This principle cleans up the plugin's surface area significantly and lets each transformation evolve at its own cadence in its own repo.

### Concurrent plugin Calls in the same pipeline

Nushell pipelines plugin Calls concurrently: in `bb ... | from edn --lines | to edn --lines | ...`, multiple plugin Calls are in flight at once and the engine routes data between them via the same stdin/stdout. While the plugin is processing Call A, messages destined for Call B arrive on stdin — both `:Call(B)` itself and `:Data` for B's input stream (which is A's output, looped back).

Our plugin processes Calls serially, but stays correct in this scenario by **routing**, not blocking:

- **`pending-calls`** — atom-vec of `:Call` messages that arrive during another Call's processing. The main loop drains it before reading more from stdin.
- **`stream-buffers`** — atom-map of stream-id → vector of pending `:Data`/`:End` messages. When a stream reader sees a message for a stream id it isn't currently consuming, it buffers the message under that id instead of discarding it. A future reader for that stream id will find the buffered messages first.

Both buffers live in `pull-stream-msg`, the unified message-pull helper used by all three readers (`read-byte-stream`, `read-list-stream`, `refill-stream-input!`). The helper takes a `stream-id` (and an optional `out-state` for output-Drop tracking) and returns the next `:Data`/`:End` message for that stream — pulling from the buffer first, otherwise reading stdin and routing what it finds.

This stays correct without threads at the cost of one design constraint: a Call can't read its input incrementally while *also* responding to its own engine traffic, so very large stream-piped pipelines may buffer more than is strictly necessary. For the cljsh use case (typical bb output sizes), this hasn't been a problem.

### 3. Streaming input

Both directions are now incremental:

- **Single-form mode** (no flag) still buffers a `ByteStream` to a string before parsing — the right tradeoff for `'edn-text' | from edn` and similar single-document inputs.
- **Multi-form mode** (`--lines` / `--objects`) over a `ByteStream` is fully streaming end-to-end: a custom `InputStream` pulls bytes on demand via `:Data` messages, `clojure.edn/read` parses one form at a time across chunk boundaries, parsed values are emitted to the output `ListStream` immediately, and a downstream `:Drop` on our output triggers a `:Drop` on the input so the engine can tear down unbounded producers (`tail -f`, infinite `(while true (prn ...))`).

The remaining limitation is producer-side: bb's default behaviour is to swallow `EPIPE` on stdout, so a bb producer ignored by a `first N` keeps running after the engine closes the pipe (visible as orphaned bb processes). Other Unix producers (`tail -f`, `cat`, etc.) honour `EPIPE` and exit cleanly. This is a bb quirk, not a plugin issue.

### 4. Better error reporting

- **Single-form and buffered multi-form modes**: parse errors carry a source-span label pointing at the offending position. We wrap the input in a `clojure.lang.LineNumberingPushbackReader`, run `clojure.edn/read` against it, and on exception query the reader's `.getLineNumber` / `.getColumnNumber`. Translating that 1-indexed position into a 0-indexed char offset, then a UTF-8 byte offset (Nushell spans are byte-indexed), and adding the source span's `:start` gives an absolute position that Nushell underlines in the rendered error. ByteStream input gets no label — its bytes have no script-level span, so there's nothing to point at.
- **Multi-form streaming mode** (incremental over a `ByteStream`): once the plugin has opened a `ListStream` and started emitting `:Data`, it can't switch to an `:Error` response — the protocol doesn't allow it. The plugin now emits a `Value::Error` as the final list element so downstream sees the failure inline; `try/catch` picks it up via the standard error machinery. Implementation note: `ShellError` serializes as `LabeledError`, so the wire shape is `{:Error {:error {:msg :labels :code :url :help :inner} :span <span>}}` — same field set as a top-level error response.

### 5. Plugin signature and metadata

Done: both commands have descriptions, search terms, category `"Formats"`, and registered flags. `:Metadata` reports `plugin-release` (with the `-SNAPSHOT` suffix during dev, plain at release time). Both signatures live as named defs (`from-edn-sig`, `to-edn-sig`) at the top of the dispatch block so they're easy to extend.

Still missing: `:examples` is empty for both commands. The protocol supports inline examples that surface in `help from edn` / `help to edn`; populating them (literal-string parses, the cljsh round-trip, `--lines` over a bb pipe, `to edn` of a record/table) is a small, high-value polish task. Author field on `:Metadata` is also unset.

### 6. Plugin registry conventions

- Filename must start with `nu_plugin_` (already correct). Asset filename on releases is `nu_plugin_edn-vX.Y.Z`; users curl-then-rename to the canonical `nu_plugin_edn` for `plugin add`. README documents the one-liner.
- Submit to [awesome-nu](https://github.com/nushell/awesome-nu) once a working release is in hand. **Blocker**: their `config.yaml` schema currently accepts `language: rust|python|go|typescript`. Adding `language: clojure` (or `babashka`) requires a PR to their schema first, then a separate PR adding our entry. Two-step.
- Reference issue [#6415](https://github.com/nushell/nushell/issues/6415) in the awesome-nu submission and (eventually) on the issue itself.

## Protocol gotchas

These bit during initial development and will bite again on every protocol-shape rework:

**1. Encoding handshake direction.** Plugin sends encoding name to Nushell *first*, not the other way around. Format: one byte for length, then the name bytes ("json" = `\x04json`). Easy to get backwards from reading the protocol docs.

**2. Field name `span`, not `internal_span`.** The protocol docs are inconsistent; as of 0.110 (verified through 0.112.2), all the value records use `:span {:start N :end N}`. If you see `missing field 'span'` errors, this is it.

**3. Goodbye arrives as a string, not a map.** The control messages `Hello`, `Goodbye` aren't all the same shape. `Hello` is a map `{:Hello {...}}`; `Goodbye` is just the string `"Goodbye"`. Type-dispatch defensively.

**4. `Metadata` call must be handled.** Before the first `Run`, Nushell sends a `Metadata` call. If you don't reply (with even a minimal response), the plugin appears hung.

**5. Bb's `*out*` needs explicit flush.** Each protocol message must end with a flush, or Nushell will appear to hang waiting for a complete message. The prototype calls `(flush)` after every `send-msg`.

**6. Plugin protocol is stable across registration and use, but `plugin add` and `plugin use` need the same `--plugin-config` flag** when not using the default config dir. Document the install steps clearly.

## Testing

`bb test` runs the suite (`nu nu_plugin_edn.tests.nu` directly works too — bb is just the convenience entry point). The plugin must be registered first via `bb register`.

What the suite covers today (63 unconditional + up-to-7 conditional ecosystem tests):

- **`from edn` scalars**: int, float, bool, string, nil.
- **`from edn` collections**: vector, map, list (sets are converted to lists, no separate test).
- **`from edn` nested structures**, the cljsh use case (`[{:filename ... :size ... :type ...} ...]`).
- **`from edn` tagged literals**: `#inst` → Nushell Date (verified via `describe`), `#uuid` → string.
- **Keyword stringification**: colon dropped, namespace preserved.
- **ByteStream input**: from `^echo`, from `bb -e`, large input (1000 records), `open` of a `.txt` file.
- **Multi-form mode (`--lines`/`--objects`)**: scalar count, mixed shapes, alias equivalence, multi-line forms, comment stripping, streamed bb output, record extraction, `first N` short-circuit, large producer (5000 records) + `first N` correctness.
- **`to edn`**: scalars (int, nil, string, empty record, empty list), simple record, list of records, nested, native-type fallbacks (filesize, duration, date), round-trips (simple, nested), end-to-end cljsh round-trip (bb → from edn → where → to edn → from edn).
- **Ecosystem integration** (conditional): `^cedn` round-trip, canonicalization key-sort verification, byte-stability across runs; `^uuidv7 gen` shape, `^uuidv7 parse | from edn` record-shape; cross-tool `uuidv7 gen --format edn → from edn → to edn → ^cedn`. Skipped silently if the CLIs aren't on PATH (no `which cedn` / `which uuidv7`).

Gaps (deliberately or as TODO):
- **Error-case tests** — malformed EDN, missing closing brace, truncated input. Five cases live in the test file: error happens, useful message, source-span label present (Value input), no label for ByteStream input, label present in `--lines` mode. Exact span offsets aren't asserted (they shift with surrounding script bytes).
- **Megabyte-scale streaming tests** — current largest is 5000 records (~30 KB).
- **Unbounded producer + `first N`** — works correctness-wise, but bb itself doesn't die on EPIPE so the test would leak processes; needs a non-bb producer (`yes`, `tail -f`) to be reliable.
- **Per-flag tests for shipped `to edn` flags** are present (`--lines`/`--objects`/`--pprint`/`--record2set`/`--keep-keyword-prefix`/`--string-keys`/`--meta`). (`--pretty` and `--canonical` were dropped from the plugin per the typed-value boundary principle; their tests live with whichever filter implements them.)

A test fails if its expected output doesn't match. Don't catch and ignore errors in tests — let them fail loud.

## Versioning scheme

**Plugin version mirrors the Nushell version it's anchored against.** v0.112.2 pairs with Nushell 0.112.2; v0.113.0 will pair with Nushell 0.113.0; etc. Same convention used by `nu_plugin_endecode`, `nu_plugin_kdl`, and Nushell's bundled plugins. Earlier semver-style releases (v0.1.0 / v0.2.0 / v0.3.0) stay browsable on the Releases page but won't have successors.

Plugin-only patches between Nushell minors (when needed) get a `-N` suffix: `0.112.2-1`, `0.112.2-2`, etc.

### Two version constants in the source

The plugin file has **two** version strings, answering different questions:

```clojure
(def nushell-target
  (or (System/getenv "NU_PLUGIN_EDN_NU_VERSION") "0.112.2"))

(def plugin-release "0.112.2-SNAPSHOT")
```

- **`nushell-target`** is sent in the `Hello` message. Nushell does a strict equality check against the running version; if it doesn't match, registration fails. The `NU_PLUGIN_EDN_NU_VERSION` env-var override lets CI sweep across Nushell versions from a single source tree without rewriting the source.
- **`plugin-release`** is sent in the `:Metadata` response. It's our own release identity, decoupled from the protocol negotiation. During dev windows it carries a `-SNAPSHOT` suffix that's visible to users via `plugin list | get version`. The `bb release-check` task refuses to ship a SNAPSHOT.

### Release dance

To ship the next release after Nushell ships a new version:

1. (Probably automated by `nushell-drift.yml`) — bump `nushell-target` to the new Nushell version, set `plugin-release` to `<new>-SNAPSHOT`. Verify tests pass.
2. Land any plugin-only changes during the SNAPSHOT window.
3. Drop the `-SNAPSHOT` suffix on `plugin-release`.
4. `bb check` (lint + fmt clean) and `bb release-check` (no SNAPSHOT).
5. Update CHANGELOG: cut `[<version>]` from `[Unreleased]`.
6. `git commit && git tag v<version> && git push origin main && git push origin v<version>`.
7. `release.yml` builds the asset and creates the GitHub Release.
8. Bump `plugin-release` back to the next `-SNAPSHOT` (the start of the next dev window). Commit, push.

### When the upstream protocol changes

If `nushell-drift.yml` opens an issue ("Nushell X.Y.Z compat broken") rather than a PR, the protocol or behaviour shifted. Procedure:

1. Diff `crates/nu-plugin-protocol/` and `crates/nu-plugin/` between the previously-anchored version and the new one in the upstream Nushell repo. Look for serialization-shape changes — new required fields, renamed variants, removed messages.
2. Fix the plugin (`nu_plugin_edn`) to match. `bb-prototype-notes.md` documents the wire shapes we depend on.
3. Run `bb test` against the new Nushell. Iterate until green.
4. Then proceed with the release dance above.

History: anchor moved 0.110.0 → 0.112.2 during initial development after inspecting `git log 0.110.0..0.112.2 -- crates/nu-plugin-protocol/ crates/nu-plugin/` and confirming no wire-protocol shape changes (only internal Rust refactors).

## CI / GitHub Actions

Three workflows in `.github/workflows/`:

- **`test.yml`** — runs on every push to `main` and every PR. Strategy matrix over Nushell versions; currently `[0.112.2]`. Each row installs that Nushell, sets `NU_PLUGIN_EDN_NU_VERSION` to match, runs `bb check` (lint + fmt-check) and the integration suite. To extend coverage when we anchor against a new Nushell, just add to the matrix. Uses `actions/checkout@v6` and `DeLaGuardo/setup-clojure@13.6.0`.

- **`nushell-drift.yml`** — runs on a Monday-06:00-UTC cron, with manual `workflow_dispatch` for testing. Fetches the latest Nushell tag, compares to `nushell-target`, exits clean if they match. If newer, installs that Nushell, runs the suite with the env-var override, and: opens a PR (with the source bumps and `-SNAPSHOT` suffix) on green, opens an issue (with the failure log) on red. Both PR and issue carry the `nushell-compat` label. Permissions in the workflow: `contents: write`, `pull-requests: write`, `issues: write`.

- **`release.yml`** — runs on `v*.*.*` tag push. Validates that `plugin-release` matches the tag and isn't a SNAPSHOT (via `bb release-check`), builds the version-suffixed asset (`nu_plugin_edn-vX.Y.Z`), creates the GitHub Release with `--generate-notes`. Auto-generated notes are minimal — usually worth manually polishing the release body via `gh release edit` afterward.

## What success looks like

- ✅ `from edn` and `to edn` work as drop-in pipeline commands.
- ✅ A Clojure user can `bb my-script.clj | from edn | where size > 1000 | sort-by size` and it just works.
- ✅ A bb script can be the source AND target of an EDN pipeline: `bb produce.clj | from edn | where ... | to edn | bb consume.clj`.
- ⏳ The plugin is in the awesome-nu registry. (Submission needs a `language: clojure` PR to their `config.yaml` schema first — none of the existing accepted languages applies.)
- ⏳ Issue #6415 gets a "fixed by external plugin" reference. (To be commented once awesome-nu submission lands.)

## Plugin scope (the typed-value boundary principle)

`nu_plugin_edn`'s job is to translate between Nushell's value system and EDN text. **Anything that doesn't cross that boundary should not be in the plugin.** Concretely:

- ✅ **In scope**: `from edn` (EDN text → typed values), `to edn` (typed values → EDN text), and flags that affect how the typed walk happens (`--lines`/`--objects` iterate over input structure; `--meta` walks a record argument; `--keep-keyword-prefix` and `--string-keys` affect how typed values map to EDN tokens).
- ❌ **Out of scope**: anything that's pure text-on-text transformation of EDN bytes after they've been emitted, or pre-parsed before they enter. Pretty-printing, canonicalization, schema validation, signing, hashing, encryption — none of these need typed-value access. They belong in standalone bb-script filters that compose via Unix pipes.

The "Clojure-shaped Nushell ecosystem" pattern that emerges:

```
                                                         ┌─→ cedn       (canonical)
typed-value pipeline ─→ to edn ─→ EDN bytes ─→ pipe ─────┼─→ pprint-edn (pretty)
(Nushell records,                                         ├─→ signet     (signing)
 lists, etc.)                                             └─→ ...
```

Each downstream filter ships in its own repo (cedn, signet, etc.), versioned independently, with its own GitHub Releases distribution. nu_plugin_edn doesn't bundle them, doesn't have flags for them, and stays small.

## Ecosystem ideas — filters and adjacent plugins

Most "do something with EDN" needs are better satisfied as **bb-script filters living in their reference library's repo** rather than as Nushell plugins. The plugin model only earns its weight when typed-value access is genuinely needed (the `from edn` / `to edn` boundary).

### Filters that should ship from their library repos

- ✅ **`cedn`** — canonical EDN filter shipped from the [canonical-edn](https://github.com/franks42/canonical-edn) repo. Single bb script (`bin/cedn`) wrapping the cedn library, with `--input`/`--output`/`--edn`/`--objects`/`--help`/`--version` flags. Streams form-by-form, EPIPE-clean, dev-mode uses local source / release-mode pulls cedn from Clojars via `add-deps`. Released as a versioned asset on GitHub Releases. Use cases: `data | to edn | ^cedn | sha256sum` (content hash), `data | to edn | ^cedn | from edn` (canonical round-trip via Nushell), `cat config.edn | ^cedn` (normalize whitespace). The pattern (single bb script in the reference library's repo, GH-Released alongside the library) is the template for the next two.
- ✅ **`uuidv7`** — UUIDv7 generator/parser/validator CLI shipped from [uuidv7.cljc](https://github.com/franks42/uuidv7.cljc). Three subcommands: `gen` (generate), `parse` (extract `{:uuid :uri :datetime :counter}` as EDN), `valid` (predicate, exit 0/1). Three output formats per emit (uuid / urn / edn). Same single-bb-script + dev-vs-release-source-resolution pattern as `cedn`. Composes via `^uuidv7 parse $id | from edn | get datetime`. Released as `uuidv7-vX.Y.Z` on GitHub Releases.
- ⏳ **`pprint-edn`** — bb filter wrapping `clojure.pprint`. ~30-line script: `slurp *in*` → `clojure.edn/read-string` → `clojure.pprint/pprint` → stdout. Useful for human-readable inspection of EDN streams in the same way `jq` is for JSON. Could live in its own tiny repo, or — given how minimal it is — as a documented one-liner alias in user docs. The `^cedn` / `^uuidv7` pattern (Maven dep on a library) doesn't really fit since there's nothing to library-ize; clojure.pprint is already in bb's stdlib.
- ⏳ **Signet CLIs** — `signet-keygen`, `signet-sign`, `signet-verify`, etc., from the [signet](https://github.com/franks42/cljc-25519) repo (the cljc-25519 / signet library). Composable with `to edn | ^cedn` as the canonical-bytes producer.

### Plugins that genuinely need to be plugins

- **None planned beyond `nu_plugin_edn` itself**, given the boundary principle. Most "Clojure-shaped Nushell tool" ideas resolve into "bb-CLI in a Clojure library's repo" instead.
- A `nu_plugin_<format>` plugin only earns its keep when the format has a typed surface in Nushell that can't be expressed as text-on-text (e.g., a binary format that needs structured Nushell output that goes beyond what `from edn` / `from json` can deliver).

### Distribution pattern (recommended for any of the above filters)

Same model `nu_plugin_edn` uses now, scaled down:

- Single executable bb script in the library's repo.
- Versioned alongside the library (so `cedn` v1.2.0 ships with cedn library v1.2.0).
- GitHub Releases with version-suffixed asset (`cedn-v1.2.0`, install as `cedn`).
- Optional `bb release-check` discipline if the SNAPSHOT/release distinction matters.
- Test workflow exercises the CLI via stdin/stdout fixtures.

The `nu_plugin_edn` repo's `.github/workflows/release.yml` and `bb.edn` are reasonable templates to copy when bootstrapping these filters.

## What success does NOT require

- Perfect EDN feature coverage. Tagged literals beyond `#inst` and `#uuid`, namespaced maps, custom readers — defer until someone asks.
- Performance parity with Rust plugins. We're targeting "works correctly," not "as fast as `from json`."
- Round-tripping every Nushell type. Some Nushell-native types (duration, filesize, binary) don't have EDN representations; document the limitation, emit best-effort.

## Conventions for this repo

- Single bb file for the plugin itself. Avoid splitting into namespaces unless the plugin grows past ~500 lines.
- Tests in nushell, not bb. We're testing the integration, not the bb internals.
- Document protocol-level findings in `bb-prototype-notes.md` as you discover them. The protocol is under-documented; this file is part of the contribution.
- When in doubt about Nushell behavior, run the plugin against real Nushell and observe; don't reason from docs alone.
- **Always lint and format Clojure code after edits.** After any change to `nu_plugin_edn` (the plugin source) or `bb.edn`, run `bb check` (clj-kondo + cljfmt check). If `bb check` fails on formatting, run `bb fmt` to apply, then re-run `bb check`. Never commit code that hasn't been through both. This is non-negotiable — do not rely on the user to remind you.
- **Always `bb release-check` before tagging a release.** It refuses to ship a SNAPSHOT version. The release workflow runs it too, so a violation will fail CI rather than ship — but catching it locally is faster.
