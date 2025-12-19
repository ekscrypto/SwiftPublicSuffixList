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

### Core Components

- **PublicSuffixList** (`Sources/SwiftPublicSuffixList/PublicSuffixList.swift`) - Main public API. Supports multiple initialization sources: embedded rules, custom rules, online registry, or local JSON file. Thread-safe with NSLock protection. Can update rules at runtime from publicsuffix.org.

- **PublicSuffixMatcher** (`Sources/SwiftPublicSuffixList/PublicSuffixMatcher.swift`) - Internal matching engine. Validates domain syntax (RFC5321) and matches against rules. Handles wildcards (`*`) and exceptions (`!`).

- **PublicSuffixRulesRegistry** (`Sources/SwiftPublicSuffixList/PublicSuffixRulesRegistry.swift`) - Loads embedded rules from `registry.json` bundled resource.

- **PublicSuffixOnlineRegistryFetcher** (`Sources/SwiftPublicSuffixList/PublicSuffixOnlineRegistryFetcher.swift`) - Fetches and parses rules from publicsuffix.org. Blocks calling thread (not main thread).

### Rule Format

Rules are stored as `[[String]]` where each inner array is a domain split by dots:
- `["com"]` - matches `.com` TLD
- `["*", "uk"]` - wildcard matches any second-level domain under `.uk`
- `["!www", "ck"]` - exception: `www.ck` is NOT restricted even if `*.ck` would match

### Platform Support

macOS 10.12+, iOS 11+, tvOS 11+. Uses `#if canImport(FoundationNetworking)` for Linux compatibility.

### Updating the Registry

The embedded `registry.json` can become outdated. Run `Utilities/update-suffix.swift` to download the latest list and regenerate the JSON file.
