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

You'll find these files in this repository:

- `nu_plugin_edn` — the plugin itself, executable bb script. Currently a working prototype.
- `nu_plugin_edn.tests.nu` — Nushell test script exercising round-trips.
- `bb-prototype-notes.md` — what was learned building the prototype: protocol details, bug list, edge cases.
- `README.md` — user-facing docs (you'll write or expand this).
- `LICENSE` — pick one (MIT or Apache-2.0 are conventional for Nushell plugins).
- `CHANGELOG.md` — empty starting file, populate as you go.

## What's working in the prototype

- Plugin handshake (encoding declaration, Hello exchange, Metadata, Goodbye).
- `from edn` for: maps, vectors, strings, integers, floats, booleans, nil, sets (rendered as lists), nested values.
- Conversion of EDN keywords to Nushell strings (currently keeps the leading `:` — see "issues to fix").
- Tested end-to-end: `'[{:filename "a.txt" :size 100} ...]' | from edn | where size > 50 | sort-by size` produces a real Nushell table.

## What's not working / needs implementing

In rough priority order:

### 1. Keyword stringification (rough edge in current prototype)

EDN keywords currently become strings with the leading colon: `:file` → `":file"`. So `where type == "file"` fails; user has to write `where type == ":file"`.

**The decision needed**: do EDN keywords become Nushell strings *with* or *without* the colon? Three options:

- **Drop the colon**: `:file` → `"file"`. Makes pipelines read naturally (`where type == "file"`). Loses round-trip fidelity (we can't distinguish `:file` from `"file"` when going back to EDN).
- **Keep the colon**: `:file` → `":file"`. Round-trip works. Pipelines look weird.
- **Make it configurable** via a flag: `from edn --keep-keyword-prefix` defaults to dropping. Most readable plus escape hatch.

I'd suggest the third — drop by default, flag to preserve. Document the trade-off prominently. Add a corresponding flag on `to edn` to opt into emitting keywords for known field names.

### 2. `to edn` (reverse direction)

The prototype only does `from edn`. Implementing `to edn` is a mirror image of the conversion logic plus EDN serialization. Cheshire doesn't emit EDN; you'll write the serializer (or use [puget](https://github.com/greglook/puget) if it works in bb — verify, don't assume).

Implementation hints:
- Nushell records → EDN maps. Choose: keyword keys (`{:name "alice"}`) or string keys (`{"name" "alice"}`)?
- Nushell lists → EDN vectors.
- Nushell tables (lists of records) → EDN vectors of maps.
- Nushell `Nothing` → EDN `nil`.
- Nushell `Date` → EDN `#inst "..."`.
- Don't try to round-trip nuon-specific types (durations, file sizes); document the limitation.

### 3. Streaming input

The prototype reads the whole input as a string before parsing. For large files (`open big.edn | from edn`), this loads the whole thing into memory. Nushell's plugin protocol supports `ListStream` input — see the protocol docs.

Streaming EDN is harder than streaming JSON because EDN doesn't have NDJSON-like conventions. Two approaches:
- **Whole-document mode** (current prototype): fine for typical configs, breaks for log files.
- **EDN-per-line mode**: each line is one EDN value. Compatible with `tools.deps`-style logs and bb script output. Add `from edn --lines` for this mode.

### 4. Better error reporting

Current prototype returns errors with empty `labels []`. Nushell's error model wants source spans pointing into the input. Compute the span from the EDN reader's exception (it knows char position) and emit it properly so Nushell highlights the bad spot.

### 5. Plugin signature and metadata

Update `:Metadata` response with proper version, plugin author, description. Update `:Signature` response with proper search terms, examples (the protocol supports inline examples that show up in `help from edn`), and category.

### 6. Plugin registry conventions

- Filename must start with `nu_plugin_` (already correct).
- README should document install: `plugin add /path/to/nu_plugin_edn` then `plugin use edn`.
- Submit to [awesome-nu](https://github.com/nushell/awesome-nu) once it's working.
- Reference issue #6415 in the README.

## Issues encountered building the prototype (gotchas)

These are real and will bite again:

**1. Encoding handshake direction.** Plugin sends encoding name to Nushell *first*, not the other way around. Format: one byte for length, then the name bytes ("json" = `\x04json`). Easy to get backwards from reading the protocol docs.

**2. Field name `span`, not `internal_span`.** The protocol docs are inconsistent; in 0.110, all the value records use `:span {:start N :end N}`. If you see `missing field 'span'` errors, this is it.

**3. Goodbye arrives as a string, not a map.** The control messages `Hello`, `Goodbye` aren't all the same shape. `Hello` is a map `{:Hello {...}}`; `Goodbye` is just the string `"Goodbye"`. Type-dispatch defensively.

**4. `Metadata` call must be handled.** Before the first `Run`, Nushell sends a `Metadata` call. If you don't reply (with even a minimal response), the plugin appears hung.

**5. Bb's `*out*` needs explicit flush.** Each protocol message must end with a flush, or Nushell will appear to hang waiting for a complete message. The prototype calls `(flush)` after every `send-msg`.

**6. Plugin protocol is stable across registration and use, but `plugin add` and `plugin use` need the same `--plugin-config` flag** when not using the default config dir. Document the install steps clearly.

## Testing

Run `nu nu_plugin_edn.tests.nu` to exercise the round-trips. Tests should cover:

- Scalars: int, float, bool, string, nil
- Collections: vector, map, set, list
- Nested structures
- The cljsh use case: `[{:filename ... :size ... :type ...} ...]`
- Round-trip: `value | to edn | from edn` should equal `value` for all supported shapes
- Error cases: malformed EDN, missing closing brace, truncated input
- Large inputs (megabyte-scale, once streaming works)

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
