// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Captures bytes written to the process's standard error descriptor while an
/// operation runs, so tests can assert that an absorbed (best-effort) failure
/// actually logged a diagnosable line rather than being silently dropped.
///
/// `LogManager`'s handler writes every level to stderr (see
/// `AxolotyLogHandler`), so a failure-path test can drive a forced
/// publication/construction failure and assert the wrapped error chain text
/// made it to the log stream. The default `LogManager` level is `.error`, so
/// the captured line is emitted for error-level absorbed failures without any
/// handler reconfiguration.
enum StandardErrorCapture {
    private static let lock = NSLock()

    /// Runs `operation` with stderr redirected to a pipe, returning the
    /// operation's result together with everything written to stderr.
    ///
    /// The operation is non-throwing (the API under test in all callers is
    /// best-effort and returns `Void`), so capture setup/teardown may throw
    /// but the wrapped operation cannot.
    static func capture<Result>(
        _ operation: () -> Result
    ) throws -> CapturedStandardError<Result> {
        lock.lock()
        defer { lock.unlock() }

        let capture = try DescriptorCapture()
        defer { capture.restore() }

        try capture.redirect()
        let result = operation()
        return CapturedStandardError(result: result, output: try capture.finish())
    }
}

/// The result of a ``StandardErrorCapture``: the operation's return value plus
/// the captured stderr text.
struct CapturedStandardError<Result> {
    let result: Result
    let output: String
}

private final class DescriptorCapture {
    private var savedDescriptor: Int32?
    private var readDescriptor: Int32?
    private var writeDescriptor: Int32?
    private var stderrIsRedirected = false

    /// Creates a capture ready to redirect stderr.
    init() throws {
        let savedDescriptor = dup(STDERR_FILENO)
        guard savedDescriptor >= 0 else {
            throw CaptureError.unableToDuplicateStderr
        }

        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeDescriptors) == 0 else {
            close(savedDescriptor)
            throw CaptureError.unableToCreatePipe
        }

        self.savedDescriptor = savedDescriptor
        readDescriptor = pipeDescriptors[0]
        writeDescriptor = pipeDescriptors[1]
    }

    func redirect() throws {
        guard let writeDescriptor,
              dup2(writeDescriptor, STDERR_FILENO) >= 0 else {
            throw CaptureError.unableToRedirectStderr
        }
        stderrIsRedirected = true
    }

    func finish() throws -> String {
        fflush(nil)
        guard let savedDescriptor,
              dup2(savedDescriptor, STDERR_FILENO) >= 0 else {
            throw CaptureError.unableToRestoreStderr
        }
        stderrIsRedirected = false
        closeSavedDescriptor()
        closeWriteDescriptor()

        guard let readDescriptor else {
            throw CaptureError.unableToReadCapturedStderr
        }

        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(readDescriptor, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(Int(count)))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                closeReadDescriptor()
                throw CaptureError.unableToReadCapturedStderr
            }
        }
        closeReadDescriptor()
        return String(decoding: bytes, as: UTF8.self)
    }

    func restore() {
        fflush(nil)
        if stderrIsRedirected, let savedDescriptor {
            _ = dup2(savedDescriptor, STDERR_FILENO)
            stderrIsRedirected = false
        }
        closeSavedDescriptor()
        closeReadDescriptor()
        closeWriteDescriptor()
    }

    private func closeSavedDescriptor() {
        guard let savedDescriptor else { return }
        close(savedDescriptor)
        self.savedDescriptor = nil
    }

    private func closeReadDescriptor() {
        guard let readDescriptor else { return }
        close(readDescriptor)
        self.readDescriptor = nil
    }

    private func closeWriteDescriptor() {
        guard let writeDescriptor else { return }
        close(writeDescriptor)
        self.writeDescriptor = nil
    }

    deinit {
        restore()
    }
}

private enum CaptureError: Error {
    case unableToDuplicateStderr
    case unableToCreatePipe
    case unableToRedirectStderr
    case unableToRestoreStderr
    case unableToReadCapturedStderr
}