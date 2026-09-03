import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct AllocationSelectorTests {
    @Test func firstFreeSkipsAssignedAndHostInUse() {
        let ranges = [25565...25570]
        #expect(
            AllocationSelector.firstFree(ranges: ranges, assigned: [25565, 25566], hostInUse: [25567]) == 25568)
        #expect(AllocationSelector.firstFree(ranges: ranges, assigned: [], hostInUse: []) == 25565)
    }

    @Test func firstFreeReturnsNilWhenExhausted() {
        let ranges = [25565...25566]
        #expect(
            AllocationSelector.firstFree(ranges: ranges, assigned: [25565], hostInUse: [25566]) == nil)
    }

    @Test func expandDeduplicatesAndClampsToValidPorts() {
        let ports = AllocationSelector.expand(ranges: [25565...25567, 25566...25568])
        #expect(ports == [25565, 25566, 25567, 25568])
        #expect(AllocationSelector.expand(ranges: [0...1, 65535...65536]) == [1, 65535])
    }

    @Test func publishedHostPortsParsesDockerPsStrings() {
        let strings = [
            "0.0.0.0:27980->80/tcp, :::27980->80/tcp",
            "0.0.0.0:25565->25565/tcp",
            "9000/tcp",  // exposed only, no host mapping
            "",
        ]
        #expect(AllocationSelector.publishedHostPorts(from: strings) == [27980, 25565])
    }
}

@Suite struct ProvisioningStoreTests {
    private func store() throws -> PanelDataStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PanelDataStore(databasePath: dir.appending(path: "p.sqlite").path)
    }

    @Test func generateAndReserveAllocations() throws {
        let s = try store()
        #expect(try s.generateAllocations(ip: "127.0.0.1", ports: Array(25565...25569)) == 5)
        // Re-generating the same ports is idempotent.
        #expect(try s.generateAllocations(ip: "127.0.0.1", ports: Array(25565...25569)) == 0)

        let reserved = try s.reserveAllocations(serverName: "mc1", count: 2)
        #expect(reserved.count == 2)
        #expect(reserved.filter(\.isPrimary).count == 1)
        // The lowest port is the primary.
        #expect(reserved.first(where: \.isPrimary)?.port == 25565)
        // The pool now shows exactly two rows bound to mc1.
        #expect(try s.allocations(forServer: "mc1").count == 2)
    }

    @Test func reserveExcludesLiveHostPortsAndFreesOnDelete() throws {
        let s = try store()
        try s.generateAllocations(ip: "127.0.0.1", ports: Array(25565...25567))
        // 25565 is "in use" by a live container → the reservation should skip it.
        let reserved = try s.reserveAllocations(serverName: "mc1", count: 1, excludingPorts: [25565])
        #expect(reserved.first?.port == 25566)
        // Freeing returns the rows to the pool.
        try s.freeAllocations(serverName: "mc1")
        #expect(try s.allocations(forServer: "mc1").isEmpty)
        #expect(try s.listAllocations().allSatisfy { $0.isFree })
    }

    @Test func perAllocationAssignReleaseAndPrimary() throws {
        let s = try store()
        try s.generateAllocations(ip: "127.0.0.1", ports: Array(25565...25567))
        let free = try s.listAllocations()
        let a = free[0].id
        let b = free[1].id

        // Assign one → it's the server's; a second server can't take it.
        #expect(try s.assignAllocation(id: a, toServer: "mc1") == true)
        #expect(try s.assignAllocation(id: a, toServer: "other") == false)
        try s.setPrimaryAllocation(id: a, forServer: "mc1")
        #expect(try s.allocations(forServer: "mc1").first(where: \.isPrimary)?.id == a)

        // Add a second, promote it → the flag moves.
        #expect(try s.assignAllocation(id: b, toServer: "mc1") == true)
        #expect(try s.setPrimaryAllocation(id: b, forServer: "mc1") == true)
        let assigned = try s.allocations(forServer: "mc1")
        #expect(assigned.first(where: \.isPrimary)?.id == b)
        #expect(assigned.filter(\.isPrimary).count == 1)

        // The primary can't be released; a non-primary can.
        #expect(try s.releaseAllocation(id: b, fromServer: "mc1") == false)  // b is primary now
        #expect(try s.releaseAllocation(id: a, fromServer: "mc1") == true)
        #expect(try s.allocations(forServer: "mc1").map(\.id) == [b])
        // Can't release another server's allocation.
        #expect(try s.releaseAllocation(id: b, fromServer: "someoneelse") == false)
        // setPrimary on an unowned allocation fails.
        #expect(try s.setPrimaryAllocation(id: free[2].id, forServer: "mc1") == false)
    }

    @Test func reserveThrowsWhenPoolExhausted() throws {
        let s = try store()
        try s.generateAllocations(ip: "127.0.0.1", ports: [25565])
        #expect(throws: ProvisioningStoreError.allocationPoolExhausted) {
            _ = try s.reserveAllocations(serverName: "mc1", count: 2)
        }
        // The partial grab was rolled back — the single port is free again.
        #expect(try s.listAllocations().allSatisfy { $0.isFree })
    }

    @Test func importEggRoundTripsThroughRawJSON() throws {
        let s = try store()
        let nestID = try s.createNest(name: "Minecraft", author: "me", description: nil)
        let raw = """
            {"meta":{"version":"PTDL_v2"},"name":"Paper","author":"a","description":"d",
             "docker_images":{"Java 21":"ghcr.io/pterodactyl/yolks:java_21"},
             "startup":"java -jar {{SERVER_JARFILE}}",
             "config":{"files":"{}","startup":"{\\"done\\":\\"Done \\"}","logs":"{}","stop":"stop"},
             "scripts":{"installation":{"script":"echo hi","container":"debian","entrypoint":"bash"}},
             "variables":[{"name":"Jar","env_variable":"SERVER_JARFILE","default_value":"server.jar",
               "user_viewable":true,"user_editable":true,"rules":"required"}]}
            """
        let egg = try EggParser.parse(raw)
        let eggID = try s.importEgg(egg, rawJSON: raw, nestID: nestID)
        let stored = try #require(try s.egg(id: eggID))
        #expect(stored.name == "Paper")
        // The faithful raw JSON re-parses to the same egg (source of truth).
        let reparsed = try stored.parsed()
        #expect(reparsed.startup == "java -jar {{SERVER_JARFILE}}")
        #expect(reparsed.variables.first?.envVariable == "SERVER_JARFILE")
        #expect(stored.dockerImages.first?.image == "ghcr.io/pterodactyl/yolks:java_21")
    }

    @Test func serverRecordRoundTripsWithLimits() throws {
        let s = try store()
        let user = try s.createUser(username: "owner", passwordHash: "h", isAdmin: false)
        let limits = ServerLimits(
            memoryMiB: 2048, swapMiB: 512, cpuPercent: 200, cpuPinning: "0,1", oomKillDisable: true)
        let id = try s.createServerRecord(
            uuid: "uuid-1", name: "mc1", eggID: nil, dockerImage: "img", ownerUserID: user.id,
            limits: limits, startup: "run", values: ["SERVER_JARFILE": "server.jar"])
        #expect(id > 0)
        let record = try #require(try s.serverRecord(name: "mc1"))
        #expect(record.limits.memoryMiB == 2048)
        #expect(record.limits.cpuPinning == "0,1")
        #expect(record.ownerUserID == user.id)
        try s.setServerStatus(name: "mc1", status: "active")
        #expect(try s.serverRecord(name: "mc1")?.status == "active")
        try s.deleteServerRecord(name: "mc1")
        #expect(try s.serverRecord(name: "mc1") == nil)
    }

    @Test func globalSettingsRoundTrip() throws {
        let s = try store()
        #expect(try s.globalSettings() == .default)
        var settings = try s.globalSettings()
        settings.companyName = "Tac-Alerts"
        settings.require2FA = .force
        try s.setGlobalSettings(settings)
        let reloaded = try s.globalSettings()
        #expect(reloaded.companyName == "Tac-Alerts")
        #expect(reloaded.require2FA == .force)
    }
}
