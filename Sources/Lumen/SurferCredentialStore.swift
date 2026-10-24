#if os(macOS)
    import Foundation
    import Vapor

    /// Shared by CLI and service, read on every request so pairing/disconnect needs no restart.
    /// Private local files avoid Keychain ACLs tied to an ad-hoc CLI binary that updates itself.
    enum SurferCredentialStore {
        private static var directory: URL {
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/Lumen/Surfer", isDirectory: true)
        }

        private static var file: URL { self.directory.appendingPathComponent("credential") }

        static func read() throws -> String? {
            let manager = FileManager.default
            guard manager.fileExists(atPath: self.directory.path) else { return nil }
            try self.validate(self.directory, directory: true)
            guard manager.fileExists(atPath: self.file.path) else { return nil }
            try self.validate(self.file, directory: false)
            let data = try Data(contentsOf: self.file)
            guard
                data.count <= 256,
                let token = String(data: data, encoding: .utf8),
                !token.isEmpty else
            {
                throw Abort(.internalServerError, reason: "The local Surfer credential is invalid. Run lumen connect surfer again.")
            }
            return token
        }

        static func save(_ token: String) throws {
            let manager = FileManager.default
            try manager.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try self.validate(self.directory, directory: true)
            // Publish only a complete, already-private file. Concurrent service reads see either
            // the old credential or the new one, never a partially written token.
            let temporary = self.directory.appendingPathComponent(UUID().uuidString)
            guard manager.createFile(atPath: temporary.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw Abort(.internalServerError, reason: "The local Surfer credential could not be saved.")
            }
            defer { try? manager.removeItem(at: temporary) }
            guard rename(temporary.path, self.file.path) == 0 else {
                throw Abort(.internalServerError, reason: "The local Surfer credential could not be published.")
            }
        }

        static func delete() throws {
            guard try self.read() != nil else { return }
            try FileManager.default.removeItem(at: self.file)
        }

        private static func validate(_ url: URL, directory: Bool) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard
                attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
                (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                let permissions = attributes[.posixPermissions] as? NSNumber,
                permissions.intValue & 0o077 == 0 else
            {
                throw Abort(.forbidden, reason: "Surfer credential storage must be owned by this user, private, and not a symbolic link.")
            }
        }
    }
#endif // os(macOS)
