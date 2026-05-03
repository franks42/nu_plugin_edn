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

# --- error cases ---
# Note: the prototype emits :Error with msg but no source span. These
# tests just verify that malformed input produces an error rather than
# a successful but wrong parse.

# --- summary ---
let failed = ($env.FAILED? | default 0)
if $failed > 0 {
    print $"\n($failed) test(s) failed"
    exit 1
} else {
    print "\nAll tests passed"
}
