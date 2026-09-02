import Foundation
import MacerodactylKit

// Headless smoke check: resolves the docker binary, lists containers through
// the exact same code path the app uses, and prints the grouped result.
// Usage: swift run kitcheck

guard let binary = DockerBinaryLocator.resolve(override: AppSettings.dockerPathOverride) else {
    print("docker binary: NOT FOUND (checked ~/.orbstack/bin, /opt/homebrew/bin, /usr/local/bin)")
    exit(2)
}
print("docker binary: \(binary.path)")

let cli = DockerCLI(binary: binary)

// Optional action mode: kitcheck <start|stop|restart> <container-name>
let arguments = CommandLine.arguments
if arguments.count == 3, ["start", "stop", "restart"].contains(arguments[1]) {
    do {
        try await cli.run([arguments[1], arguments[2]], timeout: .seconds(120))
        print("\(arguments[1]) \(arguments[2]): ok")
    } catch {
        print("\(arguments[1]) \(arguments[2]): FAILED — \(error)")
        exit(1)
    }
}

do {
    let output = try await cli.run(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(15))
    let groups = DockerPSParser.group(DockerPSParser.parse(output))
    print("daemon: ready — \(groups.stacks.count) stack(s), \(groups.unmanaged.count) unmanaged")
    for stack in groups.stacks {
        print("\nstack \(stack.name) (\(stack.runningCount)/\(stack.containers.count) running) dir=\(stack.workingDir ?? "-")")
        for container in stack.containers {
            let health = container.health.map { " [\($0.rawValue)]" } ?? ""
            print("  \(container.isRunning ? "●" : "○") \(container.name)\(health)  \(container.image)  \(container.status)")
        }
    }
    if !groups.unmanaged.isEmpty {
        print("\nunmanaged")
        for container in groups.unmanaged {
            let health = container.health.map { " [\($0.rawValue)]" } ?? ""
            print("  \(container.isRunning ? "●" : "○") \(container.name)\(health)  \(container.image)  \(container.status)")
        }
    }
} catch DockerError.daemonUnavailable {
    print("daemon: NOT RUNNING (this is the app's daemon-down state)")
    exit(3)
}
