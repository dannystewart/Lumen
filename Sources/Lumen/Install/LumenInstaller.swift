import Vapor

// MARK: - LumenInstaller

struct LumenInstaller {
    private let console: Console
    private let options: InstallerOptions
    private let fileManager: FileManager = .default

    init(console: Console, options: InstallerOptions) throws {
        self.console = console
        self.options = options
    }

    private static func generateAPIKey() -> String {
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func expandTilde(in path: String) -> String {
        if path == "~" {
            return NSHomeDirectory()
        }
        if path.hasPrefix("~/") {
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return path
    }

    func run() throws {
        let platform = InstallPlatform.current
        let sourceBinaryPath = try self.resolveCurrentExecutablePath()

        self.console.print("")
        self.console.printHeader("Lumen v\(lumenVersion) for \(platform.displayName) • Installer")
        self.console.printNote("Configure the service and install paths below.")
        self.console.print("")

        let existingInstall = InstallLocator().detectExistingInstall(on: platform)

        if self.options.automaticUpgrade, existingInstall == nil {
            throw Abort(.notFound, reason: "The existing Lumen installation could not be found.")
        }

        let plan: InstallPlan
        if let existingInstall {
            self.console.printSection("Existing installation detected")
            self.console.printLabelValue("Service type", value: existingInstall.runAsSystemService ? "system" : "user")
            self.console.printLabelValue("Binary", value: existingInstall.binaryPath)
            self.console.printLabelValue("Service", value: existingInstall.serviceFilePath)
            self.console.print("")

            if self.options.automaticUpgrade || self.console.askBool(prompt: "Keep existing config and reinstall/upgrade?", defaultValue: true) {
                let existingConfig = ConfigParser.loadExistingConfig(from: existingInstall.serviceFilePath, platform: platform)
                let preservedAPIKey = existingConfig.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

                let allowSudo = try self.resolveAllowSudo(existingValue: existingConfig.allowSudo ?? false)

                plan = InstallPlan(
                    platform: platform,
                    runAsSystemService: existingInstall.runAsSystemService,
                    sourceBinaryPath: sourceBinaryPath,
                    binaryPath: existingInstall.binaryPath,
                    serviceFilePath: existingInstall.serviceFilePath,
                    stdoutLogPath: existingInstall.stdoutLogPath,
                    stderrLogPath: existingInstall.stderrLogPath,
                    port: existingConfig.port ?? 9069,
                    allowSudo: allowSudo,
                    apiKey: (preservedAPIKey?.isEmpty == false) ? preservedAPIKey! : Self.generateAPIKey(),
                    shouldRevealAPIKey: preservedAPIKey?.isEmpty != false,
                    installAndStartNow: true,
                    shouldShowPathNotice: false,
                )
            } else {
                guard let interactivePlan = try self.buildInteractivePlan(platform: platform, sourceBinaryPath: sourceBinaryPath) else {
                    return
                }
                plan = interactivePlan
            }
        } else {
            guard let interactivePlan = try self.buildInteractivePlan(platform: platform, sourceBinaryPath: sourceBinaryPath) else {
                return
            }
            plan = interactivePlan
        }

        self.console.print("")
        self.console.printSection("Install plan")
        self.console.printLabelValue("Service type", value: plan.runAsSystemService ? "system" : "user")
        self.console.printLabelValue("Binary", value: plan.binaryPath)
        self.console.printLabelValue("Service", value: plan.serviceFilePath)
        self.console.printLabelValue("Port", value: String(plan.port))
        if plan.allowSudo {
            self.console.printWarning("Root access enabled")
        }
        self.console.print("")

        let canWriteInstall = self.canWriteInstallTargets(for: plan)

        guard canWriteInstall else {
            self.console.printError("Installation requires elevated permissions. Re-run the installer with sudo.")
            if self.options.automaticUpgrade {
                throw Abort(.forbidden, reason: "The Lumen update requires elevated permissions.")
            }
            return
        }

        try self.install(plan)
        if plan.installAndStartNow {
            try self.startService(for: plan)
            self.console.printSuccess("Lumen installed and started successfully!")
        } else {
            self.console.printSuccess("Lumen installed successfully!")
        }
        self.printAPIKeyIfNeeded(for: plan)
        self.console.print("")
        self.printPathNoticeIfNeeded(for: plan)
        self.printCompletion(for: plan)
    }

    private func buildInteractivePlan(platform: InstallPlatform, sourceBinaryPath: String) throws -> InstallPlan? {
        let runAsSystemService: Bool = switch platform {
        case .macOS:
            false
        case .linux:
            self.console.askBool(
                prompt: "Run as a system service?",
                defaultValue: false,
            )
        }

        let defaults = InstallDefaults(platform: platform, runAsSystemService: runAsSystemService)

        guard
            self.canWriteInstallTargets(
                for: InstallPlan(
                    platform: platform,
                    runAsSystemService: runAsSystemService,
                    sourceBinaryPath: sourceBinaryPath,
                    binaryPath: defaults.binaryPath,
                    serviceFilePath: defaults.serviceFilePath,
                    stdoutLogPath: defaults.stdoutLogPath,
                    stderrLogPath: defaults.stderrLogPath,
                    port: 9069,
                    allowSudo: false,
                    apiKey: "",
                    shouldRevealAPIKey: false,
                    installAndStartNow: true,
                    shouldShowPathNotice: true,
                ),
            ) else
        {
            self.console.printError("Installation requires elevated permissions for this service type. Re-run the installer with sudo.")
            return nil
        }

        let binaryPath = self.askString(
            prompt: "Install binary to",
            defaultValue: defaults.binaryPath,
        )

        let port = self.askPort(defaultValue: 9069)

        let allowSudo = try self.resolveAllowSudo(existingValue: false)

        let installAndStartNow = self.console.askBool(
            prompt: "Install and start now?",
            defaultValue: true,
        )

        let apiKeySelection = self.resolveAPIKeySelection()

        return InstallPlan(
            platform: platform,
            runAsSystemService: runAsSystemService,
            sourceBinaryPath: sourceBinaryPath,
            binaryPath: binaryPath,
            serviceFilePath: defaults.serviceFilePath,
            stdoutLogPath: defaults.stdoutLogPath,
            stderrLogPath: defaults.stderrLogPath,
            port: port,
            allowSudo: allowSudo,
            apiKey: apiKeySelection.apiKey,
            shouldRevealAPIKey: apiKeySelection.shouldRevealAPIKey,
            installAndStartNow: installAndStartNow,
            shouldShowPathNotice: binaryPath.hasPrefix(NSHomeDirectory()),
        )
    }

    private func resolveAPIKeySelection() -> (apiKey: String, shouldRevealAPIKey: Bool) {
        self.console.outputPrompt("Enter your Lumen API key, or press Enter to generate one: ")
        let input = self.console.input(isSecure: false).trimmingCharacters(in: .whitespacesAndNewlines)

        guard input.isEmpty == false else {
            return (Self.generateAPIKey(), true)
        }

        return (input, false)
    }

    private func resolveAllowSudo(existingValue: Bool) throws -> Bool {
        guard self.options.allowSudoRequested else {
            return existingValue
        }

        return self.console.askBool(
            prompt: "Allowing privileged execution is dangerous and WILL NOT WORK unless your account is configured for non-interactive privilege escalation, such as passwordless sudo. Are you sure you want to continue?",
            defaultValue: false,
        )
    }

    private func install(_ plan: InstallPlan) throws {
        let serviceContents = ServiceRenderer.serviceFile(for: plan)

        let binaryDirectory = URL(fileURLWithPath: plan.binaryPath).deletingLastPathComponent()
        let serviceDirectory = URL(fileURLWithPath: plan.serviceFilePath).deletingLastPathComponent()
        let stdoutDirectory = URL(fileURLWithPath: plan.stdoutLogPath).deletingLastPathComponent()
        let stderrDirectory = URL(fileURLWithPath: plan.stderrLogPath).deletingLastPathComponent()

        try self.createDirectoryIfNeeded(binaryDirectory.path)
        try self.createDirectoryIfNeeded(serviceDirectory.path)
        try self.createDirectoryIfNeeded(stdoutDirectory.path)
        try self.createDirectoryIfNeeded(stderrDirectory.path)

        try self.setDirectoryPermissionsIfPossible(at: binaryDirectory.path, permissions: 0o755)
        try self.setDirectoryPermissionsIfPossible(at: serviceDirectory.path, permissions: 0o755)
        try self.setDirectoryPermissionsIfPossible(at: stdoutDirectory.path, permissions: 0o700)
        try self.setDirectoryPermissionsIfPossible(at: stderrDirectory.path, permissions: 0o700)

        try self.stopServiceIfNeeded(for: plan)

        if self.fileManager.fileExists(atPath: plan.binaryPath) {
            try self.fileManager.removeItem(atPath: plan.binaryPath)
        }
        try self.fileManager.copyItem(atPath: plan.sourceBinaryPath, toPath: plan.binaryPath)

        try serviceContents.write(toFile: plan.serviceFilePath, atomically: true, encoding: .utf8)

        try self.setPermissionsIfPossible(for: plan)
    }

    private func canWriteInstallTargets(for plan: InstallPlan) -> Bool {
        [
            plan.binaryPath,
            plan.serviceFilePath,
            plan.stdoutLogPath,
            plan.stderrLogPath,
        ].allSatisfy { self.fileManager.canWritePath($0) }
    }

    private func setPermissionsIfPossible(for plan: InstallPlan) throws {
        try? self.fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: plan.binaryPath,
        )
        try? self.fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plan.serviceFilePath,
        )
    }

    private func setDirectoryPermissionsIfPossible(at path: String, permissions: Int) throws {
        try? self.fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: path,
        )
    }

    private func printAPIKeyIfNeeded(for plan: InstallPlan) {
        guard plan.shouldRevealAPIKey else {
            self.console.printSuccess("API key unchanged. Existing Prism connections should continue working.")
            return
        }

        self.console.print("")
        self.console.printWarning("Save this API key now — it will not be shown again:")
        self.console.print(plan.apiKey)
    }

    private func printPathNoticeIfNeeded(for plan: InstallPlan) {
        guard plan.shouldShowPathNotice else { return }

        let binaryDirectory = URL(fileURLWithPath: plan.binaryPath).deletingLastPathComponent().path
        self.console.print("")
        self.console.printPathNotice(binaryDirectory)
        self.console.print("")
    }

    private func printCompletion(for plan: InstallPlan) {
        guard plan.installAndStartNow == false else { return }

        self.console.printSection("When you're ready, start the service with:")
        self.console.printCommand("lumen start")
    }

    private func startService(for plan: InstallPlan) throws {
        for command in self.startCommands(for: plan) {
            try self.runShellCommand(command)
        }
    }

    private func stopServiceIfNeeded(for plan: InstallPlan) throws {
        for command in self.stopCommands(for: plan) {
            try self.runShellCommand(command, allowFailuresMatching: [
                "could not find service",
                "service is disabled",
                "no such process",
                "not loaded",
            ])
        }
    }

    private func startCommands(for plan: InstallPlan) -> [String] {
        switch plan.platform {
        case .macOS:
            if plan.runAsSystemService {
                return [
                    "launchctl bootstrap system \(shellQuote(plan.serviceFilePath))",
                ]
            } else {
                let uid = getuid()
                return [
                    "launchctl bootstrap gui/\(uid) \(shellQuote(plan.serviceFilePath))",
                ]
            }

        case .linux:
            if plan.runAsSystemService {
                return [
                    "systemctl daemon-reload",
                    "systemctl enable --now lumen.service",
                ]
            } else {
                return [
                    "systemctl --user daemon-reload",
                    "systemctl --user enable --now lumen.service",
                ]
            }
        }
    }

    private func stopCommands(for plan: InstallPlan) -> [String] {
        switch plan.platform {
        case .macOS:
            if plan.runAsSystemService {
                return [
                    "launchctl bootout system/\(plan.platform.serviceLabel)",
                ]
            } else {
                let uid = getuid()
                return [
                    "launchctl bootout gui/\(uid)/\(plan.platform.serviceLabel)",
                ]
            }

        case .linux:
            if plan.runAsSystemService {
                return [
                    "systemctl stop lumen.service",
                    "systemctl daemon-reload",
                ]
            } else {
                return [
                    "systemctl --user stop lumen.service",
                    "systemctl --user daemon-reload",
                ]
            }
        }
    }

    private func runShellCommand(
        _ command: String,
        allowFailuresMatching allowedFailureSubstrings: [String] = [],
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combinedOutput = "\(stdout)\n\(stderr)".lowercased()

        guard process.terminationStatus != 0 else {
            return
        }

        if allowedFailureSubstrings.contains(where: { combinedOutput.contains($0) }) {
            return
        }

        throw Abort(
            .internalServerError,
            reason: combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Failed to run command: \(command)"
                : "Failed to run command: \(command)\n\(stdout)\n\(stderr)".trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    private func createDirectoryIfNeeded(_ path: String) throws {
        try self.fileManager.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true,
        )
    }

    private func askString(prompt: String, defaultValue: String) -> String {
        self.console.outputPrompt("\(prompt) [\(defaultValue)]: ")
        let input = self.console.input(isSecure: false).trimmingCharacters(in: .whitespacesAndNewlines)
        return input.isEmpty ? defaultValue : Self.expandTilde(in: input)
    }

    private func askPort(defaultValue: Int) -> Int {
        while true {
            self.console.outputPrompt("Port [\(defaultValue)]: ")
            let input = self.console.input(isSecure: false).trimmingCharacters(in: .whitespacesAndNewlines)

            if input.isEmpty {
                return defaultValue
            }

            if let value = Int(input), (1 ... 65535).contains(value) {
                return value
            }

            self.console.printError("Please enter a valid port between 1 and 65535.")
        }
    }

    private func resolveCurrentExecutablePath() throws -> String {
        let executable = CommandLine.arguments.first ?? ProcessInfo.processInfo.arguments.first ?? "./lumen"
        let expanded = Self.expandTilde(in: executable)

        if expanded.hasPrefix("/") {
            return expanded
        }

        let currentDirectory = self.fileManager.currentDirectoryPath
        let workingDirectoryCandidate = URL(fileURLWithPath: currentDirectory)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path

        if self.fileManager.fileExists(atPath: workingDirectoryCandidate) {
            return workingDirectoryCandidate
        }

        let executableURL = URL(fileURLWithPath: executable)
        let swiftPMBuildPathComponents = executableURL.pathComponents.suffix(4)
        if
            swiftPMBuildPathComponents.count == 4,
            swiftPMBuildPathComponents[0] == ".build",
            swiftPMBuildPathComponents[2] == "debug"
        {
            let swiftPMCandidate = URL(fileURLWithPath: currentDirectory)
                .appendingPathComponent(".build")
                .appendingPathComponent(swiftPMBuildPathComponents[1])
                .appendingPathComponent("debug")
                .appendingPathComponent(swiftPMBuildPathComponents[3])
                .standardizedFileURL
                .path

            if self.fileManager.fileExists(atPath: swiftPMCandidate) {
                return swiftPMCandidate
            }
        }

        return executableURL.standardizedFileURL.path
    }
}
