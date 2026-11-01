import Foundation
import Vapor

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

// MARK: - ExecutionRegistry

/// Authenticated execution identities are never reused. A cancellation can arrive before its run
/// request: retain that tombstone longer than the maximum HTTP/command lifetime, not just while a
/// process exists. Duplicate run requests are rejected rather than replaying side effects.
actor ExecutionRegistry {
    private struct Entry {
        let control: ExecutionControl
        var started = false
        var expires: ContinuousClock.Instant?
    }

    private var entries: [UUID: Entry] = [:]
    private let retention: Duration = .seconds(ExecController.maxTimeout + 60)

    func begin(_ id: UUID) throws -> ExecutionControl {
        self.prune()
        var entry = self.entries[id] ?? Entry(control: ExecutionControl())
        guard !entry.started else { throw Abort(.conflict, reason: "This executionID has already been used.") }
        entry.started = true
        entry.expires = nil
        self.entries[id] = entry
        return entry.control
    }

    func cancel(_ id: UUID) -> ExecCancellationResponse {
        self.prune()
        var entry = self.entries[id] ?? Entry(control: ExecutionControl())
        let finished = entry.started && entry.expires != nil
        if !finished { entry.control.cancel() }
        if !entry.started { entry.expires = ContinuousClock().now.advanced(by: self.retention) }
        self.entries[id] = entry
        // Receipt only. The original run response acknowledges actual termination.
        return ExecCancellationResponse(executionID: id, state: finished ? "finished" : "requested")
    }

    func finish(_ id: UUID) {
        self.entries[id]?.expires = ContinuousClock().now.advanced(by: self.retention)
    }

    private func prune() {
        let now = ContinuousClock().now
        self.entries = self.entries.filter { $0.value.expires.map { $0 > now } ?? true }
    }
}

// MARK: - ExecutionControl

/// Launch and cancellation share a lock: Stop either prevents spawning or targets the exact new
/// process group. Never send a signal to the server's inherited process group.
final class ExecutionControl: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var cancelled = false
    private var processID: Int32?
    private var interruption: Task<Bool, Never>?
    private let exit: ExecutionExit = .init()

    func launch(_ spawn: () throws -> Int32) throws -> Int32? {
        try self.lock.withLock {
            guard !self.cancelled else { return nil }
            let pid = try spawn()
            self.processID = pid
            return pid
        }
    }

    func cancel() {
        self.lock.withLock {
            guard !self.cancelled else { return }
            self.cancelled = true
            if let pid = self.processID {
                self.interruption = Task.detached {
                    let confirmed = await interruptProcessGroup(pid)
                    if !confirmed { self.exit.resolve(-1) }
                    return confirmed
                }
            }
        }
    }

    func finish() -> (cancelled: Bool, interruption: Task<Bool, Never>?) {
        self.lock.withLock {
            self.processID = nil
            return (self.cancelled, self.interruption)
        }
    }

    func waitForExit(_ pid: Int32) async -> Int32 {
        let exit = self.exit
        // The waiter still reaps the child if SIGKILL cannot finish promptly. The HTTP operation
        // can independently return an honest unconfirmed outcome instead of waiting indefinitely.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var result: Int32
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR
            exit.resolve(result == -1 ? -1 : status)
        }
        return await exit.wait()
    }
}

// MARK: - ExecutionExit

/// Root exit and failed termination can race. Resolve the HTTP waiter once, retaining an early
/// outcome when it arrives before the continuation is installed.
private final class ExecutionExit: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func resolve(_ status: Int32) {
        let waiter = self.lock.withLock {
            guard self.status == nil else { return nil as CheckedContinuation<Int32, Never>? }
            self.status = status
            defer { self.continuation = nil }
            return self.continuation
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = self.lock.withLock {
                if self.status == nil { self.continuation = continuation }
                return self.status
            }
            if let status { continuation.resume(returning: status) }
        }
    }
}

func runCancellableCommand(
    command: String, workingDirectory: String?, environment: [String: String]?,
    timeout: Double, maxOutputBytes: Int, control: ExecutionControl,
) async throws -> ExecResponse {
    let stdout = try BoundedOutputCapture(maxBytes: maxOutputBytes)
    let stderr = try BoundedOutputCapture(maxBytes: maxOutputBytes)
    let pid: Int32?
    do {
        pid = try control.launch {
            try spawnCommand(command,
                             workingDirectory: workingDirectory,
                             environment: environment,
                             stdout: stdout.writeHandle.fileDescriptor,
                             stderr: stderr.writeHandle.fileDescriptor)
        }
    } catch {
        stdout.closeWriteEnd()
        stderr.closeWriteEnd()
        _ = stdout.finish()
        _ = stderr.finish()
        throw error
    }
    stdout.closeWriteEnd()
    stderr.closeWriteEnd()
    guard let pid else {
        _ = stdout.finish()
        _ = stderr.finish()
        return ExecResponse(stdout: "", stderr: "Interrupted before execution.", exitCode: 130, cancelled: true)
    }

    let timedOut = LockIsolated(false)
    let timer = Task.detached {
        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
        timedOut.setValue(true)
        control.cancel()
    }
    let status = await control.waitForExit(pid)
    timer.cancel()
    let completion = control.finish()
    let confirmed = await completion.interruption?.value ?? true
    let output = stdout.finish()
    let errors = stderr.finish()
    guard confirmed, status != -1 else {
        return ExecResponse(
            stdout: output.text + (output.truncated ? truncationMarker(maxBytes: maxOutputBytes) : ""),
            stderr: errors.text + (errors.truncated ? truncationMarker(maxBytes: maxOutputBytes) : "")
                + "\nProcess termination could not be confirmed. Do not repeat the command.",
            exitCode: -1,
            cancelled: false,
            terminationConfirmed: false,
        )
    }
    if timedOut.value { throw ExecError.timeout(timeout) }
    // POSIX wait status: normal exit in the high byte; signal termination in the low seven bits.
    let signal = status & 0x7F
    let exitCode = signal == 0 ? Int((status >> 8) & 0xFF) : 128 + Int(signal)
    return ExecResponse(
        stdout: output.text + (output.truncated ? truncationMarker(maxBytes: maxOutputBytes) : ""),
        stderr: errors.text + (errors.truncated ? truncationMarker(maxBytes: maxOutputBytes) : ""),
        exitCode: exitCode,
        cancelled: completion.cancelled,
    )
}

private func spawnCommand(_ command: String, workingDirectory: String?, environment: [String: String]?, stdout: Int32, stderr: Int32) throws -> Int32 {
    var env = ProcessInfo.processInfo.environment
    env.merge(environment ?? [:]) { _, new in new }
    let script = workingDirectory.map { "cd -- '\($0.replacingOccurrences(of: "'", with: "'\\''"))' || exit $?; \(command)" } ?? command
    let strings = ["/bin/sh", "-c", script]
    let variables = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    guard !(strings + variables).contains(where: { $0.contains("\0") }) else {
        throw Abort(.badRequest, reason: "Command, directory, and environment must not contain NUL characters.")
    }
    var argv = strings.map { strdup($0) } + [nil]
    var envp = variables.map { strdup($0) } + [nil]
    defer {
        for pointer in argv {
            free(pointer)
        }
        for pointer in envp {
            free(pointer)
        }
    }
    #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
    #else
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
    #endif // os(Linux)
    try checkSpawn(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try checkSpawn(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try checkSpawn(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    try checkSpawn(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
    try checkSpawn(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
    try checkSpawn(posix_spawnattr_setpgroup(&attributes, 0))
    var mask = sigset_t()
    sigemptyset(&mask)
    try checkSpawn(posix_spawnattr_setsigmask(&attributes, &mask))
    sigaddset(&mask, SIGINT)
    sigaddset(&mask, SIGTERM)
    sigaddset(&mask, SIGPIPE)
    try checkSpawn(posix_spawnattr_setsigdefault(&attributes, &mask))
    var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    #if !os(Linux)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    try checkSpawn(posix_spawnattr_setflags(&attributes, flags))
    var pid: Int32 = 0
    let error = argv.withUnsafeMutableBufferPointer { arguments in
        envp.withUnsafeMutableBufferPointer { variables in
            posix_spawn(&pid, "/bin/sh", &actions, &attributes, arguments.baseAddress!, variables.baseAddress!)
        }
    }
    try checkSpawn(error)
    return pid
}

private func checkSpawn(_ error: Int32) throws {
    guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
}

private func interruptProcessGroup(_ pid: Int32) async -> Bool {
    for signal in [SIGINT, SIGTERM, SIGKILL] {
        if kill(-pid, signal) == -1, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(250))
        if await processGroupIsEmpty(pid) == true { return true }
    }
    // SIGKILL cannot be handled, but a process in uninterruptible I/O can take time to exit. Keep
    // the outcome honest rather than acknowledge a still-live process as terminated.
    return await processGroupIsEmpty(pid) == true
}

private func processGroupIsEmpty(_ pid: Int32) async -> Bool? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pgid=,stat="]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard
                    process.terminationStatus == 0,
                    let text = String(data: data, encoding: .utf8) else
                {
                    continuation.resume(returning: nil)
                    return
                }
                let alive = text.split(separator: "\n").contains { line in
                    let columns = line.split(whereSeparator: \.isWhitespace)
                    return columns.count >= 2 && Int32(columns[0]) == pid && !columns[1].hasPrefix("Z")
                }
                continuation.resume(returning: !alive)
            } catch { continuation.resume(returning: nil) }
        }
    }
}
