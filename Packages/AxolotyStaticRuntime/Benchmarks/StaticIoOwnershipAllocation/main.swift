// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

nonisolated(unsafe) private var observed: UInt32 = 0

private struct ProbeByte: BinaryIoValue {
    let value: UInt8

    init(ioBytes: borrowing ByteSlice) throws(IoValueError) {
        guard ioBytes.length == 1, let value = ioBytes.byte(at: 0) else {
            throw .invalidValue
        }
        self.value = value
    }

    borrowing func encodeIoBytes(into output: inout IoByteOutput) throws(IoValueError) {
        var byte = value
        var failure: IoValueError?
        withUnsafeBytes(of: &byte) { buffer in
            do throws(IoValueError) {
                try output.write(ByteSlice(
                    bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    length: buffer.count
                ))
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }
}

@StaticIoActor(ProbeByte.self)
private enum ProbeActor {
    static func receive(
        context: UInt32,
        value: borrowing ProbeByte,
        delivery: borrowing IoDeliveryContext
    ) {
        observed &+= context &+ UInt32(value.value) &+ delivery.associationGeneration
    }
}

@inline(never)
private func dispatchHandler(
    payload: borrowing ByteSlice,
    iterations: Int
) {
    let entry = ProbeActor.staticIoHandlerEntry
    for _ in 0..<iterations {
        entry.invoke(
            context: 3,
            payload: payload,
            representation: .binary,
            sourceID: .zero,
            actorID: .zero,
            receivedAtMS: 5,
            associationGeneration: 7,
            routeKind: .coaty
        )
    }
}

@inline(never)
private func copyAndVisit(
    action: borrowing BorrowedProtocolAction,
    iterations: Int
) {
    for _ in 0..<iterations {
        var sink = InlineOwnedProtocolActionSink<1, 512>()
        guard sink.preflight(actionCount: 1), sink.append(action) else {
            fatalError("protocol-valid owning sink operation was rejected")
        }
        guard sink.visit(at: 0, { borrowed in
            if case .publish(let publication) = borrowed {
                observed &+= UInt32(publication.payload.length)
            }
        }) else {
            fatalError("accepted owning sink action was not visitable")
        }
    }
}

private let arguments = CommandLine.arguments.dropFirst()
private let operation = arguments.first ?? "handler"
private let iterations = Int(arguments.dropFirst().first ?? "50000") ?? 50000
private let payload = [UInt8(0x2A)]

payload.withUnsafeBufferPointer { payloadBuffer in
    let payloadSlice = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
    switch operation {
    case "handler":
        dispatchHandler(payload: payloadSlice, iterations: 1_000)
        dispatchHandler(payload: payloadSlice, iterations: max(1, iterations))
    case "sink":
        let publication = BorrowedProtocolPublication(
            routingKey: try! ProtocolRoutingKey(capability: .advertise, sourceID: .zero),
            target: .profile(eventTypeFilter: nil, filterKind: .direct),
            payload: payloadSlice
        )
        let action = BorrowedProtocolAction.publish(publication)
        copyAndVisit(action: action, iterations: 1_000)
        copyAndVisit(action: action, iterations: max(1, iterations))
    default:
        fatalError("expected allocation operation 'handler' or 'sink'")
    }
}

if observed == UInt32.max { print(observed) }
