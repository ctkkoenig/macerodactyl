import Foundation

/// Resolves the fixed-location system tools the app shells out to, so a machine
/// missing one degrades with an explanation instead of a silent failure.
/// These live at stable absolute paths on stock macOS (Apple Silicon and
/// Intel alike); resolution exists to *notice* the rare absence, not because
/// the path varies by setup.
public struct SystemTools: Sendable {
    private let isExecutable: @Sendable (String) -> Bool

    public init() {
        self.isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Test seam: supply an executability predicate directly.
    public init(isExecutable: @escaping @Sendable (String) -> Bool) {
        self.isExecutable = isExecutable
    }

    /// `/usr/bin/perl` powers the scheduled-restart deadline wrapper. It ships
    /// with every macOS to date (v5.34 on macOS 26), but Apple has signaled
    /// that bundled scripting runtimes may be removed in a future release, so
    /// callers must handle nil rather than assume it. `perlSearchPaths` is
    /// overridable for tests.
    public var perlSearchPaths: [String] = ["/usr/bin/perl"]

    public func perlPath() -> String? {
        perlSearchPaths.first { isExecutable($0) }
    }

    public var launchctlPath: String { "/bin/launchctl" }
}
