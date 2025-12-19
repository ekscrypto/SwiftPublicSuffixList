# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Comprehensive DocC documentation for all public APIs

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

[Unreleased]: https://github.com/ekscrypto/SwiftPublicSuffixList/compare/1.1.6...HEAD
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
