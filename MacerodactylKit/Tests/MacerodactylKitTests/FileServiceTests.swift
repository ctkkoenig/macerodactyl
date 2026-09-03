import Foundation
import Testing

@testable import MacerodactylKit

/// The Phase 1 suites proved PathConfinement in isolation; these prove the
/// LIVE file layer enforces the same boundary — every traversal shape is
/// re-run against real FileService reads and writes on disk.
@Suite struct FileServiceTests {
    private struct Fixture {
        let stacksRoot: URL
        let stackDir: URL
        let outside: URL
        let service: FileService
        let cleanup: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "fsvc-\(UUID().uuidString)")
        let stacksRoot = base.appending(path: "stacks")
        let stackDir = stacksRoot.appending(path: "web")
        let outside = base.appending(path: "secret")
        try fm.createDirectory(at: stackDir.appending(path: "config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("top secret".utf8).write(to: outside.appending(path: "creds.txt"))
        try Data("services:\n  nginx:\n    image: nginx\n".utf8)
            .write(to: stackDir.appending(path: "docker-compose.yml"))
        try Data("server {}\n".utf8).write(to: stackDir.appending(path: "config/nginx.conf"))
        try Data("KEY=value\n".utf8).write(to: stackDir.appending(path: ".env"))

        let container = DockerContainer(
            id: "c1", name: "web-nginx-1", image: "nginx", state: .running, status: "Up",
            health: nil, ports: "", composeProject: "web", composeService: "nginx",
            composeWorkingDir: stackDir.path
        )
        let service = try #require(FileService(container: container, stacksRoot: stacksRoot))
        return Fixture(
            stacksRoot: stacksRoot, stackDir: stackDir, outside: outside,
            service: service, cleanup: { try? fm.removeItem(at: base) })
    }

    // MARK: Availability gate

    @Test func compressAndDecompressRoundTrips() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        // Archive the config folder, delete it, extract into a new dir.
        try await fx.service.compress(["config"], to: "snapshot.tar.gz")
        #expect(FileManager.default.fileExists(atPath: fx.stackDir.appending(path: "snapshot.tar.gz").path))
        try fx.service.delete("config")
        try await fx.service.decompress("snapshot.tar.gz", into: "restored")
        let restored = try fx.service.read("restored/config/nginx.conf")
        #expect(restored.text.contains("server"))
    }

    @Test func compressRefusesTraversalSource() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        await #expect(throws: (any Error).self) {
            try await fx.service.compress(["../../etc/passwd"], to: "grab.tar.gz")
        }
    }

    @Test func pullRejectsNonHTTPAndTraversalBeforeAnyDownload() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        // Non-http scheme is refused (never touches the network).
        await #expect(throws: FileServiceError.invalidPath) {
            try await fx.service.pull(from: "file:///etc/passwd", to: "grabbed.txt")
        }
        // A traversal destination is refused by confinement.
        await #expect(throws: (any Error).self) {
            try await fx.service.pull(from: "https://example.com/x", to: "../escape.txt")
        }
    }

    @Test func unmanagedContainerGetsNoService() {
        let bare = DockerContainer(
            id: "b", name: "fixture-bare", image: "alpine", state: .running, status: "Up",
            health: nil, ports: "", composeProject: nil, composeService: nil, composeWorkingDir: nil
        )
        #expect(FileService(container: bare, stacksRoot: URL(fileURLWithPath: "/tmp/stacks")) == nil)
    }

    @Test func workingDirOutsideStacksRootGetsNoService() {
        let elsewhere = DockerContainer(
            id: "e", name: "app", image: "app", state: .running, status: "Up",
            health: nil, ports: "", composeProject: "app", composeService: "app",
            composeWorkingDir: "/opt/elsewhere/app"
        )
        #expect(FileService(container: elsewhere, stacksRoot: URL(fileURLWithPath: "/tmp/stacks")) == nil)
    }

    // MARK: Round trip

    @Test func listReadWriteRoundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        let rootEntries = try service.list()
        #expect(rootEntries.map(\.name) == ["config", ".env", "docker-compose.yml"])
        #expect(rootEntries.first?.isDirectory == true)

        let nested = try service.list("config")
        #expect(nested.map(\.relativePath) == ["config/nginx.conf"])

        let content = try service.read("docker-compose.yml")
        #expect(content.text.contains("image: nginx"))
        #expect(content.lineEnding == .lf)

        try service.write("docker-compose.yml", text: content.text + "    restart: unless-stopped\n", lineEnding: content.lineEnding)
        #expect(try service.read("docker-compose.yml").text.hasSuffix("restart: unless-stopped\n"))

        // New file in an existing directory.
        try service.write("config/extra.conf", text: "x", lineEnding: .lf)
        #expect(try service.read("config/extra.conf").text == "x")
    }

    // MARK: Confinement at the live layer

    @Test func traversalShapesAreRejectedOnReadAndWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        let escapes = ["../secret/creds.txt", "config/../../secret/creds.txt", "%2e%2e/secret/creds.txt", "..%2fsecret/creds.txt"]
        for path in escapes {
            #expect(throws: FileServiceError.escapesRoot) { _ = try service.read(path) }
            #expect(throws: FileServiceError.escapesRoot) { try service.write(path, text: "x", lineEnding: .lf) }
        }
        for path in ["/etc/passwd", "~/anything", "config\0/nginx.conf"] {
            #expect(throws: FileServiceError.invalidPath) { _ = try service.read(path) }
            #expect(throws: FileServiceError.invalidPath) { try service.write(path, text: "x", lineEnding: .lf) }
        }
        #expect(throws: FileServiceError.escapesRoot) { _ = try service.list("..") }

        // Nothing outside actually changed.
        #expect(try Data(contentsOf: fixture.outside.appending(path: "creds.txt")) == Data("top secret".utf8))
    }

    @Test func symlinkEscapesAreRejectedOnReadAndWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default

        try fm.createSymbolicLink(
            at: fixture.stackDir.appending(path: "sneaky"),
            withDestinationURL: fixture.outside
        )
        #expect(throws: FileServiceError.escapesRoot) { _ = try fixture.service.read("sneaky/creds.txt") }
        #expect(throws: FileServiceError.escapesRoot) { _ = try fixture.service.list("sneaky") }
        #expect(throws: FileServiceError.escapesRoot) {
            try fixture.service.write("sneaky/injected.txt", text: "x", lineEnding: .lf)
        }

        // Dangling symlink leaf pointing outside: a write through it would
        // create a file outside the root.
        try fm.createSymbolicLink(
            at: fixture.stackDir.appending(path: "dangling"),
            withDestinationURL: fixture.outside.appending(path: "not-yet.txt")
        )
        #expect(throws: FileServiceError.escapesRoot) {
            try fixture.service.write("dangling", text: "x", lineEnding: .lf)
        }
        #expect(!fm.fileExists(atPath: fixture.outside.appending(path: "not-yet.txt").path))
    }

    // MARK: Boring cases done properly

    @Test func sizeLimitIsEnforcedBeforeReading() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let big = Data(repeating: UInt8(ascii: "a"), count: FileService.maxEditableBytes + 1)
        try big.write(to: fixture.stackDir.appending(path: "big.log"))
        #expect(
            throws: FileServiceError.tooLarge(
                actualBytes: FileService.maxEditableBytes + 1,
                limitBytes: FileService.maxEditableBytes
            )
        ) {
            _ = try fixture.service.read("big.log")
        }
    }

    @Test func binaryFilesAreRefused() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // NUL bytes (jar/image shape)…
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x01]).write(to: fixture.stackDir.appending(path: "plugin.jar"))
        #expect(throws: FileServiceError.binaryFile) { _ = try fixture.service.read("plugin.jar") }
        // …and NUL-free but not valid UTF-8.
        try Data([0xFF, 0xFE, 0xC0, 0xC1]).write(to: fixture.stackDir.appending(path: "weird.bin"))
        #expect(throws: FileServiceError.binaryFile) { _ = try fixture.service.read("weird.bin") }
    }

    @Test func crlfLineEndingsSurviveEditing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try Data("line one\r\nline two\r\n".utf8).write(to: fixture.stackDir.appending(path: "win.ini"))

        let content = try fixture.service.read("win.ini")
        #expect(content.lineEnding == .crlf)
        #expect(content.text == "line one\nline two\n")  // normalized for the editor

        try fixture.service.write("win.ini", text: content.text + "line three\n", lineEnding: content.lineEnding)
        let raw = try Data(contentsOf: fixture.stackDir.appending(path: "win.ini"))
        #expect(String(decoding: raw, as: UTF8.self) == "line one\r\nline two\r\nline three\r\n")
    }

    @Test func atomicWriteLeavesNoTempDroppings() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.service.write("docker-compose.yml", text: "replaced\n", lineEnding: .lf)
        #expect(try fixture.service.read("docker-compose.yml").text == "replaced\n")
        let leftovers = try fixture.service.list().filter { $0.name.contains("mcdtmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func modificationDateSupportsExternalChangeDetection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let before = try #require(fixture.service.modificationDate("docker-compose.yml"))
        Thread.sleep(forTimeInterval: 0.05)
        try Data("changed externally\n".utf8).write(to: fixture.stackDir.appending(path: "docker-compose.yml"))
        let after = try #require(fixture.service.modificationDate("docker-compose.yml"))
        #expect(after > before)
    }

    // MARK: mkdir / rename / delete / upload / download (T2.3)

    @Test func makeDirectoryCreatesNestedAndIsIdempotentOnDir() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.service.makeDirectory("data/worlds")
        #expect(try fixture.service.list().map(\.name).contains("data"))
        #expect(try fixture.service.list("data").map(\.name) == ["worlds"])
        // An existing directory is fine; an existing file at the path is not.
        try fixture.service.makeDirectory("data/worlds")
        #expect(throws: FileServiceError.notARegularFile) { try fixture.service.makeDirectory(".env") }
    }

    @Test func renameMovesWithinTreeAndWontClobber() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.service.move(from: "docker-compose.yml", to: "compose.yaml")
        #expect(try fixture.service.list().map(\.name).contains("compose.yaml"))
        #expect(!(try fixture.service.list().map(\.name).contains("docker-compose.yml")))
        // Won't overwrite an existing destination.
        #expect(throws: (any Error).self) { try fixture.service.move(from: "compose.yaml", to: ".env") }
        #expect(throws: FileServiceError.notFound) { try fixture.service.move(from: "nope.txt", to: "x.txt") }
    }

    @Test func deleteRemovesFileAndDirectoryButNotRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.service.delete(".env")
        #expect(!(try fixture.service.list().map(\.name).contains(".env")))
        try fixture.service.delete("config")  // recursive
        #expect(!(try fixture.service.list().map(\.name).contains("config")))
        // The root itself cannot be deleted.
        #expect(throws: FileServiceError.invalidPath) { try fixture.service.delete("") }
        #expect(throws: FileServiceError.notFound) { try fixture.service.delete("gone.txt") }
    }

    @Test func uploadWritesBinaryAndDownloadReadsItBack() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0xFE])  // NUL + non-UTF8 (a jar shape)
        try fixture.service.writeData("plugins/plugin.jar", data: bytes)
        let target = try fixture.service.downloadTarget("plugins/plugin.jar")
        #expect(target.size == bytes.count)
        #expect(try Data(contentsOf: target.url) == bytes)
        // Download refuses a directory.
        #expect(throws: FileServiceError.isDirectory) { _ = try fixture.service.downloadTarget("plugins") }
    }

    @Test func uploadRefusesOversizePayload() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let big = Data(count: FileService.maxUploadBytes + 1)
        #expect(throws: FileServiceError.tooLarge(actualBytes: big.count, limitBytes: FileService.maxUploadBytes)) {
            try fixture.service.writeData("huge.bin", data: big)
        }
    }

    @Test func newOperationsRejectEveryTraversalShape() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = fixture.service
        let escapes = ["../secret/x", "config/../../secret/x", "%2e%2e/secret/x", "..%2fsecret/x"]
        for path in escapes {
            #expect(throws: FileServiceError.escapesRoot) { try service.makeDirectory(path) }
            #expect(throws: FileServiceError.escapesRoot) { try service.writeData(path, data: Data("x".utf8)) }
            #expect(throws: FileServiceError.escapesRoot) { try service.delete(path) }
            #expect(throws: FileServiceError.escapesRoot) { _ = try service.downloadTarget(path) }
            // move is confined at BOTH ends.
            #expect(throws: FileServiceError.escapesRoot) { try service.move(from: ".env", to: path) }
            #expect(throws: FileServiceError.escapesRoot) { try service.move(from: path, to: "x") }
        }
        for path in ["/etc/passwd", "~/anything", "config\0/x"] {
            #expect(throws: FileServiceError.invalidPath) { try service.makeDirectory(path) }
            #expect(throws: FileServiceError.invalidPath) { try service.delete(path) }
        }
        // A rename cannot escape via a symlinked destination parent either.
        let fm = FileManager.default
        try fm.createSymbolicLink(
            at: fixture.stackDir.appending(path: "out"), withDestinationURL: fixture.outside)
        #expect(throws: FileServiceError.escapesRoot) { try service.move(from: ".env", to: "out/stolen.env") }
        // Nothing outside actually changed.
        #expect(fm.fileExists(atPath: fixture.outside.appending(path: "creds.txt").path))
        #expect(!fm.fileExists(atPath: fixture.outside.appending(path: "stolen.env").path))
    }
}
