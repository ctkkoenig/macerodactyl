import Foundation

public enum FileServiceError: Error, Equatable, Sendable {
    case notFound
    case isDirectory
    case notARegularFile
    case tooLarge(actualBytes: Int, limitBytes: Int)
    case binaryFile
    case escapesRoot
    case invalidPath
    case io(String)
}

public enum LineEnding: String, Sendable, Equatable {
    case lf
    case crlf

    var separator: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        }
    }
}

/// File access for one container, confined to that container's own stack
/// folder. The confinement is enforced *inside* this service — every path,
/// read or write, passes through `PathConfinement.resolve` (real-path
/// resolution + prefix check; rejects `..`, encoded traversal, absolute
/// paths, NUL bytes, and symlink escapes including dangling leaves).
///
/// Construction is the availability gate: a container with no compose
/// working_dir under the stacks root (every bare `docker run` container) has
/// no file root, so `init` returns nil and callers show the permission as
/// unavailable rather than granting it and failing at use.
public struct FileService: Sendable {
    public static let maxEditableBytes = 2 * 1024 * 1024

    public let root: URL

    public init?(container: DockerContainer, stacksRoot: URL) {
        guard let root = PathConfinement.fileRoot(for: container, stacksRoot: stacksRoot) else {
            return nil
        }
        self.root = root
    }

    /// Test seam: a pre-validated root.
    init(validatedRoot: URL) {
        self.root = validatedRoot
    }

    // MARK: Listing

    public struct Entry: Identifiable, Sendable, Hashable {
        public let name: String
        /// Path relative to the confinement root, always "/"-separated, no leading slash.
        public let relativePath: String
        public let isDirectory: Bool
        public let sizeBytes: Int
        public let modified: Date?

        public var id: String { relativePath }
    }

    public func list(_ relativeDirectory: String = "") throws -> [Entry] {
        let directory = try resolve(relativeDirectory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            throw FileServiceError.notFound
        }
        guard isDir.boolValue else { throw FileServiceError.notARegularFile }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: []
            )
        } catch {
            throw FileServiceError.io(error.localizedDescription)
        }

        let prefix = relativeDirectory.isEmpty ? "" : normalized(relativeDirectory) + "/"
        return contents.compactMap { url -> Entry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(
                name: url.lastPathComponent,
                relativePath: prefix + url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                sizeBytes: values.fileSize ?? 0,
                modified: values.contentModificationDate
            )
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Reading

    public struct FileContent: Sendable, Equatable {
        /// Text normalized to "\n" line endings for editing.
        public let text: String
        /// The file's original line ending, restored on save.
        public let lineEnding: LineEnding
        public let modified: Date?
    }

    public func read(_ relativePath: String) throws -> FileContent {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileServiceError.notFound
        }
        guard !isDir.boolValue else { throw FileServiceError.isDirectory }

        // Only regular files (or symlinks already validated to stay in-root):
        // reading a FIFO or device would hang or misbehave.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileType = attributes?[.type] as? FileAttributeType
        guard fileType == .typeRegular || fileType == .typeSymbolicLink else {
            throw FileServiceError.notARegularFile
        }
        let size = (attributes?[.size] as? Int) ?? 0
        guard size <= Self.maxEditableBytes else {
            throw FileServiceError.tooLarge(actualBytes: size, limitBytes: Self.maxEditableBytes)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileServiceError.io(error.localizedDescription)
        }

        // Binary detection: NUL bytes in the head, or not valid UTF-8. The
        // editor must never load (and later mangle) a jar or an image.
        if data.prefix(8192).contains(0) {
            throw FileServiceError.binaryFile
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw FileServiceError.binaryFile
        }

        let lineEnding: LineEnding = raw.contains("\r\n") ? .crlf : .lf
        let text = lineEnding == .crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        return FileContent(text: text, lineEnding: lineEnding, modified: modificationDate(relativePath))
    }

    // MARK: Writing

    /// Atomic save: write to a temp file beside the target, fsync, then swap
    /// into place — a crash mid-save can never truncate the original. The
    /// original line ending is restored.
    public func write(_ relativePath: String, text: String, lineEnding: LineEnding) throws {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            throw FileServiceError.isDirectory
        }
        let restored = lineEnding == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        try atomicWrite(Data(restored.utf8), to: url)
    }

    /// Largest file the panel will accept in a single upload. Bounds memory and
    /// gives a sane guard against filling the disk from one request. Uploads go
    /// into a container's own stack folder (mods, jars, world data), so this is
    /// generous but finite.
    public static let maxUploadBytes = 256 * 1024 * 1024

    /// Writes raw bytes (binary-safe) to a path in the tree, atomically. Used by
    /// file upload. Refuses to overwrite a directory; refuses oversize payloads.
    public func writeData(_ relativePath: String, data: Data) throws {
        guard data.count <= Self.maxUploadBytes else {
            throw FileServiceError.tooLarge(actualBytes: data.count, limitBytes: Self.maxUploadBytes)
        }
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            throw FileServiceError.isDirectory
        }
        // The resolved parent is already confined to the tree; create it so an
        // upload into a new subfolder works without a separate mkdir.
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw FileServiceError.io(error.localizedDescription)
            }
        }
        try atomicWrite(data, to: url)
    }

    /// Downloads a remote file directly into the tree — how you install a jar or
    /// modpack without uploading gigabytes from your laptop. http(s) only,
    /// streamed to a temp file (never all into memory), size-capped, and the
    /// destination is confined like every other write.
    public func pull(from urlString: String, to relativePath: String, maxBytes: Int = maxUploadBytes) async throws {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { throw FileServiceError.invalidPath }
        let dest = try resolve(relativePath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            throw FileServiceError.isDirectory
        }
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FileServiceError.io("download failed (HTTP \(http.statusCode))")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: tempURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw FileServiceError.tooLarge(actualBytes: size, limitBytes: maxBytes) }
        let parent = dest.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: tempURL, to: dest)
        } catch {
            throw FileServiceError.io(error.localizedDescription)
        }
    }

    /// Atomic write: temp file beside the target, fsync, then swap into place —
    /// a crash mid-write can never truncate the original.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).mcdtmp-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: temp)
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw FileServiceError.io(error.localizedDescription)
        }
    }

    // MARK: Directory / rename / delete

    /// Creates a directory (and any missing parents) inside the tree. Idempotent
    /// only in that an existing directory is not an error; an existing *file* at
    /// the path is.
    public func makeDirectory(_ relativePath: String) throws {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw FileServiceError.notARegularFile
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw FileServiceError.io(error.localizedDescription)
        }
    }

    /// Renames/moves an entry. BOTH ends are confined: source and destination
    /// each pass through `resolve`, so neither can point outside the tree. Never
    /// clobbers an existing destination.
    public func move(from: String, to: String) throws {
        let source = try resolve(from)
        let destination = try resolve(to)
        guard FileManager.default.fileExists(atPath: source.path) else { throw FileServiceError.notFound }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileServiceError.io("A file already exists at the destination.")
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw FileServiceError.io(error.localizedDescription)
        }
    }

    /// Deletes a file or directory (recursively) inside the tree. Refuses to
    /// delete the confinement root itself.
    public func delete(_ relativePath: String) throws {
        let url = try resolve(relativePath)
        let resolvedRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().standardizedFileURL
        guard url.standardizedFileURL.path != resolvedRoot.path else {
            throw FileServiceError.invalidPath
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileServiceError.notFound }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FileServiceError.io(error.localizedDescription)
        }
    }

    // MARK: Download

    /// A validated, in-tree regular file plus its size, for streaming download.
    /// Binary is fine here (unlike the text editor). Directories and non-regular
    /// files are rejected.
    public func downloadTarget(_ relativePath: String) throws -> (url: URL, size: Int) {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileServiceError.notFound
        }
        guard !isDir.boolValue else { throw FileServiceError.isDirectory }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileType = attributes?[.type] as? FileAttributeType
        guard fileType == .typeRegular || fileType == .typeSymbolicLink else {
            throw FileServiceError.notARegularFile
        }
        let size = (attributes?[.size] as? Int) ?? 0
        return (url, size)
    }

    // MARK: Change detection

    public func modificationDate(_ relativePath: String) -> Date? {
        guard let url = try? resolve(relativePath) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Internals

    private func resolve(_ relativePath: String) throws -> URL {
        do {
            return try PathConfinement.resolve(relativePath, in: root)
        } catch PathConfinementError.escapesRoot {
            throw FileServiceError.escapesRoot
        } catch PathConfinementError.invalidPath {
            throw FileServiceError.invalidPath
        }
    }

    private func normalized(_ relativePath: String) -> String {
        relativePath.split(separator: "/").joined(separator: "/")
    }
}
