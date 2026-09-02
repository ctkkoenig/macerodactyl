import Foundation
import Testing
@testable import MacerodactylKit

@Suite struct RCONPacketTests {
    @Test func encodesAuthPacketWireFormat() {
        let packet = RCONPacket(id: 7, type: RCONPacket.authType, body: "hunter2")
        let data = packet.encoded()
        // length = 4 (id) + 4 (type) + 7 (body) + 2 (nulls) = 17
        #expect(data.count == 21)
        #expect(data.readLE(at: 0) == 17)
        #expect(data.readLE(at: 4) == 7)
        #expect(data.readLE(at: 8) == 3)
        #expect(data[data.count - 2] == 0 && data[data.count - 1] == 0)
        #expect(String(decoding: data[12..<19], as: UTF8.self) == "hunter2")
    }

    @Test func decodeRoundTrips() {
        let original = RCONPacket(id: 42, type: RCONPacket.responseType, body: "There are 0 of a max of 20 players online")
        var buffer = original.encoded()
        let decoded = RCONPacket.decode(from: &buffer)
        #expect(decoded == original)
        #expect(buffer.isEmpty)
    }

    @Test func decodeWaitsForCompleteFrame() {
        let full = RCONPacket(id: 1, type: 0, body: "hello").encoded()
        var partial = full.prefix(6) as Data
        #expect(RCONPacket.decode(from: &partial) == nil)
        #expect(partial.count == 6) // untouched

        // Two packets glued together decode one at a time.
        var doubled = full + RCONPacket(id: 2, type: 0, body: "again").encoded()
        #expect(RCONPacket.decode(from: &doubled)?.id == 1)
        #expect(RCONPacket.decode(from: &doubled)?.body == "again")
        #expect(doubled.isEmpty)
    }

    @Test func decodeHandlesNonZeroStartIndex() {
        // Data slices keep their parent's indices; decode must be offset-safe.
        var buffer = Data([0xFF, 0xFF]) + RCONPacket(id: 9, type: 0, body: "x").encoded()
        buffer.removeFirst(2)
        #expect(RCONPacket.decode(from: &buffer)?.id == 9)
    }

    @Test func garbageLengthDropsBuffer() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0x7F, 1, 2, 3])
        #expect(RCONPacket.decode(from: &buffer) == nil)
        #expect(buffer.isEmpty)
    }

    @Test func authFailureUsesMinusOne() {
        var buffer = RCONPacket(id: -1, type: RCONPacket.commandType, body: "").encoded()
        #expect(RCONPacket.decode(from: &buffer)?.id == -1)
    }
}

@Suite struct MinecraftDetectionTests {
    private func inspectJSON(env: [String], image: String, ports: String) -> Data {
        Data("""
        [{"Config": {"Env": \(toJSON(env)), "Image": "\(image)"},
          "NetworkSettings": {"Ports": \(ports)}}]
        """.utf8)
    }

    private func toJSON(_ strings: [String]) -> String {
        String(decoding: try! JSONEncoder().encode(strings), as: UTF8.self)
    }

    @Test func detectsPublishedRCON() {
        let json = inspectJSON(
            env: ["EULA=TRUE", "RCON_PASSWORD=fixturepass", "PATH=/usr/bin"],
            image: "itzg/minecraft-server",
            ports: #"{"25565/tcp": null, "25575/tcp": [{"HostIp": "0.0.0.0", "HostPort": "25575"}]}"#
        )
        #expect(MinecraftRCON.parse(inspectJSON: json)
            == .available(RCONEndpoint(host: "127.0.0.1", port: 25575, password: "fixturepass")))
    }

    @Test func honorsCustomRCONPort() {
        let json = inspectJSON(
            env: ["RCON_PASSWORD=pw", "RCON_PORT=9999"],
            image: "itzg/minecraft-server",
            ports: #"{"9999/tcp": [{"HostIp": "0.0.0.0", "HostPort": "31000"}]}"#
        )
        #expect(MinecraftRCON.parse(inspectJSON: json)
            == .available(RCONEndpoint(host: "127.0.0.1", port: 31000, password: "pw")))
    }

    @Test func unpublishedPortIsUnreachableNotExec() {
        let json = inspectJSON(
            env: ["RCON_PASSWORD=pw"],
            image: "itzg/minecraft-server",
            ports: #"{"25565/tcp": null}"#
        )
        if case .unreachable = MinecraftRCON.parse(inspectJSON: json) {
        } else {
            Issue.record("expected .unreachable — a Minecraft server must NEVER fall back to docker exec")
        }
    }

    @Test func ordinaryContainerIsNotMinecraft() {
        let json = inspectJSON(
            env: ["PATH=/usr/bin"],
            image: "nginx:alpine",
            ports: #"{"80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "27980"}]}"#
        )
        #expect(MinecraftRCON.parse(inspectJSON: json) == .notMinecraft)
    }
}

@Suite struct ConsoleArgTests {
    @Test func execArgsAreArraysNotShellStrings() {
        // The user's line reaches docker as ONE argv element for the
        // container's shell; the host never interprets it.
        let args = DockerArgs.exec(containerID: "abc", commandLine: "ls -la; echo $(whoami) && rm -rf /tmp/x")
        #expect(args == ["exec", "abc", "/bin/sh", "-c", "ls -la; echo $(whoami) && rm -rf /tmp/x"])
    }

    @Test func logArgs() {
        #expect(DockerArgs.logs(containerID: "abc") == ["logs", "--follow", "--tail", "500", "abc"])
        #expect(DockerArgs.logs(containerID: "abc", tail: 100, timestamps: true)
            == ["logs", "--follow", "--tail", "100", "--timestamps", "abc"])
    }
}

@MainActor
@Suite struct LogBufferTests {
    @Test func capsScrollbackWithHeadroom() {
        let buffer = LogBuffer(cap: 1000)
        buffer.append((0..<2500).map { "line \($0)" })
        #expect(buffer.lines.count <= 1000)
        #expect(buffer.lines.last?.text == "line 2499")
        // Oldest lines were dropped, order preserved.
        let ids = buffer.lines.map(\.id)
        #expect(ids == ids.sorted())
    }

    @Test func idsStayUniqueAcrossClear() {
        let buffer = LogBuffer(cap: 1000)
        buffer.append(["a", "b"])
        let lastID = buffer.lines.last!.id
        buffer.clear()
        buffer.append("c")
        #expect(buffer.lines.first!.id > lastID)
    }
}
