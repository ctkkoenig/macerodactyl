import Foundation

/// Creates/restores/deletes tar.gz backups of a server's data directory. The
/// archive work runs in a throwaway `alpine` container mounting only the data
/// dir and the backups dir, so ownership and paths are correct on Linux too (the
/// same pattern as the install step). Backups live at `<stack>/backups/`, beside
/// (not inside) the data dir so they never self-include or show in the file
/// manager root.
public enum BackupService {
    public enum BackupError: Error, Equatable {
        case notFound
        case invalidName
    }

    public struct CreatedBackup: Sendable, Equatable {
        public let uuid: String
        public let fileName: String
        public let bytes: Int64
        public init(uuid: String, fileName: String, bytes: Int64) {
            self.uuid = uuid
            self.fileName = fileName
            self.bytes = bytes
        }
    }

    static func backupsDir(stackDir: URL) -> URL {
        stackDir.appendingPathComponent("backups", isDirectory: true)
    }

    /// A backup file name must be a bare `<uuid>.tar.gz` — no path components —
    /// so a name from a request can never escape the backups dir.
    static func validated(fileName: String) -> String? {
        guard !fileName.contains("/"), !fileName.contains(".."), fileName.hasSuffix(".tar.gz"),
            fileName.count <= 80
        else { return nil }
        return fileName
    }

    public static func create(cli: DockerCLI, stackDir: URL, dataDirName: String) async throws -> CreatedBackup {
        let dataDir = stackDir.appendingPathComponent(dataDirName, isDirectory: true)
        let backups = backupsDir(stackDir: stackDir)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        let fileName = "\(uuid).tar.gz"
        try await cli.run(
            [
                "run", "--rm",
                "-v", "\(dataDir.path):/data:ro",
                "-v", "\(backups.path):/backup",
                "alpine", "tar", "czf", "/backup/\(fileName)", "-C", "/data", ".",
            ], timeout: .seconds(1800))
        let url = backups.appendingPathComponent(fileName)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return CreatedBackup(uuid: uuid, fileName: fileName, bytes: bytes)
    }

    /// Clears the data dir and extracts the backup over it. The caller MUST stop
    /// the container first.
    public static func restore(cli: DockerCLI, stackDir: URL, dataDirName: String, fileName: String) async throws {
        guard let fileName = validated(fileName: fileName) else { throw BackupError.invalidName }
        let dataDir = stackDir.appendingPathComponent(dataDirName, isDirectory: true)
        let backups = backupsDir(stackDir: stackDir)
        guard FileManager.default.fileExists(atPath: backups.appendingPathComponent(fileName).path) else {
            throw BackupError.notFound
        }
        try await cli.run(
            [
                "run", "--rm",
                "-v", "\(dataDir.path):/data",
                "-v", "\(backups.path):/backup:ro",
                "alpine", "sh", "-c",
                "rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null; tar xzf /backup/\(fileName) -C /data",
            ], timeout: .seconds(1800))
    }

    /// The on-disk backup file, or nil if the name is invalid or missing.
    public static func fileURL(stackDir: URL, fileName: String) -> URL? {
        guard let fileName = validated(fileName: fileName) else { return nil }
        let url = backupsDir(stackDir: stackDir).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func delete(stackDir: URL, fileName: String) throws {
        guard let url = fileURL(stackDir: stackDir, fileName: fileName) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
