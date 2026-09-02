import Foundation
import Testing

@testable import MacerodactylKit

/// Fuzz harnesses (T6.2): throw large volumes of random and adversarially-shaped
/// input at the two security-critical surfaces — path confinement and the
/// docker output parsers — and assert the invariants hold: confinement never
/// escapes its root and nothing ever crashes/traps on garbage.
///
/// A deterministic RNG (seeded SplitMix64) keeps failures reproducible: a failing
/// seed can be pinned and replayed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct PathConfinementFuzzTests {
    /// Tokens an attacker would combine to try to escape a confinement root.
    private let tokens = [
        "..", "../", "..\\", "%2e%2e", "%2e%2e%2f", "..%2f", "..%5c", "/", "\\", "~", "~root",
        ".", "//", "....//", "%2e", "\u{0}", "a", "b", "config", "secret", "etc", "passwd",
        "%00", " ", "\t", "\n", ".%2e", "..;", "C:", "\u{202e}", "\u{ff0e}\u{ff0e}", "….", "//..//",
    ]

    private func randomPath(_ rng: inout SplitMix64) -> String {
        let parts = Int.random(in: 0...8, using: &rng)
        var s = ""
        for _ in 0..<parts {
            if Bool.random(using: &rng) {
                s += tokens[Int.random(in: 0..<tokens.count, using: &rng)]
            } else {
                // A run of random scalars, including some that aren't valid on their own.
                let n = Int.random(in: 0...6, using: &rng)
                for _ in 0..<n {
                    let v = UInt32.random(in: 0...0x2FFF, using: &rng)
                    if let scalar = Unicode.Scalar(v) { s.unicodeScalars.append(scalar) }
                }
            }
            if Bool.random(using: &rng) { s += "/" }
        }
        return s
    }

    @Test func confinementNeverEscapesAndNeverCrashes() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "fuzz-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        try fm.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "creds"))
        defer { try? fm.removeItem(at: base) }
        let resolvedRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().standardizedFileURL

        var rng = SplitMix64(seed: 0xDEAD_BEEF_CAFE)
        for _ in 0..<20_000 {
            let path = randomPath(&rng)
            do {
                let url = try PathConfinement.resolve(path, in: root)
                // The ONLY acceptable non-throwing outcome: a URL inside the root.
                let ok =
                    url.standardizedFileURL.path == resolvedRoot.path
                    || PathConfinement.isDescendant(url.standardizedFileURL.path, of: resolvedRoot.path)
                #expect(ok, "resolve escaped the root for input \(String(reflecting: path)) -> \(url.path)")
            } catch is PathConfinementError {
                // Rejected — the expected outcome for anything dangerous.
            }
        }
        // The out-of-root secret was never touched by any of this (read-only anyway).
        #expect(try Data(contentsOf: outside.appending(path: "creds")) == Data("secret".utf8))
    }
}

@Suite struct ParserFuzzTests {
    private func randomString(_ rng: inout SplitMix64, maxLen: Int) -> String {
        let n = Int.random(in: 0...maxLen, using: &rng)
        var s = ""
        for _ in 0..<n {
            // Bias toward JSON/stats punctuation to exercise the real code paths.
            let palette = "{}[]\":,.% /BKMGiBμ\t\n0123456789abcxyz-↓↑\u{0}"
            let idx = Int.random(in: 0..<palette.count, using: &rng)
            s.append(Array(palette)[idx])
        }
        return s
    }

    @Test func parsersNeverCrashOnGarbage() {
        var rng = SplitMix64(seed: 0x1234_5678_9ABC)
        for _ in 0..<10_000 {
            let g = randomString(&rng, maxLen: 120)
            // None of these may trap on arbitrary input — they return best-effort.
            _ = DockerPSParser.parse(g)
            _ = DockerPSParser.parseHealth(fromStatus: g)
            _ = DockerPSParser.parseLabels(g)
            _ = DockerStatsParser.parse(line: g)
            _ = DockerStatsParser.parseSnapshot(g)
            _ = DockerStatsParser.parsePercent(g)
            _ = DockerStatsParser.parseBytes(g)
            _ = MinecraftRCON.parse(inspectJSON: Data(g.utf8))
        }
    }

    @Test func statsUnitParsersHandleAdversarialNumbers() {
        // Values shaped like docker's human units but hostile: overflow, negatives,
        // NaN-ish, empty, huge exponents — must not trap.
        let hostile = [
            "", " ", "%", "1e999%", "-5%", "NaN%", "Infinity%", "999999999999999999999%",
            "1.2.3MiB", "MiB", "1e400GiB", "-1kB", "0B", "  12.5  MiB  ", "1,234MB", "٠٠kB",
        ]
        for value in hostile {
            _ = DockerStatsParser.parsePercent(value)
            _ = DockerStatsParser.parseBytes(value)
        }
    }
}
