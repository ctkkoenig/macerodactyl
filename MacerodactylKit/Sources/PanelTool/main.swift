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
        print("no such user: \(name)"); exit(1)
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
    guard args.count == 3 else { print("usage: paneltool \(args[0]) USERNAME PASSWORD"); exit(64) }
    let user = try await accounts.createUser(username: args[1], password: args[2], isAdmin: args[0] == "add-admin")
    print("created \(user.username) (admin: \(user.isAdmin))")

case "grant":
    guard args.count == 4 else { print("usage: paneltool grant USERNAME CONTAINER view,power,files,console"); exit(64) }
    let user = try findUser(args[1])
    let perms = Set(args[3].split(separator: ",").map(String.init))
    let grant = ContainerGrant(
        view: perms.contains("view"), power: perms.contains("power"),
        files: perms.contains("files"), console: perms.contains("console")
    )
    try accounts.setGrant(userID: user.id, containerName: args[2], grant: grant, filesGrantable: true)
    print("granted \(args[1]) on \(args[2]): \(perms.sorted().joined(separator: ", "))")

case "audit":
    for entry in try store.listAudit(limit: 50).reversed() {
        print("\(entry.timestamp)  \(entry.username)  \(entry.action)  \(entry.containerName ?? "-")  \(entry.outcome)  \(entry.sourceIP ?? "-")")
    }

default:
    print("usage: paneltool list | add-admin U P | add-user U P | grant U CONTAINER perms | audit")
    print("db: \(dbPath)")
}
