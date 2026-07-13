@testable import Lumen
import Testing

@Suite("LumenUpdater")
struct LumenUpdaterTests {
    @Test
    func `Parses stable release tags`() throws {
        let version = try SemanticVersion(tag: "v12.34.56")

        #expect(version.major == 12)
        #expect(version.minor == 34)
        #expect(version.patch == 56)
    }

    @Test
    func `Compares each semantic version component numerically`() throws {
        #expect(try SemanticVersion("1.10.0") > SemanticVersion("1.9.9"))
        #expect(try SemanticVersion("2.0.0") > SemanticVersion("1.99.99"))
        #expect(try SemanticVersion("1.0.1") > SemanticVersion("1.0.0"))
    }

    @Test(arguments: ["1.2", "1.2.3.4", "1.2.beta", "v1.2.3", "1.-2.3"])
    func `Rejects invalid versions`(_ value: String) {
        #expect(throws: (any Error).self) {
            try SemanticVersion(value)
        }
    }

    @Test(arguments: ["1.2.3", "v1.2", "v1.2.3-beta"])
    func `Rejects invalid release tags`(_ value: String) {
        #expect(throws: (any Error).self) {
            try SemanticVersion(tag: value)
        }
    }
}
