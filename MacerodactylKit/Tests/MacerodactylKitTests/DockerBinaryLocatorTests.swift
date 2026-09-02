import Foundation
import Testing
@testable import MacerodactylKit

@Suite struct DockerBinaryLocatorTests {
    private func makeExecutable(named name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func prefersOverrideThenCandidateOrder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "locator-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = try makeExecutable(named: "docker-a", in: dir)
        let second = try makeExecutable(named: "docker-b", in: dir)
        let missing = dir.appending(path: "nope")

        // Candidate order wins when there is no override.
        #expect(DockerBinaryLocator.resolve(candidates: [missing, first, second]) == first)
        // A valid override beats candidates.
        #expect(DockerBinaryLocator.resolve(override: second.path, candidates: [first]) == second)
        // An invalid override falls back to candidates instead of failing.
        #expect(DockerBinaryLocator.resolve(override: missing.path, candidates: [first]) == first)
        // Nothing anywhere → nil.
        #expect(DockerBinaryLocator.resolve(candidates: [missing]) == nil)
    }
}
