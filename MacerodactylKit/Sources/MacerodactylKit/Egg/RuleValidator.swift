import Foundation

/// Validates service-variable values against an egg's Laravel-style `rules`
/// (`required|string|max:20|regex:/^…$/`). Pterodactyl enforces these; without
/// it a `required|regex` variable can be submitted empty or malformed and the
/// server breaks on boot. Pure and unit-tested. Covers the rules real eggs use;
/// unknown rules are ignored (permissive, never a false rejection).
public enum RuleValidator {
    public struct Violation: Sendable, Equatable {
        public let variable: String
        public let message: String
    }

    /// Validates every editable variable's effective value (the user override
    /// when editable and supplied, otherwise the default). Returns all failures.
    public static func validate(egg: PterodactylEgg, values: [String: String]) -> [Violation] {
        var violations: [Violation] = []
        for variable in egg.variables {
            let value: String?
            if variable.userEditable, let provided = values[variable.envVariable] {
                value = provided
            } else {
                value = variable.defaultValue.isEmpty ? nil : variable.defaultValue
            }
            if let message = validate(value: value, rules: variable.rules, label: variable.name) {
                violations.append(Violation(variable: variable.envVariable, message: message))
            }
        }
        return violations
    }

    /// Returns a human message if the value fails its rules, else nil.
    public static func validate(value: String?, rules: [String], label: String) -> String? {
        let isEmpty = (value ?? "").isEmpty
        let hasRequired = rules.contains("required")
        let hasNullable = rules.contains("nullable")

        if isEmpty {
            if hasRequired { return "\(label) is required." }
            return nil  // empty + not required (or nullable) → nothing more to check
        }
        _ = hasNullable
        let value = value ?? ""
        let numericContext = rules.contains("numeric") || rules.contains("integer")

        for rule in rules {
            let (name, arg) = split(rule)
            switch name {
            case "required", "nullable", "string", "sometimes", "present":
                continue
            case "numeric":
                if Double(value) == nil { return "\(label) must be a number." }
            case "integer", "int":
                if Int(value) == nil { return "\(label) must be a whole number." }
            case "boolean", "bool":
                if !["true", "false", "0", "1"].contains(value.lowercased()) {
                    return "\(label) must be true or false."
                }
            case "in":
                let options = arg.split(separator: ",").map { String($0) }
                if !options.contains(value) { return "\(label) must be one of: \(options.joined(separator: ", "))." }
            case "not_in":
                let options = arg.split(separator: ",").map { String($0) }
                if options.contains(value) { return "\(label) may not be \(value)." }
            case "max":
                if let limit = Double(arg) {
                    if numericContext, let num = Double(value), num > limit { return "\(label) must be at most \(arg)." }
                    if !numericContext, Double(value.count) > limit { return "\(label) must be at most \(arg) characters." }
                }
            case "min":
                if let limit = Double(arg) {
                    if numericContext, let num = Double(value), num < limit { return "\(label) must be at least \(arg)." }
                    if !numericContext, Double(value.count) < limit { return "\(label) must be at least \(arg) characters." }
                }
            case "between":
                let bounds = arg.split(separator: ",").compactMap { Double($0) }
                if bounds.count == 2 {
                    let measure = numericContext ? Double(value) : Double(value.count)
                    if let measure, measure < bounds[0] || measure > bounds[1] {
                        return "\(label) must be between \(Int(bounds[0])) and \(Int(bounds[1]))."
                    }
                }
            case "alpha_num", "alpha_dash":
                let allowed = CharacterSet.alphanumerics.union(
                    name == "alpha_dash" ? CharacterSet(charactersIn: "-_") : CharacterSet())
                if value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                    return "\(label) has invalid characters."
                }
            case "regex":
                if let pattern = regexPattern(arg), value.range(of: pattern, options: .regularExpression) == nil {
                    return "\(label) has an invalid format."
                }
            default:
                continue  // unknown rule → ignore (permissive)
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// "max:20" → ("max","20"); "required" → ("required",""). Splits on the FIRST
    /// colon so a `regex:/…:/…/` keeps its colons.
    static func split(_ rule: String) -> (String, String) {
        guard let colon = rule.firstIndex(of: ":") else { return (rule, "") }
        return (String(rule[rule.startIndex..<colon]), String(rule[rule.index(after: colon)...]))
    }

    /// Extracts a regex body from Laravel's `/pattern/flags` form (or returns the
    /// arg as-is if it isn't slash-delimited).
    static func regexPattern(_ arg: String) -> String? {
        guard arg.hasPrefix("/") else { return arg.isEmpty ? nil : arg }
        guard let lastSlash = arg.lastIndex(of: "/"), lastSlash != arg.startIndex else { return nil }
        return String(arg[arg.index(after: arg.startIndex)..<lastSlash])
    }
}
