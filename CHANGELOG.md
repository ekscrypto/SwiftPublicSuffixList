# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.0] - 2026-04-23

### Changed
- **Breaking:** Hostnames passed to `PublicSuffixList.isUnrestricted(_:)` and `match(_:)` must now be in ACE (Punycode) form. Raw Unicode hostnames like `example.香港` are rejected by syntax validation — encode IDN labels as `xn--…` before calling (e.g., `example.xn--j6w193g`). `isValidHost` now refuses any byte ≥ 0x80.
- **Breaking:** The embedded trie now stores labels in ACE form only. A caller that built cached `.trie` files from v2.0.x rules and loads them via `.filePath(_:)` will find them structurally valid but their IDN labels won't match (the runtime compares ASCII bytes). Rebuild caches on upgrade.
- `TrieBuilder.buildAndSerialize(rules:)` auto-converts each label via Punycode before insertion, so callers can continue to pass the PSL .dat's native UTF-8 form in `[[String]]` rules. The builder also tightens the per-label cap from 255 to 63 bytes (DNS RFC 1035).

### Added
- `Punycode` (internal) — a self-contained RFC 3492 encoder. No external IDNA dependency.
- `walkForValidation` now verifies every stored label byte is ASCII LDH (`a-z`, `A-Z`, `0-9`, `-`), rejecting crafted tries that claim non-LDH bytes. New `TrieValidationError.nonLDHLabelByte(at:byte:)` case.
- Structural check: label length ≤ 63 bytes. New `TrieValidationError.labelTooLong(at:length:)` case.

## [2.0.2] - 2026-04-23

### Added
- **Hardened trie loader.** `PublicSuffixList(source: .filePath(_:))` now runs full structural validation before trusting an on-disk buffer: CRC32 over the whole file, every offset range-checked, every reachable node visited exactly once (cycle-free), every node starts with a sentinel byte, reserved flag bits are zero, child records fit inside the buffer. Invalid files fall back to the embedded rules with a warning instead of tripping an internal precondition.
- **Bounds-checked runtime walker.** The match-time walker asserts every read against the buffer end and re-verifies each node's sentinel byte before dereferencing. A corrupted or tampered buffer manifests as a "no match" result, never an out-of-bounds read.
- **Fuzz tests** (500 fully-random + 500 header-prefixed-random buffers per seed) exercising `TrieMatcher.loadValidated`. Random inputs must be rejected or matched harmlessly; they must never crash.
- Targeted validation tests for bad magic, unsupported version, truncated buffer, corrupted body, tampered CRC field, wrong byteCount, out-of-range root offset, and missing node sentinels.
- `CRC32` helper (zlib-compatible, table-driven) shared by `TrieBuilder` and `TrieMatcher`.

## [2.0.1] - 2026-04-23

### Added
- README section showing three runtime-update flows: the built-in `updateUsingOnlineRegistry()` path, fetching raw `[[String]]` rules from a custom source and building a trie on device with `TrieBuilder.buildAndSerialize(rules:)`, and pre-compiling a trie offline then shipping the bytes.
- Short snippet documenting how to parse the upstream publicsuffix.org text format into `[[String]]`.

### Changed
- Expanded DocC on `TrieBuilder.buildAndSerialize(rules:)` with a usage example so the same guidance surfaces in Xcode Quick Help.

## [2.0.0] - 2026-04-23

### Changed
- **Breaking:** Replaced the JSON-backed rule loader and linear matcher with a memory-mapped binary trie (`registry.trie`). Load time drops by ~140× and per-match time by ~1700× in release builds; on an iPhone the library's pre-v2 ~1 s first-use cost effectively disappears.
- **Breaking:** `Match` struct simplified to `prevailingRule: [String]` and `isRestricted: Bool`. `matchedRules` is gone — it was never part of the PSL algorithm and its construction dominated match time.
- `Utilities/update-suffix.swift` now emits both `registry.json` (kept in the repo as the canonical diff artifact for the nightly workflow) and `registry.trie` (the runtime resource). The CLI entry point is unchanged: `swift update-suffix.swift`.

### Added
- `TrieFormat`, `TrieBuilder`, `TrieMatcher` in the library target. `TrieBuilder.buildAndSerialize(rules:)` is public so callers and tooling can produce trie bytes.
- `Sources/SuffixLoadBench/` — standalone executable target that benchmarks the library's load and match performance across multiple candidate formats. Run `swift run -c release SuffixLoadBench bench`.
- Comprehensive DocC documentation for all public APIs.
- Nightly workflow validates the regenerated `registry.trie` (magic bytes + minimum size) and runs `swift test` before committing — malformed tries can't ship.

### Removed
- **Breaking:** `PublicSuffixRulesRegistry` (and its `rules: [[String]]` static accessor).
- **Breaking:** `PublicSuffixMatcher` (the linear-scan matcher).
- **Breaking:** `PublicSuffixList.rules: [[String]]` — internal storage is now a binary trie, not an array of label arrays. Callers that need custom rules should continue to use `PublicSuffixList(source: .rules([[String]]))`, which builds an in-memory trie.

## [1.1.40] - 2026-04-21

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 2 suffix(es)

### Added Suffixes

- `claude.app`

### Removed Suffixes

- `cloudapps.digital`
- `london.cloudapps.digital`

## [1.1.39] - 2026-04-11

### Changed
- Updated Public Suffix List

### Summary

- Added 37 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `aberdeen.wa.us`
- `bainbridge-isl.wa.us`
- `bellevue.wa.us`
- `bremerton.wa.us`
- `centralia.wa.us`
- `chehalis.wa.us`
- `deployagent.com`
- `elastic.k2.cloud`
- `forks.wa.us`
- `gig-harbor.wa.us`
- `hoquiam.wa.us`
- `keyport.wa.us`
- `kingston.wa.us`
- `lb.ru-msk.k2.cloud`
- `lb.ru-spb.k2.cloud`
- `olympia.wa.us`
- `port-angeles.wa.us`
- `port-ludlow.wa.us`
- `port-orchard.wa.us`
- `port-townsend.wa.us`
- ... and 17 more

## [1.1.38] - 2026-04-10

### Changed
- Updated Public Suffix List

### Summary

- Added 0 suffix(es)
- Removed 1 suffix(es)

### Removed Suffixes

- `pagexl.com`

## [1.1.37] - 2026-04-08

### Changed
- Updated Public Suffix List

### Summary

- Added 3 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `opentunnel.xyz`
- `seprox.hooc.me`
- `sryze.cc`

## [1.1.36] - 2026-04-03

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `payload.dev`
- `pplx.app`

## [1.1.35] - 2026-03-19

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `exe.xyz`

## [1.1.34] - 2026-03-10

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `on.expo.app`
- `on.staging.expo.app`

## [1.1.33] - 2026-03-07

### Changed
- Updated Public Suffix List

### Summary

- Added 0 suffix(es)
- Removed 1 suffix(es)

### Removed Suffixes

- `mazeplay.com`

## [1.1.32] - 2026-03-04

### Changed
- Updated Public Suffix List

### Summary

- Added 3 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `ms.fun`
- `ms.show`
- `my.be`

## [1.1.31] - 2026-02-28

### Changed
- Updated Public Suffix List

### Summary

- Added 6 suffix(es)
- Removed 1 suffix(es)

### Added Suffixes

- `com.kh`
- `edu.kh`
- `gov.kh`
- `kh`
- `net.kh`
- `org.kh`

### Removed Suffixes

- `*.kh`

## [1.1.30] - 2026-02-26

### Changed
- Updated Public Suffix List

### Summary

- Added 4 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `intouch.email`
- `mybox.company`
- `mybox.me`
- `mybox.page`

## [1.1.29] - 2026-02-24

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `*.begetcdn.cloud`

## [1.1.28] - 2026-02-23

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `drive-platform.com`
- `drive-platform.io`

## [1.1.27] - 2026-02-18

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `kdns.fr`

## [1.1.26] - 2026-02-17

### Changed
- Updated Public Suffix List

### Summary

- Added 0 suffix(es)
- Removed 1 suffix(es)

### Removed Suffixes

- `wolterskluwer`

## [1.1.25] - 2026-02-14

### Changed
- Updated Public Suffix List

### Summary

- Added 5 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `eu-west-1.convex.cloud`
- `eu-west-1.convex.site`
- `imagine.diy`
- `us-east-1.convex.cloud`
- `us-east-1.convex.site`

## [1.1.24] - 2026-02-11

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `hue.vn`
- `sandbox.deno.net`

## [1.1.23] - 2026-02-08

### Changed
- Updated Public Suffix List

### Summary

- Added 0 suffix(es)
- Removed 1 suffix(es)

### Removed Suffixes

- `goo`

## [1.1.22] - 2026-02-07

### Changed
- Updated Public Suffix List

### Summary

- Added 12 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `1cooldns.com`
- `bumbleshrimp.com`
- `ddnsguru.com`
- `dynuddns.com`
- `dynuddns.net`
- `dynuhosting.com`
- `mysynology.net`
- `opik.net`
- `pivohosting.com`
- `roxa.org`
- `spryt.net`
- `wiredbladehosting.com`

## [1.1.21] - 2026-02-04

### Changed
- Updated Public Suffix List

### Summary

- Added 6 suffix(es)
- Removed 4 suffix(es)

### Added Suffixes

- `blob.core.usgovcloudapi.net`
- `file.core.usgovcloudapi.net`
- `file.core.windows.net`
- `usgovtrafficmanager.net`
- `web.core.usgovcloudapi.net`
- `web.core.windows.net`

### Removed Suffixes

- `*.cns.joyent.com`
- `12chars.dev`
- `12chars.it`
- `12chars.pro`

## [1.1.20] - 2026-01-30

### Changed
- Updated Public Suffix List

### Summary

- Added 18 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `*.aa.crm.dev`
- `*.ab.crm.dev`
- `*.ac.crm.dev`
- `*.ad.crm.dev`
- `*.ae.crm.dev`
- `*.af.crm.dev`
- `*.ci.crm.dev`
- `*.pa.crm.dev`
- `*.pb.crm.dev`
- `*.pc.crm.dev`
- `*.pd.crm.dev`
- `*.pe.crm.dev`
- `*.pf.crm.dev`
- `keenetic.io`
- `keenetic.link`
- `keenetic.name`
- `keenetic.pro`
- `sol.site`

## [1.1.19] - 2026-01-26

### Changed
- Updated Public Suffix List

### Summary

- Added 5 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `auth.cognito-idp.eusc-de-east-1.on.amazonwebservices.eu`
- `s3-website.dualstack.us-gov-east-1.amazonaws.com`
- `s3-website.dualstack.us-gov-west-1.amazonaws.com`
- `transfer-webapp.ap-southeast-7.on.aws`
- `transfer-webapp.mx-central-1.on.aws`

## [1.1.18] - 2026-01-25

### Changed
- Updated Public Suffix List

### Summary

- Added 6 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `corespeed.app`
- `discourse.diy`
- `miren.app`
- `miren.systems`
- `shiptoday.app`
- `shiptoday.build`

## [1.1.17] - 2026-01-21

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `spawnbase.app`

## [1.1.16] - 2026-01-17

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `kiloapps.ai`
- `kiloapps.io`

## [1.1.15] - 2026-01-14

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `base44-sandbox.com`
- `base44.app`

## [1.1.14] - 2026-01-11

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `eliv-api.kr`

## [1.1.13] - 2026-01-10

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `*.bwcloud-os-instance.de`

## [1.1.12] - 2026-01-08

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 17 suffix(es)

### Added Suffixes

- `deuxfleurs.eu`
- `deuxfleurs.page`

### Removed Suffixes

- `dd-dns.de`
- `diskstation.eu`
- `diskstation.org`
- `dray-dns.de`
- `draydns.de`
- `dyn-vpn.de`
- `dynvpn.de`
- `mein-vigor.de`
- `my-vigor.de`
- `my-wan.de`
- `onavstack.net`
- `perso.sn`
- `skygearapp.com`
- `syno-ds.de`
- `synology-diskstation.de`
- `synology-ds.de`
- `translated.page`

## [1.1.11] - 2025-12-29

### Changed
- Updated Public Suffix List

### Summary

- Added 6 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `ec.cc`
- `eu.cc`
- `gu.cc`
- `uk.cc`
- `us.cc`
- `gv.uy`

## [1.1.10] - 2025-12-23

### Changed
- Updated Public Suffix List

### Summary

- Added 3 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `ae.kg`
- `org.sk`
- `nett.to`

## [1.1.9] - 2025-12-22

### Changed
- Updated Public Suffix List

### Summary

- Added 2 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `*.cn.st`
- `imagine-proxy.work`

## [1.1.8] - 2025-12-21

### Changed
- Updated Public Suffix List

### Summary

- Added 1 suffix(es)
- Removed 0 suffix(es)

### Added Suffixes

- `antagonist.cloud`

## [1.1.6] - 2022-07-12

### Changed
- Updated Public Suffix List to 2022-07-12

## [1.1.5] - 2022-05-19

### Changed
- Migrated registry storage from generated Swift code to JSON file (`registry.json`)
- Improved bundle resource loading for registry data

## [1.1.4] - 2022-05-13

### Fixed
- Fixed iOS library compatibility issues

## [1.1.3] - 2022-05-13

### Changed
- Updated Public Suffix List to 2022-05-13

## [1.1.2] - 2022-04-08

### Changed
- Updated Public Suffix List to 2022-04-08

## [1.1.1] - 2022-03-09

### Changed
- Updated Public Suffix List to 2022-03-09

## [1.1.0] - 2022-02-19

### Added
- Async/await support for iOS 13+, macOS 10.15+, tvOS 13+
- `PublicSuffixList.list(from:urlRequestHandler:)` async factory method
- `isUnrestricted(_:) async` instance method
- `updateUsingOnlineRegistry(cachePolicy:) async` method
- `PublicSuffixListOnlineRegistryFetcher.fetch(logger:cachePolicy:urlRequestHandler:) async` method
- Code coverage with Codecov integration

### Changed
- Refactored internal matching logic into `PublicSuffixMatcher`
- Separated online fetching into `PublicSuffixListOnlineRegistryFetcher`

## [1.0.2] - 2022-02-19

### Changed
- Updated Public Suffix List

## [1.0.1] - 2022-02-15

### Changed
- Updated Public Suffix List
- Cleaned up Package.swift comments
- Updated README documentation

## [1.0.0] - 2022-01-30

### Added
- Initial release
- `PublicSuffixList` class for domain validation against the Public Suffix List
- Support for embedded, custom, online, and file-based rule sources
- `isUnrestricted(_:)` method to check if a domain is registrable
- `match(_:rules:)` method for detailed rule matching information
- `updateUsingOnlineRegistry(cachePolicy:completion:)` for runtime rule updates
- `export(to:writeOptions:)` for caching rules to disk
- Thread-safe rule access with NSLock protection
- RFC5321 domain syntax validation
- Support for wildcard rules (`*`) and exception rules (`!`)
- `PublicSuffixRulesRegistry` for accessing embedded rules
- Platform support for macOS 10.12+, iOS 11+, tvOS 11+
- Linux compatibility via FoundationNetworking
- Utility script for updating embedded Public Suffix List

[Unreleased]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/2.0.2...HEAD
[2.0.2]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/2.0.1...2.0.2
[2.0.1]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/2.0.0...2.0.1
[2.0.0]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.40...2.0.0
[1.1.40]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.39...1.1.40
[1.1.39]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.38...1.1.39
[1.1.38]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.37...1.1.38
[1.1.37]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.36...1.1.37
[1.1.36]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.35...1.1.36
[1.1.35]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.34...1.1.35
[1.1.34]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.33...1.1.34
[1.1.33]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.32...1.1.33
[1.1.32]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.31...1.1.32
[1.1.31]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.30...1.1.31
[1.1.30]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.29...1.1.30
[1.1.29]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.28...1.1.29
[1.1.28]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.27...1.1.28
[1.1.27]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.26...1.1.27
[1.1.26]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.25...1.1.26
[1.1.25]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.24...1.1.25
[1.1.24]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.23...1.1.24
[1.1.23]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.22...1.1.23
[1.1.22]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.21...1.1.22
[1.1.21]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.20...1.1.21
[1.1.20]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.19...1.1.20
[1.1.19]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.18...1.1.19
[1.1.18]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.17...1.1.18
[1.1.17]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.16...1.1.17
[1.1.16]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.15...1.1.16
[1.1.15]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.14...1.1.15
[1.1.14]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.13...1.1.14
[1.1.13]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.12...1.1.13
[1.1.12]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.11...1.1.12
[1.1.11]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.10...1.1.11
[1.1.10]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.9...1.1.10
[1.1.9]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.8...1.1.9
[1.1.8]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.7...1.1.8
[1.1.6]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.5...1.1.6
[1.1.5]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.4...1.1.5
[1.1.4]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.3...1.1.4
[1.1.3]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.2...1.1.3
[1.1.2]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.1...1.1.2
[1.1.1]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.0.2...1.1.0
[1.0.2]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/ekscrypto/SwiftPublicSuffixList/releases/tag/1.0.0
