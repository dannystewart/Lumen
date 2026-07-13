@testable import Lumen
import Testing

@Suite("ExecController")
struct ExecControllerTests {
    @Test
    func `Rejects root-scoped find commands`() {
        let commands = [
            "find / -iname '*.swift'",
            "find \"/\" -maxdepth 4 -name config.json",
            "echo ready && /usr/bin/find / -name '*.py'",
            "printf done; /bin/find '/' -type f",
            "echo nested | (find -L / -name '*.md')",
            "command find -- / -type d",
        ]

        for command in commands {
            #expect(ExecController.containsRootFind(command), "Expected to reject: \(command)")
        }
    }

    @Test
    func `Allows scoped find commands and mentions of root find`() {
        let commands = [
            "find /Users/joe -iname '*.swift'",
            "find \"/Users/joe/Obsidian/Robot Assistant\" -maxdepth 4 -name '*.py'",
            "find . -type f",
            "mdfind -name unifi-protect",
            "echo 'Do not run find / on this machine'",
        ]

        for command in commands {
            #expect(!ExecController.containsRootFind(command), "Expected to allow: \(command)")
        }
    }

    @Test
    func `Executes commands and captures both output streams`() async throws {
        let response = try await runCommand(
            command: "printf stdout; printf stderr >&2",
            workingDirectory: nil,
            environment: nil,
            timeout: 2,
            maxOutputBytes: 1000,
        )

        #expect(response.stdout == "stdout")
        #expect(response.stderr == "stderr")
        #expect(response.exitCode == 0)
    }

    @Test
    func `Timeout remains bounded when descendants and the shell ignore termination`() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await runCommand(
                command: "trap '' TERM; while :; do sleep 10; done",
                workingDirectory: nil,
                environment: nil,
                timeout: 0.1,
                maxOutputBytes: 1000,
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

    @Test
    func `Caps captured output`() async throws {
        let response = try await runCommand(
            command: "yes x | head -c 2000",
            workingDirectory: nil,
            environment: nil,
            timeout: 2,
            maxOutputBytes: 100,
        )

        #expect(response.stdout.hasSuffix("[truncated - output exceeded 100 bytes]"))
    }

    @Test
    func `Returns without waiting for a background descendant that inherits output`() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now

        let response = try await runCommand(
            command: "sleep 10 & printf complete",
            workingDirectory: nil,
            environment: nil,
            timeout: 2,
            maxOutputBytes: 1000,
        )

        #expect(response.stdout == "complete")
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }
}
