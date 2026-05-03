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

- `nu_plugin_edn` — the plugin itself, executable bb script. Past prototype: handles the protocol, all common EDN shapes, multi-form mode, and incremental streaming. Tagged `v0.1.0`.
- `nu_plugin_edn.tests.nu` — Nushell integration tests (currently 34 cases, all passing on Nushell 0.112.2).
- `bb.edn` — bb task entry points: `bb register`, `bb test`, `bb check` (clj-kondo if installed). No external `:deps` — the plugin uses only libraries bundled with babashka (`clojure.edn`, `cheshire`).
- `bb-prototype-notes.md` — protocol-level findings: handshake gotchas, ByteStream input, ListStream output, incremental-streaming machinery, bb-proxy quirks. Living document — append to it as you learn.
- `README.md` — user-facing docs and install instructions.
- `LICENSE` — MIT.
- `CHANGELOG.md` — Keep-a-Changelog format, `[Unreleased]` section maintained as features land.

## What's working

- Plugin handshake (encoding declaration, Hello exchange, Metadata, Signature, Run, Goodbye).
- `from edn` for: maps, vectors, strings, integers, floats, booleans, nil, sets (rendered as Nushell lists since Nushell has no set type), nested values, symbols (as strings), keywords.
- **Keyword stringification**: leading colon dropped, namespace preserved (`:file` → `"file"`, `:foo/bar` → `"foo/bar"`). Implemented as `(subs (str v) 1)` — deliberately not `(name v)`, which would silently strip namespaces.
- **Input shapes handled**:
  - `Empty` (no upstream)
  - `Value` (in-memory String, e.g. literal `'edn-text' | from edn`)
  - `ByteStream` (piped external stdout). For single-form mode this is buffered to a string; for `--lines`/`--objects` it's consumed truly incrementally.
- **Multi-form mode** via `--lines` (`-l`) or `--objects` (`-o`): parses every top-level form from the input, emits each through a `ListStream`. Form boundaries come from the EDN reader (matched brackets, quoted strings, comments stripped) — not newlines — so multi-line forms and `;` comments work transparently.
- **True incremental streaming** for `--lines` over `ByteStream`: bytes are pulled on demand via a custom `InputStream` proxy, forms are emitted as they're parsed, and a downstream `:Drop` on our output triggers a `:Drop` on the input so the engine can tear down unbounded producers.
- **`open file.edn`** auto-parses via the registered command — a free side-effect of registration; no explicit `from edn` needed.

## What's not working / needs implementing

In rough priority order:

### 1. Keyword stringification — DONE

Resolved: drop the leading colon by default, preserve namespace. `:file` → `"file"`, `:foo/bar` → `"foo/bar"`. Implemented as `(subs (str v) 1)` — `(name v)` would silently strip namespaces, which is wrong.

Tradeoff accepted: round-trip fidelity is lost (a Nushell `"file"` could have started life as either an EDN string or an EDN keyword). The opt-in fidelity escape hatch — a `--keep-keyword-prefix` flag on both `from edn` and `to edn` — is on the roadmap; see section 2 (Planned flags).

### 2. `to edn` (reverse direction)

The prototype only does `from edn`. Implementing `to edn` is a mirror image of the conversion logic plus EDN serialization. Cheshire doesn't emit EDN; you'll write the serializer (or use [puget](https://github.com/greglook/puget) if it works in bb — verify, don't assume).

Implementation hints:
- Nushell records → EDN maps. Choose: keyword keys (`{:name "alice"}`) or string keys (`{"name" "alice"}`)?
- Nushell lists → EDN vectors.
- Nushell tables (lists of records) → EDN vectors of maps.
- Nushell `Nothing` → EDN `nil`.
- Nushell `Date` → EDN `#inst "..."`.
- Don't try to round-trip nuon-specific types (durations, file sizes); document the limitation.

Planned flags for `to edn`:
- `--meta <record>` — prefix the emitted top-level form with Clojure-reader-style metadata: `{a: 1} | to edn --meta {source: "nu", at: (date now)}` emits `^{:source "nu" :at #inst "..."} {:a 1}`. Useful for attaching provenance/context that a bb script on the receiving end can pick up via `(meta v)`. **Caveat**: `^{...}` is Clojure-reader syntax, not in the EDN spec proper — non-Clojure EDN parsers (Python, JS, Go) will reject it. Document this loudly. For pipelines that may reach non-Clojure consumers, the portable alternative is to wrap manually: `{context: {...} data: $val} | to edn`. We're not adding a separate `--wrap` flag for that — the wrap pattern is one line of Nushell, no plugin help needed.
- `--keep-keyword-prefix` — opt-in keyword-fidelity emission, the inverse of the `from edn` flag of the same name. When set, strings that round-trip from EDN keywords (currently a string with no leading colon, no spaces) get re-emitted as keywords. Probably needs a heuristic on the producer side (e.g. only known field names) since pure strings and ex-keywords are indistinguishable in Nushell.

### 3. Streaming input

Both directions are now incremental:

- **Single-form mode** (no flag) still buffers a `ByteStream` to a string before parsing — the right tradeoff for `'edn-text' | from edn` and similar single-document inputs.
- **Multi-form mode** (`--lines` / `--objects`) over a `ByteStream` is fully streaming end-to-end: a custom `InputStream` pulls bytes on demand via `:Data` messages, `clojure.edn/read` parses one form at a time across chunk boundaries, parsed values are emitted to the output `ListStream` immediately, and a downstream `:Drop` on our output triggers a `:Drop` on the input so the engine can tear down unbounded producers (`tail -f`, infinite `(while true (prn ...))`).

The remaining limitation is producer-side: bb's default behaviour is to swallow `EPIPE` on stdout, so a bb producer ignored by a `first N` keeps running after the engine closes the pipe (visible as orphaned bb processes). Other Unix producers (`tail -f`, `cat`, etc.) honour `EPIPE` and exit cleanly. This is a bb quirk, not a plugin issue.

### 4. Better error reporting

Two distinct gaps:

- **Single-form mode**: parse errors return as `:Error` with a message, but `labels []` is empty — Nushell can't highlight the offending position in the source. Compute the span from the EDN reader's exception (it knows char position) and emit it.
- **Multi-form streaming mode**: once the plugin has opened a `ListStream` and started emitting `:Data`, it can't switch to an `:Error` response — the protocol doesn't allow it. Currently a mid-stream parse error is logged to stderr and the stream is closed (truncated output, no error visible to the user). Better behavior: emit a Nushell `Value::Error` as the final list element so downstream sees the error inline. Polish item, not blocker.

### 5. Plugin signature and metadata

Done: `from edn` has a description, `:search_terms ["edn" "clojure" "parse"]`, `:category "Formats"`, the `--lines` and `--objects` flags with descriptions.

Still missing: `:examples` is empty. The protocol supports inline examples that surface in `help from edn`; populating it (literal-string parses, the cljsh use case, `--lines` over a bb pipe) is a small, high-value polish task. `:Metadata` response also still uses a placeholder `{:version "0.1.0"}` — should track the actual release version and add author/description fields when `to edn` lands.

### 6. Plugin registry conventions

- Filename must start with `nu_plugin_` (already correct).
- README should document install: `plugin add /path/to/nu_plugin_edn` then `plugin use edn`.
- Submit to [awesome-nu](https://github.com/nushell/awesome-nu) once it's working.
- Reference issue #6415 in the README.

## Issues encountered building the prototype (gotchas)

These are real and will bite again:

**1. Encoding handshake direction.** Plugin sends encoding name to Nushell *first*, not the other way around. Format: one byte for length, then the name bytes ("json" = `\x04json`). Easy to get backwards from reading the protocol docs.

**2. Field name `span`, not `internal_span`.** The protocol docs are inconsistent; as of 0.110 (verified through 0.112.2), all the value records use `:span {:start N :end N}`. If you see `missing field 'span'` errors, this is it.

**3. Goodbye arrives as a string, not a map.** The control messages `Hello`, `Goodbye` aren't all the same shape. `Hello` is a map `{:Hello {...}}`; `Goodbye` is just the string `"Goodbye"`. Type-dispatch defensively.

**4. `Metadata` call must be handled.** Before the first `Run`, Nushell sends a `Metadata` call. If you don't reply (with even a minimal response), the plugin appears hung.

**5. Bb's `*out*` needs explicit flush.** Each protocol message must end with a flush, or Nushell will appear to hang waiting for a complete message. The prototype calls `(flush)` after every `send-msg`.

**6. Plugin protocol is stable across registration and use, but `plugin add` and `plugin use` need the same `--plugin-config` flag** when not using the default config dir. Document the install steps clearly.

## Testing

`bb test` runs the suite (`nu nu_plugin_edn.tests.nu` directly works too — bb is just the convenience entry point). The plugin must be registered first via `bb register`.

What the suite covers today (34 cases passing on 0.112.2):

- Scalars: int, float, bool, string, nil.
- Collections: vector, map, list (sets are converted to lists, no separate test).
- Nested structures, the cljsh use case (`[{:filename ... :size ... :type ...} ...]`).
- Keyword stringification: colon dropped, namespace preserved.
- ByteStream input: from `^echo`, from `bb -e`, large input (1000 records), `open` of a `.txt` file.
- Multi-form mode: scalar count, mixed shapes, `--objects` alias, multi-line forms, comment stripping, streamed bb output, record extraction, `first N` short-circuit, large producer (5000 records) + `first N` correctness.

Gaps (deliberately or as TODO):
- **Round-trip tests** (`value | to edn | from edn == value`) — waiting on `to edn`.
- **Error-case tests** — malformed EDN, missing closing brace, truncated input. The test file admits this gap in a comment.
- **Megabyte-scale streaming tests** — current largest is 5000 records (~30 KB).
- **Unbounded producer + `first N`** — works correctness-wise, but bb itself doesn't die on EPIPE so the test would leak processes; needs a non-bb producer (`yes`, `tail -f`) to be reliable.

A test fails if its expected output doesn't match. Don't catch and ignore errors in tests — let them fail loud.

## Anchored Nushell version

This plugin is anchored to **Nushell 0.112.2** as the development target. Test against this version. When updating to newer Nushell, expect protocol churn — check the [release notes](https://www.nushell.sh/blog/) for plugin protocol changes and update accordingly.

If you run against newer Nushell, do NOT silently update the version anchor in this file; bump it deliberately and verify all tests still pass.

History: anchor moved 0.110.0 → 0.112.2 after inspecting `git log 0.110.0..0.112.2 -- crates/nu-plugin-protocol/ crates/nu-plugin/` in the upstream repo and confirming no wire-protocol shape changes (only internal Rust refactors and version bumps).

## What success looks like

- `from edn` and `to edn` work as drop-in pipeline commands.
- A Clojure user can `bb my-script.clj | from edn | where size > 1000 | sort-by size` and it just works.
- A bb script can be the source AND target of an EDN pipeline: `bb produce.clj | from edn | where ... | to edn | bb consume.clj`.
- The plugin is in the awesome-nu registry.
- Issue #6415 gets a "fixed by external plugin" reference.

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
