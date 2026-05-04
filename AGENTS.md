# AGENTS.md — using nu_plugin_edn from an LLM-driven shell

You're an AI assistant. The user runs Nushell. This plugin adds two pipeline
commands — `from edn` and `to edn` — that let typed structured data flow
between Nushell and Clojure/babashka scripts without text-parsing or bash
escape hassle. This file is your reference; skim sections by heading.

## Verify the plugin is loaded

```nu
plugin list | where name == edn | length    # 1 if loaded, 0 if not
```

If 0, the plugin isn't registered in this Nushell session. Tell the user; do
not attempt `plugin add` yourself unless they've authorized installs.

## When to reach for it

- ✅ The data has Clojure shape — keywords (`:foo`), sets (`#{...}`), tagged
  literals (`#inst`, `#uuid`), namespaced keys (`:foo/bar`).
- ✅ A babashka or Clojure script is on either end of the pipe.
- ✅ You want to filter/sort/transform structured records without `jq`.
- ❌ JSON is the wire format — use `from json` / `to json` instead.
- ❌ The data is plain text or CSV — use `lines`, `parse`, `from csv`, etc.

## The interface, complete

### `from edn` — EDN text → Nushell typed values

| Flag | Effect |
|---|---|
| (none) | Parse a single EDN form. Default. |
| `--lines` / `--objects` | Parse a stream of top-level forms; each becomes one row (ListStream). Streams incrementally over piped producers. |
| `--set2record` | Render EDN sets as `{k: k}` mirror records (paired with `to edn --record2set`). Default: sets become Nushell lists. |
| `--keep-keyword-prefix` | Keep the leading `:` on keywords as a string marker (`:foo` → `":foo"`). Pair with the matching `to edn` flag for round-trip. |

`open file.edn` auto-parses via the registered command.

### `to edn` — Nushell typed values → EDN text

| Flag | Effect |
|---|---|
| (none) | Emit one form, compact. |
| `--lines` | Emit each list element on its own line. |
| `--objects` | Same as `--lines` but space-separated, no newlines. |
| `--pprint` (`-p`) | Pretty-print via `clojure.pprint`. Mutex with `--lines`/`--objects`. |
| `--record2set` | Records in mirror form (`{k: k}`) emit as EDN sets (paired with `from edn --set2record`). |
| `--keep-keyword-prefix` | Strings shaped like keywords (`":foo"`) emit as EDN keywords (paired with `from edn` flag). |
| `--string-keys` | Record keys as EDN strings (`{"name" "alice"}`) instead of keywords. For Python/JS/Go consumers. |
| `--meta <record>` | Prefix output with `^{...}` Clojure metadata. Mutex with `--lines`/`--objects`; bb consumer reads via `(meta v)`. NON-PORTABLE to non-Clojure parsers. |
| `--duration-ns` | Emit Duration as integer nanoseconds (lossless). Default: integer milliseconds (lossy). |

## Common patterns

### bb script as producer (bb → nu)

```nu
^bb -e '(prn {:host "prod" :latency-ms 42})' | from edn | get latency-ms
# => 42

^bb produce.clj | from edn --lines | where status == "active" | length
```

`from edn --lines` over a piped producer is fully incremental — `first N`
short-circuits the producer, works with `tail -f`-like sources.

### bb script as consumer (nu → bb)

```nu
{user: "alice"} | to edn | ^bb -e '(println (clojure.edn/read-string (slurp *in*)))'

[{n: 1} {n: 2}] | to edn --lines | ^bb -e '
  (require (quote [clojure.edn :as edn]))
  (doseq [line (line-seq (java.io.BufferedReader. *in*))]
    (println (edn/read-string line)))'
```

### Round-trip

```nu
^bb produce.clj
| from edn
| where size > 1000
| sort-by size
| to edn
| ^bb consume.clj
```

### Hash a structured payload (cross-tool)

```nu
{user: "alice" scope: "read"} | to edn | ^cedn | sha256sum
```

`^cedn` (canonical-EDN CLI from sibling repo) re-canonicalizes so the hash
is stable regardless of key order or whitespace. Same hash a bb script would
produce via `(sha256 (cedn/canonical-bytes v))`.

### UUIDv7 generation/parse (cross-tool)

```nu
^uuidv7 gen                                    # raw UUID string
^uuidv7 gen --format edn | from edn            # full record (uuid, datetime, counter)
^uuidv7 parse $some-uuid | from edn | get datetime
```

## Gotchas (in order of how often you'll trip on them)

1. **Records use `:` for `key: value`, not `"key": value`.** Nushell record
   syntax is `{name: "alice", age: 30}` — looks like JSON but isn't. `:`
   separates key from value, comma is optional.

2. **Access record fields by string name, not keyword.** `:foo` in EDN
   becomes `"foo"` in Nushell (colon dropped by default). So:
   ```nu
   '{:name "alice"}' | from edn | get name      # ✅ works
   '{:name "alice"}' | from edn | get :name     # ❌ "cannot find column ':name'"
   ```

3. **`let` inside `(...)` doesn't establish scope** for following
   expressions. Lift outside, or inline the comparison:
   ```nu
   # ❌ won't work — $x is "variable not found"
   ( let x = (... | to edn); $x == "..." )

   # ✅ inline the comparison
   ( ({a: 1} | to edn) == '{:a 1}' )
   ```

4. **Variable names with hyphens parse as subtraction.** `let foo-bar = 1`
   looks like `let foo - bar = 1`. Use `foo_bar`.

5. **External commands need the `^` prefix.** `^bb`, `^cedn`, `^uuidv7`.
   Without `^`, `bb` might match a Nushell builtin or alias.

6. **Plugin version must match Nushell exactly.** A protocol-level strict
   equality check fails with `Plugin compiled for nushell version X, which
   is not compatible with version Y`. Pick the GitHub release matching
   `nu --version`.

7. **`Duration` defaults to milliseconds (lossy).** Nushell stores ns
   natively; `to edn` truncates to ms. Pass `--duration-ns` for lossless
   integer nanoseconds.

8. **Keyword fidelity is lost by default.** EDN `:foo` and `"foo"` collapse
   into the same Nushell string. Use the paired `--keep-keyword-prefix`
   flag on both `from edn` and `to edn` for round-trip.

9. **EDN sets become Nushell lists by default.** Nushell has no native set
   type. Use `--set2record` / `--record2set` for round-trip via the
   `{k: k}` mirror-record convention.

10. **Record keys default to keywords on emit.** `{name: "alice"} | to edn`
    produces `{:name "alice"}`. For non-Clojure consumers (Python, JS, Go),
    use `--string-keys` to get `{"name" "alice"}`.

11. **bb's stdout doesn't honor EPIPE.** A `^bb -e '(while true (prn ...))' |
    from edn --lines | first 10` will leak the bb process — bb keeps
    writing after the pipe closes. Other Unix producers (`tail -f`, `cat`,
    `grep --line-buffered`) honor EPIPE fine. If you need to stop a bb
    producer, exit explicitly inside the bb script or kill the PID.

## Quoting tips

Nushell's quoting is regular and well-defined — this is the whole reason
the user is running you in nu instead of bash. You don't need bash's
backslash-soup:

```nu
# Single quotes preserve everything literally
'{:url "https://example.com" :body "{\"x\":1}"}'  | from edn

# Double quotes interpolate $variables
let host = "prod"
$"echo connecting to ($host)"

# Backtick strings (rare; for paths with spaces)
`/Users/Some Name/file.edn`
```

When you need to embed bb code, single-quote the whole `-e` argument and
escape inner double quotes only if necessary:

```nu
^bb -e '(prn {:msg "hi"})'                          # ✅ clean
^bb -e "(prn {:msg \"hi\"})"                         # works but uglier
```

## Type mappings reference

| Nushell type | EDN output | Notes |
|---|---|---|
| `Nothing` | `nil` | |
| `Bool` | `true` / `false` | |
| `Int`, `Float` | integer / float | |
| `String` | `"..."` | starts-with-`:` may coerce to keyword under `--keep-keyword-prefix` |
| `Date` | `#inst "..."` | round-trips |
| `Record` | `{:k v ...}` | string keys with `--string-keys` |
| `List` / table | `[v ...]` | |
| `Duration` | integer ms (default) / ns (`--duration-ns`) | lossy without flag |
| `Filesize` | integer bytes | unit dropped |
| `Binary` | base64 string | not a tagged literal |
| `Range`, `Closure`, `CellPath`, `CustomValue`, `Error` | `"#<TypeName>"` | placeholder; not round-trippable |

## Don'ts

- **Don't shell out to bash for EDN parsing** when bb-via-nu pipes work. The
  whole point is to avoid the bash escape boundary.
- **Don't use `from json` on EDN text** — silently produces wrong/partial
  results when EDN-only constructs (sets, keywords, tagged literals) appear.
- **Don't assume Duration round-trips losslessly** — see gotcha 7.
- **Don't run `plugin add` without authorization** — the user manages
  their plugin registry.
- **Don't fight Nushell's evaluation order** with shell escapes — if a
  pipeline isn't doing what you expect, the issue is almost always a
  Nushell-syntax misread, not the plugin.

## Further reading

- `README.md` — human-facing tutorial with full type mappings and ecosystem
  composition examples.
- `CLAUDE.md` — development plan / contributor guide. Read this if you're
  asked to modify the plugin, not just use it.
- `bb-prototype-notes.md` — protocol-level findings.
- Sibling tools that compose via Unix pipes:
  [canonical-edn](https://github.com/franks42/canonical-edn) (`^cedn`),
  [uuidv7.cljc](https://github.com/franks42/uuidv7.cljc) (`^uuidv7`).
