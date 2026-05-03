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

## True input-side streaming (incremental ByteStream consumption)

`--lines` / `--objects` over a `ByteStream` doesn't buffer the input —
bytes are pulled on demand and forms are emitted as they're parsed.
The interesting bits:

**The custom `InputStream`.** A `proxy [java.io.InputStream]` whose
`read()` pulls from a `ByteArrayInputStream` "current chunk" atom. When
the chunk is empty, refill: call `read-msg` and dispatch by message
type. `:Data` for our input stream id → replace the current chunk and
ack. `:End` for our input stream id → flip the eof flag. `:Drop` /
`:Ack` for our *output* stream → update an out-state atom that the
emit loop polls between forms. Other messages → log and keep reading.

**bb proxy gotcha — methods don't fall through to JDK defaults.** All
three `read` arities must be implemented (`read()`, `read(byte[])`,
`read(byte[], int, int)`), and you also need `available()` because
`InputStreamReader`'s `StreamDecoder` calls it; without it you get
`Method not implemented: available` thrown into `edn/read`. Symptoms
are flaky — sometimes the error happens after a few forms, sometimes
before any, depending on InputStreamReader's internal buffer
threshold.

**Bulk reads matter.** The 3-arg `read(byte[], int, int)` should pull
the first byte through `read-byte!` (which may refill) and then
delegate the rest to `(.read bais buf off len)` — a `System.arraycopy`
inside the JDK rather than per-byte sci↔Java calls. ~5x faster on
100K-record inputs.

**Telling the engine "stop the producer".** When the emit loop exits
before the input has signalled End (i.e. downstream short-circuited
via `Drop` on our output), send `{:Drop <input-stream-id>}` so the
engine can tear down the upstream producer. Required for `tail -f`-
style unbounded inputs to terminate. (Caveat: bb itself doesn't die
on EPIPE — a bb-specific quirk, separate from the plugin protocol.)

**Demuxer noise after early termination.** When we Drop early, the
engine has often already pushed more `:Data`/`:End` for the input
stream that didn't make it into our refill loop in time. Those
messages arrive on stdin after we return to the main loop. Classify
them as `:stream-ctl` rather than `:unknown` so the main loop swallows
them silently instead of logging.

## ListStream output

To stream multiple values back to Nushell (rather than returning one
`Value`), respond with a `ListStream` header carrying a stream id, then
push each value as a `Data` message, then `End`:

```
{:CallResponse [<call-id> {:PipelineData
                           {:ListStream {:id <sid> :span ... :metadata nil}}}]}
{:Data [<sid> {:List <nu-value>}]}    ; 0..N times
{:End <sid>}
```

The stream id space is plugin-local — direction disambiguates the
channel, so the plugin doesn't have to avoid engine-allocated ids.
A simple `(atom 0)` counter works.

After `End`, the engine sends `Ack` messages (one per `Data` it
processed) and possibly a `Drop` if a downstream command short-
circuited (e.g. `| first 10`). With single-threaded blocking reads
those messages arrive only after we return to the main loop — which
means we've already emitted everything. They're harmless to ignore,
but treating them as "expected stream control" rather than `:unknown`
keeps logs clean.

True early-termination on the input side (stop reading the byte stream
when `Drop` arrives mid-emit) requires interleaving stdin reads with
output writes — that's non-trivial because both inbound Data and
inbound Drop come over the same stdin channel, and the bb default is
blocking line reads. Deferred.

## Concurrent plugin Calls in the same pipeline

When a Nushell pipeline chains multiple plugin commands from the
same plugin (`from edn --lines | to edn --lines | from edn --lines`),
the engine pipelines them: Calls B and C arrive on stdin while we're
still processing Call A. So do `:Data` messages for B's and C's input
streams (because A's output stream is B's input stream, looped back
through the engine).

The single-threaded plugin handles this by **routing** messages, not
by running Calls concurrently:

- `pending-calls` (atom-vec) — `:Call` messages captured while we're
  inside another reader. The main loop drains this queue before
  reading more from stdin.
- `stream-buffers` (atom-map of stream-id → vec) — `:Data`/`:End`
  messages for streams the current reader isn't consuming. Future
  readers for those streams find them there first.

The unified routing lives in `pull-stream-msg`, used by every reader
(`read-byte-stream`, `read-list-stream`, `refill-stream-input!`).
Each reader passes its own stream-id; pull-stream-msg returns the
next message for that id (pulling from the buffer if available;
otherwise reading stdin and demuxing whatever arrives). `:Call`,
foreign `:Data`/`:End`, and output `:Drop` are all handled along
the way without losing messages.

The bug this fixed: in script-mode `nu` (where Nushell pipelines all
stages aggressively), the chained `from edn --lines | to edn --lines |
from edn --lines` would produce empty output for the middle stage
because B's input `:Data` arrived during Call A's incremental refill
and got discarded by the `(recur)` on a foreign stream id. The fix
is to buffer instead of discard.

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
