# Prototype notes

What was learned building the prototype. Real bugs hit, real fixes, real
edge cases. These should save you (or future Claude Code) hours.

## Plugin protocol — direction matters

Three things that are easy to get backward from reading the docs:

**1. Encoding declaration: plugin sends FIRST.**
```
[byte: length-of-encoding-name][bytes: encoding-name]
```
Then `flush`. We use `"json"` (4 bytes), so we write `\x04json`.

If you don't send this, Nushell hangs waiting. Error message you'll see
if you forget the flush: "unable to get encoding from plugin: failed
to fill whole buffer".

**2. Hello: plugin sends FIRST.**
```json
{"Hello": {"protocol": "nu-plugin", "version": "0.110.0", "features": []}}
```
Then read Nushell's Hello back. Don't validate the `version` field —
Nushell sends `"0.110.0"` and we send `"0.110.0"` and they match by
literal coincidence; a future version might diverge. Just check that
something came back.

**3. Goodbye: Nushell sends FIRST.**
But importantly, it sends it as the bare string `"Goodbye"`, not as a
map `{"Goodbye": ...}`. Type-dispatch defensively. Our `classify`
function handles both shapes.

## Field name landmines

**`span`, not `internal_span`.** The protocol docs reference both at
different points. In 0.110, the actual field name is `span` everywhere.

Symptom: `Plugin failed to decode: missing field 'span'`. Sed-fix:
`s/internal_span/span/g` across your protocol responses.

**Span structure:** `{:start <int> :end <int>}`. Nushell wants byte
offsets into the original source. Synthetic values can use
`{:start 0 :end 0}` — Nushell accepts that without complaint.

## ByteStream input

When the user types `bb produce.clj | from edn`, Nushell sends the
`Run` call with `:input` set to `{:ByteStream {:id N :span ... :type ...}}`
— **not** a `Value`. The actual bytes arrive as separate messages
*after* the Run call:

```
{:Data [<stream-id> {:Raw {:Ok [<byte-ints>...]}}]}   ; 0..N times
{:End <stream-id>}
```

The plugin must:

1. Read messages in a loop, dispatching on `:Data` / `:End`.
2. Pull bytes out via `(get-in data [:Raw :Ok])` — they're a JSON array
   of integers (because `Vec<u8>` serializes that way), not a base64
   string.
3. **Send `{:Ack <stream-id>}` after each `:Data`.** Nushell uses
   acknowledgement-based backpressure; without acks, large streams stall
   because the engine's send window fills up. Small inputs may work
   without acks by coincidence — don't be misled.
4. After `:End`, decode the accumulated bytes to a UTF-8 string and
   feed it to `edn/read-string`.

The signature can stay `(String, Any)`. Despite that declaration, Nushell
delivers byte streams to plugins as streams (rather than auto-converting
to a String Value the way it does for some built-in commands), so the
plugin must do the conversion itself.

Bonus side effect: once `from edn` is registered, `open file.edn`
auto-parses via the registered command — users get table output without
having to write `from edn`.

## Calls Nushell makes that aren't `Run`

The first `Call` after Hello is **NOT** a Run. The sequence is:

1. `Metadata` (call data is the bare string `"Metadata"`)
2. `Signature` (call data is the bare string `"Signature"`)
3. `Run` (call data is `{"Run": {...}}` — a map)

If you only handle `Run`, the plugin appears to hang during `plugin add`
because it never returns a Signature. Handle all three.

Minimal Metadata response:
```json
{"CallResponse": [<call-id>, {"Metadata": {"version": "0.1.0"}}]}
```

## Bb-specific quirks

**Don't use `(set! System/out ...)` or similar.** It's a static field;
reflection won't find a setter. Just use `(flush)` after every send.

**`println` adds a newline.** Nushell's JSON encoding expects
newline-terminated messages; this happens to be exactly right. If
you switch to `print` later, add `\n` manually.

**Cheshire is fine for the JSON layer.** No need for jsonista or
data.json. The protocol JSON is small, performance isn't a concern.

## The `plugin add` / `plugin use` workflow

A few real frictions:

- **`plugin add` writes to `$nu.plugin-path`** which is
  `~/.config/nushell/plugin.msgpackz` by default. With `--no-config-file`,
  it's nil and you must pass `--plugin-config` explicitly to BOTH
  `plugin add` AND `plugin use`.
- **`plugin add` runs your plugin briefly** to call its `Signature`
  endpoint. So protocol bugs surface during `plugin add`, not just at
  use time. This is good — you find bugs faster.
- **`plugin use` loads the plugin into the current scope.** Nothing
  persists across nu sessions automatically; users add `plugin use edn`
  to their `config.nu` to load the plugin at every session start.

## Conversion edge cases

**Keywords stringified with the colon (FIXED).** Original prototype:
`:file` became `":file"`, breaking `where type == "file"`. Now we use
`(subs (str k) 1)` to drop the leading colon while preserving any
namespace: `:file` -> `"file"`, `:foo/bar` -> `"foo/bar"`. Note that
`(name k)` would have been wrong here — it returns `"bar"` for
`:foo/bar`, silently dropping the namespace. Round-trip fidelity is
the trade-off; `--keep-keyword-prefix` is planned but deferred.

**Sets become lists.** Nushell has no set type. Best behavior: emit
as a list. If round-tripping matters, `to edn` would need a hint;
deferred for now.

**Integer overflow.** Nushell ints are i64. Bb's edn reader returns
arbitrary-precision integers if the value is large. Currently we just
pass through; very large numbers will fail JSON serialization with a
not-great error. If real users hit this, branch on
`(<= Long/MIN_VALUE v Long/MAX_VALUE)` and emit a string fallback.

## Performance

For typical use (KB-MB inputs), latency is dominated by bb startup
(~30ms). The conversion itself is fast. Don't optimize the hot path
without profiling — the bottleneck is somewhere else.

## What I'd test first when a new Nushell version drops

1. Run the existing test suite. Watch for `missing field` errors.
2. Diff the protocol docs at `nushell.sh/contributor-book/plugin_protocol_reference.html`.
3. Check the most recent two minor versions' release notes for plugin
   protocol changes.

If a major version bump happens (1.0.0 someday), expect more churn
than usual and budget a day for the update.
