import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct ComposeWriterTests {
    private func fullSpec() -> ProvisionSpec {
        ProvisionSpec(
            name: "mc1",
            image: "ghcr.io/pterodactyl/yolks:java_21",
            startup: "java -Xmx2048M $( printf %s \"-jar server.jar\" )",
            environment: ["SERVER_JARFILE": "server.jar", "SERVER_MEMORY": "2048", "SERVER_PORT": "25565"],
            limits: ServerLimits(
                memoryMiB: 2048, swapMiB: 512, cpuPercent: 200, cpuPinning: "0,1",
                ioWeight: 500, pidsLimit: 512, oomKillDisable: true),
            portMappings: [PortMapping(hostIP: "127.0.0.1", hostPort: 25565, containerPort: 25565)])
    }

    @Test func emitsContainerNameServiceAndBashEntrypoint() {
        let yaml = ComposeFileWriter.compose(fullSpec())
        #expect(yaml.contains("  server:"))
        #expect(yaml.contains("    container_name: mc1"))
        #expect(yaml.contains("    image: \"ghcr.io/pterodactyl/yolks:java_21\""))
        #expect(yaml.contains("    working_dir: /home/container"))
        #expect(yaml.contains("    entrypoint: [\"/bin/bash\", \"-c\"]"))
        #expect(yaml.contains("    restart: unless-stopped"))
    }

    @Test func quotesStartupPreservingShellSyntax() {
        let yaml = ComposeFileWriter.compose(fullSpec())
        // The inner double-quotes of the startup are escaped for YAML but the
        // shell syntax ($(...), the quotes) is intact for the container's bash.
        #expect(yaml.contains(#"    command: ["java -Xmx2048M $( printf %s \"-jar server.jar\" )"]"#))
    }

    @Test func mapsAllResourceLimits() {
        let yaml = ComposeFileWriter.compose(fullSpec())
        #expect(yaml.contains("    mem_limit: 2048m"))
        #expect(yaml.contains("    memswap_limit: 2560m"))  // memory + swap
        #expect(yaml.contains("    cpus: 2"))  // 200% → 2 whole cores
        #expect(yaml.contains("    cpuset: \"0,1\""))
        #expect(yaml.contains("    blkio_config:"))
        #expect(yaml.contains("      weight: 500"))
        #expect(yaml.contains("    pids_limit: 512"))
        #expect(yaml.contains("    oom_kill_disable: true"))
    }

    @Test func portsAndVolumesAndSortedEnvironment() {
        let yaml = ComposeFileWriter.compose(fullSpec())
        #expect(yaml.contains("      - \"127.0.0.1:25565:25565/tcp\""))
        #expect(yaml.contains("      - \"./data:/home/container\""))
        // Environment keys are emitted in sorted order for determinism.
        let jarIdx = yaml.range(of: "SERVER_JARFILE")!.lowerBound
        let memIdx = yaml.range(of: "SERVER_MEMORY")!.lowerBound
        #expect(jarIdx < memIdx)
    }

    @Test func unlimitedLimitsOmitKeys() {
        let spec = ProvisionSpec(name: "x", image: "img", startup: "run", environment: [:])
        let yaml = ComposeFileWriter.compose(spec)
        #expect(!yaml.contains("mem_limit"))
        #expect(!yaml.contains("cpus:"))
        #expect(!yaml.contains("memswap_limit"))
        // Still always has the data volume.
        #expect(yaml.contains("      - \"./data:/home/container\""))
    }

    @Test func stopConfigMapping() {
        #expect(ServerStop.from(configStop: "^C") == ServerStop(signal: "SIGINT", graceSeconds: 30))
        #expect(ServerStop.from(configStop: "SIGTERM") == ServerStop(signal: "SIGTERM", graceSeconds: 30))
        // Common console stop commands are commands, NOT the same-named signal.
        #expect(ServerStop.from(configStop: "stop") == ServerStop(signal: nil, graceSeconds: 30, command: "stop"))
        #expect(ServerStop.from(configStop: "quit") == ServerStop(signal: nil, graceSeconds: 30, command: "quit"))
        #expect(ServerStop.from(configStop: "") == ServerStop())
    }

    @Test func composeEmitsStopSignalAndGrace() {
        let spec = ProvisionSpec(
            name: "mc", image: "img", startup: "run", environment: [:],
            stopSignal: "SIGINT", stopGracePeriodSeconds: 30)
        let yaml = ComposeFileWriter.compose(spec)
        #expect(yaml.contains("    stop_signal: SIGINT"))
        #expect(yaml.contains("    stop_grace_period: 30s"))
    }

    @Test func unlimitedSwapEmitsMinusOne() {
        let spec = ProvisionSpec(
            name: "x", image: "img", startup: "run", environment: [:],
            limits: ServerLimits(memoryMiB: 1024, swapMiB: -1))
        let yaml = ComposeFileWriter.compose(spec)
        #expect(yaml.contains("    mem_limit: 1024m"))
        #expect(yaml.contains("    memswap_limit: -1"))
    }

    @Test func fractionalCPUKeepsDecimal() {
        let spec = ProvisionSpec(
            name: "x", image: "img", startup: "run", environment: [:],
            limits: ServerLimits(cpuPercent: 50))
        #expect(ComposeFileWriter.compose(spec).contains("    cpus: 0.5"))
    }
}

@Suite struct ServerProvisionerGuardTests {
    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func dummyCLI() -> DockerCLI { DockerCLI(binary: URL(fileURLWithPath: "/usr/bin/true")) }

    @Test func slugifyNormalizesFriendlyNames() {
        #expect(ServerProvisioner.slugify("Test") == "test")
        #expect(ServerProvisioner.slugify("My SMP Server") == "my-smp-server")
        #expect(ServerProvisioner.slugify("SMP #1!!") == "smp-1")
        #expect(ServerProvisioner.slugify("  --Lead/Trail--  ") == "lead-trail")
        #expect(ServerProvisioner.slugify("café münchen") == "caf-m-nchen")
        #expect(ServerProvisioner.slugify("already.valid_name-1") == "already.valid_name-1")
        // Slugs are always valid identifiers (or empty for a no-alnum input).
        #expect(ServerProvisioner.isValidName(ServerProvisioner.slugify("My Server 2026")))
        #expect(ServerProvisioner.slugify("###") == "")
        #expect(ServerProvisioner.slugify("") == "")
        // A 90-char name is capped to the 63-char limit and stays valid.
        let long = ServerProvisioner.slugify(String(repeating: "a", count: 90))
        #expect(long.count == 63 && ServerProvisioner.isValidName(long))
    }

    @Test func nameValidation() {
        #expect(ServerProvisioner.isValidName("mc1"))
        #expect(ServerProvisioner.isValidName("a.b-c_d"))
        #expect(ServerProvisioner.isValidName("1abc"))
        #expect(!ServerProvisioner.isValidName("BAD"))
        #expect(!ServerProvisioner.isValidName("has space"))
        #expect(!ServerProvisioner.isValidName("-x"))
        #expect(!ServerProvisioner.isValidName("a/b"))
        #expect(!ServerProvisioner.isValidName(""))
    }

    @Test func invalidNameFailsBeforeAnyDockerCall() async throws {
        let prov = ServerProvisioner(cli: dummyCLI(), stacksRoot: try tempRoot())
        let spec = ProvisionSpec(name: "BAD NAME", image: "img", startup: "run", environment: [:])
        await #expect(throws: ProvisionError.invalidName("BAD NAME")) {
            for try await _ in prov.provision(spec) {}
        }
    }

    @Test func existingStackFailsWithoutDeletingIt() async throws {
        let root = try tempRoot()
        let existing = root.appendingPathComponent("mc1")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        // Put a marker file in the pre-existing stack to prove it's untouched.
        let marker = existing.appendingPathComponent("keep.txt")
        try Data("precious".utf8).write(to: marker)

        let prov = ServerProvisioner(cli: dummyCLI(), stacksRoot: root)
        let spec = ProvisionSpec(name: "mc1", image: "img", startup: "run", environment: [:])
        await #expect(throws: ProvisionError.alreadyExists("mc1")) {
            for try await _ in prov.provision(spec) {}
        }
        // Crucial safety property: a name clash must NOT delete the existing
        // stack — rollback only removes what a run itself created.
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
