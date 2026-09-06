import Foundation

/// Pure naming, credential generation, and SQL construction for the managed
/// database feature — the security boundary of it. Everything that reaches the
/// `mariadb` shell is built here from a strict allow-list so a user-supplied
/// database name can never inject SQL: identifiers are limited to `[a-z0-9_]`
/// (back-tick quoted) and passwords to `[A-Za-z0-9]` (single-quoted), so neither
/// can contain a back-tick, quote, semicolon, or backslash.
public enum DatabaseProvisioning {
    /// The only characters allowed in an identifier we will pass to SQL.
    private static let identifierAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
    private static let passwordAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789")

    /// Lower-cases and strips a raw name to the identifier allow-list, capping the
    /// length. Returns nil if nothing valid remains or it wouldn't start with a
    /// letter/underscore (so a name of only digits/punctuation is rejected rather
    /// than silently mangled).
    public static func sanitize(_ raw: String, maxLength: Int) -> String? {
        let filtered = String(raw.lowercased().filter { identifierAllowed.contains($0) })
        guard let first = filtered.first, first.isLetter || first == "_" else { return nil }
        let capped = String(filtered.prefix(maxLength))
        // A trailing cut can't produce anything unsafe (still allow-listed), but
        // re-check the invariant defensively.
        return isSafeIdentifier(capped) ? capped : nil
    }

    /// True only if every character is in the identifier allow-list — the guard
    /// the SQL builders assert before interpolating.
    public static func isSafeIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { identifierAllowed.contains($0) }
    }

    /// A random 24-character password from an unambiguous alphanumeric alphabet —
    /// no quote, back-tick, or backslash, so it is safe inside a single-quoted SQL
    /// string literal without escaping.
    public static func generatePassword() -> String {
        String((0..<24).map { _ in passwordAlphabet[Int.random(in: 0..<passwordAlphabet.count)] })
    }

    /// The real database name for a server: `s<id>_<base>`, so two servers can
    /// both have a "stats" database without colliding, capped to MariaDB's 64.
    public static func databaseName(serverID: Int64, base: String) -> String? {
        guard let base = sanitize(base, maxLength: 48) else { return nil }
        return "s\(serverID)_\(base)"
    }

    /// The scoped user for a database: `u<id>_<base>`, capped to 32 (the classic
    /// MySQL username limit) so it works on any engine version.
    public static func username(serverID: Int64, base: String) -> String? {
        guard let base = sanitize(base, maxLength: 20) else { return nil }
        return String("u\(serverID)_\(base)".prefix(32))
    }

    /// SQL to create the database, its scoped user, and the grant. Inputs MUST be
    /// pre-validated; this asserts the allow-list and returns nil otherwise so a
    /// bug upstream can never smuggle an unsafe identifier through.
    public static func createSQL(database: String, username: String, password: String) -> String? {
        guard isSafeIdentifier(database), isSafeIdentifier(username),
            password.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return [
            "CREATE DATABASE IF NOT EXISTS `\(database)`;",
            "CREATE USER IF NOT EXISTS '\(username)'@'%' IDENTIFIED BY '\(password)';",
            "ALTER USER '\(username)'@'%' IDENTIFIED BY '\(password)';",
            "GRANT ALL PRIVILEGES ON `\(database)`.* TO '\(username)'@'%';",
            "FLUSH PRIVILEGES;",
        ].joined(separator: " ")
    }

    /// SQL to drop the database and its user. Same allow-list guard.
    public static func dropSQL(database: String, username: String) -> String? {
        guard isSafeIdentifier(database), isSafeIdentifier(username) else { return nil }
        return "DROP DATABASE IF EXISTS `\(database)`; DROP USER IF EXISTS '\(username)'@'%'; FLUSH PRIVILEGES;"
    }
}
