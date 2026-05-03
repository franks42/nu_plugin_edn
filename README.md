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

Early — `from edn` works for common shapes; `to edn` is still on the
roadmap. See `CLAUDE.md` for the development plan and `bb-prototype-notes.md`
for protocol-level notes.

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

# Pipe babashka script output through the plugin
bb my-producer.clj | from edn | where status == "active" | length
```

## Known limitations

- **No `to edn` yet**: only the parsing direction is implemented.
- **Whole-document only**: large EDN files are loaded into memory; no
  streaming yet.
- **Errors lack source spans**: parse errors show a message but don't
  highlight the offending location in the input.
- **Keyword round-trip**: keywords stringify to bare strings (`:file`
  → `"file"`, namespaces preserved), which is ergonomic but loses the
  keyword/string distinction. A `--keep-keyword-prefix` flag is planned.

## Development

See `CLAUDE.md` for the development plan and `bb-prototype-notes.md`
for protocol findings. Convenience tasks via `bb`:

```bash
bb register   # plugin add ./nu_plugin_edn
bb test       # run the integration test suite
bb check      # lint with clj-kondo (if installed)
```

## License

MIT — see `LICENSE`.
