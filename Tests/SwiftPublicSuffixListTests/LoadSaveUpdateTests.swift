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
    
    override class func setUp() {
        _ = PublicSuffixRulesRegistry.rules
    }
    
    override func setUp() {
        continueAfterFailure = false
    }
    
    func testLoadCustomRules() {
        let customRules1: [[String]] = [["hello","world"]]
        let firstList = PublicSuffixList(source: .rules(customRules1))

        let customRules2: [[String]] = [["other","rules"]]
        let secondList = PublicSuffixList(source: .rules(customRules2))

        XCTAssertEqual(firstList.rules, customRules1)
        XCTAssertEqual(secondList.rules, customRules2)
        XCTAssertNotEqual(customRules1, customRules2)
    }
    
    func performSaveAndLoad() {
        let customRules: [[String]] = [["hello","world"]]
        let listToSave = PublicSuffixList(source: .rules(customRules))
        let fileUrl = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertNoThrow(try listToSave.export(to: fileUrl.path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileUrl.path))
        
        let reloadedList = PublicSuffixList(source: .filePath(fileUrl.path))
        XCTAssertEqual(reloadedList.rules, customRules)
        
        XCTAssertNoThrow(try FileManager.default.removeItem(atPath: fileUrl.path))
    }
    
    func testSaveAndLoadToFromFile_expectsSameListAfterLoad() {
        let testDoneExpectation = XCTestExpectation()
        let thread = Thread {
            self.performSaveAndLoad()
            testDoneExpectation.fulfill()
        }
        thread.start()
        wait(for: [testDoneExpectation], timeout: 2.0)
    }
    
    func testLoadFromEmbedded_expectsEmbedded() {
        let testDoneExpectation = XCTestExpectation()
        Thread {
            let list = PublicSuffixList(source: .embedded)
            XCTAssertEqual(list.rules, PublicSuffixRulesRegistry.rules)
            testDoneExpectation.fulfill()
        }.start()
        wait(for: [testDoneExpectation], timeout: 2.0)
    }
    
    func testLoadDefault_expectsEmbedded() {
        let testDoneExpectation = XCTestExpectation()
        Thread {
            let list = PublicSuffixList()
            XCTAssertEqual(list.rules, PublicSuffixRulesRegistry.rules)
            testDoneExpectation.fulfill()
        }.start()
        wait(for: [testDoneExpectation], timeout: 2.0)
    }
    
    func testLoadFromEmbeddedAsync() async {
        let list = await PublicSuffixList.list(from: .embedded)
        XCTAssertEqual(list.rules, PublicSuffixRulesRegistry.rules)
    }
    
    func testUpdate_querySuccess_expectsRulesUpdated() async {
        let onlineRegistryData: Data = """
        updated
        public.suffix.list
        """.data(using: .utf8)!
        let urlQueriedExpectation = XCTestExpectation(description: "When requesting an update from the online registry there should be a URLRequest dispatched")
        let list = await PublicSuffixList.list(from: .rules([["hello","world"]]), urlRequestHandler: { request, completion in
            urlQueriedExpectation.fulfill()
            DispatchQueue.global().async {
                let successHttpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)
                completion(onlineRegistryData, successHttpResponse, nil)
            }
        })
        let updateSucceeded: Bool = await list.updateUsingOnlineRegistry()
        wait(for: [urlQueriedExpectation], timeout: 2.0)
        XCTAssertTrue(updateSucceeded)
        XCTAssertEqual(list.rules, [["updated"],["public","suffix","list"]])
    }
}
