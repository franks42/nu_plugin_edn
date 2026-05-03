# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once a 1.0 ships.

## [Unreleased]

### Added
- Initial `from edn` prototype: parses EDN scalars, vectors, maps, sets, lists, and nested structures into Nushell values.
- Nushell integration tests (`nu_plugin_edn.tests.nu`) covering scalars, collections, nested structures, and the cljsh use case.
- `bb.edn` with `test`, `register`, and `check` tasks.

### Changed
- Anchored Nushell version moved from 0.110.0 to 0.112.2 after verifying no wire-protocol changes in the intervening releases. All tests pass on 0.112.2.

### Fixed
- EDN keywords now drop the leading colon when stringified (`:file` → `"file"`), with namespaces preserved (`:foo/bar` → `"foo/bar"`). Previously the colon survived, breaking idiomatic Nushell filters like `where type == "file"`.
- **ByteStream input**: `bb produce.clj | from edn` now works directly — the plugin handles `ByteStream` pipeline input by consuming `Data` messages until `End`, acknowledging each chunk for backpressure. Previously a `| collect` workaround was required because the plugin only handled the `Value` input variant.

### Known limitations
- No `to edn` direction yet.
- No streaming input — large files are fully buffered.
- Errors don't carry source spans (the offending location isn't highlighted in the original input).
- Tagged literals beyond what `edn/read-string` handles natively are not supported.

## [0.1.0] — TBD

First registered release. Targets Nushell 0.110.0.
