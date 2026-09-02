import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct SelfSignedCertificateTests {
    @Test func generatesValidPEMCertAndKeyWith0600Key() throws {
        guard SelfSignedCertificate.opensslPath() != nil else {
            // openssl should exist on macOS; if not, skip rather than fail CI.
            return
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SelfSignedCertificate.Paths(
            certificate: dir.appending(path: "c.pem").path,
            privateKey: dir.appending(path: "k.pem").path)

        let result = try SelfSignedCertificate.generate(into: paths)
        let cert = try String(contentsOfFile: result.certificate, encoding: .utf8)
        let key = try String(contentsOfFile: result.privateKey, encoding: .utf8)
        #expect(cert.contains("-----BEGIN CERTIFICATE-----"))
        #expect(key.contains("-----BEGIN PRIVATE KEY-----") || key.contains("-----BEGIN RSA PRIVATE KEY-----"))

        // Private key must not be world/group readable.
        let perms = try FileManager.default.attributesOfItem(atPath: result.privateKey)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}
