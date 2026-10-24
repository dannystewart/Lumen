import Foundation
import Vapor
#if os(macOS)
    import AppKit
    import AsyncHTTPClient
#endif

// MARK: - SurferStatus

struct SurferStatus: Content {
    let installed: Bool
    let running: Bool
    let credentialStored: Bool
    /// A saved credential is not proof that Surfer still authorizes it.
    let authorization: String
}

#if os(macOS)
    /// A fixed integration, not a general-purpose MCP registry or HTTP proxy.
    enum SurferIntegration {
        private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }

        static let bundleID = "com.dannystewart.Surfer"
        static let origin = "http://127.0.0.1:48321"

        @MainActor
        static var applicationURL: URL? {
            NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID).first?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: self.bundleID)
        }

        @MainActor
        static var isRunning: Bool {
            !NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID).isEmpty
        }

        static func status() async -> SurferStatus {
            let installed = await self.applicationURL != nil
            let running = await self.isRunning
            let token = try? SurferCredentialStore.read()
            var authorization = token == nil ? "not_paired" : "unknown"
            if running, let token {
                if let (data, response) = try? await self.request(path: "/connect/status", token: token, timeout: 2) {
                    if
                        response.statusCode == 200,
                        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
                        let authorized = body["authorized"]
                    {
                        authorization = authorized ? "authorized" : "disconnected"
                    } else if response.statusCode == 401 {
                        authorization = "not_paired"
                    } else if response.statusCode == 403 {
                        authorization = "disabled"
                    }
                }
            }
            return .init(installed: installed, running: running, credentialStored: token != nil, authorization: authorization)
        }

        static func printStatus(to console: Console) async {
            let status = await self.status()
            console.printSection("Surfer")
            console.printLabelValue("Installed", value: status.installed ? "yes" : "no")
            console.printLabelValue("Running", value: status.running ? "yes" : "no")
            console.printLabelValue("Credential stored", value: status.credentialStored ? "yes" : "no")
            console.printLabelValue("Authorization", value: status.authorization)
            console.print("")
        }

        @MainActor
        static func open(_ urls: [URL] = []) async throws {
            guard let applicationURL = self.applicationURL else {
                throw Abort(.notFound, reason: "Surfer is not installed on this Mac.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = !urls.isEmpty
            do {
                if urls.isEmpty {
                    _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
                } else {
                    _ = try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration)
                }
            } catch {
                throw Abort(.serviceUnavailable, reason: "Surfer could not be opened in this user's desktop session.")
            }
        }

        static func ensureRunning(token: String, requireAuthorized: Bool = true) async throws {
            if await !(self.isRunning) { try await self.open() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            repeat {
                try Task.checkCancellation()
                if let (data, response) = try? await self.request(path: "/connect/status", token: token, timeout: 2) {
                    let authorized = (try? JSONSerialization.jsonObject(with: data) as? [String: Bool])?["authorized"] == true
                    guard response.statusCode == 200, !requireAuthorized || authorized else {
                        throw Abort(.forbidden, reason: "Surfer authorization is disabled, disconnected, or expired. Reconnect locally with lumen connect surfer; remote requests cannot reauthorize it.")
                    }
                    return
                }
                try await Task.sleep(for: .milliseconds(200))
            } while ContinuousClock.now < deadline
            throw Abort(.serviceUnavailable, reason: "Surfer's automation server is unavailable. Check automation settings on the Mac; it will not be enabled automatically.")
        }

        static func request(path: String, method: String = "GET", token: String? = nil, body: Data? = nil, timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
            // This helper is private to fixed integration paths. Never accept a remote target URL.
            guard
                ["/connect/status", "/connect/token", "/connect/disconnect"].contains(path),
                let url = URL(string: self.origin + path) else { throw Abort(.internalServerError) }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.httpBody = body
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count <= 8192 else { throw Abort(.badGateway) }
            return (data, http)
        }
    }

    struct SurferController: RouteCollection {
        func boot(routes: RoutesBuilder) throws {
            let integration = routes.grouped("integrations", "surfer")
            integration.get("status") { _ in await SurferIntegration.status() }
            integration.post("connect") { _ async throws -> SurferStatus in
                guard let token = try SurferCredentialStore.read() else {
                    throw Abort(.preconditionFailed, reason: "Pair locally on the Mac with lumen connect surfer first.")
                }
                try await SurferIntegration.ensureRunning(token: token)
                return await SurferIntegration.status()
            }
            for method in [HTTPMethod.POST, .GET, .DELETE] {
                integration.on(method, "mcp", body: .collect(maxSize: "8mb"), use: self.relay)
            }
        }

        @Sendable
        private func relay(req: Request) async throws -> Response {
            guard req.headers.first(name: "Origin") == nil else {
                throw Abort(.forbidden, reason: "Browser origins are not allowed.")
            }
            guard let token = try SurferCredentialStore.read() else {
                throw Abort(.preconditionFailed, reason: "Pair locally on the Mac with lumen connect surfer first.")
            }
            // Only an explicit connect or an MCP request can launch the app, never discovery.
            try await SurferIntegration.ensureRunning(token: token)
            var upstream = HTTPClientRequest(url: SurferIntegration.origin + "/mcp")
            upstream.method = req.method
            upstream.headers.add(name: "Authorization", value: "Bearer \(token)")
            // Do not forward Host, cookies, API credentials, proxy headers, or arbitrary headers.
            for name in ["Accept", "Content-Type", "Mcp-Session-Id", "MCP-Protocol-Version"] {
                if let value = req.headers.first(name: name) { upstream.headers.add(name: name, value: value) }
            }
            if let body = req.body.data { upstream.body = .bytes(body) }
            do {
                let result = try await req.application.http.client.shared.execute(upstream, timeout: .seconds(600))
                // Surfer's current stateless transport returns bounded JSON, not SSE/replay
                // streams. Fail explicitly if that contract changes rather than buffering an
                // endless stream.
                guard result.headers.contentType?.type != "text" || result.headers.contentType?.subType != "event-stream" else {
                    throw Abort(.badGateway, reason: "This relay requires Surfer's JSON MCP transport.")
                }
                let body = try await result.body.collect(upTo: 50 * 1024 * 1024)
                var headers = HTTPHeaders()
                for name in ["Content-Type", "Mcp-Session-Id", "MCP-Protocol-Version", "Allow", "Retry-After"] {
                    if let value = result.headers.first(name: name) { headers.add(name: name, value: value) }
                }
                headers.add(name: "Cache-Control", value: "no-store")
                return Response(status: result.status, headers: headers, body: .init(buffer: body))
            } catch let error as Abort { throw error }
            catch {
                // Never log request/response content or replay an action after a transport failure.
                throw Abort(.badGateway, reason: "Surfer's response was interrupted. An action may have executed; inspect before retrying.")
            }
        }
    }
#endif // os(macOS)
