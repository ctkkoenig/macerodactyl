import Foundation
import Testing

@testable import MacerodactylPanel

@Suite struct TOTPTests {
    // RFC 6238 test secret "12345678901234567890" (ASCII), base32-encoded.
    let rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    @Test func base32RoundTrips() throws {
        let bytes = Array("12345678901234567890".utf8)
        #expect(TOTP.base32Encode(bytes) == rfcSecret)
        #expect(TOTP.base32Decode(rfcSecret) == bytes)
        #expect(TOTP.base32Decode("!!!!") == nil)  // invalid alphabet
    }

    @Test func matchesRFC6238Vectors() {
        // RFC 6238 SHA-1 8-digit vectors; we emit 6 digits = the last six.
        // T=59 → 94287082 → 287082 ; T=1111111109 → 07081804 → 081804.
        #expect(TOTP.code(secret: rfcSecret, at: Date(timeIntervalSince1970: 59)) == "287082")
        #expect(TOTP.code(secret: rfcSecret, at: Date(timeIntervalSince1970: 1_111_111_109)) == "081804")
        #expect(TOTP.code(secret: rfcSecret, at: Date(timeIntervalSince1970: 1_234_567_890)) == "005924")
    }

    @Test func verifyAcceptsCurrentRejectsWrongAndHonorsWindow() {
        let now = Date(timeIntervalSince1970: 1_111_111_109)
        let current = TOTP.code(secret: rfcSecret, at: now)!
        #expect(TOTP.verify(current, secret: rfcSecret, at: now))
        #expect(!TOTP.verify("000000", secret: rfcSecret, at: now))
        #expect(!TOTP.verify("12345", secret: rfcSecret, at: now))  // wrong length
        // A code from one step ago is accepted within the ±1 window…
        let prev = TOTP.code(secret: rfcSecret, at: now.addingTimeInterval(-30))!
        #expect(TOTP.verify(prev, secret: rfcSecret, at: now))
        // …but not one from three steps ago.
        let old = TOTP.code(secret: rfcSecret, at: now.addingTimeInterval(-90))!
        #expect(!TOTP.verify(old, secret: rfcSecret, at: now))
    }

    @Test func generatedSecretsAreUsableAndDistinct() {
        let a = TOTP.generateSecret(), b = TOTP.generateSecret()
        #expect(a != b)
        #expect(TOTP.base32Decode(a) != nil)
        let code = TOTP.code(secret: a)!
        #expect(TOTP.verify(code, secret: a))
    }

    @Test func provisioningURIIsWellFormed() {
        let uri = TOTP.provisioningURI(secret: rfcSecret, account: "alice", issuer: "Macerodactyl")
        #expect(uri.hasPrefix("otpauth://totp/"))
        #expect(uri.contains("secret=\(rfcSecret)"))
        #expect(uri.contains("issuer=Macerodactyl"))
        #expect(uri.contains("digits=6"))
        #expect(uri.contains("period=30"))
    }
}
