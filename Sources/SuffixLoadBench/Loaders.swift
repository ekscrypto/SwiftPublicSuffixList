import Foundation

enum Loaders {

    static func loadJSON(path: String) -> [[String]] {
        let url = URL(fileURLWithPath: path)
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode([[String]].self, from: data)
    }

    static func loadBinaryPlist(path: String) -> [[String]] {
        let url = URL(fileURLWithPath: path)
        let data = try! Data(contentsOf: url)
        let any = try! PropertyListSerialization.propertyList(from: data, format: nil)
        return any as! [[String]]
    }

    /// Custom binary (length-prefixed).
    static func loadSimpleBinary(path: String) -> [[String]] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { rawBuf -> [[String]] in
            let base = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var p = base
            let end = base.advanced(by: rawBuf.count)

            let ruleCount = readU32LE(&p)
            var rules: [[String]] = []
            rules.reserveCapacity(Int(ruleCount))
            for _ in 0..<ruleCount {
                precondition(p < end)
                let labelCount = Int(p.pointee); p = p.advanced(by: 1)
                var rule: [String] = []
                rule.reserveCapacity(labelCount)
                for _ in 0..<labelCount {
                    let len = Int(p.pointee); p = p.advanced(by: 1)
                    let s = String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)
                    p = p.advanced(by: len)
                    rule.append(s)
                }
                rules.append(rule)
            }
            return rules
        }
    }

    /// Deduplicated binary — unique label table + u16 indices.
    static func loadDedupBinary(path: String) -> [[String]] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { rawBuf -> [[String]] in
            let base = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var p = base

            let labelCount = Int(readU32LE(&p))
            var labels: [String] = []
            labels.reserveCapacity(labelCount)
            for _ in 0..<labelCount {
                let len = Int(p.pointee); p = p.advanced(by: 1)
                let s = String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)
                p = p.advanced(by: len)
                labels.append(s)
            }

            let ruleCount = Int(readU32LE(&p))
            var rules: [[String]] = []
            rules.reserveCapacity(ruleCount)
            for _ in 0..<ruleCount {
                let n = Int(p.pointee); p = p.advanced(by: 1)
                var rule: [String] = []
                rule.reserveCapacity(n)
                for _ in 0..<n {
                    let idx = Int(readU16LE(&p))
                    rule.append(labels[idx])
                }
                rules.append(rule)
            }
            return rules
        }
    }

    /// Plain text — one rule per line, labels joined by '.'.
    static func loadText(path: String) -> [[String]] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        var rules: [[String]] = []
        rules.reserveCapacity(10_500)
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" }).forEach { line in
            let parts = line.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." })
            var rule: [String] = []
            rule.reserveCapacity(parts.count)
            for p in parts {
                rule.append(String(p))
            }
            rules.append(rule)
        }
        return rules
    }

    /// Text parser operating on raw UTF-8 bytes, skipping Swift's Substring machinery.
    static func loadTextFast(path: String) -> [[String]] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { rawBuf -> [[String]] in
            let base = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let count = rawBuf.count
            var rules: [[String]] = []
            rules.reserveCapacity(10_500)
            var rule: [String] = []
            var labelStart = 0
            var i = 0
            while i < count {
                let b = base[i]
                if b == 0x2E { // '.'
                    rule.append(String(decoding: UnsafeBufferPointer(start: base + labelStart, count: i - labelStart), as: UTF8.self))
                    labelStart = i + 1
                } else if b == 0x0A { // '\n'
                    rule.append(String(decoding: UnsafeBufferPointer(start: base + labelStart, count: i - labelStart), as: UTF8.self))
                    rules.append(rule)
                    rule = []
                    labelStart = i + 1
                }
                i += 1
            }
            if labelStart < count {
                rule.append(String(decoding: UnsafeBufferPointer(start: base + labelStart, count: count - labelStart), as: UTF8.self))
                rules.append(rule)
            }
            return rules
        }
    }

    /// Parse the compile-time-embedded StaticString using the same tight
    /// UTF-8 walker used for the file-based text loader. No I/O, no Data
    /// allocation, no JSON tokenizer — just pointer iteration over a
    /// read-only segment of the binary.
    static func loadSwiftLiteral() -> [[String]] {
        let raw = GeneratedRules.raw
        let base = raw.utf8Start
        let count = raw.utf8CodeUnitCount
        var rules: [[String]] = []
        rules.reserveCapacity(10_500)
        var rule: [String] = []
        var labelStart = 0
        var i = 0
        while i < count {
            let b = base[i]
            if b == 0x2E {
                rule.append(String(decoding: UnsafeBufferPointer(start: base + labelStart, count: i - labelStart), as: UTF8.self))
                labelStart = i + 1
            } else if b == 0x0A {
                rule.append(String(decoding: UnsafeBufferPointer(start: base + labelStart, count: i - labelStart), as: UTF8.self))
                rules.append(rule)
                rule = []
                labelStart = i + 1
            }
            i += 1
        }
        if labelStart < count {
            rule.append(String(decoding: UnsafeBufferPointer(start: base + labelStart, count: count - labelStart), as: UTF8.self))
            rules.append(rule)
        }
        return rules
    }

    @inline(__always)
    private static func readU32LE(_ p: inout UnsafePointer<UInt8>) -> UInt32 {
        let v = UInt32(p[0]) | (UInt32(p[1]) << 8) | (UInt32(p[2]) << 16) | (UInt32(p[3]) << 24)
        p = p.advanced(by: 4)
        return v
    }

    @inline(__always)
    private static func readU16LE(_ p: inout UnsafePointer<UInt8>) -> UInt16 {
        let v = UInt16(p[0]) | (UInt16(p[1]) << 8)
        p = p.advanced(by: 2)
        return v
    }
}
