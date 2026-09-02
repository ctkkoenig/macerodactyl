import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct ComposeDetectionTests {
    let docker = URL(fileURLWithPath: "/opt/homebrew/bin/docker")

    @Test func prefersPluginWhenAvailable() {
        let command = ComposeCommand.detect(dockerBinary: docker, pluginWorks: { _ in true })
        #expect(command == .plugin(dockerBinary: docker))
        let (exe, args) = command!.invocation(["--project-directory", "/x", "up", "-d"])
        #expect(exe == docker)
        #expect(args == ["compose", "--project-directory", "/x", "up", "-d"])
    }

    @Test func fallsBackToStandaloneBesideDocker() {
        let standalone = "/opt/homebrew/bin/docker-compose"
        let command = ComposeCommand.detect(
            dockerBinary: docker,
            pluginWorks: { _ in false },
            fileManager: FakeFS(executables: [standalone])
        )
        #expect(command == .standalone(binary: URL(fileURLWithPath: standalone)))
        let (exe, args) = command!.invocation(["--project-directory", "/x", "stop"])
        #expect(exe.path == standalone)
        #expect(args == ["--project-directory", "/x", "stop"])  // no "compose" prefix
    }

    @Test func standaloneCandidatesCoverBothArchitectures() {
        let candidates = ComposeCommand.standaloneCandidates(besideDocker: URL(fileURLWithPath: "/custom/bin/docker"))
            .map(\.path)
        #expect(candidates.contains("/custom/bin/docker-compose"))  // beside the resolved docker
        #expect(candidates.contains("/opt/homebrew/bin/docker-compose"))  // Apple Silicon
        #expect(candidates.contains("/usr/local/bin/docker-compose"))  // Intel
    }

    @Test func nilWhenNeitherShapeExists() {
        let command = ComposeCommand.detect(
            dockerBinary: docker, pluginWorks: { _ in false },
            fileManager: FakeFS(executables: [])
        )
        #expect(command == nil)
    }
}

@Suite struct SystemToolsTests {
    @Test func findsPerlWhenPresent() {
        let tools = SystemTools(isExecutable: { $0 == "/usr/bin/perl" })
        #expect(tools.perlPath() == "/usr/bin/perl")
    }

    @Test func returnsNilWhenPerlMissing() {
        let tools = SystemTools(isExecutable: { _ in false })
        #expect(tools.perlPath() == nil)
    }
}

@Suite struct DockerBinaryArchCoverageTests {
    @Test func candidatesCoverBothArchitectures() {
        let paths = DockerBinaryLocator.defaultCandidates.map(\.path)
        #expect(paths.contains("/opt/homebrew/bin/docker"))  // Apple Silicon Homebrew
        #expect(paths.contains("/usr/local/bin/docker"))  // Intel Homebrew / Docker Desktop
        #expect(paths.contains { $0.hasSuffix(".orbstack/bin/docker") })
        #expect(paths.contains("/usr/bin/docker"))  // Linux container (Tier 4 headless server)
    }
}

/// Minimal FileManager stand-in for executable-existence checks.
final class FakeFS: FileManager, @unchecked Sendable {
    let executables: Set<String>
    init(executables: [String]) {
        self.executables = Set(executables)
        super.init()
    }
    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}
