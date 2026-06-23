import Vapor

// MARK: - Entrypoint

@main
struct Entrypoint {
    static func main() async throws {
        let arguments = CommandLine.arguments

        if Self.shouldPrintUsage(arguments: arguments) {
            let console = Terminal()
            Self.printUsage(to: console)

            let manager = try LumenServiceManager(console: console)
            try manager.run(action: .status)
            return
        }

        if Self.shouldRunInstaller(arguments: arguments) {
            let installerOptions = InstallerOptions.from(arguments: arguments)
            let installer = try LumenInstaller(console: Terminal(), options: installerOptions)
            try installer.run()
            return
        }

        if Self.shouldRunUninstaller(arguments: arguments) {
            let uninstaller = try LumenUninstaller(console: Terminal())
            try uninstaller.run()
            return
        }

        if let lifecycleAction = Self.lifecycleAction(arguments: arguments) {
            let manager = try LumenServiceManager(console: Terminal())
            try manager.run(action: lifecycleAction)
            return
        }

        var env = try Environment.detect(arguments: arguments)
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        do {
            try configure(app)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }

        try await app.execute()
        try await app.asyncShutdown()
    }

    private static func shouldPrintUsage(arguments: [String]) -> Bool {
        arguments.count == 1
    }

    private static func printUsage(to console: Console) {
        console.print("")
        console.printHeader("Lumen v\(lumenVersion)")
        console.printNote("Lumen runs as an installed service. Use one of these commands:")
        console.print("")
        console.printCommand("lumen install")
        console.printCommand("lumen start")
        console.printCommand("lumen stop")
        console.printCommand("lumen restart")
        console.printCommand("lumen status")
        console.printCommand("lumen uninstall")
    }

    private static func shouldRunInstaller(arguments: [String]) -> Bool {
        guard arguments.count >= 2 else { return false }
        return arguments[1] == "install" || arguments.contains("--install")
    }

    private static func shouldRunUninstaller(arguments: [String]) -> Bool {
        guard arguments.count >= 2 else { return false }
        return arguments[1] == "uninstall" || arguments.contains("--uninstall")
    }

    private static func lifecycleAction(arguments: [String]) -> LumenServiceAction? {
        guard arguments.count >= 2 else { return nil }

        return switch arguments[1] {
        case "start": .start
        case "stop": .stop
        case "restart": .restart
        case "status": .status
        default: nil
        }
    }
}

// MARK: - InstallerOptions

struct InstallerOptions {
    let allowSudoRequested: Bool

    static func from(arguments: [String]) -> InstallerOptions {
        let normalizedArguments = arguments.dropFirst().filter {
            $0 != "install" && $0 != "--install"
        }

        let allowSudoRequested = normalizedArguments.contains("--allow-sudo")

        return InstallerOptions(
            allowSudoRequested: allowSudoRequested,
        )
    }
}

// MARK: - Configuration

func configure(_ app: Application) throws {
    let port = Int(Environment.get("LUMEN_PORT") ?? "9069") ?? 9069
    app.http.server.configuration.port = port
    app.http.server.configuration.hostname = "0.0.0.0"

    try routes(app)

    app.logger.info("Lumen configured on port \(port)")
}

// MARK: - Routes

func routes(_ app: Application) throws {
    // Unprotected — just confirms the server is reachable
    app.get("health") { _ in HealthResponse.current }

    // Authenticated routes — require a valid bearer token
    let protected = app.grouped(APIKeyMiddleware())
    protected.get("info") { _ in InfoResponse.current }
    try protected.register(collection: ExecController())
    try protected.register(collection: FileController())
}
