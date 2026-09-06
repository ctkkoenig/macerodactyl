import Foundation
import MacerodactylKit
import MacerodactylPanel

// Ops/verification helper for the web panel's account store.
// Usage (targets the app's real DB by default):
//   paneltool list
//   paneltool add-admin USERNAME PASSWORD
//   paneltool add-user USERNAME PASSWORD
//   paneltool grant USERNAME CONTAINER view,power,files,console
//   paneltool audit

let dbPath = try AppPaths.databasePath()
let store = try PanelDataStore(databasePath: dbPath)
let accounts = AccountManager(store: store)
let args = Array(CommandLine.arguments.dropFirst())

func findUser(_ name: String) throws -> PanelUser {
    guard let user = try store.user(named: name) else {
        print("no such user: \(name)")
        exit(1)
    }
    return user
}

switch args.first {
case "list":
    for user in try accounts.listUsers() {
        let grants = try store.grants(forUserID: user.id)
        let scope = user.isAdmin ? "ALL (admin)" : grants.keys.sorted().joined(separator: ", ")
        print("\(user.username)\(user.isAdmin ? " *" : "")  →  \(scope.isEmpty ? "(no grants)" : scope)")
    }

case "add-admin", "add-user":
    guard args.count == 3 else {
        print("usage: paneltool \(args[0]) USERNAME PASSWORD")
        exit(64)
    }
    let user = try await accounts.createUser(username: args[1], password: args[2], isAdmin: args[0] == "add-admin")
    print("created \(user.username) (admin: \(user.isAdmin))")

case "grant":
    guard args.count == 4 else {
        print("usage: paneltool grant USERNAME CONTAINER view,power,files,console")
        exit(64)
    }
    let user = try findUser(args[1])
    let perms = Set(args[3].split(separator: ",").map(String.init))
    let grant = ContainerGrant(
        view: perms.contains("view"), power: perms.contains("power"),
        files: perms.contains("files"), console: perms.contains("console"),
        schedules: perms.contains("schedules")
    )
    try accounts.setGrant(userID: user.id, containerName: args[2], grant: grant, filesGrantable: true)
    print("granted \(args[1]) on \(args[2]): \(perms.sorted().joined(separator: ", "))")

case "audit":
    for entry in try store.listAudit(limit: 50).reversed() {
        print(
            "\(entry.timestamp)  \(entry.username)  \(entry.action)  \(entry.containerName ?? "-")  \(entry.outcome)  \(entry.sourceIP ?? "-")"
        )
    }

case "daemon":
    // Manage the web-panel LaunchAgent: install <binpath> | uninstall | status.
    let manager = try PanelDaemonManager()
    switch args.count >= 2 ? args[1] : "status" {
    case "install":
        guard args.count == 3 else {
            print("usage: paneltool daemon install <path-to-macerodactyld>")
            break
        }
        try manager.install(daemonBinaryPath: args[2])
        print("installed LaunchAgent → \(manager.plistPath.path)")
        print("binary: \(args[2]); loaded: \(manager.isLoaded())")
    case "uninstall":
        try manager.uninstall()
        print("uninstalled panel LaunchAgent")
    default:
        print("installed: \(manager.isInstalled)  loaded: \(manager.isLoaded())")
        if let path = manager.installedBinaryPath() { print("binary: \(path)") }
    }

case "provision":
    // Live provisioning smoke test. FIXTURE ONLY — always point stacksRoot at a
    // scratch directory, never the user's real ~/stacks.
    //   paneltool provision <egg.json> <name> <scratch-stacks-root> [memoryMiB] [port]
    guard args.count >= 4 else {
        print("usage: paneltool provision <egg.json> <name> <scratch-stacks-root> [memoryMiB] [port]")
        exit(64)
    }
    let eggPath = args[1]
    let serverName = args[2]
    let scratchRoot = URL(fileURLWithPath: (args[3] as NSString).expandingTildeInPath)
    let memoryMiB = args.count > 4 ? (Int(args[4]) ?? 1024) : 1024
    let port = args.count > 5 ? (Int(args[5]) ?? 25565) : 25565

    guard let dockerURL = DockerBinaryLocator.resolve() else {
        print("could not locate the docker binary")
        exit(1)
    }
    let rawEgg = try String(contentsOf: URL(fileURLWithPath: eggPath), encoding: .utf8)
    let egg = try EggParser.parse(rawEgg)
    for warning in EggValidator.validate(egg) { print("⚠︎ \(warning.message)") }
    guard let image = egg.defaultImage else {
        print("egg declares no docker image")
        exit(1)
    }
    let runtime = ServerRuntimeContext(memoryMiB: memoryMiB, port: port, uuid: UUID().uuidString)
    let resolved = VariableResolver.resolveStartup(egg: egg, values: [:], runtime: runtime)
    let stop = ServerStop.from(configStop: egg.configStop)
    let spec = ProvisionSpec(
        name: serverName, image: image, startup: resolved.startup.value, environment: resolved.environment,
        install: egg.install, limits: ServerLimits(memoryMiB: memoryMiB),
        portMappings: [PortMapping(hostIP: "127.0.0.1", hostPort: port, containerPort: port)],
        configFiles: egg.configFiles, stopSignal: stop.signal, stopGracePeriodSeconds: stop.graceSeconds)
    try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    print("Provisioning \"\(serverName)\" from \(egg.name) [\(image)] into \(scratchRoot.path)")
    let service = DaemonContainerService(cli: DockerCLI(binary: dockerURL), stacksRoot: scratchRoot)
    for try await line in await service.provision(spec) { print(line) }

case "deprovision":
    guard args.count == 3 else {
        print("usage: paneltool deprovision <name> <scratch-stacks-root>")
        exit(64)
    }
    guard let dockerURL = DockerBinaryLocator.resolve() else {
        print("could not locate the docker binary")
        exit(1)
    }
    let scratchRoot = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    let service = DaemonContainerService(cli: DockerCLI(binary: dockerURL), stacksRoot: scratchRoot)
    try await service.deprovision(name: args[1])
    print("deprovisioned \(args[1])")

case "db":
    switch args.count >= 2 ? args[1] : "check" {
    case "check", "integrity":
        let result = try store.integrityCheck()
        print("integrity: \(result.joined(separator: "; "))  (\(store.isHealthy ? "healthy" : "PROBLEMS"))")
    case "checkpoint":
        try store.checkpoint()
        print("WAL checkpointed (truncated)")
    case "backup":
        guard args.count == 3 else {
            print("usage: paneltool db backup <destination-path>")
            break
        }
        try store.backup(toPath: args[2])
        print("backup written to \(args[2])")
    case "restore":
        guard args.count == 3 else {
            print("usage: paneltool db restore <backup-path>  (STOP the panel first)")
            break
        }
        let sidelined = try PanelBackup.restore(from: args[2], to: dbPath)
        print("restored from \(args[2]); previous DB kept at \(sidelined)")
    default:
        print("usage: paneltool db check | checkpoint | backup <path> | restore <path>")
    }

default:
    print("usage: paneltool list | add-admin U P | add-user U P | grant U CONTAINER perms | audit")
    print("       paneltool daemon install <macerodactyld-path> | uninstall | status")
    print("       paneltool db check | checkpoint | backup <path> | restore <path>")
    print("db: \(dbPath)")
}
