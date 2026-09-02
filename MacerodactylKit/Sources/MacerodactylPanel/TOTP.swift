import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// RFC 6238 time-based one-time passwords (what authenticator apps generate).
/// HMAC-SHA1, 6 digits, 30-second period — the near-universal defaults, so any
/// standard authenticator works. Implemented directly on the crypto we already
/// depend on (no extra dependency), and cross-platform (CryptoKit / swift-crypto).
public enum TOTP {
    public static let digits = 6
    public static let period = 30

    /// A fresh random secret (20 bytes = 160 bits, the RFC-recommended size),
    /// base32-encoded for authenticator apps.
    public static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base32Encode(bytes)
    }

    /// The `otpauth://` URI an authenticator imports (typically via QR). `account`
    /// is shown to the user; `issuer` labels which service it's for.
    public static func provisioningURI(secret: String, account: String, issuer: String = "Macerodactyl") -> String {
        let label = "\(issuer):\(account)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account
        let iss = issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer
        return "otpauth://totp/\(label)?secret=\(secret)&issuer=\(iss)&algorithm=SHA1&digits=\(digits)&period=\(period)"
    }

    /// The code for a given secret at a given time (default now).
    public static func code(secret: String, at date: Date = Date()) -> String? {
        guard let key = base32Decode(secret) else { return nil }
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(period))
        return code(key: key, counter: counter)
    }

    /// Verifies a user-entered code against the secret, allowing a ±`window`
    /// step of clock drift (the standard tolerance). Comparison is length-then-
    /// constant-time to avoid leaking via timing.
    public static func verify(_ input: String, secret: String, at date: Date = Date(), window: Int = 1) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == digits, let key = base32Decode(secret) else { return false }
        let base = Int64(max(0, date.timeIntervalSince1970) / Double(period))
        for offset in -window...window {
            let counter = base + Int64(offset)
            guard counter >= 0 else { continue }
            if constantTimeEquals(code(key: key, counter: UInt64(counter)), trimmed) { return true }
        }
        return false
    }

    // MARK: internals

    private static func code(key: [UInt8], counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let counterBytes = withUnsafeBytes(of: &bigEndian) { Array($0) }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterBytes, using: SymmetricKey(data: key))
        let hash = Array(mac)
        let offset = Int(hash[hash.count - 1] & 0x0f)
        let binary =
            (UInt32(hash[offset] & 0x7f) << 24) | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8) | UInt32(hash[offset + 3])
        let otp = binary % UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)u", otp)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32Encode(_ data: [UInt8]) -> String {
        var output = ""
        var buffer = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1f
                bitsLeft -= 5
                output.append(base32Alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1f
            output.append(base32Alphabet[index])
        }
        return output
    }

    static func base32Decode(_ string: String) -> [UInt8]? {
        var lookup = [Character: Int]()
        for (i, c) in base32Alphabet.enumerated() { lookup[c] = i }
        var buffer = 0
        var bitsLeft = 0
        var bytes = [UInt8]()
        for raw in string.uppercased() where raw != "=" && !raw.isWhitespace {
            guard let value = lookup[raw] else { return nil }
            buffer = (buffer << 5) | value
            bitsLeft += 5
            if bitsLeft >= 8 {
                bytes.append(UInt8((buffer >> (bitsLeft - 8)) & 0xff))
                bitsLeft -= 8
            }
        }
        return bytes.isEmpty ? nil : bytes
    }
}
