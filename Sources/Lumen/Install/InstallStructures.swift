import Foundation
import Vapor

// MARK: - InstallConsoleStyle

enum InstallConsoleStyle {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let cyan = "\u{001B}[36m"
    static let white = "\u{001B}[37m"
    static let green = "\u{001B}[32m"
    static let red = "\u{001B}[31m"
    static let yellow = "\u{001B}[33m"
    static let dim = "\u{001B}[2m"

    static func colorize(_ text: String, color: String, bold: Bool = false) -> String {
        let boldPrefix = bold ? self.bold : ""
        return "\(boldPrefix)\(color)\(text)\(self.reset)"
    }

    static func header(_ text: String) -> String {
        self.colorize(text, color: self.cyan, bold: true)
    }

    static func section(_ text: String) -> String {
        self.colorize(text, color: self.cyan, bold: true)
    }

    static func label(_ text: String) -> String {
        self.colorize(text, color: self.cyan, bold: true)
    }

    static func value(_ text: String) -> String {
        self.colorize(text, color: self.white)
    }

    static func success(_ text: String) -> String {
        self.colorize(text, color: self.green, bold: true)
    }

    static func error(_ text: String) -> String {
        self.colorize(text, color: self.red, bold: true)
    }

    static func warning(_ text: String) -> String {
        self.colorize(text, color: self.yellow, bold: true)
    }

    static func command(_ text: String) -> String {
        self.colorize(text, color: self.white, bold: true)
    }

    static func prompt(_ text: String) -> String {
        self.colorize(text, color: self.cyan, bold: true)
    }

    static func note(_ text: String) -> String {
        self.colorize(text, color: self.dim)
    }

    static func bullet(label: String, value: String) -> String {
        "• \(self.label(label + ":")) \(self.value(value))"
    }
}

extension Console {
    func printStyled(_ text: String = "") {
        self.print(text)
    }

    func printHeader(_ text: String) {
        self.print(InstallConsoleStyle.header(text))
    }

    func printSection(_ text: String) {
        self.print(InstallConsoleStyle.section(text))
    }

    func printLabelValue(_ label: String, value: String) {
        self.print(InstallConsoleStyle.bullet(label: label, value: value))
    }

    func printSuccess(_ text: String) {
        self.print(InstallConsoleStyle.success("✓ \(text)"))
    }

    func printError(_ text: String) {
        self.print(InstallConsoleStyle.error(text))
    }

    func printWarning(_ text: String) {
        self.print(InstallConsoleStyle.warning("⚠ \(text)"))
    }

    func printCommand(_ text: String) {
        self.print(InstallConsoleStyle.command(text))
    }

    func printNote(_ text: String) {
        self.print(InstallConsoleStyle.note(text))
    }

    func printPathNotice(_ binaryPath: String) {
        self.print(InstallConsoleStyle.note("To run `lumen` commands from anywhere, make sure \(binaryPath) is in your PATH."))
    }

    func outputPrompt(_ text: String) {
        self.output(InstallConsoleStyle.prompt(text).consoleText(), newLine: false)
    }
}

// MARK: - InstallLocator

struct InstallLocator {
    private let fileManager: FileManager = .default

    func detectExistingInstall(on platform: InstallPlatform) -> ExistingInstall? {
        let userDefaults = InstallDefaults(platform: platform, runAsSystemService: false)
        if self.fileManager.fileExists(atPath: userDefaults.serviceFilePath) || self.fileManager.fileExists(atPath: userDefaults.binaryPath) {
            return ExistingInstall(
                runAsSystemService: false,
                binaryPath: userDefaults.binaryPath,
                serviceFilePath: userDefaults.serviceFilePath,
                stdoutLogPath: userDefaults.stdoutLogPath,
                stderrLogPath: userDefaults.stderrLogPath,
            )
        }

        if platform == .linux {
            let systemDefaults = InstallDefaults(platform: platform, runAsSystemService: true)
            if self.fileManager.fileExists(atPath: systemDefaults.serviceFilePath) || self.fileManager.fileExists(atPath: systemDefaults.binaryPath) {
                return ExistingInstall(
                    runAsSystemService: true,
                    binaryPath: systemDefaults.binaryPath,
                    serviceFilePath: systemDefaults.serviceFilePath,
                    stdoutLogPath: systemDefaults.stdoutLogPath,
                    stderrLogPath: systemDefaults.stderrLogPath,
                )
            }
        }

        return nil
    }
}

// MARK: - InstallPlan

struct InstallPlan {
    let platform: InstallPlatform
    let runAsSystemService: Bool
    let sourceBinaryPath: String
    let binaryPath: String
    let serviceFilePath: String
    let stdoutLogPath: String
    let stderrLogPath: String
    let port: Int
    let allowSudo: Bool
    let apiKey: String
    let shouldRevealAPIKey: Bool
    let installAndStartNow: Bool
    let shouldShowPathNotice: Bool
}

// MARK: - ExistingInstall

struct ExistingInstall {
    let runAsSystemService: Bool
    let binaryPath: String
    let serviceFilePath: String
    let stdoutLogPath: String
    let stderrLogPath: String
}

// MARK: - ExistingConfig

struct ExistingConfig {
    let apiKey: String?
    let port: Int?
    let allowSudo: Bool?
}

// MARK: - InstallPlatform

enum InstallPlatform {
    case macOS
    case linux

    static var current: InstallPlatform {
        #if os(macOS)
            .macOS
        #elseif os(Linux)
            .linux
        #else
            .macOS
        #endif // os(macOS)
    }

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        }
    }

    var serviceLabel: String {
        switch self {
        case .macOS: "ai.prismapp.Lumen"
        case .linux: "lumen"
        }
    }
}

// MARK: - InstallDefaults

struct InstallDefaults {
    let binaryPath: String
    let serviceFilePath: String
    let stdoutLogPath: String
    let stderrLogPath: String

    init(platform: InstallPlatform, runAsSystemService: Bool) {
        switch platform {
        case .macOS:
            let home = NSHomeDirectory()
            self.binaryPath = "\(home)/.local/bin/lumen"
            self.serviceFilePath = "\(home)/Library/LaunchAgents/ai.prismapp.Lumen.plist"
            self.stdoutLogPath = "\(home)/Library/Logs/Lumen/lumen.log"
            self.stderrLogPath = "\(home)/Library/Logs/Lumen/lumen-error.log"

        case .linux:
            if runAsSystemService {
                self.binaryPath = "/usr/local/bin/lumen"
                self.serviceFilePath = "/etc/systemd/system/lumen.service"
                self.stdoutLogPath = "/var/log/lumen/lumen.log"
                self.stderrLogPath = "/var/log/lumen/lumen-error.log"
            } else {
                let home = NSHomeDirectory()
                self.binaryPath = "\(home)/.local/bin/lumen"
                self.serviceFilePath = "\(home)/.config/systemd/user/lumen.service"
                self.stdoutLogPath = "\(home)/.local/state/lumen/lumen.log"
                self.stderrLogPath = "\(home)/.local/state/lumen/lumen-error.log"
            }
        }
    }
}

// MARK: - ServiceRenderer

enum ServiceRenderer {
    static func serviceFile(for plan: InstallPlan) -> String {
        switch plan.platform {
        case .macOS:
            self.launchdPlist(for: plan)
        case .linux:
            self.systemdUnit(for: plan)
        }
    }

    private static func launchdPlist(for plan: InstallPlan) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plan.platform.serviceLabel)</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(self.escapeXML(plan.binaryPath))</string>
                <string>serve</string>
                <string>--env</string>
                <string>production</string>
            </array>

            <key>EnvironmentVariables</key>
            <dict>
                <key>LUMEN_API_KEY</key>
                <string>\(self.escapeXML(plan.apiKey))</string>
                <key>LUMEN_PORT</key>
                <string>\(plan.port)</string>
                <key>LUMEN_ALLOW_SUDO</key>
                <string>\(plan.allowSudo ? "true" : "false")</string>
            </dict>

            <key>RunAtLoad</key>
            <true/>

            <key>KeepAlive</key>
            <true/>

            <key>StandardOutPath</key>
            <string>\(self.escapeXML(plan.stdoutLogPath))</string>

            <key>StandardErrorPath</key>
            <string>\(self.escapeXML(plan.stderrLogPath))</string>
        </dict>
        </plist>
        """
    }

    private static func systemdUnit(for plan: InstallPlan) -> String {
        """
        [Unit]
        Description=Lumen - lightweight command execution server for Prism
        Documentation=https://github.com/dannystewart/lumen
        After=network.target

        [Service]
        Type=simple
        ExecStart=\(plan.binaryPath) serve --env production
        Environment="LUMEN_API_KEY=\(self.escapeSystemd(plan.apiKey))"
        Environment="LUMEN_PORT=\(plan.port)"
        Environment="LUMEN_ALLOW_SUDO=\(plan.allowSudo ? "true" : "false")"
        Restart=on-failure
        RestartSec=5s
        TimeoutStopSec=10s
        StandardOutput=append:\(plan.stdoutLogPath)
        StandardError=append:\(plan.stderrLogPath)
        SyslogIdentifier=lumen

        [Install]
        WantedBy=\(plan.runAsSystemService ? "multi-user.target" : "default.target")
        """
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func escapeSystemd(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Shell Helpers

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
