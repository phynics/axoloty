#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-no-escaping-borrows.sh"
scanner="$root/Tests/Support/lib/detect-escaping-borrow.pl"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repository"
mkdir -p "$fixture/Source/Runtime" "$fixture/Tests/Support/checks" "$fixture/Tests/Support/lib"
cp "$checker" "$fixture/Tests/Support/checks/check-no-escaping-borrows.sh"
cp "$scanner" "$fixture/Tests/Support/lib/detect-escaping-borrow.pl"

# A clean fixture (no escaping borrow) must pass.
cat > "$fixture/Source/Runtime/Clean.swift" <<'EOF'
struct Clean {
    private func eventType(_ topic: String) -> WireEventType? {
        let bytes = Array(topic.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count).eventType
        }
    }

    func nested(_ operation: [UInt8]) -> Int {
        return operation.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            let payload = ByteSlice(bytes: base, length: buffer.count)
            do {
                if true {
                    return 1
                }
            } catch {
                return -1
            }
            return payload.length
        }
    }
}
EOF

if ! (cd "$fixture" && "$fixture/Tests/Support/checks/check-no-escaping-borrows.sh") >/dev/null; then
    echo "error: checker rejected a clean fixture with no escaping borrows" >&2
    exit 1
fi

# The exact historical shape (6172052: TopicLayoutConformanceTests.view(_:)
# returning a TopicView built inside withUnsafeBufferPointer) must fail.
cat > "$fixture/Source/Runtime/Bad.swift" <<'EOF'
struct Bad {
    private func view(_ topic: String) -> TopicView {
        let bytes = Array(topic.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }
    }
}
EOF

if (cd "$fixture" && "$fixture/Tests/Support/checks/check-no-escaping-borrows.sh") >/dev/null 2>&1; then
    echo "error: checker accepted the known escaping-TopicView shape (6172052)" >&2
    exit 1
fi

if ! (cd "$fixture" && "$fixture/Tests/Support/checks/check-no-escaping-borrows.sh") 2>&1 \
    | grep -q 'Bad.swift:4'; then
    echo "error: checker did not report the escaping construction at its actual line" >&2
    exit 1
fi

# Remove the bad fixture; a free-function `withUnsafeBytes(of:)` spelling of
# the same shape must also fail.
rm "$fixture/Source/Runtime/Bad.swift"
cat > "$fixture/Source/Runtime/BadFreeFunction.swift" <<'EOF'
struct BadFreeFunction {
    private func slice(_ raw: UInt64) -> ByteSlice {
        var storage = raw
        return withUnsafeBytes(of: &storage) { buffer in
            ByteSlice(bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), length: 8)
        }
    }
}
EOF

if (cd "$fixture" && "$fixture/Tests/Support/checks/check-no-escaping-borrows.sh") >/dev/null 2>&1; then
    echo "error: checker accepted the free-function withUnsafeBytes(of:) escaping shape" >&2
    exit 1
fi
rm "$fixture/Source/Runtime/BadFreeFunction.swift"

# A file under an excluded static-replay path must not be scanned, even
# when it contains the exact bad shape.
mkdir -p "$fixture/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime"
cat > "$fixture/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime/Excluded.swift" <<'EOF'
struct Excluded {
    private func view(_ topic: String) -> TopicView {
        let bytes = Array(topic.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }
    }
}
EOF

if ! (cd "$fixture" && "$fixture/Tests/Support/checks/check-no-escaping-borrows.sh") >/dev/null; then
    echo "error: checker scanned an excluded static-replay path" >&2
    exit 1
fi
rm -rf "$fixture/Packages/AxolotyStaticRuntime"

echo "escaping-borrow checker self-test passed"
