import Foundation

/// Applies an egg's `config.files` to a server's data directory before first
/// boot — the step Pterodactyl's Wings does on every start. Without it a server
/// ignores its own configured port/RCON (e.g. Minecraft binds the default 25565
/// instead of its allocation). Pure and unit-tested; the provisioner calls it
/// after the install script and before `compose up`.
///
/// The `config.files` wire shape (a JSON-encoded string on the egg):
/// `{ "<path>": { "parser": "properties|file|json|yaml|…", "find": { k: v } } }`
/// where values reference `{{server.build.default.port}}` / `{{SERVER_PORT}}`.
public enum ConfigFileApplier {
    public struct Result: Sendable, Equatable {
        public var applied: [String]
        public var warnings: [String]
    }

    /// Builds the substitution namespace `config.files` values reference. Includes
    /// the raw env (SERVER_PORT, …) and Pterodactyl's `server.build.*` aliases.
    public static func substitutions(environment: [String: String]) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in environment {
            map[key] = value
            map["server.build.env.\(key)"] = value
        }
        if let port = environment["SERVER_PORT"] {
            map["server.build.default.port"] = port
            map["server.port"] = port
        }
        if let ip = environment["SERVER_IP"] { map["server.build.default.ip"] = ip }
        if let mem = environment["SERVER_MEMORY"] { map["server.build.memory"] = mem }
        return map
    }

    /// Rewrites the configured files under `dataDir`. Never escapes `dataDir`
    /// (paths with `..`/absolute are skipped with a warning).
    public static func apply(
        configFilesJSON: String, into dataDir: URL, substitutions: [String: String]
    ) -> Result {
        var applied: [String] = []
        var warnings: [String] = []
        guard !configFilesJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(applied: [], warnings: [])
        }
        guard let data = configFilesJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Result(applied: [], warnings: ["config.files is not a JSON object; skipped."])
        }

        for (path, spec) in root {
            guard let spec = spec as? [String: Any] else { continue }
            let parser = (spec["parser"] as? String)?.lowercased() ?? "file"
            let finds = flattenFinds(spec["find"])
            guard !finds.isEmpty else { continue }
            guard let fileURL = confinedURL(path, in: dataDir) else {
                warnings.append("Skipped \"\(path)\" (path escapes the data directory).")
                continue
            }
            let resolved = finds.mapValues { substitute($0, substitutions) }
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8))

            let output: String?
            switch parser {
            case "properties":
                output = applyProperties(existing ?? "", resolved)
            case "file":
                if let existing { output = applyFile(existing, resolved) } else { output = nil }
            case "json":
                output = applyJSON(existing ?? "{}", resolved)
            case "yaml", "yml":
                if let existing { output = applyYAMLLines(existing, resolved) } else { output = nil }
            default:
                warnings.append("\"\(path)\": parser \"\(parser)\" not supported yet; left unchanged.")
                output = nil
            }

            guard let output else {
                if existing == nil { warnings.append("\"\(path)\" doesn't exist yet; left for the server to create.") }
                continue
            }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(output.utf8).write(to: fileURL)
                applied.append(path)
            } catch {
                warnings.append("Couldn't write \"\(path)\": \(error).")
            }
        }
        return Result(applied: applied.sorted(), warnings: warnings)
    }

    // MARK: - Parsers

    /// `key=value` upsert, preserving comments/blank lines and other keys; new
    /// keys are appended. Handles Minecraft's `server.properties`.
    static func applyProperties(_ text: String, _ finds: [String: String]) -> String {
        var remaining = finds
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("!"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if let value = remaining[key] {
                lines[i] = "\(key)=\(value)"
                remaining.removeValue(forKey: key)
            }
        }
        for (key, value) in remaining.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)=\(value)")
        }
        // Drop a leading empty line if the file was created fresh.
        if lines.first == "" { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// Literal find→replace over the whole file (Wings' `file` parser).
    static func applyFile(_ text: String, _ finds: [String: String]) -> String {
        var out = text
        for (find, value) in finds { out = out.replacingOccurrences(of: find, with: value) }
        return out
    }

    /// Dotted-path set into a JSON document; creates missing objects.
    static func applyJSON(_ text: String, _ finds: [String: String]) -> String? {
        var root =
            (try? JSONSerialization.jsonObject(with: Data((text.isEmpty ? "{}" : text).utf8)) as? [String: Any])
            ?? [:]
        for (path, value) in finds { root = setPath(root, path.components(separatedBy: "."), value) }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Best-effort line-based YAML set: replaces the scalar after `key:` for the
    /// last path component. Nested paths are matched by leaf key only.
    static func applyYAMLLines(_ text: String, _ finds: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        for (path, value) in finds {
            let leaf = path.components(separatedBy: ".").last ?? path
            for i in lines.indices {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\(leaf):") else { continue }
                let indent = String(lines[i].prefix { $0 == " " })
                lines[i] = "\(indent)\(leaf): \(value)"
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func setPath(_ object: [String: Any], _ path: [String], _ value: String) -> [String: Any] {
        var object = object
        guard let head = path.first else { return object }
        if path.count == 1 {
            object[head] = coerce(value)
        } else {
            let child = object[head] as? [String: Any] ?? [:]
            object[head] = setPath(child, Array(path.dropFirst()), value)
        }
        return object
    }

    /// JSON values that are clearly numeric/bool are written as such, else string.
    private static func coerce(_ value: String) -> Any {
        if value == "true" { return true }
        if value == "false" { return false }
        if let int = Int(value) { return int }
        if let dbl = Double(value), value.contains(".") { return dbl }
        return value
    }

    /// A `find` block can be a flat map or (rarely) nested; flatten to dotted keys.
    static func flattenFinds(_ any: Any?) -> [String: String] {
        guard let dict = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in dict {
            if let nested = value as? [String: Any] {
                for (subKey, subValue) in flattenFinds(nested) { out["\(key).\(subKey)"] = subValue }
            } else if let str = Coerce.string(value) {
                out[key] = str
            }
        }
        return out
    }

    /// `{{ token }}` substitution allowing dotted tokens (server.build.default.port).
    static func substitute(_ template: String, _ map: [String: String]) -> String {
        guard template.contains("{{") else { return template }
        let ns = template as NSString
        let regex = try! NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_.]+)\\s*\\}\\}")
        var result = ""
        var cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            let full = match.range
            if full.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            result += map[ns.substring(with: match.range(at: 1))] ?? ""
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    private static func confinedURL(_ path: String, in dataDir: URL) -> URL? {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !clean.isEmpty, !clean.split(separator: "/").contains("..") else { return nil }
        let url = dataDir.appendingPathComponent(clean)
        let root = dataDir.standardizedFileURL.path
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard parent == root || parent.hasPrefix(root + "/") else { return nil }
        return url
    }
}
