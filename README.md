![swift workflow](https://github.com/ekscrypto/SwiftPublicSuffixList/actions/workflows/swift.yml/badge.svg) [![codecov](https://codecov.io/gh/ekscrypto/SwiftPublicSuffixList/branch/main/graph/badge.svg?token=W9KO1BG8S0)](https://codecov.io/gh/ekscrypto/SwiftPublicSuffixList) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) ![Issues](https://img.shields.io/github/issues/ekscrypto/SwiftPublicSuffixList) ![Releases](https://img.shields.io/github/v/release/ekscrypto/SwiftPublicSuffixList)

# SwiftPublicSuffixList

This library is a Swift implementation of the necessary code to check a domain name against the [Public Suffix List](https://publicsuffix.org) and identify if the domains should be restricted.

Restricted domains should not be allowed to set cookies, directly host websites or send/receive emails.

As of 2026, the list contains over 10k entries.

## Performance

The library ships a pre-compiled binary trie (`registry.trie`) that is memory-mapped at first use. There is no JSON parsing and no per-rule allocation — load cost is effectively the time to `mmap` a ~150 KB file (well under 1 ms on any supported device).

Matching walks the trie by label from TLD inward. A single `isUnrestricted(_:)` call runs in microseconds and does not allocate heap memory proportional to the rule set, so checking thousands of domains in a loop is a non-issue.

This replaces the pre-v2 behaviour where loading the JSON-backed rule set and scanning it linearly could take up to ~1 s on a mobile device.

## Regular Updates Recommended

The [Public Suffix List](https://publicsuffix.org) is updated regularly. Pulling the latest version of this library is usually sufficient; for applications that need the freshest list between releases, fetch it at runtime (see below).

LAST UPDATED: 2026-04-21 03:10:05 UTC

### Shell Command

Run `Utilities/update-suffix.swift` to download the latest Public Suffix List and regenerate both `registry.json` (kept for CI diffs) and `registry.trie` (the runtime resource).

    cd Utilities
    swift update-suffix.swift

### Runtime updates

Use an instance of `PublicSuffixList` (rather than the static helpers) when you need to update the rules at runtime.

    import SwiftPublicSuffixList

    let cacheUrl = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("public-suffix-list.trie")

    let publicSuffixList = await PublicSuffixList.list(from: .filePath(cacheUrl.path))

Request a registry update from publicsuffix.org:

    let success: Bool = await publicSuffixList.updateUsingOnlineRegistry()

Persist the updated rules for next launch (writes the binary trie format):

    try publicSuffixList.export(to: cacheUrl.path)

## Classes & Usage

### PublicSuffixList

#### .match(_ candidate: String) -> Match?

    import SwiftPublicSuffixList

Using the default built-in Public Suffix List rules:

    if let match = PublicSuffixList.match("yahoo.com") {
        // match.isRestricted == false
        // match.prevailingRule == ["com"]
    }

    // or using a PublicSuffixList instance…
    let publicSuffixList = PublicSuffixList()
    if let match = publicSuffixList.match("yahoo.com") {
        // match.isRestricted == false
    }

    // or the async equivalent
    let publicSuffixList = await PublicSuffixList.list()
    if let match = publicSuffixList.match("yahoo.com") {
        // match.isRestricted == false
    }

Using a single custom validation rule, requiring domains to end with `.com` but allowing any domain within the `.com` TLD:

    if let match = PublicSuffixList.match("yahoo.com", rules: [["com"]]) {
        // match.isRestricted == false
        // match.prevailingRule == ["com"]
    }

    // or using a PublicSuffixList instance…
    let publicSuffixList = PublicSuffixList(source: .rules([["com"]]))
    if let match = publicSuffixList.match("yahoo.com") {
        // match.isRestricted == false
        // match.prevailingRule == ["com"]
    }

Using a single custom validation rule that restricts domains ending with `.com` but allows any subdomain:

    if let match = PublicSuffixList.match("yahoo.com", rules: [["*","com"]]) {
        // yahoo.com matches *.com and so it is restricted
        // match.isRestricted == true
        // match.prevailingRule == ["com"]  // wildcard edge walked; rule body is the labels matched
    }

    if let match = PublicSuffixList.match("www.yahoo.com", rules: [["*","com"]]) {
        // yahoo.com matches *.com and is restricted, but www.yahoo.com has one
        // more label than the rule, so it's registrable.
        // match.isRestricted == false
    }

Defining an exception to a more generic rule:

    if let match = PublicSuffixList.match("yahoo.com", rules: [["*","com"],["!yahoo","com"]]) {
        // The exception (!yahoo.com) overrides the *.com rule.
        // match.isRestricted == false
        // match.prevailingRule == ["!yahoo","com"]
    }

#### .isUnrestricted(_ candidate: String) -> Bool

Convenience that returns `!match.isRestricted`, or `false` if no rule matches or the host is syntactically invalid. This is the fastest path — zero heap allocations proportional to the rule set.

    if PublicSuffixList.isUnrestricted("yahoo.com") {
        // true — yahoo.com is unrestricted by default
    }

    // or using a PublicSuffixList instance…
    let publicSuffixList = PublicSuffixList()
    if publicSuffixList.isUnrestricted("yahoo.com") {
        // true — yahoo.com is unrestricted by default
    }

### Match

`Match` exposes only two fields — the prevailing rule and whether the candidate is restricted:

    public struct Match {
        public let prevailingRule: [String]
        public let isRestricted: Bool
    }

(The legacy `matchedRules` field was removed in v2; it was never part of the public-suffix algorithm and its construction cost dominated match time.)
