import Foundation

/// One archived snapshot of a server's data directory.
public struct BackupRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var containerName: String
    public var uuid: String
    public var name: String?
    public var fileName: String
    public var bytes: Int64
    public var checksum: String?
    public var createdAt: String

    public init(
        id: Int64, containerName: String, uuid: String, name: String?, fileName: String, bytes: Int64,
        checksum: String?, createdAt: String
    ) {
        self.id = id
        self.containerName = containerName
        self.uuid = uuid
        self.name = name
        self.fileName = fileName
        self.bytes = bytes
        self.checksum = checksum
        self.createdAt = createdAt
    }
}

extension PanelDataStore {
    public func listBackups(containerName: String) throws -> [BackupRecord] {
        try db.query(
            "SELECT * FROM backups WHERE container_name = ? ORDER BY created_at DESC", [.text(containerName)]
        ).map(Self.backupFromRow)
    }

    public func backup(uuid: String) throws -> BackupRecord? {
        try db.query("SELECT * FROM backups WHERE uuid = ?", [.text(uuid)]).first.map(Self.backupFromRow)
    }

    public func backupCount(containerName: String) throws -> Int {
        Int(
            try db.query(
                "SELECT COUNT(*) AS c FROM backups WHERE container_name = ?", [.text(containerName)]
            ).first?["c"]?.asInt ?? 0)
    }

    @discardableResult
    public func recordBackup(
        containerName: String, uuid: String, name: String?, fileName: String, bytes: Int64, checksum: String?
    ) throws -> Int64 {
        try db.run(
            """
            INSERT INTO backups (container_name, uuid, name, file_name, bytes, checksum)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(containerName), .text(uuid), name.map { SQLValue.text($0) } ?? .null,
                .text(fileName), .integer(bytes), checksum.map { SQLValue.text($0) } ?? .null,
            ])
    }

    public func deleteBackup(uuid: String) throws {
        try db.run("DELETE FROM backups WHERE uuid = ?", [.text(uuid)])
    }

    private static func backupFromRow(_ row: [String: SQLValue]) -> BackupRecord {
        BackupRecord(
            id: row["id"]!.asInt!, containerName: row["container_name"]?.asString ?? "",
            uuid: row["uuid"]?.asString ?? "", name: row["name"]?.asString,
            fileName: row["file_name"]?.asString ?? "", bytes: row["bytes"]?.asInt ?? 0,
            checksum: row["checksum"]?.asString, createdAt: row["created_at"]?.asString ?? "")
    }
}
