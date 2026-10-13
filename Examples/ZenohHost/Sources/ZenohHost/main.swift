// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyZenoh
import Foundation

// `axoloty/1` carries CBOR on the wire. The example's `send` mode accepts a
// JSON Channel envelope and encodes it with `JSONToCBOR` before publishing, so
// the example stays readable while the wire uses the sealed profile.

@main
struct ZenohHost {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("ZenohHost failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3 else {
            print("Usage: ZenohHost <listen|send> <endpoint> <channel> [payload]")
            exit(EXIT_FAILURE)
        }

        let mode = arguments[0]
        let endpoint = arguments[1]
        let channel = arguments[2]
        let configuration = try ZenohBindingConfiguration(connectEndpoint: endpoint)
        let binding = ZenohBinding(configuration: configuration)
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "zenoh-example")
        let events = try builder.events(
            matching: .channel(identifier: channel),
            buffering: .fail(capacity: 4)
        )
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: binding)
        try await runtime.start()

        switch mode {
        case "listen":
            await listen(runtime: runtime, events: events, channel: channel)
        case "send":
            guard arguments.count == 4 else {
                await runtime.stop()
                print("Usage: ZenohHost send <endpoint> <channel> <payload>")
                exit(EXIT_FAILURE)
            }
            await send(runtime: runtime, channel: channel, payload: arguments[3])
        default:
            await runtime.stop()
            print("Mode must be listen or send")
            exit(EXIT_FAILURE)
        }

        await runtime.stop()
    }

    private static func listen(
        runtime: AxolotyRuntime,
        events: RuntimeEventStream,
        channel: String
    ) async {
        print("LISTENING channel=\(channel)")
        var iterator = events.makeAsyncIterator()
        if let event = await iterator.next() {
            // `axoloty/1` payloads are CBOR, so print the encoded bytes. An
            // application decodes them with the schema it expects.
            let hex = event.value.map { String(format: "%02x", $0) }.joined()
            print("RECEIVED channel=\(channel) bytes=\(event.value.count) hex=\(hex)")
        }
    }

    private static func send(
        runtime: AxolotyRuntime,
        channel: String,
        payload: String
    ) async {
        guard let bytes = JSONToCBOR.encode(payload) else {
            await runtime.stop()
            FileHandle.standardError.write(Data("Payload must be a complete JSON value\n".utf8))
            exit(EXIT_FAILURE)
        }
        let initialPublications = await runtime.diagnosticsSnapshot().publishedFrames
        let receipt = await runtime.publish(.channel(identifier: channel, payload: bytes))
        guard receipt == .accepted else {
            await runtime.stop()
            FileHandle.standardError.write(Data("Channel operation was rejected: \(receipt)\n".utf8))
            exit(EXIT_FAILURE)
        }
        for _ in 0..<100 {
            if await runtime.diagnosticsSnapshot().publishedFrames > initialPublications {
                print("PUBLISHED channel=\(channel) bytes=\(bytes.count)")
                try? await Task.sleep(for: .milliseconds(250))
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await runtime.stop()
        FileHandle.standardError.write(Data("Channel publication did not reach the Zenoh transport\n".utf8))
        exit(EXIT_FAILURE)
    }
}
