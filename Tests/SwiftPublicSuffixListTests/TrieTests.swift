//
//  TrieTests.swift
//  SwiftPublicSuffixList
//
//  Focused tests on the trie serializer + walker. End-to-end behaviour is
//  already covered by SwiftPublicSuffixListTests and LoadSaveUpdateTests;
//  this file targets the format itself — round-trip stability, header
//  invariants, wildcard/exception encoding, edge cases.
//

import XCTest
@testable import SwiftPublicSuffixList

final class TrieTests: XCTestCase {

    // MARK: - Format invariants

    func testHeaderHasPSLTMagicAndVersion() {
        let bytes = TrieBuilder.buildAndSerialize(rules: [["com"]])
        XCTAssertGreaterThanOrEqual(bytes.count, 24 + 4, "header + trailing CRC minimum")
        XCTAssertEqual(bytes[0], 0x50) // P
        XCTAssertEqual(bytes[1], 0x53) // S
        XCTAssertEqual(bytes[2], 0x4C) // L
        XCTAssertEqual(bytes[3], 0x54) // T
        XCTAssertEqual(bytes[4], 2, "version must be 2")
    }

    func testHeaderRootOffsetPointsWithinBuffer() {
        let bytes = TrieBuilder.buildAndSerialize(rules: [["com"], ["org"], ["net"]])
        let rootOffset = UInt32(bytes[8])
                       | (UInt32(bytes[9]) << 8)
                       | (UInt32(bytes[10]) << 16)
                       | (UInt32(bytes[11]) << 24)
        XCTAssertGreaterThanOrEqual(rootOffset, 24)
        XCTAssertLessThan(Int(rootOffset), bytes.count)
    }

    func testHeaderRuleCountReflectsInput() {
        let rules: [[String]] = [["com"], ["org"], ["net"], ["co", "uk"], ["*", "ck"]]
        let bytes = TrieBuilder.buildAndSerialize(rules: rules)
        let ruleCount = UInt32(bytes[16])
                      | (UInt32(bytes[17]) << 8)
                      | (UInt32(bytes[18]) << 16)
                      | (UInt32(bytes[19]) << 24)
        XCTAssertEqual(Int(ruleCount), rules.count)
    }

    func testHeaderByteCountMatchesBufferLength() {
        let bytes = TrieBuilder.buildAndSerialize(rules: [["com"], ["co", "uk"]])
        let byteCount = UInt32(bytes[20])
                      | (UInt32(bytes[21]) << 8)
                      | (UInt32(bytes[22]) << 16)
                      | (UInt32(bytes[23]) << 24)
        XCTAssertEqual(Int(byteCount), bytes.count)
    }

    // MARK: - Determinism / stability

    func testSerializationIsDeterministic() {
        let rules: [[String]] = [["com"], ["co", "uk"], ["*", "ck"], ["!www", "ck"]]
        let a = TrieBuilder.buildAndSerialize(rules: rules)
        let b = TrieBuilder.buildAndSerialize(rules: rules)
        XCTAssertEqual(a, b, "same input must produce byte-identical output")
    }

    func testChildOrderingIsDeterministicRegardlessOfInputOrder() {
        let rulesA: [[String]] = [["com"], ["org"], ["net"]]
        let rulesB: [[String]] = [["net"], ["com"], ["org"]]
        let a = TrieBuilder.buildAndSerialize(rules: rulesA)
        let b = TrieBuilder.buildAndSerialize(rules: rulesB)
        // Input order shouldn't matter — the serializer sorts children by
        // label bytes before writing.
        XCTAssertEqual(a, b)
    }

    // MARK: - Round-trip matching

    private func match(_ rules: [[String]]) -> TrieMatcher {
        TrieMatcher(data: TrieBuilder.buildAndSerialize(rules: rules))
    }

    func testSimpleTLDRule() {
        let m = match([["com"]])
        XCTAssertFalse(m.isUnrestricted("com"))
        XCTAssertTrue(m.isUnrestricted("yahoo.com"))
        XCTAssertTrue(m.isUnrestricted("mail.yahoo.com"))
        XCTAssertFalse(m.isUnrestricted("com."))   // trailing dot rejected by host syntax
    }

    func testTwoLabelRule() {
        let m = match([["co", "uk"]])
        XCTAssertFalse(m.isUnrestricted("co.uk"))
        XCTAssertTrue(m.isUnrestricted("bbc.co.uk"))
        XCTAssertTrue(m.isUnrestricted("www.bbc.co.uk"))
        XCTAssertFalse(m.isUnrestricted("uk"))     // .uk not in the trie; walk finds no match
    }

    func testWildcardRuleRestrictsOneLabelBelow() {
        let m = match([["*", "ck"]])
        XCTAssertFalse(m.isUnrestricted("foo.ck"))          // matched by *.ck
        XCTAssertTrue(m.isUnrestricted("site.foo.ck"))      // one more label than rule
    }

    func testExceptionOverridesWildcard() {
        let m = match([["*", "ck"], ["!www", "ck"]])
        XCTAssertFalse(m.isUnrestricted("foo.ck"),   "foo.ck matched by *.ck")
        XCTAssertTrue (m.isUnrestricted("www.ck"),   "www.ck is an exception — registrable")
        XCTAssertTrue (m.isUnrestricted("mail.www.ck"))
    }

    func testExceptionPrefersOverDeeperNonException() {
        // Rule set where an exception rule is the best match even though a
        // non-exception also matches at the same depth. This is the exact
        // case the previous matcher special-cased via
        // "any exception wins regardless of depth".
        let m = match([["*", "ck"], ["!www", "ck"]])
        guard let decision = m.match("www.ck") else {
            XCTFail("www.ck should match an exception rule")
            return
        }
        XCTAssertFalse(decision.isRestricted)
        XCTAssertEqual(decision.prevailingRule, ["!www", "ck"],
                       "prevailing rule must carry the ! marker on the leftmost label")
    }

    func testDeeplyNestedRule() {
        let m = match([["izumizaki", "fukushima", "jp"]])
        XCTAssertFalse(m.isUnrestricted("izumizaki.fukushima.jp"))
        XCTAssertTrue(m.isUnrestricted("site.izumizaki.fukushima.jp"))
        XCTAssertFalse(m.isUnrestricted("fukushima.jp"),
                       "the 3-label rule shouldn't match the 2-label suffix alone")
    }

    // MARK: - Edge cases

    func testEmptyRuleSetMatchesNothing() {
        let m = match([])
        XCTAssertFalse(m.isUnrestricted("yahoo.com"))
        XCTAssertNil(m.match("yahoo.com"))
    }

    func testEmptyRuleIsIgnored() {
        let m = match([[]])
        XCTAssertFalse(m.isUnrestricted("yahoo.com"))
    }

    func testEmptyLabelsWithinRuleAreIgnored() {
        // Stray empty labels (e.g. from extra dots in input data) should be
        // skipped, not turned into zero-length children — otherwise a rule
        // like ["com", ""] would create a corrupted trie edge.
        let m = match([["", "com"]])
        XCTAssertFalse(m.isUnrestricted("com"))
        XCTAssertTrue(m.isUnrestricted("yahoo.com"))
    }

    func testDuplicateRulesCollapse() {
        let single = TrieBuilder.buildAndSerialize(rules: [["com"]])
        let duped  = TrieBuilder.buildAndSerialize(rules: [["com"], ["com"], ["com"]])
        // Node structure collapses on duplicates. Compare the body region
        // (between the 24-byte header and the 4-byte trailing CRC); the
        // header's ruleCount diagnostic and trailing CRC will legitimately
        // differ between single and duped.
        func body(_ d: Data) -> Data {
            d.subdata(in: 24..<(d.count - 4))
        }
        XCTAssertEqual(body(single), body(duped),
                       "duplicate rules must not multiply the trie body")
    }

    func testUnicodeLabelsRoundTrip() {
        let m = match([["公司", "cn"], ["jp"]])
        XCTAssertFalse(m.isUnrestricted("公司.cn"))
        XCTAssertTrue(m.isUnrestricted("baidu.公司.cn"))
        XCTAssertTrue(m.isUnrestricted("秋田.jp"))
    }

    func testMaximumLabelLengthAccepted() {
        // RFC 1035 caps a label at 63 bytes; our format allows up to 255.
        // This exercises the long-but-valid path.
        let long = String(repeating: "a", count: 63)
        let m = match([["net"]])
        XCTAssertTrue(m.isUnrestricted("\(long).net"))
    }

    func testLabelOver63BytesRejectedByHostValidation() {
        let tooLong = String(repeating: "a", count: 64)
        let m = match([["net"]])
        XCTAssertFalse(m.isUnrestricted("\(tooLong).net"),
                       "host validation must reject labels over 63 bytes")
    }

    func testManyChildrenAtOneLevel() {
        // 500 TLDs directly under root exercises the linear child-scan path
        // in the walker and confirms serialization handles large child_count.
        let tlds = (0..<500).map { ["tld\($0)"] }
        let m = match(tlds)
        XCTAssertFalse(m.isUnrestricted("tld0"))
        XCTAssertTrue(m.isUnrestricted("site.tld0"))
        XCTAssertFalse(m.isUnrestricted("tld499"))
        XCTAssertTrue(m.isUnrestricted("site.tld499"))
        XCTAssertTrue(m.isUnrestricted("site.tld250"))
        XCTAssertFalse(m.isUnrestricted("site.not-in-list"))
    }

    // MARK: - Bad file handling via PublicSuffixList.filePath(_:)

    func testFilePathWithNonPSLTMagicFallsBackToEmbedded() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".trie")
        // Write garbage — definitely not the PSLT magic.
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        try? garbage.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exp = XCTestExpectation()
        Thread {
            let list = PublicSuffixList(source: .filePath(tmp.path))
            // Fallback to embedded — yahoo.com is registrable.
            XCTAssertTrue(list.isUnrestricted("yahoo.com"))
            exp.fulfill()
        }.start()
        wait(for: [exp], timeout: 2.0)
    }

    func testFilePathWithTruncatedHeaderFallsBackToEmbedded() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".trie")
        // Correct magic but shorter than the 24-byte header. Previously this
        // would trip TrieMatcher's internal size precondition; PublicSuffixList
        // now pre-validates the full header length and falls back cleanly.
        let stub = Data([0x50, 0x53, 0x4C, 0x54, 0x01, 0x00, 0x00, 0x00])
        try? stub.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exp = XCTestExpectation()
        Thread {
            let list = PublicSuffixList(source: .filePath(tmp.path))
            XCTAssertTrue(list.isUnrestricted("yahoo.com"))
            exp.fulfill()
        }.start()
        wait(for: [exp], timeout: 2.0)
    }

    func testFilePathWithUnsupportedVersionFallsBackToEmbedded() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".trie")
        // Valid magic, valid header length, but version byte = 99 — future
        // format we don't know how to parse.
        var stub = Data([0x50, 0x53, 0x4C, 0x54, 99])
        stub.append(contentsOf: Array(repeating: UInt8(0), count: 24 - stub.count))
        try? stub.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exp = XCTestExpectation()
        Thread {
            let list = PublicSuffixList(source: .filePath(tmp.path))
            XCTAssertTrue(list.isUnrestricted("yahoo.com"))
            exp.fulfill()
        }.start()
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - Validation: tampered / malformed buffers

    private func validBytes(_ rules: [[String]] = [["com"], ["co", "uk"]]) -> Data {
        TrieBuilder.buildAndSerialize(rules: rules)
    }

    func testValidationAcceptsWellFormedBuffer() {
        let bytes = validBytes()
        XCTAssertNotNil(TrieMatcher.loadValidated(data: bytes))
    }

    func testValidationRejectsBadMagic() {
        var bytes = validBytes()
        bytes[0] = 0xFF  // corrupt magic
        XCTAssertNil(TrieMatcher.loadValidated(data: bytes))
    }

    func testValidationRejectsUnsupportedVersion() {
        var bytes = validBytes()
        bytes[4] = 99
        // (CRC is now wrong too, which would reject earlier; either way: nil.)
        XCTAssertNil(TrieMatcher.loadValidated(data: bytes))
    }

    func testValidationRejectsTruncatedBuffer() {
        let bytes = validBytes()
        let truncated = bytes.prefix(20) // shorter than header
        XCTAssertNil(TrieMatcher.loadValidated(data: Data(truncated)))
    }

    func testValidationRejectsCorruptedBody() {
        var bytes = validBytes()
        // Flip a byte in the middle of the body — CRC must reject.
        let mid = 24 + (bytes.count - 28) / 2
        bytes[mid] ^= 0xFF
        XCTAssertNil(TrieMatcher.loadValidated(data: bytes))
    }

    func testValidationRejectsCorruptedCRCField() {
        var bytes = validBytes()
        // Flip a bit in the trailing CRC — must reject.
        bytes[bytes.count - 1] ^= 0x01
        XCTAssertNil(TrieMatcher.loadValidated(data: bytes))
    }

    func testValidationRejectsWrongByteCount() {
        var bytes = validBytes()
        // Claim the buffer is 1 byte longer than it really is.
        let fake = UInt32(bytes.count + 1).littleEndian
        withUnsafeBytes(of: fake) { src in
            for i in 0..<4 { bytes[20 + i] = src[i] }
        }
        XCTAssertNil(TrieMatcher.loadValidated(data: bytes))
    }

    func testValidationRejectsOutOfRangeRootOffset() {
        var bytes = validBytes()
        // Point rootOffset past end of buffer. CRC also breaks, which is the
        // reason we expect rejection — but either way the matcher must refuse.
        let bad = UInt32(0xFFFF_FFFF).littleEndian
        withUnsafeBytes(of: bad) { src in
            for i in 0..<4 { bytes[8 + i] = src[i] }
        }
        XCTAssertNil(TrieMatcher.loadValidated(data: bytes))
    }

    func testValidationRejectsMissingNodeSentinel() {
        var bytes = validBytes()
        // Locate root node (header bytes 8..11), blow away its sentinel byte.
        let rootOffset = Int(UInt32(bytes[8])
                         | (UInt32(bytes[9]) << 8)
                         | (UInt32(bytes[10]) << 16)
                         | (UInt32(bytes[11]) << 24))
        bytes[rootOffset] = 0x00  // should be TrieFormat.nodeSentinel (0xE9)
        // Need to repair CRC to reach the sentinel check; otherwise CRC rejects first.
        let crcRange = bytes.count - 4
        // Recompute CRC32 over tampered body.
        var crc: UInt32 = 0xFFFFFFFF
        let table: [UInt32] = {
            var t = [UInt32](repeating: 0, count: 256)
            for i in 0..<256 {
                var c = UInt32(i)
                for _ in 0..<8 { c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
                t[i] = c
            }
            return t
        }()
        for i in 0..<crcRange {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(bytes[i])) & 0xFF)]
        }
        let crcLE = (crc ^ 0xFFFFFFFF).littleEndian
        withUnsafeBytes(of: crcLE) { src in
            for i in 0..<4 { bytes[crcRange + i] = src[i] }
        }
        XCTAssertNil(TrieMatcher.loadValidated(data: bytes),
                     "node without sentinel must be rejected")
    }

    // MARK: - Fuzz: random bytes must never crash

    func testFuzzRandomBytesAreRejectedOrMatchHarmlessly() {
        // Seeded PRNG for reproducibility.
        var rng = SplitMix64(seed: 0xC0FF_EE_DEAD_BEEF)
        for _ in 0..<500 {
            let length = Int(rng.next() % 4096)  // 0..4095 bytes
            var bytes = Data(count: length)
            for i in 0..<length {
                bytes[i] = UInt8(rng.next() & 0xFF)
            }
            // Validator must never trap; it returns nil for invalid inputs.
            let matcher = TrieMatcher.loadValidated(data: bytes)
            if let matcher = matcher {
                // If by astronomical chance the random bytes validate as a
                // real trie, matching must still not crash.
                _ = matcher.isUnrestricted("yahoo.com")
                _ = matcher.isUnrestricted("www.ck")
                _ = matcher.isUnrestricted("")
            }
        }
    }

    func testFuzzMagicOnlyRandomRestIsRejected() {
        // Bias the fuzz toward "looks like a trie" (correct magic + version)
        // to exercise validator paths beyond the header.
        var rng = SplitMix64(seed: 0xDEAD_BEEF_FEED_FACE)
        for _ in 0..<500 {
            let length = 28 + Int(rng.next() % 2048)
            var bytes = Data(count: length)
            bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x4C; bytes[3] = 0x54
            bytes[4] = 2  // claimed version 2
            for i in 5..<length {
                bytes[i] = UInt8(rng.next() & 0xFF)
            }
            // Forge a plausible byteCount = length.
            let bc = UInt32(length).littleEndian
            withUnsafeBytes(of: bc) { src in
                for i in 0..<4 { bytes[20 + i] = src[i] }
            }
            // Validator never traps.
            _ = TrieMatcher.loadValidated(data: bytes)
        }
    }

    // MARK: - Parity with embedded rules for a well-known case

    func testEmbeddedTrieHandlesWildcardAndExceptionFromRealPSL() {
        // These cases are known to appear in the real publicsuffix.org list.
        // They double as canaries if we ever ship a broken embedded trie.
        XCTAssertTrue(PublicSuffixList.isUnrestricted("www.ck"),
                      "www.ck is the canonical PSL exception — must be registrable")
        XCTAssertFalse(PublicSuffixList.isUnrestricted("anything.ck"),
                       "*.ck public suffix, plain anything.ck must be restricted")
        XCTAssertTrue(PublicSuffixList.isUnrestricted("site.anything.ck"),
                      "one level deeper than *.ck is registrable")
    }
}

/// Reproducible PRNG for fuzz tests. Not cryptographic.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
