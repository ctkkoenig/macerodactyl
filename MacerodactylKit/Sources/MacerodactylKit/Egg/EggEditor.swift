import Foundation

/// A structured set of edits to a stored egg. Every field is optional: only the
/// provided ones are changed, so the editor can send just what it touched and the
/// rest of the egg JSON (meta, features, anything the UI doesn't model) is left
/// intact.
public struct EggEdits: Sendable {
    public var name: String?
    public var author: String?
    public var description: String?
    public var startup: String?
    /// config.stop
    public var stop: String?
    /// config.files (a JSON string, as Pterodactyl stores it)
    public var configFiles: String?
    /// config.logs (a JSON string)
    public var configLogs: String?
    public var installScript: String?
    public var installContainer: String?
    public var installEntrypoint: String?
    public var images: [(label: String, image: String)]?
    public var variables: [VariableEdit]?

    public struct VariableEdit: Sendable {
        public var name: String
        public var description: String
        public var envVariable: String
        public var defaultValue: String
        public var userViewable: Bool
        public var userEditable: Bool
        public var rules: [String]
        public init(
            name: String, description: String, envVariable: String, defaultValue: String,
            userViewable: Bool, userEditable: Bool, rules: [String]
        ) {
            self.name = name
            self.description = description
            self.envVariable = envVariable
            self.defaultValue = defaultValue
            self.userViewable = userViewable
            self.userEditable = userEditable
            self.rules = rules
        }
    }

    public init(
        name: String? = nil, author: String? = nil, description: String? = nil, startup: String? = nil,
        stop: String? = nil, configFiles: String? = nil, configLogs: String? = nil,
        installScript: String? = nil, installContainer: String? = nil, installEntrypoint: String? = nil,
        images: [(label: String, image: String)]? = nil, variables: [VariableEdit]? = nil
    ) {
        self.name = name
        self.author = author
        self.description = description
        self.startup = startup
        self.stop = stop
        self.configFiles = configFiles
        self.configLogs = configLogs
        self.installScript = installScript
        self.installContainer = installContainer
        self.installEntrypoint = installEntrypoint
        self.images = images
        self.variables = variables
    }
}

/// Applies structured edits onto an egg's raw JSON in place — the robust path for
/// the admin egg editor. It patches the parsed JSON tree (never rebuilds it from
/// scratch), so fields the editor doesn't model survive untouched; the caller
/// then re-parses the result through `EggParser` to validate before saving.
public enum EggEditor {
    public enum EditError: Error, Equatable, Sendable { case notAnObject, serializationFailed }

    public static func apply(_ edits: EggEdits, to rawJSON: String) throws -> String {
        guard let data = rawJSON.data(using: .utf8),
            var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw EditError.notAnObject }

        if let name = edits.name { root["name"] = name }
        if let author = edits.author { root["author"] = author }
        if let description = edits.description { root["description"] = description }
        if let startup = edits.startup { root["startup"] = startup }

        if let images = edits.images {
            // Pterodactyl stores docker_images as {label: image}. Preserve order
            // isn't representable in a JSON object, so this matches the format.
            var dict: [String: String] = [:]
            for option in images where !option.image.isEmpty { dict[option.label] = option.image }
            root["docker_images"] = dict
        }

        // config.{stop,files,logs} live under the "config" object.
        if edits.stop != nil || edits.configFiles != nil || edits.configLogs != nil {
            var config = (root["config"] as? [String: Any]) ?? [:]
            if let stop = edits.stop { config["stop"] = stop }
            if let files = edits.configFiles { config["files"] = files }
            if let logs = edits.configLogs { config["logs"] = logs }
            root["config"] = config
        }

        // scripts.installation.{script,container,entrypoint}.
        if edits.installScript != nil || edits.installContainer != nil || edits.installEntrypoint != nil {
            var scripts = (root["scripts"] as? [String: Any]) ?? [:]
            var installation = (scripts["installation"] as? [String: Any]) ?? [:]
            if let script = edits.installScript { installation["script"] = script }
            if let container = edits.installContainer { installation["container"] = container }
            if let entrypoint = edits.installEntrypoint { installation["entrypoint"] = entrypoint }
            scripts["installation"] = installation
            root["scripts"] = scripts
        }

        if let variables = edits.variables {
            root["variables"] = variables.map { variable -> [String: Any] in
                [
                    "name": variable.name,
                    "description": variable.description,
                    "env_variable": variable.envVariable,
                    "default_value": variable.defaultValue,
                    "user_viewable": variable.userViewable,
                    "user_editable": variable.userEditable,
                    // Laravel-style pipe-joined rules, matching the egg export format.
                    "rules": variable.rules.joined(separator: "|"),
                ]
            }
        }

        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            let string = String(data: out, encoding: .utf8)
        else { throw EditError.serializationFailed }
        return string
    }
}
