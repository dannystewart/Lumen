import Foundation
import Vapor

// MARK: - ExecRequest

struct ExecRequest: Content {
    var executionID: UUID?
    let command: String
    let workingDirectory: String?
    let environment: [String: String]?
    let timeout: Double?
}

// MARK: - ExecResponse

struct ExecResponse: Content {
    let stdout: String
    let stderr: String
    let exitCode: Int
    var cancelled: Bool = false
    var terminationConfirmed: Bool = true
}

// MARK: - ExecCancellationRequest

struct ExecCancellationRequest: Content {
    let executionID: UUID
}

// MARK: - ExecCancellationResponse

struct ExecCancellationResponse: Content {
    let executionID: UUID
    let state: String
}

// MARK: - HealthResponse

struct HealthResponse: Content {
    static var current: HealthResponse { HealthResponse(status: "ok") }

    let status: String
}

// MARK: - InfoResponse

/// Response from a Lumen node's authenticated `GET /info` endpoint. Contains server identity
/// information that should not be exposed publicly.
struct InfoResponse: Content {
    static var current: InfoResponse {
        InfoResponse(
            hostname: normalizedHostname,
            platform: currentPlatform,
            version: lumenVersion,
        )
    }

    private static var normalizedHostname: String {
        let rawHostname = ProcessInfo.processInfo.hostName
        let suffixes = [".local", ".lan", ".home"]

        for suffix in suffixes where rawHostname.lowercased().hasSuffix(suffix) {
            return String(rawHostname.dropLast(suffix.count))
        }

        return rawHostname
    }

    private static var currentPlatform: String {
        #if os(Linux)
            "linux"
        #elseif os(macOS)
            "macos"
        #else
            "unknown"
        #endif // os(Linux)
    }

    let hostname: String
    let platform: String
    let version: String
    var surfer: SurferStatus?
}
