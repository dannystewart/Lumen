import Foundation
import Vapor

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

// MARK: - ExecError

enum ExecError: Error {
    case timeout(Double)
}

// MARK: AbortError

extension ExecError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .timeout: .requestTimeout
        }
    }

    var reason: String {
        switch self {
        case let .timeout(seconds):
            "Command timed out after \(Int(seconds))s"
        }
    }
}

// MARK: - ExecController

struct ExecController: RouteCollection {
    /// Server-enforced maximum timeout in seconds. No command can run longer than this.
    static let maxTimeout: Double = 600

    /// Default timeout when the client doesn't specify one.
    static let defaultTimeout: Double = 120

    /// Maximum output size per stream (stdout/stderr) in bytes. Prevents memory exhaustion from
    /// commands that produce unbounded output.
    static let maxOutputBytes = 1_000_000 // 1 MB

    /// Environment variables that cannot be overridden by the client. These control process loading
    /// behavior and could be used for privilege escalation.
    static let blockedEnvironmentKeys: Set<String> = [
        "PATH",
        "HOME",
        "USER",
        "SHELL",
        "LOGNAME",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "LUMEN_API_KEY",
    ]

    /// Privilege escalation commands blocked by default. Set LUMEN_ALLOW_SUDO=true in the
    /// environment to permit them.
    static let escalationCommands: [String] = ["sudo", "su", "pkexec", "doas", "runuser"]

    /// Returns true if the command contains a privilege escalation call.
    static func containsPrivilegeEscalation(_ command: String) -> Bool {
        self.escalationCommands.contains { cmd in
            command.range(of: "\\b\(NSRegularExpression.escapedPattern(for: cmd))\\b", options: .regularExpression) != nil
        }
    }

    func boot(routes: RoutesBuilder) throws {
        routes.post("exec", use: self.execute)
    }

    @Sendable
    func execute(req: Request) async throws -> ExecResponse {
        let body = try req.content.decode(ExecRequest.self)
        req.logger.info("exec: \(body.command)")

        if Environment.get("LUMEN_ALLOW_SUDO") != "true", Self.containsPrivilegeEscalation(body.command) {
            throw Abort(.forbidden, reason: "Privilege escalation commands (sudo, su, etc.) are blocked. Set LUMEN_ALLOW_SUDO=true to permit.")
        }

        let effectiveTimeout = max(1, min(body.timeout ?? Self.defaultTimeout, Self.maxTimeout))

        let sanitizedEnv = body.environment.map { env in
            env.filter { !Self.blockedEnvironmentKeys.contains($0.key) }
        }

        return try await runCommand(
            command: body.command,
            workingDirectory: body.workingDirectory,
            environment: sanitizedEnv,
            timeout: effectiveTimeout,
            maxOutputBytes: Self.maxOutputBytes,
        )
    }
}

// MARK: - Process Execution

func runCommand(
    command: String,
    workingDirectory: String?,
    environment: [String: String]?,
    timeout: Double,
    maxOutputBytes: Int,
) async throws -> ExecResponse {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]

    if let wd = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: wd)
    }

    if let env = environment {
        var merged = ProcessInfo.processInfo.environment
        merged.merge(env) { _, new in new }
        process.environment = merged
    }

    // Drain both streams while the command runs, retaining only the configured limit. This avoids
    // pipe backpressure without allowing unbounded output to consume memory or disk.
    let stdoutCapture = try BoundedOutputCapture(maxBytes: maxOutputBytes)
    let stderrCapture = try BoundedOutputCapture(maxBytes: maxOutputBytes)
    process.standardOutput = stdoutCapture.writeHandle
    process.standardError = stderrCapture.writeHandle

    // Set the termination handler before running so we never miss a fast exit
    let didTimeout = LockIsolated(false)
    let timeoutTask = LockIsolated<Task<Void, Never>?>(nil)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in
            continuation.resume()
        }
        do {
            try process.run()
            stdoutCapture.closeWriteEnd()
            stderrCapture.closeWriteEnd()
        } catch {
            stdoutCapture.closeWriteEnd()
            stderrCapture.closeWriteEnd()
            _ = stdoutCapture.finish()
            _ = stderrCapture.finish()
            continuation.resume(throwing: error)
            return
        }

        // Timeout is always enforced. Terminate the full descendant tree, then escalate after a
        // short grace period so children cannot retain output descriptors or outlive the request.
        timeoutTask.setValue(Task.detached {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard process.isRunning else { return }
            didTimeout.setValue(true)
            let processIDs = terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let remainingProcessIDs = [process.processIdentifier] + descendantProcessIDs(of: process.processIdentifier)
            signalProcesses(Array(Set(processIDs + remainingProcessIDs)), signal: SIGKILL)
        })
    }

    if didTimeout.value {
        await timeoutTask.value?.value
    } else {
        timeoutTask.value?.cancel()
    }

    let (stdout, stdoutTruncated) = stdoutCapture.finish()
    let (stderr, stderrTruncated) = stderrCapture.finish()

    if didTimeout.value {
        throw ExecError.timeout(timeout)
    }

    return ExecResponse(
        stdout: stdoutTruncated ? stdout + truncationMarker(maxBytes: maxOutputBytes) : stdout,
        stderr: stderrTruncated ? stderr + truncationMarker(maxBytes: maxOutputBytes) : stderr,
        exitCode: Int(process.terminationStatus),
    )
}

private func truncationMarker(maxBytes: Int) -> String {
    let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
    return "\n[truncated - output exceeded \(limit)]"
}

@discardableResult
private func terminateProcessTree(rootPID: Int32, signal: Int32) -> [Int32] {
    let processIDs = [rootPID] + descendantProcessIDs(of: rootPID)
    signalProcesses(processIDs, signal: signal)
    return processIDs
}

// MARK: - BoundedOutputCapture

/// Continuously drains a child-process stream while retaining only a bounded prefix.
private final class BoundedOutputCapture: @unchecked Sendable {
    let writeHandle: FileHandle

    private let maxBytes: Int
    private let queue = DispatchQueue(label: "dev.dannystewart.lumen.output-capture")
    private let readDescriptor: Int32
    private var data = Data()
    private var source: DispatchSourceRead!
    private var truncated = false

    init(maxBytes: Int) throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            #if os(Linux)
                Glibc.pipe(buffer.baseAddress!)
            #else
                Darwin.pipe(buffer.baseAddress!)
            #endif
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        self.maxBytes = max(0, maxBytes)
        self.readDescriptor = descriptors[0]
        self.writeHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)

        #if os(Linux)
            let flags = Glibc.fcntl(self.readDescriptor, F_GETFL)
            _ = Glibc.fcntl(self.readDescriptor, F_SETFL, flags | O_NONBLOCK)
        #else
            let flags = Darwin.fcntl(self.readDescriptor, F_GETFL)
            _ = Darwin.fcntl(self.readDescriptor, F_SETFL, flags | O_NONBLOCK)
        #endif

        self.source = DispatchSource.makeReadSource(fileDescriptor: self.readDescriptor, queue: self.queue)
        self.source.setEventHandler { [weak self] in
            self?.drainAvailableBytes()
        }
        self.source.setCancelHandler { [readDescriptor = self.readDescriptor] in
            #if os(Linux)
                _ = Glibc.close(readDescriptor)
            #else
                _ = Darwin.close(readDescriptor)
            #endif
        }
        self.source.resume()
    }

    func closeWriteEnd() {
        try? self.writeHandle.close()
    }

    func finish() -> (text: String, truncated: Bool) {
        self.queue.sync {
            self.drainAvailableBytes()
            self.source.cancel()
            return (String(data: self.data, encoding: .utf8) ?? "", self.truncated)
        }
    }

    private func drainAvailableBytes() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                #if os(Linux)
                    Glibc.read(self.readDescriptor, bytes.baseAddress, bytes.count)
                #else
                    Darwin.read(self.readDescriptor, bytes.baseAddress, bytes.count)
                #endif
            }

            if bytesRead > 0 {
                let remainingCapacity = max(0, self.maxBytes - self.data.count)
                let retainedCount = min(remainingCapacity, bytesRead)
                if retainedCount > 0 {
                    self.data.append(contentsOf: buffer.prefix(retainedCount))
                }
                if bytesRead > remainingCapacity {
                    self.truncated = true
                }
            } else if bytesRead == -1, errno == EINTR {
                continue
            } else if bytesRead == 0 {
                self.source.cancel()
                return
            } else {
                return
            }
        }
    }
}

private func signalProcesses(_ processIDs: [Int32], signal: Int32) {
    for processID in processIDs.reversed() {
        #if os(Linux)
            _ = Glibc.kill(processID, signal)
        #else
            _ = Darwin.kill(processID, signal)
        #endif
    }
}

private func descendantProcessIDs(of rootPID: Int32) -> [Int32] {
    let captureURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-ps-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: captureURL.path, contents: nil) else { return [] }
    defer { try? FileManager.default.removeItem(at: captureURL) }

    do {
        let handle = try FileHandle(forWritingTo: captureURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try handle.close()
    } catch {
        return []
    }

    guard
        let data = try? Data(contentsOf: captureURL),
        let output = String(data: data, encoding: .utf8)
    else {
        return []
    }

    var childrenByParent = [Int32: [Int32]]()
    for line in output.split(separator: "\n") {
        let columns = line.split(whereSeparator: \Character.isWhitespace)
        guard
            columns.count == 2,
            let processID = Int32(columns[0]),
            let parentID = Int32(columns[1])
        else {
            continue
        }
        childrenByParent[parentID, default: []].append(processID)
    }

    var descendants = [Int32]()
    func appendDescendants(of parentID: Int32) {
        for childID in childrenByParent[parentID] ?? [] {
            descendants.append(childID)
            appendDescendants(of: childID)
        }
    }
    appendDescendants(of: rootPID)
    return descendants
}

// MARK: - LockIsolated

/// A simple wrapper that provides Sendable-safe read/write access to a value via a lock. Used here
/// to safely share a flag across the process termination handler and the kill task.
final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock: NSLock = .init()

    var value: Value {
        self.lock.withLock { self._value }
    }

    init(_ value: Value) {
        self._value = value
    }

    func setValue(_ newValue: Value) {
        self.lock.withLock { self._value = newValue }
    }
}
