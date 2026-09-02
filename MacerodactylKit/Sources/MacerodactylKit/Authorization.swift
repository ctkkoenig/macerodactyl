import Foundation

/// The separately grantable permissions, modeled on Pterodactyl subusers.
public enum ContainerPermission: String, CaseIterable, Sendable, Codable {
    case view
    case power
    case files
    case console
    case schedules
}

/// Per-container grant for one user. Keyed by container *name*: compose
/// recreates containers with new IDs but stable names, so names are the
/// durable identity grants attach to.
public struct ContainerGrant: Sendable, Equatable, Codable {
    public var view: Bool
    public var power: Bool
    public var files: Bool
    public var console: Bool
    /// Manage scheduled restarts (create/edit/delete launchd agents) over HTTP.
    public var schedules: Bool

    public init(view: Bool = false, power: Bool = false, files: Bool = false, console: Bool = false, schedules: Bool = false) {
        self.view = view
        self.power = power
        self.files = files
        self.console = console
        self.schedules = schedules
    }

    public func allows(_ permission: ContainerPermission) -> Bool {
        switch permission {
        case .view: view
        case .power: power
        case .files: files
        case .console: console
        case .schedules: schedules
        }
    }

    public var isEmpty: Bool { !view && !power && !files && !console && !schedules }
}

/// Pure scoping logic — THE security boundary of the web panel. No I/O, no
/// state; construct one per authenticated request from that user's grants.
///
/// Rules it encodes:
/// - Admins can do everything (file access still requires the container to
///   have a file root at all).
/// - A non-view grant never leaks existence: any permission on an ungranted
///   or invisible container is denied, and callers must translate denial of
///   `view` into 404, not 403.
/// - power/files/console do NOT imply each other, but all of them require
///   view — a user who can't see a container can't act on it.
public struct AuthorizationEngine: Sendable {
    public let isAdmin: Bool
    private let grants: [String: ContainerGrant]

    public init(isAdmin: Bool, grants: [String: ContainerGrant] = [:]) {
        self.isAdmin = isAdmin
        self.grants = grants
    }

    public func canView(containerNamed name: String) -> Bool {
        if isAdmin { return true }
        return grants[name]?.view ?? false
    }

    public func can(_ permission: ContainerPermission, containerNamed name: String) -> Bool {
        if isAdmin { return true }
        guard let grant = grants[name], grant.view else { return false }
        return grant.allows(permission)
    }

    /// Filters a container list down to what this user may know exists.
    public func visible(_ containers: [DockerContainer]) -> [DockerContainer] {
        if isAdmin { return containers }
        return containers.filter { canView(containerNamed: $0.name) }
    }

    /// Filters grouped containers, dropping stacks that end up empty.
    public func visible(_ groups: ContainerGroups) -> ContainerGroups {
        if isAdmin { return groups }
        let stacks = groups.stacks.compactMap { stack -> ContainerStack? in
            let members = visible(stack.containers)
            guard !members.isEmpty else { return nil }
            return ContainerStack(name: stack.name, workingDir: stack.workingDir, containers: members)
        }
        return ContainerGroups(stacks: stacks, unmanaged: visible(groups.unmanaged))
    }
}

public enum PathConfinementError: Error, Equatable, Sendable {
    case invalidPath
    case escapesRoot
}

/// File access confinement: a container's files are its own stack folder under
/// the stacks root, and nothing else.
public enum PathConfinement {
    /// The directory a container's file access is confined to, or nil if it has
    /// none. Containers without a compose working_dir under the stacks root
    /// (bare `docker run`) get NO file access — callers must grey the
    /// permission out rather than grant-then-fail.
    public static func fileRoot(for container: DockerContainer, stacksRoot: URL) -> URL? {
        guard let workingDir = container.composeWorkingDir, !workingDir.isEmpty else { return nil }
        let root = URL(fileURLWithPath: workingDir).standardizedFileURL
        let stacks = stacksRoot.standardizedFileURL
        guard isDescendant(root.path, of: stacks.path), root.path != stacks.path else { return nil }
        return root
    }

    /// Resolves a user-supplied relative path against a confinement root,
    /// throwing unless the result stays inside it. Defends against absolute
    /// paths, "..", percent-encoded traversal, NUL bytes, and symlink escapes.
    /// The target itself may not exist yet (new file being written); its
    /// nearest existing ancestor is what gets symlink-resolved.
    public static func resolve(_ relativePath: String, in root: URL) throws -> URL {
        guard !relativePath.contains("\0") else { throw PathConfinementError.invalidPath }
        // The HTTP layer already percent-decodes; decode once more so a
        // double-encoded %2e%2e cannot sneak through as a literal.
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        guard !decoded.contains("\0"), !decoded.hasPrefix("/"), !decoded.hasPrefix("~") else {
            throw PathConfinementError.invalidPath
        }
        let components = decoded.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains("~") else {
            throw PathConfinementError.escapesRoot
        }

        let resolvedRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().standardizedFileURL
        var candidate = resolvedRoot
        for component in components where component != "." {
            candidate.append(path: component)
        }
        candidate = candidate.standardizedFileURL
        guard candidate.path == resolvedRoot.path || isDescendant(candidate.path, of: resolvedRoot.path) else {
            throw PathConfinementError.escapesRoot
        }

        // Symlinks inside the tree may point anywhere; resolve the nearest
        // existing ancestor and re-check.
        let resolved = resolveThroughExistingAncestor(candidate)
        guard resolved.path == resolvedRoot.path || isDescendant(resolved.path, of: resolvedRoot.path) else {
            throw PathConfinementError.escapesRoot
        }

        // A symlink leaf must land inside the root too — including a dangling
        // one, which a write would otherwise create a file through.
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path) {
            let destinationURL =
                destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : resolved.deletingLastPathComponent().appending(path: destination)
            let final = destinationURL.resolvingSymlinksInPath().standardizedFileURL
            guard final.path == resolvedRoot.path || isDescendant(final.path, of: resolvedRoot.path) else {
                throw PathConfinementError.escapesRoot
            }
        }
        return candidate
    }

    static func isDescendant(_ path: String, of rootPath: String) -> Bool {
        let root = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(root)
    }

    private static func resolveThroughExistingAncestor(_ url: URL) -> URL {
        var existing = url
        var trailing: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in trailing {
            resolved.append(path: component)
        }
        return resolved.standardizedFileURL
    }
}
