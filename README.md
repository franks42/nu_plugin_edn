# nu_plugin_edn

A Nushell plugin for parsing and emitting [EDN](https://github.com/edn-format/edn)
(Extensible Data Notation, the Clojure data format).

Closes the gap left by older versions of `nu_plugin_formats` which previously
supported EDN. See [issue #6415](https://github.com/nushell/nushell/issues/6415).

## Why

Nushell ships with `from json`, `from yaml`, `from toml`, and several other
format converters. EDN was previously included but is not in the current
bundled `nu_plugin_formats`. This plugin adds it back.

The motivating use case: piping data between Nushell and Clojure/babashka
scripts. EDN preserves richer structure than JSON (sets, keywords, tagged
literals, namespaced keys), which makes it the natural wire format for
Clojure-shaped pipelines.

## Status

Both directions work. `from edn` is feature-complete (single-form, multi-
form `--lines`/`--objects`, true incremental streaming over piped
producers). `to edn` is shipped with the basic shape — keyword-keyed
records, vectors, scalar fallbacks for Nushell-native types — and a
handful of planned flags (`--pretty`, `--meta`, `--lines`, `--keep-
keyword-prefix`, `--string-keys`) on the roadmap. See `CLAUDE.md` for
the development plan and `bb-prototype-notes.md` for protocol-level
notes.

## Requirements

- Nushell 0.112.2 (other versions may need protocol updates — the anchor
  is documented in `CLAUDE.md` and bumped deliberately)
- [Babashka](https://babashka.org/) — `bb` on PATH

## Install

```bash
# Make the plugin executable
chmod +x nu_plugin_edn

# Register with Nushell
plugin add ./nu_plugin_edn
plugin use edn
```

To load on every Nushell start, add to your `config.nu`:
```nu
plugin use edn
```

## Use

```nu
# Parse a single EDN value
'{:name "alice" :age 30}' | from edn
# => {name: alice, age: 30}

# Parse a vector of maps (renders as a Nushell table)
'[{:filename "a.txt" :size 100} {:filename "b.txt" :size 200}]' | from edn

# Compose with native Nushell pipeline ops
'[{:filename "a.txt" :size 100} {:filename "b.txt" :size 200} {:filename "c.txt" :size 300}]'
  | from edn
  | where size > 150
  | sort-by size --reverse

# Pipe babashka script output through the plugin (no extra glue needed)
bb my-producer.clj | from edn | where status == "active" | length

# `open` of a .edn file auto-parses via the registered command
open config.edn | get :database

# Multi-form input: parse a sequence of top-level EDN forms.
# Each `(prn ...)` in the producer becomes one row; `first N` short-circuits.
bb -e '(doseq [event (events)] (prn event))' | from edn --lines | first 10

# `to edn` — emit Nushell values as EDN text
{name: "alice" age: 30} | to edn
# => {:name "alice", :age 30}

[{n: 1} {n: 2} {n: 3}] | to edn
# => [{:n 1} {:n 2} {:n 3}]

# End-to-end round-trip through bb on both sides
bb produce.clj | from edn | where size > 1000 | sort-by size | to edn | bb consume.clj
```

## Type mappings (`to edn`)

| Nushell type      | EDN output                | Notes                          |
|-------------------|---------------------------|--------------------------------|
| `Nothing`         | `nil`                     |                                |
| `Bool`            | `true` / `false`          |                                |
| `Int`             | integer                   |                                |
| `Float`           | float                     |                                |
| `String`          | `"..."`                   |                                |
| `Date`            | `#inst "..."`             | round-trips                    |
| `Record`          | `{:k v ...}`              | keyword keys                   |
| `List` / table    | `[v ...]`                 |                                |
| `Duration`        | integer milliseconds      | lossy: ns precision dropped    |
| `Filesize`        | integer bytes             | unit dropped                   |
| `Binary`          | base64 string             | not a tagged literal           |
| `Range`, `Closure`, `CellPath`, `CustomValue`, `Error` | `"#<TypeName>"` placeholder | best-effort, not round-trippable |

## Known limitations

- **Single-form `from edn` buffers the input**: a whole-document
  `from edn` (without `--lines`) reads the entire byte stream into
  memory before parsing. Fine for configs; for log-sized single
  documents, prefer multi-form mode (`--lines`) which is fully
  incremental.
- **Errors lack source spans**: parse errors show a message but don't
  highlight the offending location in the input.
- **Keyword round-trip**: `from edn` strips the leading colon
  (`:file` → `"file"`, namespaces preserved); `to edn` emits all
  string-shaped fields as plain strings. A `--keep-keyword-prefix`
  flag pair is planned to opt into fidelity.
- **`to edn` types**: see the type-mappings table above. Nushell
  durations, filesizes, and binaries fall back to primitives — lossy
  by design.

## Development

See `CLAUDE.md` for the development plan and `bb-prototype-notes.md`
for protocol findings. Convenience tasks via `bb`:

```bash
bb register   # plugin add ./nu_plugin_edn
bb test       # run the integration test suite
bb lint       # clj-kondo
bb fmt        # apply cljfmt
bb fmt-check  # verify cljfmt formatting (CI-friendly)
bb check      # lint + fmt-check, the pre-commit task
```

## License

MIT — see `LICENSE`.
