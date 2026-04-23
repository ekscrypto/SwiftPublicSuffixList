# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build the package
swift build

# Run all tests
swift test

# Run a single test
swift test --filter SwiftPublicSuffixListTests.testValidSyntaxHosts

# Update the public suffix registry (run from Utilities directory)
cd Utilities && swift update-suffix.swift
```

## Architecture Overview

SwiftPublicSuffixList is a Swift library for validating domain names against the [Public Suffix List](https://publicsuffix.org). It determines if a domain is "restricted" (a public suffix like `com` or `co.uk`) or "unrestricted" (a registrable domain like `yahoo.com`).

The library is backed by a pre-compiled binary trie (`registry.trie`) that is memory-mapped at load time. There is no JSON parsing and no per-rule heap allocation — load and match are both effectively allocation-free.

### Core Components

- **PublicSuffixList** (`Sources/SwiftPublicSuffixList/PublicSuffixList.swift`) - Main public API. Supports multiple initialization sources: embedded trie, custom `[[String]]` rules (built into a trie in memory), online registry, or local trie file. Thread-safe with NSLock protection. Can update rules at runtime from publicsuffix.org.

- **TrieFormat** (`Sources/SwiftPublicSuffixList/TrieFormat.swift`) - Binary format description (magic, flags, node layout). Little-endian on disk.

- **TrieBuilder** (`Sources/SwiftPublicSuffixList/TrieBuilder.swift`) - Builds an in-memory trie from `[[String]]` rules and serializes it into the binary format. Public, so tooling can emit trie files.

- **TrieMatcher** (`Sources/SwiftPublicSuffixList/TrieMatcher.swift`) - Walks the serialized trie in place. Validates host syntax (RFC5321, ASCII-only), splits the candidate into labels, and descends the trie right-to-left (TLD first). Implements `isUnrestricted(_:)` as the zero-alloc fast path and `match(_:)` which additionally reconstructs the prevailing rule.

- **Punycode** (`Sources/SwiftPublicSuffixList/Punycode.swift`) - Internal RFC 3492 encoder. Used by `TrieBuilder` to convert IDN labels to ACE form (`xn--…`) at build time so the serialized trie contains only ASCII bytes. Encoder-only; the library never needs to decode ACE back to Unicode.

- **PublicSuffixOnlineRegistryFetcher** (`Sources/SwiftPublicSuffixList/PublicSuffixOnlineRegistryFetcher.swift`) - Fetches and parses rules from publicsuffix.org. Returns `[[String]]`; the caller builds a trie from them. Blocks calling thread (not main thread).

### Binary Trie Format

`registry.trie` layout (little-endian throughout):

```
Header (24 bytes)
  magic        'P','S','L','T'   (4 bytes)
  version      current format     (1 byte)
  flags        reserved           (1 byte)
  _padding                        (2 bytes)
  rootOffset   absolute offset    (4 bytes)
  nodeCount    diagnostic         (4 bytes)
  ruleCount    diagnostic         (4 bytes)
  byteCount    total file size    (4 bytes, includes header + body + trailer)

Body (starts at offset 24)
Node records. Every node:
  sentinel     0xE9               (1 byte — cheap "is this a node?" check)
  flags        1 byte
    bit 0  isTerminal     (path from root == public-suffix rule)
    bit 1  isException    (terminal inverts isRestricted)
    bit 2  hasWildcard
    bits 3-7 reserved; must be zero
  childCount   2 bytes
  if hasWildcard: wildcardOffset   4 bytes
  children[childCount], sorted by label UTF-8 bytes:
    labelLen    1 byte (> 0)
    labelBytes  labelLen bytes
    childOffset 4 bytes

Trailer (last 4 bytes of buffer)
  crc32        zlib-compatible CRC32 over bytes[0 ..< byteCount - 4]
```

`TrieMatcher.loadValidated(data:)` runs the full validation pass
(CRC check, every offset in range, every node visited exactly once,
sentinel + flag bits verified). `.filePath(_:)` loading always goes
through it; trusted sources (`.embedded`, `.rules`, `.onlineRegistry`'s
own serialization output) skip revalidation because we produced the
bytes ourselves.

### Rule Representation

When callers supply custom rules via `.rules([[String]])`, each inner array is a domain split by dots, in the same leftmost-first order used by the published PSL text:

- `["com"]` — matches `.com` TLD
- `["*", "uk"]` — wildcard matches any second-level domain under `.uk`
- `["!www", "ck"]` — exception: `www.ck` is NOT restricted even if `*.ck` would match

`TrieBuilder.buildAndSerialize(rules:)` converts those into the binary format. Since v3.0 the builder runs each label through `Punycode.toACE(_:)` so callers can still pass the PSL .dat's native UTF-8 form (e.g. `["公司", "香港"]`); the serialized trie contains ASCII-only ACE labels (e.g. `["xn--55qx5d", "xn--j6w193g"]`). Pure-ASCII labels pass through verbatim.

### ACE-only host inputs (v3.0 breaking change)

`PublicSuffixList.isUnrestricted(_:)` and `match(_:)` accept ASCII hostnames only. Raw Unicode labels are rejected by `isValidHost` (any byte ≥ 0x80 → invalid). Callers that need to check an IDN host must Punycode-encode each label first:

```swift
// ❌ rejected since v3.0
list.isUnrestricted("example.香港")

// ✅ correct
list.isUnrestricted("example.xn--j6w193g")
```

This aligns with DNS wire format (labels are ASCII on the wire) and with RFC 5321 hostnames (email host parts are ASCII; SMTPUTF8 is out of scope for PSL matching). The library intentionally does *not* include a Punycode decoder — decoding ACE back to Unicode for display is the caller's responsibility.

Structural validation of stored labels also enforces the LDH rule: every label byte must be in `[a-zA-Z0-9-]`, and each label is capped at 63 bytes (RFC 1035). Crafted trie files that violate either rule are rejected by `TrieMatcher.loadValidated`.

### Match Struct

```swift
public struct Match {
    public let prevailingRule: [String]
    public let isRestricted: Bool
}
```

The legacy `matchedRules` field was removed; it was never part of the PSL algorithm and its construction cost dominated match time.

### Platform Support

macOS 10.12+, iOS 11+, tvOS 11+. Uses `#if canImport(FoundationNetworking)` for Linux compatibility.

### Updating the Registry

Run `Utilities/update-suffix.swift` to download the latest list and regenerate both `registry.json` (kept for CI diff/changelog tooling) and `registry.trie` (the runtime resource). The trie builder code is inlined in that script — keep it in sync with `Sources/SwiftPublicSuffixList/Trie*.swift` if the format ever changes.

### Benchmark Harness

`Sources/SuffixLoadBench/` is a separate executable target that measures load-phase and match-phase performance across multiple storage formats (JSON, binary plist, custom binary, dedup binary, plain text, Swift `StaticString`, and the trie). Use it to validate any future format change:

```bash
swift run -c release SuffixLoadBench generate   # regenerate all candidate formats
swift run -c release SuffixLoadBench bench      # time them
```

## Changelog

The project maintains a changelog (`CHANGELOG.md`). The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

When making changes, update the `[Unreleased]` section with:
- **Added** for new features
- **Changed** for changes in existing functionality
- **Deprecated** for soon-to-be removed features
- **Removed** for now removed features
- **Fixed** for any bug fixes
- **Security** for vulnerability fixes

## Automated Nightly Updates

A GitHub Actions workflow (`.github/workflows/update-suffix-list.yml`) runs daily at 2:00 AM UTC to update the Public Suffix List. The workflow:

1. Downloads the latest list from publicsuffix.org
2. Compares with the current embedded list (both `registry.json` and `registry.trie`)
3. If changes are detected:
   - Regenerates `registry.json` (used for the human-readable diff) and `registry.trie` (the runtime resource)
   - Updates `CHANGELOG.md` with added/removed suffixes
   - Updates `README.md` timestamp
   - Increments the patch version (e.g., 1.1.6 → 1.1.7)
   - Commits all changes
   - Creates a new git tag
   - Creates a GitHub release

The workflow can also be triggered manually via the GitHub Actions UI.
