import Foundation

/// A parsed Pterodactyl egg. This is our normalized, tolerant representation of
/// the real Pterodactyl egg export format (both `PTDL_v1` and `PTDL_v2`). The
/// wire format is messy — polymorphic fields, JSON-encoded-as-string blocks,
/// numbers where strings are expected — so parsing (see `EggParser`) coerces
/// everything into these stable Swift types. The byte-faithful original is kept
/// separately as `raw_json` in the database so re-export never loses a field
/// this model doesn't happen to model.
public struct PterodactylEgg: Sendable, Equatable, Codable {
    /// `meta.version` — "PTDL_v1" or "PTDL_v2" (or whatever a future export says;
    /// we parse best-effort rather than reject unknown versions).
    public var metaVersion: String
    public var name: String
    public var author: String
    public var eggDescription: String
    /// Ordered image choices (first is the default). Order matters — Pterodactyl
    /// presents them as a dropdown whose first entry is the default image.
    public var dockerImages: [ImageOption]
    /// The startup command, with `{{VARIABLE}}` placeholders still in place.
    public var startup: String
    /// `config.files` — a JSON-encoded string in the export; kept verbatim.
    public var configFiles: String
    /// The "server is up" marker(s) from `config.startup.done` (normalized to an
    /// array; a single string becomes a one-element array).
    public var doneStrings: [String]
    /// `config.logs` — JSON-encoded string; kept verbatim.
    public var configLogs: String
    /// `config.stop` — the stop command or signal (e.g. "stop", "^C").
    public var configStop: String
    public var install: InstallScript
    public var variables: [EggVariable]
    /// v2 `features` (e.g. "eula", "java_version"); `[]` on v1.
    public var features: [String]
    /// v2 `file_denylist`; `[]` on v1.
    public var fileDenylist: [String]

    public init(
        metaVersion: String,
        name: String,
        author: String = "",
        eggDescription: String = "",
        dockerImages: [ImageOption],
        startup: String,
        configFiles: String = "",
        doneStrings: [String] = [],
        configLogs: String = "",
        configStop: String = "",
        install: InstallScript = InstallScript(),
        variables: [EggVariable] = [],
        features: [String] = [],
        fileDenylist: [String] = []
    ) {
        self.metaVersion = metaVersion
        self.name = name
        self.author = author
        self.eggDescription = eggDescription
        self.dockerImages = dockerImages
        self.startup = startup
        self.configFiles = configFiles
        self.doneStrings = doneStrings
        self.configLogs = configLogs
        self.configStop = configStop
        self.install = install
        self.variables = variables
        self.features = features
        self.fileDenylist = fileDenylist
    }

    /// A single "label → image" choice from `docker_images`.
    public struct ImageOption: Sendable, Equatable, Codable {
        public var label: String
        public var image: String
        public init(label: String, image: String) {
            self.label = label
            self.image = image
        }
    }

    /// The egg's install step: a script that runs inside a throwaway container
    /// with the new server's data volume mounted at `/mnt/server`.
    public struct InstallScript: Sendable, Equatable, Codable {
        public var script: String
        /// The install image (e.g. "ghcr.io/pterodactyl/installers:debian").
        public var container: String
        /// The interpreter the script is fed to (e.g. "bash", "ash").
        public var entrypoint: String
        public init(script: String = "", container: String = "", entrypoint: String = "bash") {
            self.script = script
            self.container = container
            self.entrypoint = entrypoint
        }
        /// True when there is an install script that can actually be run.
        public var isRunnable: Bool {
            !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// One service variable — becomes an environment variable in the server
    /// container and is substitutable in the startup command as `{{env}}`.
    public struct EggVariable: Sendable, Equatable, Codable {
        public var name: String
        public var variableDescription: String
        public var envVariable: String
        public var defaultValue: String
        public var userViewable: Bool
        public var userEditable: Bool
        /// Pterodactyl validation rules, split from the "a|b|c" wire form.
        public var rules: [String]
        public init(
            name: String,
            variableDescription: String = "",
            envVariable: String,
            defaultValue: String = "",
            userViewable: Bool = true,
            userEditable: Bool = true,
            rules: [String] = []
        ) {
            self.name = name
            self.variableDescription = variableDescription
            self.envVariable = envVariable
            self.defaultValue = defaultValue
            self.userViewable = userViewable
            self.userEditable = userEditable
            self.rules = rules
        }
    }

    /// The default docker image (first option), or nil if the egg declared none.
    public var defaultImage: String? { dockerImages.first?.image }

    /// True if `image` is one of the egg's declared images (custom images allowed
    /// too, but this lets the UI mark a known one).
    public func declaresImage(_ image: String) -> Bool {
        dockerImages.contains { $0.image == image }
    }
}
