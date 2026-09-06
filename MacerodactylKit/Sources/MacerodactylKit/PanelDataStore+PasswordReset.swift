import Foundation

/// Single-use, time-limited password-reset tokens. Only the token's SHA-256 hash
/// is stored (never the raw token), so a leaked database can't reset an account.
/// Tokens are admin-issued and handed to the user out of band — there is no email
/// delivery — and consuming one both changes the password and is recorded so the
/// same link can never be replayed.
extension PanelDataStore {
    /// Creates a reset token for a user, superseding any prior unused token for
    /// that user (only one active reset at a time). `expiresAtISO` and the stored
    /// hash are supplied by the caller (the raw token lives only in the link).
    public func createPasswordReset(userID: Int64, tokenHash: String, expiresAtISO: String) throws {
        // Invalidate any earlier unused resets for this user first.
        try db.run("DELETE FROM password_resets WHERE user_id = ? AND used_at IS NULL", [.integer(userID)])
        try db.run(
            "INSERT INTO password_resets (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
            [.integer(userID), .text(tokenHash), .text(expiresAtISO)])
    }

    /// The user id a still-valid (unused, unexpired) reset token belongs to, or
    /// nil. `nowISO` is compared lexicographically against the ISO expiry.
    public func validPasswordReset(tokenHash: String, nowISO: String) throws -> Int64? {
        try db.query(
            "SELECT user_id FROM password_resets WHERE token_hash = ? AND used_at IS NULL AND expires_at > ?",
            [.text(tokenHash), .text(nowISO)]
        ).first?["user_id"]?.asInt
    }

    /// Marks a reset token consumed so its link can never be replayed.
    public func consumePasswordReset(tokenHash: String, atISO: String) throws {
        try db.run(
            "UPDATE password_resets SET used_at = ? WHERE token_hash = ?", [.text(atISO), .text(tokenHash)])
    }

    /// Deletes every session for a user — used after a password reset so any
    /// previously-open (possibly hostile) session is forced to re-authenticate.
    public func deleteAllSessions(userID: Int64) throws {
        try db.run("DELETE FROM sessions WHERE user_id = ?", [.integer(userID)])
    }
}
