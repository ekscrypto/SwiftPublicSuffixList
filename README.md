![swift workflow](https://github.com/ekscrypto/SwiftPublicSuffixList/actions/workflows/swift.yml/badge.svg) [![codecov](https://codecov.io/gh/ekscrypto/SwiftPublicSuffixList/branch/main/graph/badge.svg?token=W9KO1BG8S0)](https://codecov.io/gh/ekscrypto/SwiftPublicSuffixList) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) ![Issues](https://img.shields.io/github/issues/ekscrypto/SwiftPublicSuffixList) ![Releases](https://img.shields.io/github/v/release/ekscrypto/SwiftPublicSuffixList)

# SwiftPublicSuffixList

This library is a Swift implementation of the necessary code to check a domain name against the [Public Suffix List](https://publicsuffix.org) and identify if the domains should be restricted.

Restricted domains should not be allowed to set cookies, directly host websites or send/receive emails.

As of 2026, the list contains over 10k entries.

## Performance

The library ships a pre-compiled binary trie (`registry.trie`) that is memory-mapped at first use. There is no JSON parsing and no per-rule allocation — load cost is effectively the time to `mmap` a ~150 KB file (well under 1 ms on any supported device).

Matching walks the trie by label from TLD inward. A single `isUnrestricted(_:)` call runs in microseconds and does not allocate heap memory proportional to the rule set, so checking thousands of domains in a loop is a non-issue.

This replaces the pre-v2 behaviour where loading the JSON-backed rule set and scanning it linearly could take up to ~1 s on a mobile device.

## Hostnames must be in ACE (Punycode) form

Since v3.0, `isUnrestricted(_:)` and `match(_:)` expect hostnames in ASCII / ACE form. IDN labels must be Punycode-encoded by the caller before the check:

    // ❌ rejected — raw Unicode is not a valid wire-format hostname
    PublicSuffixList.isUnrestricted("example.香港")

    // ✅ correct
    PublicSuffixList.isUnrestricted("example.xn--j6w193g")

This matches the DNS wire format and the RFC 5321 hostname syntax used in email. The embedded trie stores ACE-form labels only, so the matcher can compare byte-for-byte against whatever the caller supplies without surprise. Rule inputs to `.rules([[String]])` may still be in UTF-8 form — the builder runs each label through an RFC 3492 Punycode encoder at build time.

If your input is a Unicode hostname, convert it with `PublicSuffixList.ace(_:)` before the check:

    let host = PublicSuffixList.ace("example.香港") // "example.xn--j6w193g"
    PublicSuffixList.isUnrestricted(host)            // true

`ace(_:)` applies the internal Punycode encoder to each label and rejoins with `.` — it does no case folding or Unicode normalization, so feed already-canonicalized labels (NFC, lowercased as appropriate) if you need full IDNA processing. The library intentionally ships no decoder; rendering ACE back to Unicode is the caller's responsibility.

## Regular Updates Recommended

The [Public Suffix List](https://publicsuffix.org) is updated regularly. Pulling the latest version of this library is usually sufficient; for applications that need the freshest list between releases, fetch it at runtime (see below).

LAST UPDATED: 2026-04-26 03:11:50 UTC

### Shell Command

Run `Utilities/update-suffix.swift` to download the latest Public Suffix List and regenerate both `registry.json` (kept for CI diffs) and `registry.trie` (the runtime resource).

    cd Utilities
    swift update-suffix.swift

### Runtime updates — fetch from publicsuffix.org

Use an instance of `PublicSuffixList` (rather than the static helpers) when you need to update the rules at runtime. The built-in updater hits publicsuffix.org and replaces the in-memory trie on success:

    import SwiftPublicSuffixList

    let cacheUrl = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("public-suffix-list.trie")

    // Falls back to embedded rules if the cache file is missing/corrupt.
    let publicSuffixList = await PublicSuffixList.list(from: .filePath(cacheUrl.path))

    let success: Bool = await publicSuffixList.updateUsingOnlineRegistry()
    if success {
        // Persist the new trie for next launch so startup avoids the network.
        try publicSuffixList.export(to: cacheUrl.path)
    }

### Runtime updates — your own data source

If you'd rather ship rules from your own CDN (to avoid hotlinking publicsuffix.org, to control the update cadence, or to amend the list with custom entries), there are two paths.

**Path A: Ship raw rules, build the trie on device.** Send your app an `[[String]]` — one inner array per rule, labels in leftmost-first order. Anything that decodes to `[[String]]` works (JSON, plist, your own wire format). The library builds a trie in memory in a couple of milliseconds.

    // Example: your server returns a JSON array of string arrays.
    let data: Data = try await URLSession.shared.data(from: myUpdateURL).0
    let rules = try JSONDecoder().decode([[String]].self, from: data)

    // Build and use directly (one-shot).
    let list = PublicSuffixList(source: .rules(rules))

    // …or persist as a trie so subsequent launches skip the JSON parse.
    let trieBytes = TrieBuilder.buildAndSerialize(rules: rules)
    try trieBytes.write(to: cacheUrl)

**Path B: Pre-compile the trie on your server (or at build time) and ship bytes.** The on-disk format is a memory-mappable binary blob — no parsing cost on device. Any Swift process that can `import SwiftPublicSuffixList` can produce one:

    import SwiftPublicSuffixList

    // Rules in leftmost-first order — same format used by publicsuffix.org.
    let rules: [[String]] = [
        ["com"],
        ["co", "uk"],
        ["*", "ck"],
        ["!www", "ck"],
        // …
    ]

    let bytes: Data = TrieBuilder.buildAndSerialize(rules: rules)
    try bytes.write(to: URL(fileURLWithPath: "/path/to/registry.trie"))

On device, load it the same way you would the embedded resource — either by pointing `.filePath` at the cached file, or by bundling it as a resource:

    let list = PublicSuffixList(source: .filePath(cacheUrl.path))

`TrieBuilder.buildAndSerialize(rules:)` and the `.filePath(_:)` / `.rules(_:)` sources are the full public surface for custom data flows. The nightly workflow script (`Utilities/update-suffix.swift`) is itself a worked example of building a trie from the upstream PSL text format.

### Parsing the upstream PSL text

The publicsuffix.org distribution is a plain-text file — one rule per line, comments start with `//`. Parsing it into `[[String]]` is trivial; `updateUsingOnlineRegistry(...)` does it internally, but if you want to handle the fetch yourself:

    let text: String = // fetched from publicsuffix.org or your mirror
    let rules: [[String]] = text
        .components(separatedBy: .newlines)
        .filter { !$0.hasPrefix("//") && !$0.isEmpty }
        .map { $0.components(separatedBy: ".") }

    let trieBytes = TrieBuilder.buildAndSerialize(rules: rules)

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
