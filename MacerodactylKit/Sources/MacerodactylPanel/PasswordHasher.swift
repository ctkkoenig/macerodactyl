import CryptoKit
import Foundation
import HummingbirdBcrypt

/// Bcrypt password hashing at cost factor 12. Two things worth stating:
///
/// - **72-byte truncation:** bcrypt only reads the first 72 bytes of its input,
///   silently ignoring the rest, so a long passphrase's tail wouldn't count.
///   We pre-hash the password with SHA-256 and base64-encode it (44 bytes,
///   well under 72) before bcrypt, so the entire password contributes.
/// - **Off the event loop:** bcrypt at cost 12 is deliberately slow (~0.25s)
///   and CPU-bound. Running it on the server's cooperative executor would
///   stall other requests, so it's offloaded to a background thread.
public enum PasswordHasher {
    public static let cost: UInt8 = 12

    public static func hash(_ password: String) async -> String {
        let prepared = prepared(password)
        return await offThread { Bcrypt.hash(prepared, cost: cost) }
    }

    public static func verify(_ password: String, hash: String) async -> Bool {
        let prepared = prepared(password)
        return await offThread { Bcrypt.verify(prepared, hash: hash) }
    }

    /// SHA-256 → base64 so passwords longer than 72 bytes aren't truncated.
    static func prepared(_ password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return Data(digest).base64EncodedString()
    }

    static func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
