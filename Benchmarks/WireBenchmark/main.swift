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
import AxolotyProtocol
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

struct LoadedCorpus {
    let cases: [CorpusCase]
    let fingerprint: String
}

enum BenchmarkFailure: Error, CustomStringConvertible {
    case operation(caseID: String, name: String, reason: String)

    var description: String {
        switch self {
        case let .operation(caseID, name, reason):
            return "wire benchmark failed: case '\(caseID)', operation '\(name)': \(reason)"
        }
    }
}

func loadCorpus(from corpusDirectory: URL = URL(fileURLWithPath: "Benchmarks/Corpus")) -> LoadedCorpus {
    let manifestURL = corpusDirectory.appendingPathComponent("manifest.json")
    let manifestData = try! Data(contentsOf: manifestURL)
    let manifest = try! JSONDecoder().decode(CorpusManifest.self, from: manifestData)
    var payloadDataInManifestOrder: [Data] = []
    let cases = manifest.cases.map { entry in
        let payloadURL = corpusDirectory.appendingPathComponent(entry.payloadFile)
        let payloadData = try! Data(contentsOf: payloadURL)
        payloadDataInManifestOrder.append(payloadData)
        let topicBytes = Array(entry.topic.utf8)
        let payloadBytes = Array(payloadData)
        return CorpusCase(
            id: entry.id, family: entry.family,
            sizeClass: entry.sizeClass,
            topicBytes: topicBytes, payloadBytes: payloadBytes
        )
    }
    return LoadedCorpus(
        cases: cases,
        fingerprint: corpusFingerprint(
            manifest: manifestData,
            payloads: payloadDataInManifestOrder
        )
    )
}

// MARK: - Timing infrastructure

func measureOperation(
    caseID: String,
    _ name: String,
    batchSize: inout Int,
    operation: () throws -> Void
) throws -> (batchSize: Int, samplesNs: [Int]) {
    do {
        // Warm-up: 1,000 iterations.
        for _ in 0..<1_000 { try operation() }

        // Calibrate: find batch size N so that N iterations take ≥ 250ms.
        if batchSize == 0 {
            var n = 1
            while true {
                let clock = ContinuousClock()
                let elapsed = try clock.measure {
                    for _ in 0..<n { try operation() }
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
            let elapsed = try clock.measure {
                for _ in 0..<n { try operation() }
            }
            let totalNs = Int(elapsed.components.seconds) * 1_000_000_000
                + Int(elapsed.components.attoseconds / 1_000_000_000)
            samples.append(totalNs / n)
        }
        return (n, samples)
    } catch let failure as BenchmarkFailure {
        throw failure
    } catch {
        throw BenchmarkFailure.operation(
            caseID: caseID,
            name: name,
            reason: String(describing: error)
        )
    }
}

// MARK: - DTO decode dispatch

enum BenchmarkDTO {
    case advertise(AdvertiseWireData)
    case deadvertise(DeadvertiseWireData)
    case channel(ChannelWireData)
    case associate(AssociateWireData)
    case ioValue(IoValueWireData)
    case discover(DiscoverWireData)
    case resolve(ResolveWireData)
    case query(QueryWireData)
    case retrieve(RetrieveWireData)
    case update(UpdateWireData)
    case complete(CompleteWireData)
    case call(CallWireData)
    case returnEvent(ReturnWireData)

    func encode(to writer: inout WireWriter) throws {
        switch self {
        case .advertise(let value): try value.encode(to: &writer)
        case .deadvertise(let value): try value.encode(to: &writer)
        case .channel(let value): try value.encode(to: &writer)
        case .associate(let value): try value.encode(to: &writer)
        case .ioValue(let value): try value.encode(to: &writer)
        case .discover(let value): try value.encode(to: &writer)
        case .resolve(let value): try value.encode(to: &writer)
        case .query(let value): try value.encode(to: &writer)
        case .retrieve(let value): try value.encode(to: &writer)
        case .update(let value): try value.encode(to: &writer)
        case .complete(let value): try value.encode(to: &writer)
        case .call(let value): try value.encode(to: &writer)
        case .returnEvent(let value): try value.encode(to: &writer)
        }
    }
}

func decodeDTO(
    caseID: String,
    family: String,
    reader: WireReader,
    operationName: String
) throws -> BenchmarkDTO {
    switch family {
    case "ADV": return .advertise(try AdvertiseWireData(from: reader))
    case "DAD": return .deadvertise(try DeadvertiseWireData(from: reader))
    case "CHN": return .channel(try ChannelWireData(from: reader))
    case "ASC": return .associate(try AssociateWireData(from: reader))
    case "IOV": return .ioValue(try IoValueWireData(from: reader))
    case "DSC": return .discover(try DiscoverWireData(from: reader))
    case "RSV": return .resolve(try ResolveWireData(from: reader))
    case "QRY": return .query(try QueryWireData(from: reader))
    case "RTV": return .retrieve(try RetrieveWireData(from: reader))
    case "UPD": return .update(try UpdateWireData(from: reader))
    case "CPL": return .complete(try CompleteWireData(from: reader))
    case "CLL": return .call(try CallWireData(from: reader))
    case "RTN": return .returnEvent(try ReturnWireData(from: reader))
    default:
        throw BenchmarkFailure.operation(
            caseID: caseID,
            name: operationName,
            reason: "unsupported family '\(family)'"
        )
    }
}

// MARK: - Heaptrack validation mode

func validateAllocations() {
    // These functions have known allocation profiles. heaptrack should
    // measure: zeroAlloc=0, oneAlloc=1, manyAllocs(100)=100. The trailing
    // `wireDecodeRoute` fixture exercises the real borrowed decode + static
    // routing hot path; on Swift 6.3 host builds its reader workspace is
    // stack-resident and must allocate nothing, so expected is 0.
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

    print(",")
    // The wire decode + static route steady state. The reader/decoder must not
    // allocate String/Array or a JSON value tree per iteration, and the reader
    // workspace is a constant-size inline/temporary buffer (stack-resident on
    // Swift 6.3 host builds). This fixture asserts per-iteration behavior; a
    // small constant number of one-time setup allocations is expected and is
    // not measured as a per-message cost.
    let payload = "{\"ioSourceId\":\"33333333-3333-4333-8333-333333333333\",\"ioActorId\":\"33333333-3333-4333-8333-333333333333\",\"isExternalRoute\":true}"
    let topic = "coaty/3/ns/ASC:filter/source-id"
    let payloadBytes = Array(payload.utf8)
    let topicBytes = Array(topic.utf8)
    var sink = 0
    payloadBytes.withUnsafeBufferPointer { pb in
        topicBytes.withUnsafeBufferPointer { tb in
            var processor = ProtocolProcessor<16>()
            for _ in 0..<1_000 {
                let message = BorrowedMessage(
                    topicBytes: tb.baseAddress!, topicLength: tb.count,
                    payloadBytes: pb.baseAddress!, payloadLength: pb.count
                )
                if (try? AssociateWireData(from: message.reader())) != nil { sink += 1 }
                var actionSink = InlineProtocolActionSink<1>()
                if let frame = try? BorrowedProtocolFrame(topic: message.topic, payload: message.payload) {
                    _ = processor.processInbound(.profile(frame), nowMS: 1, sink: &actionSink)
                }
            }
        }
    }
    // Support the sink to keep the loop live.
    if sink < 0 { print(sink) }
    print(#"{"name":"wireDecodeRoute","expectedAllocations":0}"#)

    print("]}")
}

// MARK: - Main benchmark

func corpusDirectory() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIRE_BENCHMARK_CORPUS_DIR"] ?? "Benchmarks/Corpus")
}

func runBenchmark() throws {
    let loadedCorpus = loadCorpus(from: corpusDirectory())
    let corpus = loadedCorpus.cases

    // Environment fingerprint.
    let swiftVersion = "Swift 6.3"
    let targetTriple = "x86_64-unknown-linux-gnu"
    let cpu = readProcLine("/proc/cpuinfo", key: "model name") ?? "unknown"
    let kernel = readProcLine("/proc/version", key: nil) ?? "unknown"
    let corpusHash = loadedCorpus.fingerprint
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
        let topicResult = try corpusCase.topicBytes.withUnsafeBufferPointer { tb -> (Int, [Int]) in
            let topicPtr = tb.baseAddress!
            return try measureOperation(caseID: corpusCase.id, "topicParse", batchSize: &topicBatch) {
                let tv = TopicView(topicBytes: topicPtr, length: tb.count)
                guard tv.eventType != nil else {
                    throw BenchmarkFailure.operation(
                        caseID: corpusCase.id,
                        name: "topicParse",
                        reason: "topic has no recognized event type"
                    )
                }
            }
        }
        print(#""topicParse":{"batchSize":\#(topicResult.0),"samplesNs":\#(topicResult.1)}"#)

        // 2. dtoDecode
        print(",")
        var decodeBatch = 0
        let decodeResult = try corpusCase.payloadBytes.withUnsafeBufferPointer { pb -> (Int, [Int]) in
            let payloadPtr = pb.baseAddress!
            return try measureOperation(caseID: corpusCase.id, "dtoDecode", batchSize: &decodeBatch) {
                let reader = WireReader(bytes: payloadPtr, length: pb.count)
                _ = try decodeDTO(
                    caseID: corpusCase.id,
                    family: corpusCase.family,
                    reader: reader,
                    operationName: "dtoDecode"
                )
            }
        }
        print(#""dtoDecode":{"batchSize":\#(decodeResult.0),"samplesNs":\#(decodeResult.1)}"#)

        // 3. dtoEncode
        print(",")
        var encodeBatch = 0
        let encodeResult = try corpusCase.payloadBytes.withUnsafeBufferPointer { pb -> (Int, [Int]) in
            let payloadPtr = pb.baseAddress!
            let dto: BenchmarkDTO
            do {
                let reader = WireReader(bytes: payloadPtr, length: pb.count)
                dto = try decodeDTO(
                    caseID: corpusCase.id,
                    family: corpusCase.family,
                    reader: reader,
                    operationName: "dtoEncode"
                )
            } catch let failure as BenchmarkFailure {
                throw failure
            } catch {
                throw BenchmarkFailure.operation(
                    caseID: corpusCase.id,
                    name: "dtoEncode",
                    reason: String(describing: error)
                )
            }

            return try measureOperation(caseID: corpusCase.id, "dtoEncode", batchSize: &encodeBatch) {
                var writer = WireWriter(buffer: encodeBuffer, capacity: 512)
                try dto.encode(to: &writer)
            }
        }
        print(#""dtoEncode":{"batchSize":\#(encodeResult.0),"samplesNs":\#(encodeResult.1)}"#)

        // 4. borrowedValidation
        print(",")
        var validationBatch = 0
        let validationResult = try measureOperation(caseID: corpusCase.id, "borrowedValidation", batchSize: &validationBatch) {
            try corpusCase.topicBytes.withUnsafeBufferPointer { tb in
                try corpusCase.payloadBytes.withUnsafeBufferPointer { pb in
                    _ = try BorrowedMessage.validated(
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
        let combinedResult = try measureOperation(caseID: corpusCase.id, "combinedParseDecode", batchSize: &combinedBatch) {
            try corpusCase.topicBytes.withUnsafeBufferPointer { tb in
                try corpusCase.payloadBytes.withUnsafeBufferPointer { pb in
                    let msg = try BorrowedMessage.validated(
                        topicBytes: tb.baseAddress!,
                        topicLength: tb.count,
                        payloadBytes: pb.baseAddress!,
                        payloadLength: pb.count
                    )
                    let reader = msg.reader()
                    _ = try decodeDTO(
                        caseID: corpusCase.id,
                        family: corpusCase.family,
                        reader: reader,
                        operationName: "combinedParseDecode"
                    )
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

func corpusFingerprint(manifest: Data, payloads: [Data]) -> String {
    var hasher = SHA256()
    hasher.updateFramed(manifest)
    for payload in payloads {
        hasher.updateFramed(payload)
    }
    return hasher.hexDigest
}

private struct SHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var messageLength = UInt64(0)

    mutating func updateFramed(_ data: Data) {
        var length = UInt64(data.count)
        var lengthBytes = [UInt8](repeating: 0, count: 8)
        for index in 0..<8 {
            lengthBytes[7 - index] = UInt8(truncatingIfNeeded: length)
            length >>= 8
        }
        update(lengthBytes)
        update(data)
    }

    var hexDigest: String {
        var copy = self
        let digest = copy.finalize()
        let hex = Array("0123456789abcdef".utf8)
        return digest.reduce(into: "") { result, byte in
            result.append(Character(UnicodeScalar(hex[Int(byte >> 4)])))
            result.append(Character(UnicodeScalar(hex[Int(byte & 0x0f)])))
        }
    }

    private mutating func update(_ data: Data) {
        update(Array(data))
    }

    private mutating func update(_ bytes: [UInt8]) {
        messageLength &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        processAvailableBlocks()
    }

    private mutating func processAvailableBlocks() {
        while buffer.count >= 64 {
            process(Array(buffer.prefix(64)))
            buffer.removeFirst(64)
        }
    }

    private mutating func process(_ block: [UInt8]) {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let offset = index * 4
            words[index] = UInt32(block[offset]) << 24
                | UInt32(block[offset + 1]) << 16
                | UInt32(block[offset + 2]) << 8
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let first = rotateRight(words[index - 15], by: 7)
                ^ rotateRight(words[index - 15], by: 18)
                ^ (words[index - 15] >> 3)
            let second = rotateRight(words[index - 2], by: 17)
                ^ rotateRight(words[index - 2], by: 19)
                ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ first &+ words[index - 7] &+ second
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for index in 0..<64 {
            let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sum1 &+ choose &+ Self.roundConstants[index] &+ words[index]
            let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sum0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private mutating func finalize() -> [UInt8] {
        let bitLength = messageLength &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for index in stride(from: 7, through: 0, by: -1) {
            buffer.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(index * 8)))
        }
        processAvailableBlocks()

        var result: [UInt8] = []
        result.reserveCapacity(32)
        for value in state {
            result.append(UInt8(truncatingIfNeeded: value >> 24))
            result.append(UInt8(truncatingIfNeeded: value >> 16))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
            result.append(UInt8(truncatingIfNeeded: value))
        }
        return result
    }

    private func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
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

if CommandLine.arguments.contains("--corpus-fingerprint") {
    print(loadCorpus(from: corpusDirectory()).fingerprint)
} else if CommandLine.arguments.contains("--validate-allocations") {
    validateAllocations()
} else {
    do {
        try runBenchmark()
    } catch {
        let message = "\(error)\n"
        if let data = message.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        exit(1)
    }
}
