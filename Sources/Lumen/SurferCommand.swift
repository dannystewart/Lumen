import Foundation
import Vapor
#if os(macOS)
    import CryptoKit
    import Security
#endif

// MARK: - SurferCommand

enum SurferCommand {
    #if os(macOS)
        private struct Callback: Content {
            let state: String
            let code: String?
            let error: String?
        }

        private struct Token: Decodable {
            let access_token: String
            let token_type: String
            let mcp_endpoint: String
        }

        private actor Inbox {
            let state: String

            private var consumed = false
            private let stream: AsyncStream<Callback>
            private let continuation: AsyncStream<Callback>.Continuation

            init(state: String) {
                self.state = state
                (self.stream, self.continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            }

            func receive(_ callback: Callback) -> Bool {
                guard
                    callback.state == self.state,
                    !self.consumed,
                    callback.error != nil || callback.code?.utf8.count == 43 else { return false }
                self.consumed = true
                self.continuation.yield(callback)
                self.continuation.finish()
                return true
            }

            func wait() async throws -> Callback {
                for await callback in self.stream {
                    return callback
                }
                throw CancellationError()
            }
        }

        private static func connect(console: Console) async throws {
            guard await SurferIntegration.applicationURL != nil else {
                throw Abort(.notFound, reason: "Surfer is not installed on this Mac.")
            }
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw Abort(.internalServerError, reason: "A secure pairing request could not be created.")
            }
            let verifier = self.urlToken(Data(random))
            let state = UUID().uuidString
            let inbox = Inbox(state: state)
            let callbackApp = try await Application.make(.production)
            callbackApp.logger.logLevel = .critical
            callbackApp.http.server.configuration.hostname = "127.0.0.1"
            callbackApp.http.server.configuration.port = 0
            callbackApp.on(.POST, "surfer", "callback", body: .collect(maxSize: "2kb")) { req async throws -> HTTPStatus in
                guard
                    req.headers.first(name: "Origin") == nil,
                    let host = req.headers.first(name: "Host"),
                    host.hasPrefix("127.0.0.1:"),
                    let callback = try? req.content.decode(Callback.self),
                    await inbox.receive(callback) else { throw Abort(.badRequest) }
                return .noContent
            }
            do {
                try await callbackApp.server.start(address: .hostname("127.0.0.1", port: 0))
                guard let port = callbackApp.http.server.shared.localAddress?.port else { throw Abort(.internalServerError) }
                var url = URLComponents()
                url.scheme = "surfer"
                url.host = "automation"
                url.path = "/connect"
                url.queryItems = [
                    .init(name: "integration", value: "lumen"),
                    .init(name: "callback_port", value: String(port)),
                    .init(name: "state", value: state),
                    .init(name: "code_challenge", value: self.urlToken(Data(SHA256.hash(data: Data(verifier.utf8))))),
                    .init(name: "code_challenge_method", value: "S256"),
                ]
                guard let connectionURL = url.url else { throw Abort(.internalServerError) }
                console.printNote("Opening Surfer...")
                console.printNote("Click Allow when prompted to connect.")
                try await SurferIntegration.open([connectionURL])
                let callback = try await withThrowingTaskGroup(of: Callback.self) { group in
                    group.addTask { try await inbox.wait() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(300))
                        throw Abort(.requestTimeout, reason: "Pairing expired. Run lumen connect surfer again.")
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw CancellationError() }
                    return result
                }
                guard callback.error == nil, let code = callback.code else {
                    throw Abort(.forbidden, reason: callback.error == "access_denied" ? "Connection cancelled in Surfer." : "Surfer could not start its automation server.")
                }
                let body = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier])
                let (data, response) = try await SurferIntegration.request(path: "/connect/token", method: "POST", body: body)
                guard
                    response.statusCode == 200,
                    let token = try? JSONDecoder().decode(Token.self, from: data),
                    token.token_type == "Bearer",
                    token.mcp_endpoint == SurferIntegration.origin + "/mcp",
                    !token.access_token.isEmpty,
                    token.access_token.utf8.count <= 256 else
                {
                    throw Abort(.badGateway, reason: "The secure pairing exchange failed. Run lumen connect surfer again.")
                }
                // Verify authorization before reporting success; do not print credentials or
                // proofs.
                let (statusData, statusResponse) = try await SurferIntegration.request(path: "/connect/status", token: token.access_token)
                guard
                    statusResponse.statusCode == 200,
                    (try? JSONSerialization.jsonObject(with: statusData) as? [String: Bool])?["authorized"] == true else
                {
                    throw Abort(.forbidden, reason: "Surfer no longer authorizes this connection. Connect again locally.")
                }
                try SurferCredentialStore.save(token.access_token)
                console.printSuccess("Connected to Surfer!")
                try await callbackApp.asyncShutdown()
            } catch {
                try? await callbackApp.asyncShutdown()
                if let abort = error as? Abort { throw abort }
                throw Abort(.badGateway, reason: "Surfer pairing could not be completed. No credential or proof was printed. Try lumen connect surfer again.")
            }
        }

        private static func disconnect(console: Console) async throws {
            guard let token = try SurferCredentialStore.read() else {
                console.printNote("Lumen has no stored Surfer connection.")
                return
            }
            // Keep the credential on failure: deleting it alone would not revoke Surfer access.
            try await SurferIntegration.ensureRunning(token: token, requireAuthorized: false)
            let (_, response) = try await SurferIntegration.request(path: "/connect/disconnect", method: "POST", token: token)
            guard response.statusCode == 200 else {
                throw Abort(.serviceUnavailable, reason: "Surfer authorization could not be revoked. The local credential was retained. Disconnect Lumen in Surfer, or retry when its automation server is available.")
            }
            try SurferCredentialStore.delete()
            console.printSuccess("Disconnected from Surfer. Remote requests cannot reconnect it; run lumen connect surfer to approve again.")
        }

        private static func urlToken(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    #endif // os(macOS)

    static func run(action: String, console: Console) async throws {
        #if os(macOS)
            guard getuid() != 0 else {
                throw Abort(.forbidden, reason: "Run Surfer connection commands as your desktop user, without sudo.")
            }
            switch action {
            case "connect": try await self.connect(console: console)
            case "disconnect": try await self.disconnect(console: console)
            default: throw Abort(.badRequest, reason: "Use lumen connect surfer or lumen disconnect surfer.")
            }
        #else
            throw Abort(.notImplemented, reason: "The Surfer integration is available only on macOS.")
        #endif // os(macOS)
    }
}
