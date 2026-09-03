import Foundation

/// A non-fatal issue found in an imported egg. Eggs are never *rejected* for
/// these (the goal is to import all real Pterodactyl eggs); they surface as
/// warnings in the admin UI so the operator can decide.
public struct EggWarning: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case unsupportedMetaVersion
        case noDockerImage
        case emptyStartup
        case noInstallScript
        case installScriptWithoutContainer
        case invalidEnvVariableName
        case duplicateEnvVariable
    }
    public var kind: Kind
    public var message: String
    public var id: String { "\(kind.rawValue):\(message)" }

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Pure validation over a parsed egg — returns warnings, never throws.
public enum EggValidator {
    /// Env var names Docker/Pterodactyl expect: uppercase letters, digits, and
    /// underscores, not starting with a digit.
    static let envNamePattern = "^[A-Za-z_][A-Za-z0-9_]*$"

    public static func validate(_ egg: PterodactylEgg) -> [EggWarning] {
        var warnings: [EggWarning] = []

        if egg.metaVersion != "PTDL_v1" && egg.metaVersion != "PTDL_v2" {
            warnings.append(
                .init(
                    .unsupportedMetaVersion,
                    "Unrecognized egg version \"\(egg.metaVersion)\" — imported best-effort."))
        }

        if egg.dockerImages.isEmpty {
            warnings.append(
                .init(.noDockerImage, "The egg declares no Docker image; you'll have to enter one."))
        }

        if egg.startup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(.init(.emptyStartup, "The egg has an empty startup command."))
        }

        if egg.install.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(
                .init(.noInstallScript, "The egg has no install script; nothing will be installed."))
        } else if egg.install.container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(
                .init(
                    .installScriptWithoutContainer,
                    "The egg has an install script but no install image to run it in."))
        }

        var seen = Set<String>()
        for variable in egg.variables {
            if variable.envVariable.range(of: envNamePattern, options: .regularExpression) == nil {
                warnings.append(
                    .init(
                        .invalidEnvVariableName,
                        "Variable \"\(variable.name)\" has an unusual env name \"\(variable.envVariable)\"."))
            }
            if !seen.insert(variable.envVariable).inserted {
                warnings.append(
                    .init(
                        .duplicateEnvVariable,
                        "Duplicate variable env name \"\(variable.envVariable)\"."))
            }
        }

        return warnings
    }
}
