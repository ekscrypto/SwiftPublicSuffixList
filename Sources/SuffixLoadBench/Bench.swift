import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct Sample {
    let label: String
    let nanos: [UInt64]
    let rssDeltaBytes: Int64
    let fileSizeBytes: Int
    let ruleCount: Int
    let labelCount: Int
}

enum BenchClock {
    static func now() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}

#if canImport(Darwin)
func currentResidentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return kerr == KERN_SUCCESS ? Int64(info.resident_size) : -1
}
#else
func currentResidentBytes() -> Int64 { -1 }
#endif

func stats(_ xs: [UInt64]) -> (min: UInt64, median: UInt64, p95: UInt64, max: UInt64, mean: Double) {
    precondition(!xs.isEmpty)
    let sorted = xs.sorted()
    let median = sorted[sorted.count / 2]
    let p95idx = max(0, Int(Double(sorted.count) * 0.95) - 1)
    let mean = Double(xs.reduce(0, +)) / Double(xs.count)
    return (sorted.first!, median, sorted[p95idx], sorted.last!, mean)
}

func formatMillis(_ ns: UInt64) -> String {
    String(format: "%8.2f", Double(ns) / 1_000_000.0)
}

func formatMillis(_ ns: Double) -> String {
    String(format: "%8.2f", ns / 1_000_000.0)
}

func formatBytes(_ n: Int) -> String {
    if n < 1024 { return "\(n) B" }
    let kb = Double(n) / 1024.0
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    return String(format: "%.2f MB", kb / 1024.0)
}

func runBench(label: String,
              iterations: Int,
              warmup: Int,
              fileSize: Int,
              measuredLoad: () -> (ruleCount: Int, labelCount: Int)) -> Sample {
    for _ in 0..<warmup {
        _ = measuredLoad()
    }
    let rssBefore = currentResidentBytes()
    var nanos: [UInt64] = []
    nanos.reserveCapacity(iterations)
    var ruleCount = 0
    var labelCount = 0
    for _ in 0..<iterations {
        let t0 = BenchClock.now()
        let r = measuredLoad()
        let t1 = BenchClock.now()
        nanos.append(t1 - t0)
        ruleCount = r.ruleCount
        labelCount = r.labelCount
    }
    let rssAfter = currentResidentBytes()
    let delta = (rssBefore >= 0 && rssAfter >= 0) ? (rssAfter - rssBefore) : -1
    return Sample(label: label,
                  nanos: nanos,
                  rssDeltaBytes: delta,
                  fileSizeBytes: fileSize,
                  ruleCount: ruleCount,
                  labelCount: labelCount)
}

func printTable(_ samples: [Sample], baselineLabel: String) {
    let header = [
        "strategy".padding(toLength: 28, withPad: " ", startingAt: 0),
        " size".padding(toLength: 10, withPad: " ", startingAt: 0),
        "  min ms".padding(toLength: 10, withPad: " ", startingAt: 0),
        " med ms".padding(toLength: 10, withPad: " ", startingAt: 0),
        " p95 ms".padding(toLength: 10, withPad: " ", startingAt: 0),
        " max ms".padding(toLength: 10, withPad: " ", startingAt: 0),
        " mean ms".padding(toLength: 10, withPad: " ", startingAt: 0),
        "  speedup".padding(toLength: 10, withPad: " ", startingAt: 0),
        "  rss Δ".padding(toLength: 12, withPad: " ", startingAt: 0)
    ].joined()
    print(header)
    print(String(repeating: "─", count: header.count))

    let baselineMean = samples.first { $0.label == baselineLabel }.map {
        Double($0.nanos.reduce(0, +)) / Double($0.nanos.count)
    } ?? 0

    for s in samples {
        let st = stats(s.nanos)
        let speedup = baselineMean > 0 ? baselineMean / st.mean : 1.0
        let rss = s.rssDeltaBytes >= 0 ? formatBytes(Int(s.rssDeltaBytes)) : "n/a"
        let row = [
            s.label.padding(toLength: 28, withPad: " ", startingAt: 0),
            formatBytes(s.fileSizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0),
            formatMillis(st.min).padding(toLength: 10, withPad: " ", startingAt: 0),
            formatMillis(st.median).padding(toLength: 10, withPad: " ", startingAt: 0),
            formatMillis(st.p95).padding(toLength: 10, withPad: " ", startingAt: 0),
            formatMillis(st.max).padding(toLength: 10, withPad: " ", startingAt: 0),
            formatMillis(st.mean).padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%8.2fx", speedup).padding(toLength: 10, withPad: " ", startingAt: 0),
            rss.padding(toLength: 12, withPad: " ", startingAt: 0)
        ].joined()
        print(row)
    }
    print("")
    if let first = samples.first {
        print("rules: \(first.ruleCount)  labels: \(first.labelCount)  iterations: \(first.nanos.count)")
    }
}
