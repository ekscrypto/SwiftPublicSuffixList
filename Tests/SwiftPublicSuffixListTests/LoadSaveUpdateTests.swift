//
//  LoadSaveUpdateTests.swift
//  SwiftPublicSuffixList
//
//  Created by Dave Poirier on 2022-02-19.
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license
//

import XCTest
@testable import SwiftPublicSuffixList

final class LoadSaveUpdateTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
        super.setUp()
    }

    /// Probes that two custom rule sources behave differently from each other
    /// and from the embedded rules — equivalent to the old `list.rules ==`
    /// equality checks now that internal storage is a trie, not `[[String]]`.
    func testLoadCustomRules() {
        let customRules1: [[String]] = [["hello", "world"]]
        let firstList = PublicSuffixList(source: .rules(customRules1))

        let customRules2: [[String]] = [["other", "rules"]]
        let secondList = PublicSuffixList(source: .rules(customRules2))

        XCTAssertTrue(firstList.isUnrestricted("site.hello.world"))
        XCTAssertFalse(firstList.isUnrestricted("hello.world"))
        XCTAssertFalse(firstList.isUnrestricted("site.other.rules"),
                       "first list's trie should not match rules from the second list")

        XCTAssertTrue(secondList.isUnrestricted("site.other.rules"))
        XCTAssertFalse(secondList.isUnrestricted("other.rules"))
        XCTAssertFalse(secondList.isUnrestricted("site.hello.world"))
    }

    private func performSaveAndLoad() {
        let customRules: [[String]] = [["hello", "world"]]
        let listToSave = PublicSuffixList(source: .rules(customRules))
        let fileUrl = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertNoThrow(try listToSave.export(to: fileUrl.path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileUrl.path))

        let reloadedList = PublicSuffixList(source: .filePath(fileUrl.path))
        XCTAssertTrue(reloadedList.isUnrestricted("site.hello.world"))
        XCTAssertFalse(reloadedList.isUnrestricted("hello.world"))
        XCTAssertFalse(reloadedList.isUnrestricted("yahoo.com"),
                       "reloaded list should not accidentally fall back to embedded rules")

        XCTAssertNoThrow(try FileManager.default.removeItem(atPath: fileUrl.path))
    }

    func testSaveAndLoadToFromFile_expectsSameBehaviorAfterLoad() {
        let testDoneExpectation = XCTestExpectation()
        let thread = Thread {
            self.performSaveAndLoad()
            testDoneExpectation.fulfill()
        }
        thread.start()
        wait(for: [testDoneExpectation], timeout: 2.0)
    }

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    func testLoadFromNonExistentFile_expectsEmbedded() async {
        let nonExistentFilePath = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let list = await PublicSuffixList.list(from: .filePath(nonExistentFilePath),
                                               urlRequestHandler: { _, _ in
            XCTFail("No network query should be performed")
        })
        // Fallback to embedded rules → real TLDs work.
        let unrestricted: Bool = await list.isUnrestricted("yahoo.com")
        XCTAssertTrue(unrestricted)
    }

    func testLoadFromEmbedded_expectsEmbedded() {
        let testDoneExpectation = XCTestExpectation()
        Thread {
            let list = PublicSuffixList(source: .embedded)
            XCTAssertTrue(list.isUnrestricted("yahoo.com"))
            XCTAssertFalse(list.isUnrestricted("com"))
            testDoneExpectation.fulfill()
        }.start()
        wait(for: [testDoneExpectation], timeout: 2.0)
    }

    func testLoadDefault_expectsEmbedded() {
        let testDoneExpectation = XCTestExpectation()
        Thread {
            let list = PublicSuffixList()
            XCTAssertTrue(list.isUnrestricted("yahoo.com"))
            testDoneExpectation.fulfill()
        }.start()
        wait(for: [testDoneExpectation], timeout: 2.0)
    }

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    func testLoadFromEmbeddedAsync() async {
        let list = await PublicSuffixList.list(from: .embedded)
        let unrestricted: Bool = await list.isUnrestricted("yahoo.com")
        XCTAssertTrue(unrestricted)
    }

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    func testUpdate_querySuccess_expectsRulesUpdated() async {
        let onlineRegistryData: Data = """
        updated
        public.suffix.list
        """.data(using: .utf8)!
        let urlQueriedExpectation = XCTestExpectation(
            description: "When requesting an update from the online registry there should be a URLRequest dispatched"
        )
        let list = await PublicSuffixList.list(
            from: .rules([["hello", "world"]]),
            urlRequestHandler: { request, completion in
                urlQueriedExpectation.fulfill()
                DispatchQueue.global().async {
                    let success = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)
                    completion(onlineRegistryData, success, nil)
                }
            })
        let updateSucceeded: Bool = await list.updateUsingOnlineRegistry()
        await fulfillment(of: [urlQueriedExpectation], timeout: 2.0)
        XCTAssertTrue(updateSucceeded)
        // New rules in effect: 'updated' is a TLD, 'public.suffix.list' is a 3-label rule.
        let checkUpdatedBare: Bool = await list.isUnrestricted("updated")
        let checkUpdatedSite: Bool = await list.isUnrestricted("site.updated")
        let checkSuffixBare: Bool = await list.isUnrestricted("public.suffix.list")
        let checkSuffixSite: Bool = await list.isUnrestricted("site.public.suffix.list")
        let checkOldRule: Bool = await list.isUnrestricted("site.hello.world")
        XCTAssertFalse(checkUpdatedBare)
        XCTAssertTrue(checkUpdatedSite)
        XCTAssertFalse(checkSuffixBare)
        XCTAssertTrue(checkSuffixSite)
        // Old rules no longer apply.
        XCTAssertFalse(checkOldRule)
    }

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    func testLoadOnlineRegistry_querySuccess_expectsOnlineRules() async {
        let onlineRegistryData: Data = """
        loaded-from-web
        public.suffix.list
        """.data(using: .utf8)!
        let urlQueriedExpectation = XCTestExpectation(
            description: "When requesting an update from the online registry there should be a URLRequest dispatched"
        )
        let list = await PublicSuffixList.list(
            from: .onlineRegistry(nil),
            urlRequestHandler: { request, completion in
                urlQueriedExpectation.fulfill()
                DispatchQueue.global().async {
                    let success = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)
                    completion(onlineRegistryData, success, nil)
                }
            })
        await fulfillment(of: [urlQueriedExpectation], timeout: 2.0)
        let unrestrictedA: Bool = await list.isUnrestricted("site.loaded-from-web")
        let unrestrictedB: Bool = await list.isUnrestricted("loaded-from-web")
        let unrestrictedC: Bool = await list.isUnrestricted("site.public.suffix.list")
        let unrestrictedD: Bool = await list.isUnrestricted("yahoo.com")
        XCTAssertTrue(unrestrictedA)
        XCTAssertFalse(unrestrictedB)
        XCTAssertTrue(unrestrictedC)
        // yahoo.com should NOT resolve — we're using the stubbed online rules, not embedded.
        XCTAssertFalse(unrestrictedD)
    }

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    func testLoadOnlineRegistry_query500Failed_expectsEmbedded() async {
        let onlineRegistryData: Data = """
        loaded-from-web
        public.suffix.list
        """.data(using: .utf8)!
        let urlQueriedExpectation = XCTestExpectation(
            description: "When requesting an update from the online registry there should be a URLRequest dispatched"
        )
        let list = await PublicSuffixList.list(
            from: .onlineRegistry(nil),
            urlRequestHandler: { request, completion in
                urlQueriedExpectation.fulfill()
                DispatchQueue.global().async {
                    let failure = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "1.1", headerFields: nil)
                    completion(onlineRegistryData, failure, nil)
                }
            })
        await fulfillment(of: [urlQueriedExpectation], timeout: 2.0)
        // Fallback to embedded rules.
        let unrestricted: Bool = await list.isUnrestricted("yahoo.com")
        XCTAssertTrue(unrestricted)
    }

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    func testUpdate_query500Failed_expectsRulesUnchanged() async {
        let onlineRegistryData: Data = """
        should-not-be-processed
        public.suffix.list
        """.data(using: .utf8)!
        let urlQueriedExpectation = XCTestExpectation(
            description: "When requesting an update from the online registry there should be a URLRequest dispatched"
        )
        let list = await PublicSuffixList.list(
            from: .rules([["hello", "world"]]),
            urlRequestHandler: { request, completion in
                urlQueriedExpectation.fulfill()
                DispatchQueue.global().async {
                    let failure = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "1.1", headerFields: nil)
                    completion(onlineRegistryData, failure, nil)
                }
            })
        let updateSucceeded: Bool = await list.updateUsingOnlineRegistry()
        await fulfillment(of: [urlQueriedExpectation], timeout: 2.0)
        XCTAssertFalse(updateSucceeded)
        // Original rules still active.
        let goodHello: Bool = await list.isUnrestricted("site.hello.world")
        let badIgnored: Bool = await list.isUnrestricted("site.should-not-be-processed")
        XCTAssertTrue(goodHello)
        XCTAssertFalse(badIgnored)
    }
}
