//
//  SwiftPublicSuffixListTests.swift
//  SwiftPublicSuffixList
//
//  Created by Dave Poirier on 2022-01-30.
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license.

import XCTest
@testable import SwiftPublicSuffixList

class SwiftPublicSuffixListTests: XCTestCase {

    let validSyntaxHosts: [String] = [
        "yahoo.com", // confirm simplest case
        "mail.gov.ck", // confirm we can process *.TLD rules
        "www.ck", // confirm we can match ! exception rules, like !www.ck
        "visitor.hotel.kitakyushu.jp", // confirm proper handling of * rule for multi-components
        "natural-history.izumizaki.fukushima.jp", // confirm multi-level rule for 4 components
        "my-site.com", // confirm - characters are allowed
        "my.site.com", // confirm sub-domains are allowed
        "www.秋田.jp", // confirm Unicode characters in host are allowed
        "bucarest.telekommunikation.museum", // confirm longer TLD are allowed
        "123456789012345678901234567890123456789012345678901234567890123.net", // confirm maximum allowed component of 63 characters
        "123456789012345678901234567890123456789012345678901234567890123.123456789012345678901234567890123456789012345678901234567890123.123456789012345678901234567890123456789012345678901234567890123.123456789012345678901234567890123456789012345678901234567.net", // confirm maximum allowed entire host of 253 characters
        "8.8.8.org", // confirm numerical domains are allowed provided they are within a TLD,
        "灣.澳门" // confirm Unicode TLD are allowed
    ]
    
    let invalidSyntaxHosts: [String] = [
        "", // Empty string not allowed
        ".", // No host or TLD specified
        "x.x", // Invalid TLD: .x
        "site.jq", // Invalid TLD: .jq
        "website..com", // Double . separators are not allowed
        ".com", // Missing host in front of TLD
        "com", // TLD-only cannot host
        ".website.com", // Leading . not allowed
        "website.com.", // Trailing . not allowed
        "my~site.com", // Invalid character ~
        "my(site.com", // Invalid character (
        "my)site.com", // Invalid character )
        "my%site.com", // Invalid character %
        "my_site.com", // Invalid character _
        "my!site.com", // Invalid character !
        "my@site.com", // Invalid character @
        "my&site.com", // Invalid character &
        "my^site.com", // Invalid character ^
        "my#site.com", // Invalid character #
        "my*site.com", // Invalid character *
        "my,site.com", // Invalid character ,
        "my}site.com", // Invalid character }
        "my{site.com", // Invalid character {
        "my'site.com", // Invalid character '
        "my site.com", // Invalid character <space>
        "my\"site.com", // Potentially invalid character " -- to be confirmed, not listed on Microsoft site
        "秋田.jp", // listed as public suffix
        "รัฐบาล.ไทย", // listed as public suffix
        "izumizaki.fukushima.jp", // listed as public suffix,
        "hotel.kitakyushu.jp", // matching *.kitakyushu.jp public suffix
        "website.ck", // *.ck listed as public suffix, not matching !www.ck exception
        "telekommunikation.museum", // listed as public suffix
        "1234567890123456789012345678901234567890123456789012345678901234.net", // maximum allowed exceeded 64 > 63
        "123456789012345678901234567890123456789012345678901234567890123.123456789012345678901234567890123456789012345678901234567890123.123456789012345678901234567890123456789012345678901234567890123.123456789012345678901234567890123456789012345678901234567.museum" // maximum allowed entire host exceeded 256 > 253
    ]
    
    func testValidSyntaxHosts() {
        validSyntaxHosts.forEach { XCTAssertTrue(PublicSuffixList.isUnrestricted($0), "Expected \($0) to be a valid email host syntax") }
    }
    
    func testInvalidSyntaxHosts() {
        invalidSyntaxHosts.forEach { XCTAssertFalse(PublicSuffixList.isUnrestricted($0), "Expected \($0) to be an invalid email host syntax") }
    }
    
    func testValidSyntaxHostsInstance() {
        let testDoneExpectation = XCTestExpectation()
        DispatchQueue.global().async {
            let list = PublicSuffixList(source: .embedded)
            self.validSyntaxHosts.forEach { XCTAssertTrue(list.isUnrestricted($0), "Expected \($0) to be a valid email host syntax") }
            testDoneExpectation.fulfill()
        }
        wait(for: [testDoneExpectation], timeout: 2.0)
    }
    
    func testValidSyntaxHostsAsyncInstance() async {
        let list = await PublicSuffixList.list()
        for validHost in validSyntaxHosts {
            let unrestrictedAsync: Bool = await list.isUnrestricted(validHost)
            XCTAssertTrue(unrestrictedAsync, "Expected \(validHost) to be a valid email host syntax")
        }
    }
    
    func testInvalidSyntaxHostsAsyncInstance() async {
        let list = await PublicSuffixList.list()
        for invalidHost in invalidSyntaxHosts {
            let unrestricted: Bool = await list.isUnrestricted(invalidHost)
            XCTAssertFalse(unrestricted, "Expected \(invalidHost) to be an invalid email host syntax")
        }
    }
    
    func testSimpleSuffix() {
        XCTAssertFalse(PublicSuffixList.isUnrestricted("com", rules: [["com"]]))
        XCTAssertTrue(PublicSuffixList.isUnrestricted("yahoo.com", rules: [["com"]] ))
    }
    
    func testSimpleSuffixWithWildcardRule() {
        XCTAssertFalse(PublicSuffixList.isUnrestricted("yahoo.com", rules: [["*","com"]]), "When rule contains a wildcard, any label should match and be considered public-suffix")
    }
    
    func testSubdomainWithSimpleSuffixAndWildcardRule() {
        XCTAssertTrue(PublicSuffixList.isUnrestricted("mail.yahoo.com", rules: [["*","com"]]), "When <label>.TLD matches a wildcard but it has a subdomain, it should no longer be considered a public-suffix and be allowed")
    }
    
    func testSubdomainWithSimpleSuffixWithWildcardAndException() {
        XCTAssertTrue(PublicSuffixList.isUnrestricted("yahoo.com", rules: [["*","com"],["!yahoo","com"]]), "An exception exists for this exact match therefore it is not a public-suffix and should be allowed")
        XCTAssertTrue(PublicSuffixList.isUnrestricted("yahoo.com", rules: [["!yahoo","com"],["*","com"]]), "An exception exists for this exact match therefore it is not a public-suffix and should be allowed")
    }
    
    func testExtendedSuffix() {
        XCTAssertFalse(PublicSuffixList.isUnrestricted("izumizaki.fukushima.jp", rules: [["izumizaki","fukushima","jp"]]),"A domain containing multiple labels perfectly match a defined public-suffix, it should not be allowed")
        XCTAssertFalse(PublicSuffixList.isUnrestricted("izumizaki.fukushima.jp"))
    }
    
    func testEmptyRules() {
        XCTAssertFalse(PublicSuffixList.isUnrestricted("website.com", rules: []), "When no rules are specified, code should default to failed validation")
        XCTAssertFalse(PublicSuffixList.isUnrestricted("website.com", rules: [[]]), "When no rules are specified, code should default to failed validation")
    }
    
    func testEmptyRulesIgnored() {
        XCTAssertTrue(PublicSuffixList.isUnrestricted("website.com", rules: [[], [], ["com"], []]), "Empty suffix rules should be ignored but rules with definitions should still be processed")
    }
}
