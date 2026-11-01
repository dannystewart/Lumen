import Foundation
@testable import Lumen
import Testing

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

// MARK: - CommandCancellationTests

@Suite("Command cancellation")
struct CommandCancellationTests {
    @Test
    func `cancellation preceding the run request prevents launch`() async throws {
        let registry = ExecutionRegistry()
        let id = UUID()
        _ = await registry.cancel(id)
        let control = try await registry.begin(id)
        var launched = false
        let processID = try control.launch {
            launched = true
            return 12345
        }
        // HTTP run/cancel requests travel independently. Registration must not replace an earlier
        // cancellation tombstone with fresh, runnable state when the run arrives second.
        #expect(processID == nil)
        #expect(!launched)
    }

    @Test
    func `interruption reaches the child before termination is acknowledged`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("ready")
        let acknowledgement = directory.appendingPathComponent("interrupted")
        let readiness = try FIFOReadiness(url: fifo)
        defer { readiness.cancel() }
        let control = ExecutionControl()
        defer { control.cancel() }

        func quote(_ text: String) -> String { "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'" }
        let handler = "printf interrupted > \(quote(acknowledgement.path)); exit 0"
        let child = "trap \(quote(handler)) INT TERM; printf ready > \(quote(fifo.path)); sleep 30 & wait"
        let operation = Task {
            do {
                let response = try await runCancellableCommand(
                    command: "/bin/sh -c \(quote(child)) & wait",
                    workingDirectory: nil,
                    environment: nil,
                    timeout: 10,
                    maxOutputBytes: 1000,
                    control: control,
                )
                readiness.fail()
                return response
            } catch {
                readiness.fail()
                throw error
            }
        }
        // The FIFO is an explicit child-ready handshake. sleep is the interrupted workload, not
        // synchronization. Signalling only the shell (a tempting Process.terminate replacement)
        // cannot produce the child's acknowledgement and must not count as completed cancellation.
        try await readiness.wait()
        control.cancel()
        let response = try await operation.value
        #expect(response.cancelled)
        #expect(try String(contentsOf: acknowledgement, encoding: .utf8) == "interrupted")
    }
}

// MARK: - FIFOReadiness

/// Finishes on child readiness or early command exit; a spawn failure must not strand a FIFO read.
private final class FIFOReadiness: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private let source: DispatchSourceRead

    init(url: URL) throws {
        guard mkfifo(url.path, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let descriptor = open(url.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        self.source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        self.source.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 32)
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { self?.finish(.success(())) }
        }
        self.source.setCancelHandler { _ = close(descriptor) }
        self.source.resume()
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = self.lock.withLock {
                if self.result == nil { self.continuation = continuation }
                return self.result
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func fail() { self.finish(.failure(CancellationError())) }
    func cancel() { self.source.cancel() }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = self.lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Void, Error>? }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
        self.source.cancel()
    }
}
