import Foundation

/// Generates and locates a self-signed TLS certificate for the panel, so
/// enabling LAN access can encrypt the connection instead of shipping
/// credentials in plaintext. This is about **encryption, not authentication**:
/// browsers will warn about the self-signed cert (expected); the tunnel path
/// (real TLS terminated upstream) stays the recommended default.
///
/// Cert + key live in the support dir (`panel-cert.pem`, `panel-key.pem`, key
/// mode 0600). Generation shells out to `openssl`, resolved by explicit path
/// (GUI/daemon inherit no shell PATH).
public enum SelfSignedCertificate {
    public struct Paths: Sendable, Equatable {
        public let certificate: String
        public let privateKey: String
    }

    public enum CertError: Error, Equatable, Sendable {
        case opensslNotFound
        case generationFailed(String)
    }

    static func opensslPath(fileManager: FileManager = .default) -> String? {
        ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    public static func paths() throws -> Paths {
        let dir = try AppPaths.supportDirectory()
        return Paths(
            certificate: dir.appending(path: "panel-cert.pem").path,
            privateKey: dir.appending(path: "panel-key.pem").path)
    }

    /// Whether a usable cert + key already exist on disk.
    public static func exists() -> Bool {
        guard let paths = try? paths() else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.certificate) && fm.fileExists(atPath: paths.privateKey)
    }

    /// Returns the cert/key paths, generating a fresh self-signed pair if they
    /// don't already exist. Idempotent.
    @discardableResult
    public static func ensure() throws -> Paths {
        let paths = try paths()
        if exists() { return paths }
        return try generate(into: paths)
    }

    static func generate(into paths: Paths) throws -> Paths {
        guard let openssl = opensslPath() else { throw CertError.opensslNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", paths.privateKey, "-out", paths.certificate,
            "-days", "825", "-nodes",
            "-subj", "/CN=Macerodactyl Panel",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw CertError.generationFailed(String(describing: error)) }
        process.waitUntilExit()
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CertError.generationFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The private key must not be world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.privateKey)
        return paths
    }
}
