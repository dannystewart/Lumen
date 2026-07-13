@testable import Lumen
import Testing

@Suite("ExecController")
struct ExecControllerTests {
    @Test("Executes commands and captures both output streams")
    func capturesOutput() async throws {
        let response = try await runCommand(
            command: "printf stdout; printf stderr >&2",
            workingDirectory: nil,
            environment: nil,
            timeout: 2,
            maxOutputBytes: 1_000,
        )

        #expect(response.stdout == "stdout")
        #expect(response.stderr == "stderr")
        #expect(response.exitCode == 0)
    }

    @Test("Timeout remains bounded when descendants and the shell ignore termination")
    func killsTimedOutProcessTree() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await runCommand(
                command: "trap '' TERM; while :; do sleep 10; done",
                workingDirectory: nil,
                environment: nil,
                timeout: 0.1,
                maxOutputBytes: 1_000,
            )
            Issue.record("Expected command to time out")
        } catch let error as ExecError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, received \(error)")
                return
            }
        }

        #expect(startedAt.duration(to: clock.now) < .seconds(3))
    }

    @Test("Caps captured output")
    func capsOutput() async throws {
        let response = try await runCommand(
            command: "yes x | head -c 2000",
            workingDirectory: nil,
            environment: nil,
            timeout: 2,
            maxOutputBytes: 100,
        )

        #expect(response.stdout.hasSuffix("[truncated - output exceeded 100 bytes]"))
    }

    @Test("Returns without waiting for a background descendant that inherits output")
    func ignoresInheritedOutputDescriptor() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now

        let response = try await runCommand(
            command: "sleep 10 & printf complete",
            workingDirectory: nil,
            environment: nil,
            timeout: 2,
            maxOutputBytes: 1_000,
        )

        #expect(response.stdout == "complete")
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }
}
