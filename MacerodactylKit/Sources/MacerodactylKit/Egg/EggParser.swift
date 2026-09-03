import Foundation

/// Parses the real Pterodactyl egg export format into a `PterodactylEgg`.
///
/// Deliberately tolerant: the goal is "imports *all* Pterodactyl eggs", so this
/// goes through `JSONSerialization` and coerces every field by hand rather than
/// fighting `Codable` over the format's polymorphic corners (numbers where
/// strings are expected, `rules` as string-or-array, `config.*` as
/// JSON-encoded strings, v1 `image` vs v2 `docker_images`). Unknown keys and
/// unknown future `meta.version`s are ignored, not rejected.
public enum EggParser {
    public enum ParseError: Error, Equatable {
        case notJSON
        case notAnObject
        case missingStartup
    }

    public static func parse(_ json: String) throws -> PterodactylEgg {
        guard let data = json.data(using: .utf8) else { throw ParseError.notJSON }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> PterodactylEgg {
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            throw ParseError.notJSON
        }
        guard let root = any as? [String: Any] else { throw ParseError.notAnObject }

        let meta = root["meta"] as? [String: Any]
        let metaVersion = Coerce.string(meta?["version"]) ?? "unknown"

        let startup = Coerce.string(root["startup"]) ?? ""
        guard !startup.isEmpty else { throw ParseError.missingStartup }

        let config = root["config"] as? [String: Any]

        return PterodactylEgg(
            metaVersion: metaVersion,
            name: Coerce.string(root["name"]) ?? "Unnamed egg",
            author: Coerce.string(root["author"]) ?? "",
            eggDescription: Coerce.string(root["description"]) ?? "",
            dockerImages: dockerImages(from: root),
            startup: startup,
            configFiles: jsonBlock(config?["files"]),
            doneStrings: doneStrings(from: config?["startup"]),
            configLogs: jsonBlock(config?["logs"]),
            configStop: Coerce.string(config?["stop"]) ?? "",
            install: installScript(from: root),
            variables: variables(from: root["variables"]),
            features: Coerce.stringArray(root["features"]),
            fileDenylist: Coerce.stringArray(root["file_denylist"])
        )
    }

    // MARK: - Field extraction

    /// `docker_images` (v2 map) or `image`/`images` (v1). Order preserved where
    /// the source is ordered; a v1 single image is labeled by the image itself.
    static func dockerImages(from root: [String: Any]) -> [PterodactylEgg.ImageOption] {
        if let map = root["docker_images"] {
            // v2: an object {label: image}. JSONSerialization gives an unordered
            // dictionary, so sort by label for a stable, deterministic order.
            if let dict = map as? [String: Any] {
                let options = dict.compactMap { key, value -> PterodactylEgg.ImageOption? in
                    guard let image = Coerce.string(value) else { return nil }
                    return PterodactylEgg.ImageOption(label: key, image: image)
                }
                if !options.isEmpty { return options.sorted { $0.label < $1.label } }
            }
            // Some exports use an array of image strings under docker_images.
            let arr = Coerce.stringArray(map)
            if !arr.isEmpty { return arr.map { PterodactylEgg.ImageOption(label: $0, image: $0) } }
        }
        if let images = root["images"] {
            let arr = Coerce.stringArray(images)
            if !arr.isEmpty { return arr.map { PterodactylEgg.ImageOption(label: $0, image: $0) } }
        }
        if let single = Coerce.string(root["image"]), !single.isEmpty {
            return [PterodactylEgg.ImageOption(label: single, image: single)]
        }
        return []
    }

    /// `config.startup` carries `{ "done": <string|[string]> }`. In the export it
    /// is usually a JSON-encoded *string*, but tolerate a nested object too.
    static func doneStrings(from value: Any?) -> [String] {
        guard let value else { return [] }
        let object: [String: Any]?
        if let dict = value as? [String: Any] {
            object = dict
        } else if let str = Coerce.string(value),
            let data = str.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            object = parsed
        } else {
            object = nil
        }
        guard let done = object?["done"] else { return [] }
        if let s = done as? String { return [s] }
        return Coerce.stringArray(done)
    }

    /// `scripts.installation.{script,container,entrypoint}`.
    static func installScript(from root: [String: Any]) -> PterodactylEgg.InstallScript {
        let installation = (root["scripts"] as? [String: Any])?["installation"] as? [String: Any]
        return PterodactylEgg.InstallScript(
            script: Coerce.string(installation?["script"]) ?? "",
            container: Coerce.string(installation?["container"]) ?? "",
            entrypoint: Coerce.string(installation?["entrypoint"]) ?? "bash"
        )
    }

    static func variables(from value: Any?) -> [PterodactylEgg.EggVariable] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let v = entry as? [String: Any] else { return nil }
            guard let env = Coerce.string(v["env_variable"]), !env.isEmpty else { return nil }
            return PterodactylEgg.EggVariable(
                name: Coerce.string(v["name"]) ?? env,
                variableDescription: Coerce.string(v["description"]) ?? "",
                envVariable: env,
                defaultValue: Coerce.string(v["default_value"]) ?? "",
                userViewable: Coerce.bool(v["user_viewable"]) ?? true,
                userEditable: Coerce.bool(v["user_editable"]) ?? true,
                rules: rules(from: v["rules"])
            )
        }
    }

    /// `rules` is "required|string|max:20" (v1) or sometimes an array (v2).
    static func rules(from value: Any?) -> [String] {
        if let array = value as? [Any] { return Coerce.stringArray(array) }
        guard let str = Coerce.string(value) else { return [] }
        return str.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `config.files`/`config.logs` are JSON-encoded strings in the export. Keep
    /// them verbatim if a string; if an object slipped through, re-serialize it.
    static func jsonBlock(_ value: Any?) -> String {
        if let str = value as? String { return str }
        guard let value,
            let data = try? JSONSerialization.data(withJSONObject: value),
            let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }
}

/// Small coercion helpers for the loosely-typed egg wire format.
enum Coerce {
    /// True only for a genuine JSON boolean. `JSONSerialization` decodes `true`/
    /// `false` to an `NSNumber` that reports the Objective-C type char `"c"`,
    /// while JSON integers report `"q"`/`"i"`/`"l"` — on both macOS and Linux
    /// (Swift Foundation never emits an `Int8`-typed number for a JSON integer).
    /// This lets us avoid stringifying a numeric `1` as "true" without the
    /// CoreFoundation type-id APIs, which don't exist on Linux.
    static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return String(cString: number.objCType) == "c"
    }

    /// A JSON value that "should" be a string, tolerating numbers and bools.
    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if isJSONBoolean(value) { return (value as? NSNumber)?.boolValue == true ? "true" : "false" }
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            // Integer-valued numbers print without a decimal; reals keep it.
            let type = String(cString: n.objCType)
            if type == "f" || type == "d" { return String(n.doubleValue) }
            return String(n.int64Value)
        default: return nil
        }
    }

    /// A JSON value that "should" be a bool, tolerating 0/1 and "true"/"false".
    static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if isJSONBoolean(value) { return (value as? NSNumber)?.boolValue }
        switch value {
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// A JSON array of strings, tolerating a single string or scalar members.
    static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [Any] { return array.compactMap { string($0) } }
        if let single = string(value) { return [single] }
        return []
    }
}
