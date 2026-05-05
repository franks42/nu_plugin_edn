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

`v0.112.2-2` ships both directions feature-rich:

- **`from edn`** — single-form, multi-form (`--lines`/`--objects`, fully streaming over piped producers), `#inst` / `#uuid` tagged literals, `--set2record`, `--keep-keyword-prefix`, source-span error labels, mid-stream error surfacing.
- **`to edn`** — records, lists/tables, scalars, type fallbacks for Nushell-native types without an EDN equivalent (Duration, Filesize, Binary), `--lines`/`--objects`, `--pprint`, `--record2set`, `--keep-keyword-prefix`, `--string-keys`, `--meta`.

See `CLAUDE.md` for the development plan and `bb-prototype-notes.md` for
protocol-level notes.

## Versioning

The plugin version mirrors the Nushell version it's anchored against:
plugin **0.112.2** pairs with Nushell **0.112.2**, plugin **0.113.0**
will pair with Nushell **0.113.0**, etc. Older plugin versions stay
installable on the GitHub Releases page so users on older Nushells
can still grab a working build. Plugin-only bug fixes between Nushell
minors (when they happen) get a `-N` patch suffix
(`0.112.2-1`, `0.112.2-2`, ...).

## Setup

### 1. Install Nushell

If you don't already have it, follow [the Nushell install guide](https://www.nushell.sh/book/installation.html)
(Homebrew, winget, cargo, scoop, distro packages — pick one). Confirm with `nu --version`. The plugin
is anchored to a specific Nushell version (see [Versioning](#versioning)) — note your version, you'll
match the plugin to it in step 3.

### 2. Install Babashka

The plugin runtime is a babashka script — `bb` must be on PATH. Follow
[the Babashka install guide](https://github.com/babashka/babashka#installation) (Homebrew, scoop,
the install script, etc.). Confirm with `bb --version`.

You'll likely want bb anyway: it's what you run on the other side of the pipe — a Clojure REPL that
starts in 30ms, perfect for shell scripts.

### 3. Install nu_plugin_edn

Pick the release matching your Nushell version. Plugin **0.112.2-2** pairs with Nushell **0.112.2**:

```bash
curl -L https://github.com/franks42/nu_plugin_edn/releases/download/v0.112.2-2/nu_plugin_edn-v0.112.2-2 -o nu_plugin_edn
chmod +x nu_plugin_edn

# Register with Nushell
nu -c 'plugin add ./nu_plugin_edn; plugin use edn'
```

To load on every Nushell start, add to your `config.nu`:
```nu
plugin use edn
```

Browse all releases at <https://github.com/franks42/nu_plugin_edn/releases>. The plugin version
must match the running Nushell version exactly — the protocol enforces strict equality at
registration. Mismatches fail with `Plugin compiled for nushell version X, which is not
compatible with version Y`.

### What you just gained

After registering, Nushell has two new pipeline commands:

- **`from edn`** — parse EDN bytes or text into Nushell typed values (records, tables, dates, …).
- **`to edn`** — emit Nushell typed values as EDN bytes/text.

Plus an automatic hook: `open config.edn` parses `.edn` files via the registered command, no
explicit `from edn` needed.

## Tutorial

### Parse and emit (the basics)

```nu
# Parse a single EDN value
'{:name "alice" :age 30}' | from edn
# => {name: alice, age: 30}

# Parse a vector of maps — renders as a Nushell table
'[{:filename "a.txt" :size 100} {:filename "b.txt" :size 200}]' | from edn
# ╭───┬──────────┬──────╮
# │ # │ filename │ size │
# ├───┼──────────┼──────┤
# │ 0 │ a.txt    │  100 │
# │ 1 │ b.txt    │  200 │
# ╰───┴──────────┴──────╯

# Emit a Nushell record/table as EDN
{name: "alice" age: 30} | to edn
# => {:name "alice", :age 30}

[{n: 1} {n: 2} {n: 3}] | to edn
# => [{:n 1} {:n 2} {:n 3}]
```

### Compose with native Nushell pipeline ops

Once parsed, EDN values flow through Nushell's filters/transforms like any structured data:

```nu
'[{:filename "a.txt" :size 100} {:filename "b.txt" :size 200} {:filename "c.txt" :size 300}]'
| from edn
| where size > 150
| sort-by size --reverse
# ╭───┬──────────┬──────╮
# │ # │ filename │ size │
# ├───┼──────────┼──────┤
# │ 0 │ c.txt    │  300 │
# │ 1 │ b.txt    │  200 │
# ╰───┴──────────┴──────╯

# `open` of a .edn file auto-parses via the registered command
open config.edn | get :database
```

### bb scripts as **producers** (bb → nu)

Anywhere a bb script writes EDN to stdout, `from edn` consumes it as typed values:

```nu
# Single form per stdout: bb prints one EDN value, plugin parses it
^bb -e '(prn {:host "prod" :latency-ms 42})' | from edn | get latency-ms
# => 42

# Multi-form: every (prn ...) becomes one row; `first N` short-circuits the producer
^bb -e '(doseq [event (events)] (prn event))' | from edn --lines | first 10

# Real-world: filter a stream of records by some structural condition
^bb -e '(doseq [r (read-log)] (prn r))'
| from edn --lines
| where status == "active"
| where latency-ms > 100
| length
```

`from edn --lines` over a piped producer is **fully incremental**: bytes are pulled on demand,
forms parsed and emitted one at a time, and a downstream `first N` triggers a `:Drop` that tells
the producer to stop. Works with unbounded sources (`tail -f`, infinite generators).

### bb scripts as **consumers** (nu → bb)

`to edn` emits Nushell values as EDN bytes that any bb script can read:

```nu
# Pipe a Nushell record into a bb script that consumes EDN from stdin
{user: "alice" roles: [admin reviewer]} | to edn | ^bb -e '
    (let [v (clojure.edn/read-string (slurp *in*))]
      (println "user:" (:user v))
      (println "is admin?:" (boolean (some #{"admin"} (:roles v)))))'
# user: alice
# is admin?: true

# Multi-form output: each list element becomes its own top-level form
[{n: 1} {n: 2} {n: 3}] | to edn --lines | ^bb -e '
    (require (quote [clojure.edn :as edn]))
    (doseq [line (line-seq (java.io.BufferedReader. *in*))]
      (println "got:" (edn/read-string line)))'
# got: {:n 1}
# got: {:n 2}
# got: {:n 3}
```

### Round-trip: bb → nu → bb

The full pattern — bb scripts on both ends, Nushell as the middleware:

```nu
^bb produce.clj
| from edn
| where size > 1000
| sort-by size
| to edn
| ^bb consume.clj
```

Structured data flows end-to-end without any text-parsing intermediaries. No bash escaping, no
`jq`, no JSON-shaped impedance mismatch with Clojure data (sets, keywords, namespaced keys,
tagged literals all preserve through the pipe).

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

### bb scripts as **filters** (`^app` pattern) — the wider Clojure-shaped Nushell ecosystem

Some EDN-related operations are pure text-on-text transformations — they don't need access to
Nushell typed values. Per the [typed-value boundary principle](CLAUDE.md), those live in
**standalone bb-script CLIs** in their reference library's repo and compose via Unix pipes.

Two are released today:

#### `^cedn` — canonical EDN (byte-stable serialization)

[github.com/franks42/canonical-edn](https://github.com/franks42/canonical-edn)

Reads EDN, emits the same value with sorted keys + normalized whitespace + canonical token forms.
Output is byte-stable across runs and process boundaries — suitable for hashing, signing, content
addressing.

```nu
# Hash a structured payload's canonical form (different key orders → same bytes → same hash)
{b: 2, a: 1} | to edn | ^cedn | sha256sum
{a: 1, b: 2} | to edn | ^cedn | sha256sum
# both produce the same digest

# Round-trip a Nushell value through canonical EDN
{b: 2, a: 1} | to edn | ^cedn | from edn
# => {a: 1, b: 2}    (key order normalized)

# Normalize whitespace in an existing .edn file
cat config.edn | ^cedn

# Diff two structurally-equivalent EDN files reliably
diff (^cedn -i a.edn) (^cedn -i b.edn)
```

#### `^uuidv7` — RFC 9562 UUIDv7 generator/parser/validator

[github.com/franks42/uuidv7.cljc](https://github.com/franks42/uuidv7.cljc)

Generate time-ordered UUIDs, parse them into structured fields, validate.

```nu
# Generate one
^uuidv7 gen
# 0195a4c8-fae8-7c8d-b2a1-3f7e92a4d8b1

# Generate, attach to a record, emit as EDN
{event: "login", id: (^uuidv7 gen | str trim)} | to edn
# => {:event "login", :id "0195a4c8-..."}

# Parse a UUIDv7 — output is EDN, plugin parses into a Nushell record
^uuidv7 parse "0195a4c8-fae8-7c8d-b2a1-3f7e92a4d8b1" | from edn
# ╭──────────┬──────────────────────────────────────╮
# │ uuid     │ 0195a4c8-fae8-7c8d-b2a1-3f7e92a4d8b1 │
# │ uri      │ urn:uuid:0195a4c8-...                │
# │ datetime │ 2026-05-04 10:23:45.831 +00:00       │
# │ counter  │ [3197 17246 1834...]                 │
# ╰──────────┴──────────────────────────────────────╯

# Pull just the embedded timestamp
^uuidv7 parse $my-id | from edn | get datetime

# Validate a UUIDv7 (exit 0 if valid v7, 1 otherwise)
^uuidv7 valid $maybe-id
```

#### Composing all three

Each tool is independently useful, but they shine when chained:

```nu
# Cross-tool: generate a UUIDv7, parse it, attach context, hash the canonical form
^uuidv7 gen --format edn      # bb tool emits EDN: {:uuid #uuid "..." :datetime #inst "..." ...}
| from edn                    # plugin: EDN bytes → Nushell record (typed)
| insert source "ingest-svc"  # nushell native: add a field
| to edn                      # plugin: typed → EDN bytes
| ^cedn                       # bb tool: canonicalize
| sha256sum                   # standard Unix: hash

# Filter a bb stream, sort, sign with attached context
^bb produce-events.clj
| from edn --lines
| where status == "active"
| sort-by timestamp
| each { |row| {data: $row, signed-at: (date now)} }
| to edn --lines
| ^cedn -o
| ^bb sign-each-line.clj
```

The pattern: **typed transformations happen inside Nushell** (`where`, `sort-by`, `each`, `insert`,
`update`, etc.) on the typed side of `from edn` / `to edn`; **byte-level transformations happen in
external CLIs** (`^cedn` for canonicalization, `^uuidv7` for ID generation, future tools for signing
/ hashing / encryption) on the EDN-bytes side.

`nu_plugin_edn` is the only piece that needs to be a Nushell plugin — everything else is a regular
external command piped through `^name` syntax.

#### `babqua-bb-nushell-demo` — the same pattern inside a notebook

[`babqua-bb-nushell-demo`](https://github.com/franks42/babqua-bb-nushell-demo) is a Quarto +
[Babqua](https://scicloj.github.io/babqua/) notebook that runs nu pipelines from inside
`{.clojure .bb}` code blocks. Demonstrates the typed-value boundary principle interactively —
typed transforms inside Nushell on one side of `from edn` / `to edn`, byte-level transforms via
`^cedn` / `^uuidv7` / `sha256sum` on the other side, all rendered live via Kindly metadata
(table, chart, hash). Self-contained: bundled `bin/` ships the sibling CLIs, no system installs
needed.


## Type mappings (`to edn`)

| Nushell type      | EDN output                | Notes                          |
|-------------------|---------------------------|--------------------------------|
| `Nothing`         | `nil`                     |                                |
| `Bool`            | `true` / `false`          |                                |
| `Int`             | integer                   |                                |
| `Float`           | float                     |                                |
| `String`          | `"..."`                   |                                |
| `Date`            | `#inst "..."`             | round-trips                    |
| `Record`          | `{:k v ...}`              | keyword keys; with `--record2set`, mirror-form `{k: k}` records emit as `#{:k ...}` (keyword sets) |
| `List` / table    | `[v ...]`                 |                                |
| `Duration`        | integer milliseconds      | lossy by 6 orders of magnitude — see [Type quirks](#type-quirks-to-watch-for). With `--duration-ns`, integer nanoseconds (lossless). |
| `Filesize`        | integer bytes             | unit dropped                   |
| `Binary`          | base64 string             | not a tagged literal           |
| `Range`, `Closure`, `CellPath`, `CustomValue`, `Error` | `"#<TypeName>"` placeholder | best-effort, not round-trippable |

### EDN sets

By default, EDN sets become Nushell lists (Nushell has no native set type). Opt into a `{k: k}` mirror-record convention via the paired flags:

```nu
'#{:admin :viewer :editor}' | from edn                    # → [admin viewer editor]    (default — list)
'#{:admin :viewer :editor}' | from edn --set2record       # → {admin: admin, viewer: viewer, editor: editor}
{admin: "admin" viewer: "viewer"} | to edn --record2set   # → #{:admin :viewer}
```

`from edn --set2record` + `to edn --record2set` round-trip a keyword/string set without loss. Caveats: int and composite-element sets degrade — Nushell record keys are strings only.

### Pretty-print vs compact

```nu
{a: 1, b: [2 3 4]} | to edn              # compact:  {:a 1, :b [2 3 4]}
{a: 1, b: [2 3 4]} | to edn --pprint     # pprinted (indented, multi-line for nested data)
```

`--pprint` is mutually exclusive with `--lines` / `--objects`. For canonical (byte-stable) output suitable for hashing/signing, pipe through the [`cedn` CLI](https://github.com/franks42/canonical-edn) instead — different tool, different purpose.

### Type quirks to watch for

A handful of `to edn` defaults are pragmatic rather than lossless. Worth knowing about so they don't surprise you when output diverges from what a Clojure programmer would have written by hand:

- **`Duration` defaults to milliseconds (lossy)** — Nushell stores Duration as nanoseconds, but the EDN integer we emit truncates to ms because that's the conventional unit for elapsed times in EDN-shaped APIs. Pass `--duration-ns` for lossless ns integer:
  ```nu
  {d: 1234567ns} | to edn                 # => {:d 1}            (ms, lossy)
  {d: 1234567ns} | to edn --duration-ns   # => {:d 1234567}      (ns, lossless)
  ```
  No standard `#duration` EDN tag exists, so the bb consumer needs to know the unit from context. (`#inst` / `Date` is separate and preserves nanosecond precision through `cedn` already — see the canonical-edn library's `format-inst`.)

- **`Filesize` emits as integer bytes — unit dropped.** `1MiB` becomes `1048576`. The bb consumer doesn't see "MiB" anywhere.

- **`Binary` emits as a base64 string, not a tagged literal.** `cedn` has a custom `#bytes` reader that round-trips properly; we don't use it because that would bind us to a non-standard EDN extension.

- **EDN keywords round-trip lossily by default.** `:foo` → Nushell `"foo"` (colon dropped). The string `"foo"` and the keyword `:foo` collapse into the same Nushell value. Opt into fidelity with the paired `--keep-keyword-prefix` flag (see [Known limitations](#known-limitations)).

- **EDN sets become Nushell lists by default.** Nushell has no native set type. Opt into the `{k: k}` mirror-record convention with `--set2record` / `--record2set` (see [EDN sets](#edn-sets)).

- **Record keys are emitted as keywords by default.** `{name: "alice"}` becomes `{:name "alice"}`. For non-Clojure consumers, use `--string-keys` to get `{"name" "alice"}`.

- **Nushell `Range`, `Closure`, `CellPath`, `CustomValue`, `Error` have no EDN equivalent.** They emit as `"#<TypeName>"` placeholder strings. Don't expect round-trip.

If your pipeline goes `nu | to edn | ^cedn | sha256sum` (a content hash for signing/comparison), and a bb script computes `(sha256 (cedn/canonical-bytes v))` directly, the hashes will match **only if `to edn`'s representation matches the value the bb side has in mind**. The integration tests in `nu_plugin_edn.tests.nu` include equivalence checks (`nu pipeline canonical bytes == direct ^cedn --edn invocation`) that catch structural drift.

## Known limitations

- **Single-form `from edn` buffers the input**: a whole-document
  `from edn` (without `--lines`) reads the entire byte stream into
  memory before parsing. Fine for configs; for log-sized single
  documents, prefer multi-form mode (`--lines`) which is fully
  incremental.
- **Keyword round-trip**: by default, `from edn` strips the leading colon
  (`:file` → `"file"`, namespaces preserved) and `to edn` emits all
  string-shaped fields as plain strings. Opt into fidelity via the
  paired `--keep-keyword-prefix` flag on both sides — keywords carry
  their `:` as a marker through the Nushell value (`:foo` → `":foo"`),
  and emit back as keywords. Caveat: with the flag, plain strings
  starting with `:` will coerce to keywords on the to-edn side.
- **`to edn` types**: see the type-mappings table above. Nushell
  durations, filesizes, and binaries fall back to primitives — lossy
  by design.

## For AI assistants

See [`AGENTS.md`](AGENTS.md) — terse reference covering the interface,
common patterns, gotchas, and quoting tips, written for LLM agents
running `nu` in a shell session.

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

MIT — same as Nushell. See `LICENSE`.
