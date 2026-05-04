# nu_plugin_edn.tests.nu
#
# Run with:  nu nu_plugin_edn.tests.nu
#
# Assumes the plugin has been registered:
#   plugin add ./nu_plugin_edn
#   plugin use edn
#
# Each test prints "OK" or "FAIL" with context. Exit code is non-zero if
# any test fails.

plugin use edn

mut failures = 0
mut count = 0

def check [label: string, actual: any, expected: any] {
    if $actual == $expected {
        print $"OK   ($label)"
    } else {
        print $"FAIL ($label)"
        print $"     got:    ($actual | to nuon)"
        print $"     wanted: ($expected | to nuon)"
        $env.FAILED = ($env.FAILED? | default 0) + 1
    }
}

# --- scalars ---
check "int"      ('42' | from edn) 42
check "negative" ('-7' | from edn) (-7)
check "float"    ('3.14' | from edn) 3.14
check "string"   ('"hello"' | from edn) "hello"
check "true"     ('true' | from edn) true
check "false"    ('false' | from edn) false
check "nil"      ('nil' | from edn) null

# --- collections ---
check "empty vector"   ('[]' | from edn) []
check "vector of ints" ('[1 2 3]' | from edn) [1 2 3]
check "vector strings" ('["a" "b" "c"]' | from edn) ["a" "b" "c"]
check "empty map"      ('{}' | from edn) {}
check "simple map"     ('{:name "alice" :age 30}' | from edn) {name: "alice", age: 30}

# --- nested structures ---
let nested = '[{:filename "a.txt" :size 100} {:filename "b.txt" :size 200}]' | from edn
check "vector of maps - count" ($nested | length) 2
check "vector of maps - first filename" ($nested | first | get filename) "a.txt"
check "vector of maps - sortable" (
    $nested | sort-by size --reverse | first | get filename
) "b.txt"

# --- the cljsh-shape end-to-end test ---
let cljsh_out = '[{:filename "report.pdf" :size 142857 :type :file}
                  {:filename "scratch"    :size 4096   :type :dir}
                  {:filename "data.csv"   :size 99999  :type :file}]' | from edn

check "cljsh: count"      ($cljsh_out | length) 3
check "cljsh: filter+sort" (
    $cljsh_out | where type == "file" | sort-by size | first | get filename
) "data.csv"

# Keyword stringification: leading colon is dropped, namespace is preserved.
check "keyword drops colon"        ('{:k :file}' | from edn | get k) "file"
check "namespaced keyword keeps ns" ('{:k :foo/bar}' | from edn | get k) "foo/bar"

# Tagged literals: #inst -> Nushell Date, #uuid -> Nushell string.
check "from edn: #inst becomes a Date" (
    '{:at #inst "2024-01-15T10:30:00Z"}' | from edn | get at | describe
) "datetime"

check "from edn: #uuid becomes a string" (
    '{:id #uuid "550e8400-e29b-41d4-a716-446655440000"}' | from edn | get id
) "550e8400-e29b-41d4-a716-446655440000"

# --- ByteStream input (piped from external commands) ---
# These exercise the stream code path: Nushell delivers external command
# stdout as a ByteStream, not a String Value, and the plugin must consume
# Data/End messages and Ack each chunk.

check "byte stream from echo" (
    ^echo '{:greeting "hello"}' | from edn | get greeting
) "hello"

check "byte stream from bb" (
    bb -e '(prn [{:n 1} {:n 2} {:n 3}])' | from edn | length
) 3

# Larger payload to exercise backpressure (multi-chunk stream).
let big = (
    bb -e '(prn (vec (for [i (range 1000)] {:idx i :pad (apply str (repeat 50 "x"))})))'
    | from edn
)
check "byte stream large input - count" ($big | length) 1000
check "byte stream large input - last"  ($big | last | get idx) 999

# Using a temp file via `open` of a non-.edn extension also routes through
# the byte stream path (.edn would auto-parse via the registered command).
'{:from "file"}' | save /tmp/nu_plugin_edn_test.txt -f
check "byte stream via open of .txt" (
    open /tmp/nu_plugin_edn_test.txt | from edn | get from
) "file"
rm /tmp/nu_plugin_edn_test.txt

# --- Multi-form mode (--lines / --objects) ---
# Streams each top-level EDN form as a separate value via ListStream
# output. Form boundaries are determined by the EDN reader (matched
# brackets, quoted strings, comments stripped) — not by newlines.

check "lines: count of 3 scalar forms" (
    "42 43 44" | from edn --lines | length
) 3

check "lines: mixed shapes" (
    "[1 2] {:a 1} :kw" | from edn --lines | length
) 3

check "objects: alias for --lines" (
    "[1 2] {:a 1}" | from edn --objects | length
) 2

# Multi-line vector spans several lines — still ONE form. Then a second
# form follows. Total: 2.
check "lines: multi-line forms parse as one each" (
    "[1\n 2\n 3]\n{:a 1}" | from edn --lines | length
) 2

# Comments between forms are stripped by the EDN reader.
check "lines: comments are stripped" (
    "; header\n[1 2 3]\n; footer" | from edn --lines | length
) 1

# Streaming through bb output (the cljsh use case for streaming producers).
check "lines: streamed bb output" (
    bb -e '(doseq [i (range 5)] (prn {:i i :tag :bb}))' | from edn --lines | length
) 5

check "lines: bb output values are records" (
    bb -e '(doseq [i (range 3)] (prn {:i i}))' | from edn --lines | get i | math sum
) 3

# Early-termination via `first` — `from edn --lines` emits a ListStream
# so downstream commands can short-circuit.
check "lines: first N short-circuits" (
    bb -e '(doseq [i (range 100)] (prn {:i i}))' | from edn --lines | first 3 | length
) 3

# Large incremental input — verifies the streaming InputStream + Drop
# protocol handle multi-chunk producer output without buffering all of
# it before parsing begins.
check "lines: large producer + first N is correct" (
    bb -e '(doseq [i (range 5000)] (prn {:i i}))'
    | from edn --lines | first 5 | get i | math sum
) 10

# --- to edn ---
# Record -> map with keyword keys, list -> vector, nested -> nested.

check "to edn: scalar int"   (42 | to edn) "42"
check "to edn: scalar nil"   (null | to edn) "nil"
check "to edn: scalar str"   ("hello" | to edn) '"hello"'
check "to edn: empty record" ({} | to edn) "{}"
check "to edn: empty list"   ([] | to edn) "[]"

# Records use keyword keys (the chosen default — matches Clojure idiom
# and the cljsh receive-side). The exact key order is preserved by the
# Nushell record's natural iteration order.
check "to edn: simple record" (
    {name: "alice"} | to edn
) '{:name "alice"}'

check "to edn: list of records" (
    [{n: 1} {n: 2}] | to edn
) "[{:n 1} {:n 2}]"

check "to edn: nested" (
    {users: [{name: "a"} {name: "b"}], count: 2} | to edn
) '{:users [{:name "a"} {:name "b"}], :count 2}'

# Nushell-native types fall back to primitives. These are lossy by
# design — see CLAUDE.md / README. Tests pin the chosen mapping so it
# doesn't drift.
check "to edn: filesize -> bytes int" (
    {sz: 1MiB} | to edn
) "{:sz 1048576}"

check "to edn: duration -> ms int" (
    {d: 1sec} | to edn
) "{:d 1000}"

check "to edn: date -> #inst" (
    {at: 2024-01-15T10:30:00Z} | to edn
) '{:at #inst "2024-01-15T10:30:00.000-00:00"}'

# Round-trip: a Nushell value passed through to edn | from edn should
# come back equal (modulo type coercions documented above — keywords
# come back as plain strings without the colon, so we test with shapes
# that stay invariant).
check "to edn -> from edn round-trip: simple" (
    {a: 1, b: [1 2 3]} | to edn | from edn
) {a: 1, b: [1 2 3]}

check "to edn -> from edn round-trip: nested record" (
    {x: {y: {z: "deep"}}} | to edn | from edn
) {x: {y: {z: "deep"}}}

# The cljsh round-trip: bb produces EDN, Nushell filters/sorts, emits
# EDN back. End-to-end shape preservation is what matters.
check "to edn: cljsh round-trip" (
    bb -e '(prn [{:filename "a.txt" :size 100} {:filename "b.txt" :size 200}])'
    | from edn
    | where size > 50
    | to edn
    | from edn
    | get filename
) ["a.txt", "b.txt"]

# --- to edn --lines / --objects ---
# Same item-iteration semantics as `from edn --lines`, mirrored on output:
# walk the input as a sequence of top-level forms, emit each with a
# separator. `--lines` uses newlines (line-discipline output, plays with
# head/tail/wc -l); `--objects` uses single spaces (compact concatenated
# output, since EDN forms self-delimit). The two flags are NOT synonyms
# on `to edn` — different separator semantics.

# Default (no flag) preserves the existing behavior: emit ONE form.
check "to edn: no flag wraps list as vector" (
    [1 2 3] | to edn
) "[1 2 3]"

# --lines: newline-separated items
check "to edn --lines: list elements as separate forms" (
    [1 2 3] | to edn --lines
) "1\n2\n3\n"

check "to edn --lines: records" (
    [{n: 1} {n: 2}] | to edn --lines
) "{:n 1}\n{:n 2}\n"

# --objects: space-separated items
check "to edn --objects: list elements space-separated" (
    [1 2 3] | to edn --objects
) "1 2 3 "

check "to edn --objects: records" (
    [{n: 1} {n: 2}] | to edn --objects
) "{:n 1} {:n 2} "

# Empty list emits empty string in both multi-form modes
check "to edn --lines: empty list" ([] | to edn --lines) ""
check "to edn --objects: empty list" ([] | to edn --objects) ""

# Scalar input produces one form (mirrors from edn --lines on a single
# top-level form)
check "to edn --lines: scalar" (42 | to edn --lines) "42\n"
check "to edn --objects: scalar" (42 | to edn --objects) "42 "

# ListStream input (`where`, `each`, etc.) is collected and iterated
check "to edn --lines: ListStream from where" (
    [{n: 1} {n: 2} {n: 3}] | where n > 1 | to edn --lines
) "{:n 2}\n{:n 3}\n"

# Round-trip through from edn (parser is whitespace-agnostic, so both
# separators work)
check "to edn --lines round-trips through from edn --lines" (
    [{n: 1} {n: 2} {n: 3}] | to edn --lines | from edn --lines | length
) 3

check "to edn --objects round-trips through from edn --objects" (
    [{n: 1} {n: 2}] | to edn --objects | from edn --objects | length
) 2

# Chained-plugin round-trip via a string literal (no incremental path).
check "to edn --lines: chained-plugin round-trip preserves N forms" (
    "{:i 0}\n{:i 1}\n{:i 2}\n"
    | from edn --lines
    | to edn --lines
    | from edn --lines
    | get i | math sum
) 3

# Streaming round-trip: bb produces (ByteStream → incremental from-edn),
# pipeline chains through to-edn and a second from-edn. This exercises
# concurrent plugin Calls — the engine sends Call(to edn) while
# from-edn is still in incremental refill. Stream readers queue the
# Call so the main loop dispatches it after from-edn finishes. End-to-
# end cljsh streaming story.
check "to edn --lines: bb-streamed round-trip via chained plugin Calls" (
    bb -e '(doseq [i (range 3)] (prn {:i i :tag :stream}))'
    | from edn --lines
    | to edn --lines
    | from edn --lines
    | get i | math sum
) 3

# --- to edn --pprint ---

check "to edn --pprint: simple value compact still on one line" (
    {a: 1, b: 2} | to edn --pprint | str trim
) "{:a 1, :b 2}"

check "to edn --pprint: nested value splits across lines" (
    {users: [{name: "a"} {name: "b"}], count: 2} | to edn --pprint | str contains "\n"
) true

check "to edn --pprint: round-trips through from edn" (
    {a: 1, b: [2 3 4]} | to edn --pprint | from edn
) {a: 1, b: [2 3 4]}

check "to edn --pprint --lines: error" (
    try {
        {a: 1} | to edn --pprint --lines
        "no error"
    } catch { |_| "error" }
) "error"

check "to edn --pprint --objects: error" (
    try {
        {a: 1} | to edn --pprint --objects
        "no error"
    } catch { |_| "error" }
) "error"

# --- from edn --set2record / to edn --record2set ---
# Sets in EDN are parsed as Nushell lists by default; opt into the
# `{k: k}` mirror-record convention via these paired flags. The
# round-trip is loss-free for keyword/string sets only — see the
# README for the full type-mapping table.

check "from edn (default): set becomes a list" (
    "#{:a :b :c}" | from edn | sort
) ["a" "b" "c"]

check "from edn --set2record: keyword set becomes mirror record" (
    "#{:admin :viewer}" | from edn --set2record | columns | sort
) [admin viewer]

check "from edn --set2record: every value equals its key" (
    "#{:admin :viewer :editor}" | from edn --set2record
    | items {|k v| $k == $v}
    | all { |x| $x }
) true

check "to edn --record2set: mirror record emits as set" (
    # Set element ordering isn't deterministic; parse back and sort.
    {admin: "admin", viewer: "viewer"} | to edn --record2set | from edn | sort
) ["admin" "viewer"]

check "to edn --record2set: non-mirror record stays a map" (
    {a: "x", b: "y"} | to edn --record2set
) '{:a "x", :b "y"}'

check "to edn --record2set: empty record stays a map" (
    {} | to edn --record2set
) "{}"

# Round-trip via the pair: EDN set -> mirror record -> EDN set.
check "set2record + record2set: round-trip preserves keyword set" (
    "#{:admin :viewer :editor}"
    | from edn --set2record
    | to edn --record2set
    | from edn
    | sort
) ["admin" "editor" "viewer"]

# --- --keep-keyword-prefix paired flag ---
# Preserves keyword/string fidelity by carrying the leading `:` as a
# marker on the Nushell-side string. Pair both flags for round-trip.

check "from edn --keep-keyword-prefix: keyword value keeps colon" (
    '{:a :foo}' | from edn --keep-keyword-prefix | get :a
) ":foo"

check "from edn --keep-keyword-prefix: namespaced keyword keeps colon" (
    '{:k :foo/bar}' | from edn --keep-keyword-prefix | get :k
) ":foo/bar"

check "from edn --keep-keyword-prefix: plain string stays plain" (
    '{:a "hello"}' | from edn --keep-keyword-prefix | get :a
) "hello"

check "from edn --keep-keyword-prefix: keyword keys keep colon" (
    '{:a 1}' | from edn --keep-keyword-prefix | columns
) [":a"]

check "to edn --keep-keyword-prefix: prefixed string emits as keyword" (
    {":a": ":foo"} | to edn --keep-keyword-prefix
) '{:a :foo}'

check "to edn --keep-keyword-prefix: plain string stays string" (
    {a: "hello"} | to edn --keep-keyword-prefix
) '{:a "hello"}'

# Full round-trip: EDN keywords survive intact through both flags.
check "keep-keyword-prefix: round-trips keywords" (
    '{:a :foo, :b "bar", :c :ns/qual}'
    | from edn --keep-keyword-prefix
    | to edn --keep-keyword-prefix
    | from edn --keep-keyword-prefix
    | get :a
) ":foo"

check "keep-keyword-prefix: round-trip preserves string-vs-keyword distinction" (
    '{:k :v, :s "v"}'
    | from edn --keep-keyword-prefix
    | to edn --keep-keyword-prefix
) '{:k :v, :s "v"}'

# Default behaviour unchanged when flag is off.
check "default: keyword still degrades to plain string" (
    '{:a :foo}' | from edn | get a
) "foo"

# --- --string-keys ---
# Emit record keys as EDN strings instead of keywords. Useful for
# pipelines feeding non-Clojure consumers (Python/JS/Go) that don't
# speak keyword keys.

check "to edn --string-keys: simple record" (
    {name: "alice", age: 30} | to edn --string-keys
) '{"name" "alice", "age" 30}'

check "to edn --string-keys: nested" (
    {user: {name: "alice"}} | to edn --string-keys
) '{"user" {"name" "alice"}}'

check "to edn --string-keys: empty record" (
    {} | to edn --string-keys
) "{}"

check "to edn (default): keys are still keywords" (
    {name: "alice"} | to edn
) '{:name "alice"}'

# --string-keys + --keep-keyword-prefix combined: --string-keys wins
# for keys; --keep-keyword-prefix still applies to values.
check "to edn --string-keys --keep-keyword-prefix: keys string, values still keyword-coerced" (
    {":a": ":foo"} | to edn --string-keys --keep-keyword-prefix
) '{":a" :foo}'

# --- --meta ---
# Prefix the emitted top-level form with Clojure reader metadata.
# Non-portable to non-Clojure EDN parsers; useful for bb consumers
# that read the metadata via `(meta v)`.

check "to edn --meta: prefixes with ^{...}" (
    {a: 1} | to edn --meta {source: "nu"}
) '^{:source "nu"} {:a 1}'

check "to edn --meta: works with multi-key meta record" (
    {a: 1, b: 2} | to edn --meta {source: "nu", version: "1.0"}
) '^{:source "nu", :version "1.0"} {:a 1, :b 2}'

check "to edn --meta: error when combined with --lines" (
    try {
        [1 2] | to edn --meta {x: 1} --lines
        "no error"
    } catch { |_| "error" }
) "error"

check "to edn --meta: error when combined with --objects" (
    try {
        [1 2] | to edn --meta {x: 1} --objects
        "no error"
    } catch { |_| "error" }
) "error"

check "to edn --meta: error when arg is not a record" (
    try {
        {a: 1} | to edn --meta "not a record"
        "no error"
    } catch { |_| "error" }
) "error"

# --- error cases ---
# Parse errors carry a source-span label pointing at the offending
# location in the user's script (Value input only — ByteStream input
# has no script-level span and gets a label-less error).

check "error: malformed map produces error" (
    try { '{:a 1 :b}' | from edn; "no error" } catch { |_| "error" }
) "error"

check "error: malformed map carries useful message" (
    try { '{:a 1 :b}' | from edn; "" } catch { |e|
        $e.msg | str starts-with "EDN parse error:"
    }
) true

# Source-span label: Value input (literal string) → labels[0].span
# points at the failing position in the source. The exact start/end
# offsets vary with surrounding script bytes, so we just assert that
# a label is present with the expected text.
check "error: Value input carries source-span label" (
    try { '{:a 1 :b}' | from edn; null } catch { |e|
        let parsed = ($e.json | from json)
        ($parsed.labels | length) > 0 and (
            ($parsed.labels | first | get text) == "parse error here"
        )
    }
) true

check "error: ByteStream input has no source-span label" (
    try { ^bash -c 'echo "{:a 1 :b}"' | from edn; null } catch { |e|
        ($e.json | from json | get labels | length) == 0
    }
) true

check "error: --lines mode also carries source-span label on bad form" (
    try { '1 :foo {:bad}' | from edn --lines | length; null } catch { |e|
        ($e.json | from json | get labels | length) > 0
    }
) true

# Mid-stream parse errors over a ByteStream can't switch a ListStream
# response into an Error response (protocol limitation), so the plugin
# emits a Value::Error as the final list element. Downstream sees it
# as either a top-level error or as something try/catch picks up.

check "error: mid-stream parse error in ByteStream --lines surfaces as an error" (
    try {
        ^bb -e '(prn 1) (prn 2) (println "{:bad")' | from edn --lines | each { |x| $x }
        "no error"
    } catch { |_| "error" }
) "error"

check "error: mid-stream error message starts with EDN parse error" (
    try {
        ^bb -e '(prn 1) (println "{:bad")' | from edn --lines | each { |x| $x }
        ""
    } catch { |e| $e.msg | str starts-with "EDN parse error:" }
) true

# --- Ecosystem integration ---
# Tests that exercise composition with adjacent CLI tools from the
# wider Clojure-shaped Nushell ecosystem (cedn, uuidv7). They run
# conditionally — if the external CLI isn't on PATH, the test is
# skipped silently rather than failing. Install the missing tool
# from its GitHub Release if you want full coverage:
#   - cedn:   github.com/franks42/canonical-edn/releases
#   - uuidv7: github.com/franks42/uuidv7.cljc/releases

let has_cedn = (which cedn | is-not-empty)
let has_uuidv7 = (which uuidv7 | is-not-empty)

if not $has_cedn {
    print "SKIP cedn integration tests (cedn not on PATH — install from canonical-edn GH Releases)"
}
if not $has_uuidv7 {
    print "SKIP uuidv7 integration tests (uuidv7 not on PATH — install from uuidv7.cljc GH Releases)"
}

# --- cedn integration ---
# `to edn | ^cedn | from edn` round-trips a value through the
# canonical-EDN filter and back into Nushell typed values.

if $has_cedn {
    check "ecosystem: to edn | ^cedn | from edn round-trip" (
        {b: 2, a: 1, list: [3 1 2]} | to edn | ^cedn | from edn
    ) {a: 1, b: 2, list: [3 1 2]}

    check "ecosystem: cedn canonicalizes — different key orders produce identical bytes" (
        ({b: 2, a: 1} | to edn | ^cedn) == ({a: 1, b: 2} | to edn | ^cedn)
    ) true

    check "ecosystem: cedn output is byte-stable across runs" (
        ({user: "alice"} | to edn | ^cedn) == ({user: "alice"} | to edn | ^cedn)
    ) true
}

# --- uuidv7 integration ---
# Generate and parse UUIDv7s through the uuidv7 CLI; round-trip
# through `from edn` to confirm the EDN output of `uuidv7 parse`
# is structurally consumable by the plugin.

if $has_uuidv7 {
    check "ecosystem: ^uuidv7 gen produces a 36-char UUID string" (
        ^uuidv7 gen | str trim | str length
    ) 36

    let uuid_str = (^uuidv7 gen | str trim)
    let parsed = (^uuidv7 parse $uuid_str | from edn)

    check "ecosystem: ^uuidv7 parse | from edn produces datetime as a Date" (
        $parsed | get datetime | describe
    ) "datetime"

    check "ecosystem: ^uuidv7 parse | from edn produces a record with the four expected keys" (
        $parsed | columns | sort
    ) [counter datetime uri uuid]
}

# --- Cross-tool composition (both CLIs together) ---
# Headline ecosystem story: uuidv7 → from edn → manipulate → to edn → cedn.

if ($has_cedn and $has_uuidv7) {
    let parsed = (^uuidv7 gen --format edn | from edn)
    let canonical = ($parsed | to edn | ^cedn)
    check "ecosystem: uuidv7 → from edn → to edn → ^cedn produces canonical bytes containing :uuid" (
        $canonical | str contains ":uuid"
    ) true
}

# --- summary ---
let failed = ($env.FAILED? | default 0)
if $failed > 0 {
    print $"\n($failed) test(s) failed"
    exit 1
} else {
    print "\nAll tests passed"
}
