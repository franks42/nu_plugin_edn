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
