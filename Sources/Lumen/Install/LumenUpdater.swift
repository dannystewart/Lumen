import Vapor

// MARK: - LumenUpdater

struct LumenUpdater {
    private static let repositoryURL = "https://github.com/dannystewart/Lumen.git"

    private let console: Console
    private let fileManager: FileManager = .default

    init(console: Console) {
        self.console = console
    }

    func run() throws {
        let platform = InstallPlatform.current

        self.console.print("")
        self.console.printHeader("Lumen v\(lumenVersion) for \(platform.displayName) • Updater")
        self.console.printNote("Check tagged releases and update the installed Lumen service.")
        self.console.print("")

        guard InstallLocator().detectExistingInstall(on: platform) != nil else {
            self.console.printWarning("No existing installation was found.")
            self.console.printNote("Run `lumen install` before using the updater.")
            self.console.print("")
            return
        }

        self.console.printSection("Checking for updates")
        let latestTag = try self.latestReleaseTag()
        let latestVersion = try SemanticVersion(tag: latestTag)
        let currentVersion = try SemanticVersion(lumenVersion)

        self.console.printLabelValue("Installed", value: "v\(currentVersion)")
        self.console.printLabelValue("Latest", value: latestTag)
        self.console.print("")

        guard latestVersion > currentVersion else {
            self.console.printSuccess("Lumen is already up to date.")
            self.console.print("")
            return
        }

        let temporaryDirectory = self.fileManager
            .temporaryDirectory
            .appendingPathComponent("lumen-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? self.fileManager.removeItem(at: temporaryDirectory) }

        try self.fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let sourceDirectory = temporaryDirectory.appendingPathComponent("source", isDirectory: true)

        self.console.printSection("Installing \(latestTag)")
        self.console.printNote("Downloading the tagged source release...")
        try self.run(
            executable: "/usr/bin/env",
            arguments: [
                "git",
                "clone",
                "--quiet",
                "--depth",
                "1",
                "--branch",
                latestTag,
                "--single-branch",
                Self.repositoryURL,
                sourceDirectory.path,
            ],
        )

        self.console.printNote("Building the release binary...")
        try self.run(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "-c", "release", "--product", "lumen"],
            currentDirectory: sourceDirectory,
        )

        let binaryDirectory = try self.capture(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "-c", "release", "--show-bin-path"],
            currentDirectory: sourceDirectory,
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedBinary = URL(fileURLWithPath: binaryDirectory).appendingPathComponent("lumen")

        guard self.fileManager.isExecutableFile(atPath: updatedBinary.path) else {
            throw Abort(.internalServerError, reason: "The release build did not produce an executable Lumen binary.")
        }

        try self.run(
            executable: updatedBinary.path,
            arguments: ["install", "--automatic-upgrade"],
        )
    }

    private func latestReleaseTag() throws -> String {
        let output = try self.capture(
            executable: "/usr/bin/env",
            arguments: ["git", "ls-remote", "--tags", "--refs", Self.repositoryURL],
        )

        let tags = output.components(separatedBy: .newlines).compactMap { line -> (String, SemanticVersion)? in
            guard let reference = line.split(whereSeparator: \Character.isWhitespace).last else { return nil }
            let tag = String(reference).replacingOccurrences(of: "refs/tags/", with: "")
            guard let version = try? SemanticVersion(tag: tag) else { return nil }
            return (tag, version)
        }

        guard let latest = tags.max(by: { $0.1 < $1.1 }) else {
            throw Abort(.internalServerError, reason: "No stable Lumen release tags were found.")
        }

        return latest.0
    }

    private func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Abort(
                .internalServerError,
                reason: "Update command failed with exit code \(process.terminationStatus): \(([executable] + arguments).joined(separator: " "))",
            )
        }
    }

    private func capture(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let reason = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Abort(
                .internalServerError,
                reason: reason.isEmpty ? "Unable to check for Lumen updates." : reason,
            )
        }

        return output
    }
}

// MARK: - SemanticVersion

struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String {
        "\(self.major).\(self.minor).\(self.patch)"
    }

    init(_ version: String) throws {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            let major = Int(components[0]),
            let minor = Int(components[1]),
            let patch = Int(components[2]),
            major >= 0,
            minor >= 0,
            patch >= 0 else
        {
            throw Abort(.internalServerError, reason: "Invalid Lumen version: \(version)")
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init(tag: String) throws {
        guard tag.hasPrefix("v") else {
            throw Abort(.internalServerError, reason: "Invalid Lumen release tag: \(tag)")
        }
        try self.init(String(tag.dropFirst()))
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
