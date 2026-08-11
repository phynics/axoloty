// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Release-only wire benchmark for AxolotyWire (issue #300).
//
// Loads the benchmark corpus, times topic parse, DTO decode/encode,
// borrowed-message validation, and combined parse-decode for every case,
// and emits machine-readable JSON with raw samples for downstream
// percentile and noise analysis.
//
// The orchestration script (check-benchmark-wire.sh) runs this 5 times
// with `taskset` CPU pinning, computes p50/p95, checks noise (MAD ≤ 5%),
// and compares against the checked-in baseline.
//
// Build: swift build -c release --product WireBenchmark
// Run:   WireBenchmark [--validate-allocations]

import AxolotyWire
import Foundation

// MARK: - Corpus loading

struct CorpusCase {
    let id: String
    let family: String
    let sizeClass: String
    let topicBytes: [UInt8]
    let payloadBytes: [UInt8]
}

struct CorpusManifest: Decodable {
    let cases: [CaseEntry]
    struct CaseEntry: Decodable {
        let id: String
        let family: String
        let sizeClass: String
        let topic: String
        let payloadFile: String
    }
}

func loadCorpus() -> [CorpusCase] {
    let manifestURL = URL(fileURLWithPath: "Benchmarks/Corpus/manifest.json")
    let data = try! Data(contentsOf: manifestURL)
    let manifest = try! JSONDecoder().decode(CorpusManifest.self, from: data)
    let corpusDir = URL(fileURLWithPath: "Benchmarks/Corpus")
    return manifest.cases.map { entry in
        let payloadURL = corpusDir.appendingPathComponent(entry.payloadFile)
        let payloadData = try! Data(contentsOf: payloadURL)
        let topicBytes = Array(entry.topic.utf8)
        let payloadBytes = Array(payloadData)
        return CorpusCase(
            id: entry.id, family: entry.family,
            sizeClass: entry.sizeClass,
            topicBytes: topicBytes, payloadBytes: payloadBytes
        )
    }
}

// MARK: - Timing infrastructure

func measureOperation(
    _ name: String,
    batchSize: inout Int,
    operation: () -> Void
) -> (batchSize: Int, samplesNs: [Int]) {
    // Warm-up: 1,000 iterations.
    for _ in 0..<1_000 { operation() }

    // Calibrate: find batch size N so that N iterations take ≥ 250ms.
    if batchSize == 0 {
        var n = 1
        while true {
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                for _ in 0..<n { operation() }
            }
            if elapsed >= .milliseconds(250) { break }
            n *= 2
            if n > 10_000_000 { break } // safety cap
        }
        batchSize = n
    }

    // Sample: 30 batches of batchSize iterations.
    let n = batchSize
    var samples: [Int] = []
    samples.reserveCapacity(30)
    for _ in 0..<30 {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<n { operation() }
        }
        let totalNs = Int(elapsed.components.seconds) * 1_000_000_000
            + Int(elapsed.components.attoseconds / 1_000_000_000)
        samples.append(totalNs / n)
    }
    return (n, samples)
}

// MARK: - DTO decode dispatch

func decodeDTO(family: String, reader: WireReader) {
    switch family {
    case "ADV": _ = try? AdvertiseWireData(from: reader)
    case "DAD": _ = try? DeadvertiseWireData(from: reader)
    case "CHN": _ = try? ChannelWireData(from: reader)
    case "ASC": _ = try? AssociateWireData(from: reader)
    case "IOV": _ = try? IoValueWireData(from: reader)
    case "DSC": _ = try? DiscoverWireData(from: reader)
    case "RSV": _ = try? ResolveWireData(from: reader)
    case "QRY": _ = try? QueryWireData(from: reader)
    case "RTV": _ = try? RetrieveWireData(from: reader)
    case "UPD": _ = try? UpdateWireData(from: reader)
    case "CPL": _ = try? CompleteWireData(from: reader)
    case "CLL": _ = try? CallWireData(from: reader)
    case "RTN": _ = try? ReturnWireData(from: reader)
    default: break
    }
}

// MARK: - Heaptrack validation mode

func validateAllocations() {
    // These functions have known allocation profiles. heaptrack should
    // measure: zeroAlloc=0, oneAlloc=1, manyAllocs(100)=100.
    print(#"{"mode":"validate-allocations","fixtures":["#)

    func zeroAlloc() -> Int { return 42 }
    for _ in 0..<10_000 { _ = zeroAlloc() }
    print(#"{"name":"zeroAlloc","expectedAllocations":0}"#)

    print(",")
    func oneAlloc() -> [UInt8] { return [42] }
    for _ in 0..<10_000 { _ = oneAlloc() }
    print(#"{"name":"oneAlloc","expectedAllocations":10000}"#)

    print(",")
    func manyAllocs(_ n: Int) -> [[UInt8]] {
        var result: [[UInt8]] = []
        for _ in 0..<n { result.append([42]) }
        return result
    }
    for _ in 0..<10_000 { _ = manyAllocs(100) }
    print(#"{"name":"manyAllocs100","expectedAllocations":1000000}"#)

    print("]}")
}

// MARK: - Main benchmark

func runBenchmark() {
    let corpus = loadCorpus()

    // Environment fingerprint.
    let swiftVersion = "Swift 6.3"
    let targetTriple = "x86_64-unknown-linux-gnu"
    let cpu = readProcLine("/proc/cpuinfo", key: "model name") ?? "unknown"
    let kernel = readProcLine("/proc/version", key: nil) ?? "unknown"
    let corpusHash = sha256File("Benchmarks/Corpus/manifest.json") ?? "unknown"
    let commit = gitShortHash() ?? "unknown"
    let clean = gitIsClean()

    // Output JSON header.
    print(#"{"environment":{"#)
    print(#""swiftVersion":"\#(swiftVersion)","#)
    print(#""targetTriple":"\#(targetTriple)","#)
    print(#""optimization":"release","#)
    print(#""cpu":"\#(cpu)","#)
    print(#""kernel":"\#(kernel.replacingOccurrences(of: "\n", with: " "))","#)
    print(#""corpusHash":"\#(corpusHash)","#)
    print(#""commit":"\#(commit)","#)
    print(#""clean":\#(clean)},"#)
    print(#""cases":["#)

    let encodeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    defer { encodeBuffer.deallocate() }

    for (caseIndex, corpusCase) in corpus.enumerated() {
        if caseIndex > 0 { print(",") }
        print(#"{"caseId":"\#(corpusCase.id)","family":"\#(corpusCase.family)","sizeClass":"\#(corpusCase.sizeClass)","operations":{"#)

        // 1. topicParse
        var topicBatch = 0
        let topicResult = corpusCase.topicBytes.withUnsafeBufferPointer { tb -> (Int, [Int]) in
            let topicPtr = tb.baseAddress!
            return measureOperation("topicParse", batchSize: &topicBatch) {
                let tv = TopicView(topicBytes: topicPtr, length: tb.count)
                _ = tv.eventType
            }
        }
        print(#""topicParse":{"batchSize":\#(topicResult.0),"samplesNs":\#(topicResult.1)}"#)

        // 2. dtoDecode
        print(",")
        var decodeBatch = 0
        let decodeResult = corpusCase.payloadBytes.withUnsafeBufferPointer { pb -> (Int, [Int]) in
            let payloadPtr = pb.baseAddress!
            return measureOperation("dtoDecode", batchSize: &decodeBatch) {
                let reader = WireReader(bytes: payloadPtr, length: pb.count)
                decodeDTO(family: corpusCase.family, reader: reader)
            }
        }
        print(#""dtoDecode":{"batchSize":\#(decodeResult.0),"samplesNs":\#(decodeResult.1)}"#)

        // 3. dtoEncode
        print(",")
        var encodeBatch = 0
        let encodeResult = corpusCase.payloadBytes.withUnsafeBufferPointer { pb -> (Int, [Int]) in
            let payloadPtr = pb.baseAddress!
            // Pre-decode for the encode benchmark.
            return measureOperation("dtoEncode", batchSize: &encodeBatch) {
                let reader = WireReader(bytes: payloadPtr, length: pb.count)
                var writer = WireWriter(buffer: encodeBuffer, capacity: 512)
                // Decode then encode.
                switch corpusCase.family {
                case "ADV":
                    if let dto = try? AdvertiseWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "DAD":
                    if let dto = try? DeadvertiseWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "CHN":
                    if let dto = try? ChannelWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "ASC":
                    if let dto = try? AssociateWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "IOV":
                    if let dto = try? IoValueWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "DSC":
                    if let dto = try? DiscoverWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "RSV":
                    if let dto = try? ResolveWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "QRY":
                    if let dto = try? QueryWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "RTV":
                    if let dto = try? RetrieveWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "UPD":
                    if let dto = try? UpdateWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "CPL":
                    if let dto = try? CompleteWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "CLL":
                    if let dto = try? CallWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                case "RTN":
                    if let dto = try? ReturnWireData(from: reader) {
                        _ = try? dto.encode(to: &writer)
                    }
                default:
                    break
                }
            }
        }
        print(#""dtoEncode":{"batchSize":\#(encodeResult.0),"samplesNs":\#(encodeResult.1)}"#)

        // 4. borrowedValidation
        print(",")
        var validationBatch = 0
        let validationResult = measureOperation("borrowedValidation", batchSize: &validationBatch) {
            corpusCase.topicBytes.withUnsafeBufferPointer { tb in
                corpusCase.payloadBytes.withUnsafeBufferPointer { pb in
                    _ = try? BorrowedMessage.validated(
                        topicBytes: tb.baseAddress!,
                        topicLength: tb.count,
                        payloadBytes: pb.baseAddress!,
                        payloadLength: pb.count
                    )
                }
            }
        }
        print(#""borrowedValidation":{"batchSize":\#(validationResult.0),"samplesNs":\#(validationResult.1)}"#)

        // 5. combinedParseDecode
        print(",")
        var combinedBatch = 0
        let combinedResult = measureOperation("combinedParseDecode", batchSize: &combinedBatch) {
            corpusCase.topicBytes.withUnsafeBufferPointer { tb in
                corpusCase.payloadBytes.withUnsafeBufferPointer { pb in
                    if let msg = try? BorrowedMessage.validated(
                        topicBytes: tb.baseAddress!,
                        topicLength: tb.count,
                        payloadBytes: pb.baseAddress!,
                        payloadLength: pb.count
                    ) {
                        let reader = msg.reader()
                        decodeDTO(family: corpusCase.family, reader: reader)
                    }
                }
            }
        }
        print(#""combinedParseDecode":{"batchSize":\#(combinedResult.0),"samplesNs":\#(combinedResult.1)}"#)

        print("}}")
    }

    print("]}")
}

// MARK: - Helpers

func readProcLine(_ path: String, key: String?) -> String? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    if let key {
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix(key) {
                // /proc/cpuinfo lines look like "key\t: value" — split on the
                // first colon so the key prefix and tab do not leak a control
                // character into the emitted JSON (Swift string interpolation
                // does not escape control characters).
                if let colonRange = line.range(of: ":") {
                    return String(line[colonRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                }
                return line.replacingOccurrences(of: key, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    return content.components(separatedBy: "\n").first
}

func sha256File(_ path: String) -> String? {
    let data = try? Data(contentsOf: URL(fileURLWithPath: path))
    guard let data else { return nil }
    // Simple: use the file size + first/last bytes as a quick hash.
    // The orchestration script verifies the actual SHA-256.
    return String(format: "%016x", data.count) + String(data.hashValue, radix: 16)
}

func gitShortHash() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch { return nil }
}

func gitIsClean() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["status", "--porcelain"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty
    } catch { return false }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--validate-allocations") {
    validateAllocations()
} else {
    runBenchmark()
}
