import Foundation
import SwiftPublicSuffixList

enum Mode: String {
    case generate
    case bench
}

let args = CommandLine.arguments
guard args.count >= 2, let mode = Mode(rawValue: args[1]) else {
    print("Usage: SuffixLoadBench generate | bench [initIterations] [matchIterations] [warmup]")
    exit(1)
}

switch mode {
case .generate:
    try runGenerate()
case .bench:
    let initIters = (args.count >= 3 ? Int(args[2]) : nil) ?? 50
    let matchIters = (args.count >= 4 ? Int(args[3]) : nil) ?? 20
    let warmup = (args.count >= 5 ? Int(args[4]) : nil) ?? 3
    try runBench(initIterations: initIters, matchIterations: matchIters, warmup: warmup)
}

func runGenerate() throws {
    print("Reading source rules from \(Generators.resolveSourceRegistryJsonPath())")
    let rules = try Generators.loadSourceRules()
    print("rules: \(rules.count)  labels: \(rules.reduce(0) { $0 + $1.count })")
    print("output dir: \(Generators.outputDir())")
    print("  json       → \(try Generators.writeJSONCopy(rules))")
    print("  plist bin  → \(try Generators.writeBinaryPlist(rules))")
    print("  bin        → \(try Generators.writeSimpleBinary(rules))")
    print("  dedup bin  → \(try Generators.writeDedupBinary(rules))")
    print("  text       → \(try Generators.writeText(rules))")
    print("  swift      → \(try Generators.writeSwiftLiteral(rules))")
    print("  trie       → \(try Generators.writeTrie(rules))")
    print("")
    print("Rebuild before running `bench` so GeneratedRules.swift picks up changes:")
    print("  swift build -c release && swift run -c release SuffixLoadBench bench")
}

enum MatcherState {
    case rules([[String]])
    case trie(TrieMatcher)

    func isUnrestricted(_ candidate: String) -> Bool {
        switch self {
        case .rules(let r): return PublicSuffixList.isUnrestricted(candidate, rules: r)
        case .trie(let t): return t.isUnrestricted(candidate)
        }
    }
}

struct Strategy {
    let label: String
    let filePath: String?
    let load: () -> MatcherState
}

func runBench(initIterations: Int, matchIterations: Int, warmup: Int) throws {
    let dir = Generators.outputDir()
    let triePath = dir + "/registry.trie"
    let strategies: [Strategy] = [
        Strategy(label: "1. JSON (baseline)",
                 filePath: dir + "/registry.json",
                 load: { .rules(Loaders.loadJSON(path: dir + "/registry.json")) }),
        Strategy(label: "2. Binary plist",
                 filePath: dir + "/registry.plist",
                 load: { .rules(Loaders.loadBinaryPlist(path: dir + "/registry.plist")) }),
        Strategy(label: "3. Custom binary",
                 filePath: dir + "/registry.bin",
                 load: { .rules(Loaders.loadSimpleBinary(path: dir + "/registry.bin")) }),
        Strategy(label: "4. Custom binary + dedup",
                 filePath: dir + "/registry-dedup.bin",
                 load: { .rules(Loaders.loadDedupBinary(path: dir + "/registry-dedup.bin")) }),
        Strategy(label: "5. Plain text (Substring)",
                 filePath: dir + "/registry.txt",
                 load: { .rules(Loaders.loadText(path: dir + "/registry.txt")) }),
        Strategy(label: "5b. Plain text (raw UTF8)",
                 filePath: dir + "/registry.txt",
                 load: { .rules(Loaders.loadTextFast(path: dir + "/registry.txt")) }),
        Strategy(label: "6. Swift StaticString",
                 filePath: nil,
                 load: { .rules(Loaders.loadSwiftLiteral()) }),
        Strategy(label: "7. Memory-mapped trie",
                 filePath: triePath,
                 load: {
                     let data = try! Data(contentsOf: URL(fileURLWithPath: triePath),
                                          options: [.mappedIfSafe])
                     return .trie(TrieMatcher(data: data))
                 })
    ]

    let candidates = BenchCorpus.candidates

    // Correctness: every strategy must agree with the JSON baseline on isUnrestricted
    // for every candidate.
    print("== correctness ==")
    let baselineState = strategies[0].load()
    let baselineResults = candidates.map { baselineState.isUnrestricted($0) }
    var anyFail = false
    for s in strategies {
        let state = s.load()
        var mismatches: [(String, Bool, Bool)] = []
        for (i, c) in candidates.enumerated() {
            let got = state.isUnrestricted(c)
            if got != baselineResults[i] {
                mismatches.append((c, baselineResults[i], got))
            }
        }
        let status = mismatches.isEmpty ? "OK  " : "FAIL"
        print("  \(status) \(s.label)  candidates=\(candidates.count)  mismatches=\(mismatches.count)")
        if !mismatches.isEmpty {
            anyFail = true
            for m in mismatches.prefix(5) {
                print("      \(m.0)  expected=\(m.1) got=\(m.2)")
            }
        }
    }
    if anyFail {
        print("")
        print("Correctness mismatches present — still running timing for visibility.")
    }
    print("")

    // Init-phase benchmark.
    print("== init phase (from on-disk asset to ready-to-match) ==")
    var initSamples: [Sample] = []
    for s in strategies {
        let fileSize: Int = {
            guard let p = s.filePath else { return 0 }
            let attr = try? FileManager.default.attributesOfItem(atPath: p)
            return (attr?[.size] as? Int) ?? 0
        }()
        let sample = runBench(label: s.label,
                              iterations: initIterations,
                              warmup: warmup,
                              fileSize: fileSize) {
            let st = s.load()
            switch st {
            case .rules(let r): return (r.count, r.reduce(0) { $0 + $1.count })
            case .trie: return (0, 0)
            }
        }
        initSamples.append(sample)
    }
    printTable(initSamples, baselineLabel: "1. JSON (baseline)")

    // Match-phase benchmark: initialize once, then time one full pass over the
    // corpus. Report per-match amortized time.
    print("")
    print("== match phase (per-candidate amortized; \(candidates.count) candidates × \(matchIterations) passes) ==")
    var matchSamples: [Sample] = []
    for s in strategies {
        let state = s.load()
        for _ in 0..<warmup {
            for c in candidates { _ = state.isUnrestricted(c) }
        }
        var passTimes: [UInt64] = []
        passTimes.reserveCapacity(matchIterations)
        for _ in 0..<matchIterations {
            let t0 = BenchClock.now()
            for c in candidates {
                _ = state.isUnrestricted(c)
            }
            let t1 = BenchClock.now()
            passTimes.append((t1 - t0) / UInt64(candidates.count))
        }
        matchSamples.append(Sample(label: s.label,
                                   nanos: passTimes,
                                   rssDeltaBytes: -1,
                                   fileSizeBytes: 0,
                                   ruleCount: 0,
                                   labelCount: 0))
    }
    printMatchTable(matchSamples, baselineLabel: "1. JSON (baseline)")
}

func printMatchTable(_ samples: [Sample], baselineLabel: String) {
    let header = [
        "strategy".padding(toLength: 28, withPad: " ", startingAt: 0),
        "  min µs".padding(toLength: 10, withPad: " ", startingAt: 0),
        " med µs".padding(toLength: 10, withPad: " ", startingAt: 0),
        " p95 µs".padding(toLength: 10, withPad: " ", startingAt: 0),
        " max µs".padding(toLength: 10, withPad: " ", startingAt: 0),
        " mean µs".padding(toLength: 10, withPad: " ", startingAt: 0),
        "  speedup".padding(toLength: 10, withPad: " ", startingAt: 0)
    ].joined()
    print(header)
    print(String(repeating: "─", count: header.count))

    let baselineMean = samples.first { $0.label == baselineLabel }.map {
        Double($0.nanos.reduce(0, +)) / Double($0.nanos.count)
    } ?? 0

    for s in samples {
        let st = stats(s.nanos)
        let speedup = baselineMean > 0 ? baselineMean / st.mean : 1.0
        let row = [
            s.label.padding(toLength: 28, withPad: " ", startingAt: 0),
            String(format: "%8.2f", Double(st.min) / 1000.0).padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%8.2f", Double(st.median) / 1000.0).padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%8.2f", Double(st.p95) / 1000.0).padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%8.2f", Double(st.max) / 1000.0).padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%8.2f", st.mean / 1000.0).padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%8.2fx", speedup).padding(toLength: 10, withPad: " ", startingAt: 0)
        ].joined()
        print(row)
    }
}
