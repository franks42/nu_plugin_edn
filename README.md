# nu_plugin_edn

[![test](https://github.com/franks42/nu_plugin_edn/actions/workflows/test.yml/badge.svg)](https://github.com/franks42/nu_plugin_edn/actions/workflows/test.yml)

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

## Versioning

The plugin version mirrors the Nushell version it's anchored against:
plugin **0.112.2** pairs with Nushell **0.112.2**, plugin **0.113.0**
will pair with Nushell **0.113.0**, etc. Older plugin versions stay
installable on the GitHub Releases page so users on older Nushells
can still grab a working build. Plugin-only bug fixes between Nushell
minors (when they happen) get a `-N` patch suffix
(`0.112.2-1`, `0.112.2-2`, ...).

## Requirements

- Nushell version matching the plugin version exactly — the protocol
  does a strict equality check at registration. Mismatches fail with
  `Plugin compiled for nushell version X, which is not compatible with version Y`.
- [Babashka](https://babashka.org/) — `bb` on PATH.

## Install

```bash
# Pick the release matching your Nushell version. Example: Nushell 0.112.2
curl -L https://github.com/franks42/nu_plugin_edn/releases/download/v0.112.2/nu_plugin_edn-v0.112.2 -o nu_plugin_edn
chmod +x nu_plugin_edn

# Register with Nushell
nu -c 'plugin add ./nu_plugin_edn; plugin use edn'
```

To load on every Nushell start, add to your `config.nu`:
```nu
plugin use edn
```

The latest release is at <https://github.com/franks42/nu_plugin_edn/releases/latest>.

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

### Pretty-printing EDN

For demos and human-readable inspection, a tiny `pprint-edn` filter is a
few lines of bb. Drop this into your `config.nu`:

```nu
# Pretty-print EDN bytes from stdin (uses bb's stdlib clojure.pprint).
def pprint-edn [] {
    ^bb -e '(require (quote [clojure.pprint :as pp]))
            (pp/pprint (clojure.edn/read-string (slurp *in*)))'
}
```

Then:

```nu
{user: "alice" roles: [admin reviewer] active: true} | to edn | pprint-edn
# {:user "alice",
#  :roles [admin reviewer],
#  :active true}

cat config.edn | pprint-edn
```

(There's no `^pprint-edn` external CLI in the ecosystem yet — `clojure.pprint`
is in bb's stdlib, so a Nushell custom command is enough; no separate library
to wrap.)

### Composing with the wider Clojure-shaped Nushell ecosystem

[`cedn`](https://github.com/franks42/canonical-edn) (canonical-EDN filter) and
[`uuidv7`](https://github.com/franks42/uuidv7.cljc) (UUIDv7 generator/parser/
validator) are sibling tools — single bb-script CLIs released alongside their
reference libraries. They compose with `nu_plugin_edn` via Unix pipes:

```nu
# Hash a structured payload's canonical form
{user: "alice" scope: read} | to edn | ^cedn | sha256sum

# Pull a UUIDv7's embedded timestamp into Nushell
^uuidv7 parse "0195a4c8-fae8-7c8d-b2a1-..." | from edn | get datetime

# Round-trip via canonical EDN
{b: 2 a: 1} | to edn | ^cedn | from edn   # => {a: 1, b: 2}
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
