// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";

const [manifestPath, outputPath] = process.argv.slice(2);
if (!manifestPath || !outputPath) {
  throw new Error("usage: generate-embedded-corpus.mjs MANIFEST OUTPUT");
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const corpusDirectory = path.dirname(manifestPath);
const dtoByFamily = {
  ADV: "AdvertiseWireData", ASC: "AssociateWireData", CHN: "ChannelWireData",
  CLL: "CallWireData", CPL: "CompleteWireData", DAD: "DeadvertiseWireData",
  DSC: "DiscoverWireData", IOV: "IoValueWireData", QRY: "QueryWireData",
  RSV: "ResolveWireData", RTN: "ReturnWireData", RTV: "RetrieveWireData",
  UPD: "UpdateWireData",
};
const eventByFamily = {
  ADV: "advertise", ASC: "associate", CHN: "channel", CLL: "call",
  CPL: "complete", DAD: "deadvertise", DSC: "discover", IOV: "ioValue",
  QRY: "query", RSV: "resolve", RTN: "returnEvent", RTV: "retrieve",
  UPD: "update",
};

function swiftLiteral(value) {
  let result = '"';
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (character === '"') result += '\\"';
    else if (character === "\\") result += "\\\\";
    else if (character === "\n") result += "\\n";
    else if (character === "\r") result += "\\r";
    else if (character === "\t") result += "\\t";
    else if (codePoint < 0x20 || codePoint > 0x7e) result += `\\u{${codePoint.toString(16)}}`;
    else result += character;
  }
  return `${result}"`;
}

const corpusConstants = manifest.cases.map((corpusCase, index) => {
  const payload = fs.readFileSync(path.join(corpusDirectory, corpusCase.payloadFile), "utf8");
  return `private let corpusTopic${index}: StaticString = ${swiftLiteral(corpusCase.topic)}
private let corpusPayload${index}: StaticString = ${swiftLiteral(payload)}`;
}).join("\n");

const invocations = manifest.cases.map((corpusCase, index) => {
  const dto = dtoByFamily[corpusCase.family];
  const event = eventByFamily[corpusCase.family];
  if (!dto || !event) throw new Error(`unsupported corpus family: ${corpusCase.family}`);
  return `    runCorpusCase(
        topicParseId: ${swiftLiteral(`corpus:${corpusCase.id}:topicParse`)},
        decodeId: ${swiftLiteral(`corpus:${corpusCase.id}:dtoDecode`)},
        encodeId: ${swiftLiteral(`corpus:${corpusCase.id}:dtoEncode`)},
        combinedId: ${swiftLiteral(`corpus:${corpusCase.id}:combined`)},
        borrowedId: ${swiftLiteral(`corpus:${corpusCase.id}:borrowed`)},
        topicBuildId: ${swiftLiteral(`corpus:${corpusCase.id}:topicBuild`)},
        topic: corpusTopic${index},
        payload: corpusPayload${index}, eventType: .${event}, dto: ${dto}.self,
        record: record
    )`;
}).join("\n");

const topicBenchmarkStatements = manifest.cases.map((corpusCase, index) =>
  `    if TopicView(topicBytes: corpusTopic${index}.utf8Start, length: corpusTopic${index}.utf8CodeUnitCount).eventType == .${eventByFamily[corpusCase.family]} { result &+= 1 }`,
).join("\n");
const decodeBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if (try? ${dtoByFamily[corpusCase.family]}(from: corpusReader(corpusPayload${index}))) != nil { result &+= 1 }`;
}).join("\n");
const encodeBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if let decoded = try? ${dtoByFamily[corpusCase.family]}(from: corpusReader(corpusPayload${index})) {
        withCorpusEncodeBuffer { output in
            var writer = WireWriter(buffer: output.baseAddress!, capacity: output.count)
            if (try? decoded.encode(to: &writer)) != nil { result &+= 1 }
        }
    }`;
}).join("\n");
const combinedBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if TopicView(topicBytes: corpusTopic${index}.utf8Start, length: corpusTopic${index}.utf8CodeUnitCount).eventType == .${eventByFamily[corpusCase.family]} && (try? ${dtoByFamily[corpusCase.family]}(from: corpusReader(corpusPayload${index}))) != nil { result &+= 1 }`;
}).join("\n");
const borrowedBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if (try? BorrowedMessage.validated(topicBytes: corpusTopic${index}.utf8Start, topicLength: corpusTopic${index}.utf8CodeUnitCount, payloadBytes: corpusPayload${index}.utf8Start, payloadLength: corpusPayload${index}.utf8CodeUnitCount)) != nil { result &+= 1 }`;
}).join("\n");

const source = `// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
// Generated from Benchmarks/Corpus/manifest.json. Do not edit.

import AxolotyWire

${corpusConstants}

struct EmbeddedBenchmarkMetrics {
    let topicParseP50ns: UInt32
    let topicParseP95ns: UInt32
    let dtoDecodeP50ns: UInt32
    let dtoDecodeP95ns: UInt32
    let dtoEncodeP50ns: UInt32
    let dtoEncodeP95ns: UInt32
    let combinedP50ns: UInt32
    let combinedP95ns: UInt32
    let borrowedP50ns: UInt32
    let borrowedP95ns: UInt32
}

private var embeddedBenchmarkSink: UInt32 = 0
private var embeddedCorpusParserWorkspace = EmbeddedWireParserWorkspace()
private var embeddedCorpusEncodeBuffer = InlineArray<2_048, UInt8>(repeating: 0)

@inline(__always)
private func corpusReader(_ payload: StaticString) -> WireReader {
    WireReader(
        bytes: payload.utf8Start,
        length: payload.utf8CodeUnitCount,
        workspace: &embeddedCorpusParserWorkspace
    )
}

@inline(__always)
private func withCorpusEncodeBuffer<R>(
    _ body: (UnsafeMutableBufferPointer<UInt8>) -> R
) -> R {
    withUnsafeMutableBytes(of: &embeddedCorpusEncodeBuffer) { raw in
        body(UnsafeMutableBufferPointer(
            start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
            count: raw.count
        ))
    }
}

@inline(never)
private func topicBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${topicBenchmarkStatements}
    return result
}

@inline(never)
private func decodeBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${decodeBenchmarkStatements}
    return result
}

@inline(never)
private func encodeBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${encodeBenchmarkStatements}
    return result
}

@inline(never)
private func combinedBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${combinedBenchmarkStatements}
    return result
}

@inline(never)
private func borrowedBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${borrowedBenchmarkStatements}
    return result
}

private func measureCorpusPass(_ pass: () -> UInt32) -> (UInt32, UInt32) {
    for warmupIndex in 0..<1000 {
        embeddedBenchmarkSink &+= pass()
        if warmupIndex & 15 == 15 { vTaskDelay(1) }
    }
    var batch = 1
    while true {
        let start = esp_timer_get_time()
        for _ in 0..<batch { embeddedBenchmarkSink &+= pass() }
        if esp_timer_get_time() - start >= 250_000 { break }
        vTaskDelay(1)
        batch &*= 2
    }
    return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 30) { samples in
        for sampleIndex in 0..<30 {
            vTaskDelay(1)
            let overheadStart = esp_timer_get_time()
            for _ in 0..<batch { embeddedBenchmarkSink &+= 1 }
            let overhead = esp_timer_get_time() - overheadStart
            let start = esp_timer_get_time()
            for _ in 0..<batch { embeddedBenchmarkSink &+= pass() }
            let elapsed = esp_timer_get_time() - start
            let netMicroseconds = elapsed > overhead ? elapsed - overhead : 0
            samples[sampleIndex] = UInt32((netMicroseconds * 1000) / Int64(batch * 39))
        }
        for index in 1..<30 {
            let value = samples[index]
            var insertion = index
            while insertion > 0 && samples[insertion - 1] > value {
                samples[insertion] = samples[insertion - 1]
                insertion -= 1
            }
            samples[insertion] = value
        }
        return (samples[14], samples[28])
    }
}

func benchmarkGeneratedCorpus() -> EmbeddedBenchmarkMetrics {
    let topic = measureCorpusPass(topicBenchmarkPass)
    let decode = measureCorpusPass(decodeBenchmarkPass)
    let encode = measureCorpusPass(encodeBenchmarkPass)
    let combined = measureCorpusPass(combinedBenchmarkPass)
    let borrowed = measureCorpusPass(borrowedBenchmarkPass)
    return EmbeddedBenchmarkMetrics(
        topicParseP50ns: topic.0, topicParseP95ns: topic.1,
        dtoDecodeP50ns: decode.0, dtoDecodeP95ns: decode.1,
        dtoEncodeP50ns: encode.0, dtoEncodeP95ns: encode.1,
        combinedP50ns: combined.0, combinedP95ns: combined.1,
        borrowedP50ns: borrowed.0, borrowedP95ns: borrowed.1
    )
}

@inline(__always)
private func corpusBytesEqual(_ slice: ByteSlice, _ expected: StaticString) -> Bool {
    guard slice.length == expected.utf8CodeUnitCount else { return false }
    for index in 0..<slice.length where slice.byte(at: index) != expected.utf8Start[index] {
        return false
    }
    return true
}

private func runCorpusCase<T: WireDecodable & WireEncodable>(
    topicParseId: StaticString,
    decodeId: StaticString,
    encodeId: StaticString,
    combinedId: StaticString,
    borrowedId: StaticString,
    topicBuildId: StaticString,
    topic: StaticString,
    payload: StaticString,
    eventType: WireEventType,
    dto: T.Type,
    record: (StaticString, Bool) -> Void
) {
    let topicView = TopicView(topicBytes: topic.utf8Start, length: topic.utf8CodeUnitCount)
    record(topicParseId, topicView.eventType == eventType)

    let reader = corpusReader(payload)
    guard let decoded = try? T(from: reader) else {
        record(decodeId, false); record(encodeId, false); record(combinedId, false)
        record(borrowedId, false); record(topicBuildId, false)
        return
    }
    record(decodeId, true)

    withCorpusEncodeBuffer { output in
        var writer = WireWriter(buffer: output.baseAddress!, capacity: output.count)
        record(encodeId, (try? decoded.encode(to: &writer)) != nil && writer.position <= 2_048)
    }

    let combined = topicView.eventType == eventType && (try? T(from: reader)) != nil
    record(combinedId, combined)

    let borrowed = try? BorrowedMessage.validated(
        topicBytes: topic.utf8Start, topicLength: topic.utf8CodeUnitCount,
        payloadBytes: payload.utf8Start, payloadLength: payload.utf8CodeUnitCount
    )
    record(
        borrowedId,
        borrowed?.eventType == eventType &&
            borrowed?.reader(workspace: &embeddedCorpusParserWorkspace).length == payload.utf8CodeUnitCount
    )

    var built = false
    if let source = topicView.sourceIdLevel.flatMap(UUID16.init(parsing:)),
       let parsedType = topicView.eventType {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { output in
            var builder = TopicBuilder(buffer: output.baseAddress!, capacity: output.count)
            var valid = (try? builder.writePrefix()) != nil
            if valid { valid = (try? builder.writeNamespace("bench")) != nil }
            if valid { valid = (try? builder.writeEventType(parsedType, filter: topicView.eventTypeFilter)) != nil }
            if valid { valid = (try? builder.writeSourceId(source)) != nil }
            if valid, let correlation = topicView.correlationIdLevel.flatMap(UUID16.init(parsing:)) {
                valid = (try? builder.writeCorrelationId(correlation)) != nil
            }
            built = valid && corpusBytesEqual(builder.build(), topic)
        }
    }
    record(topicBuildId, built)
}

func runGeneratedCorpus(_ record: (StaticString, Bool) -> Void) {
${invocations}
}
`;

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, source);
