import Foundation

public struct ConsoleEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let command: String
    public let output: String
    public let isError: Bool

    public init(command: String, output: String, isError: Bool = false) {
        self.id = UUID()
        self.command = command
        self.output = output
        self.isError = isError
    }
}

/// Line-based console over `docker exec`: each command runs statelessly in the
/// container's own /bin/sh (no TTY, no persistent session). A console instance
/// is bound to exactly one container at construction — there is no way to
/// point an existing session somewhere else, which is what confinement to the
/// granted container hangs on at the service level.
public struct ExecConsole: Sendable {
    public let containerID: String
    private let cli: DockerCLI

    public init(containerID: String, cli: DockerCLI) {
        self.containerID = containerID
        self.cli = cli
    }

    public func run(_ commandLine: String) async -> ConsoleEntry {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ConsoleEntry(command: commandLine, output: "", isError: false)
        }
        do {
            let result = try await cli.execute(
                DockerArgs.exec(containerID: containerID, commandLine: trimmed),
                timeout: .seconds(60)
            )
            var output = result.stdout
            if !result.stderr.isEmpty {
                output += (output.isEmpty ? "" : "\n") + result.stderr
            }
            if result.exitCode != 0 {
                output += (output.isEmpty ? "" : "\n") + "(exit \(result.exitCode))"
            }
            return ConsoleEntry(
                command: trimmed,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                isError: result.exitCode != 0
            )
        } catch {
            return ConsoleEntry(
                command: trimmed,
                output: ContainerStore.describe(error),
                isError: true
            )
        }
    }
}
