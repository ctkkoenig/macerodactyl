import Foundation
import Testing
@testable import MacerodactylKit

@Suite struct HealthParsingTests {
    @Test func healthy() {
        #expect(DockerPSParser.parseHealth(fromStatus: "Up 3 days (healthy)") == .healthy)
    }

    @Test func unhealthy() {
        #expect(DockerPSParser.parseHealth(fromStatus: "Up 41 seconds (unhealthy)") == .unhealthy)
    }

    @Test func starting() {
        #expect(DockerPSParser.parseHealth(fromStatus: "Up 2 seconds (health: starting)") == .starting)
    }

    @Test func exitCodeParensAreNotHealth() {
        #expect(DockerPSParser.parseHealth(fromStatus: "Exited (1) 2 hours ago") == nil)
        #expect(DockerPSParser.parseHealth(fromStatus: "Exited (0) 3 days ago") == nil)
    }

    @Test func noParens() {
        #expect(DockerPSParser.parseHealth(fromStatus: "Up 10 minutes") == nil)
    }
}

@Suite struct LabelParsingTests {
    @Test func simplePairs() {
        let labels = DockerPSParser.parseLabels("a=1,b=2")
        #expect(labels == ["a": "1", "b": "2"])
    }

    @Test func commaInsideValue() {
        let labels = DockerPSParser.parseLabels("desc=hello, world,com.docker.compose.project=web")
        #expect(labels["desc"] == "hello, world")
        #expect(labels["com.docker.compose.project"] == "web")
    }

    @Test func empty() {
        #expect(DockerPSParser.parseLabels("") == [:])
    }
}

@Suite struct PSParseAndGroupingTests {
    private func psLine(
        id: String = "abc123", name: String, image: String = "nginx:latest",
        state: String = "running", status: String = "Up 3 days (healthy)",
        labels: String = ""
    ) -> String {
        let dict: [String: String] = [
            "ID": id, "Names": name, "Image": image, "State": state,
            "Status": status, "Ports": "0.0.0.0:8080->80/tcp", "Labels": labels,
        ]
        let data = try! JSONEncoder().encode(dict)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func parsesJSONLines() {
        let output = [
            psLine(name: "web-1", labels: "com.docker.compose.project=web,com.docker.compose.service=nginx,com.docker.compose.project.working_dir=/tmp/stacks/web"),
            psLine(name: "loner", state: "exited", status: "Exited (1) 2 hours ago"),
            "not json at all",
        ].joined(separator: "\n")

        let containers = DockerPSParser.parse(output)
        #expect(containers.count == 2)
        let web = containers.first { $0.name == "web-1" }
        #expect(web?.composeProject == "web")
        #expect(web?.composeService == "nginx")
        #expect(web?.composeWorkingDir == "/tmp/stacks/web")
        #expect(web?.health == .healthy)
        #expect(web?.isRunning == true)

        let loner = containers.first { $0.name == "loner" }
        #expect(loner?.composeProject == nil)
        #expect(loner?.health == nil)
        #expect(loner?.state == .exited)
    }

    @Test func groupsByComposeProjectWithUnmanagedSection() {
        let output = [
            psLine(name: "web-nginx", labels: "com.docker.compose.project=web,com.docker.compose.project.working_dir=/tmp/stacks/web"),
            psLine(name: "web-redis", labels: "com.docker.compose.project=web,com.docker.compose.project.working_dir=/tmp/stacks/web"),
            psLine(name: "bot", labels: "com.docker.compose.project=bot,com.docker.compose.project.working_dir=/tmp/stacks/bot"),
            psLine(name: "bare"),
        ].joined(separator: "\n")

        let groups = DockerPSParser.group(DockerPSParser.parse(output))
        #expect(groups.stacks.map(\.name) == ["bot", "web"])
        #expect(groups.stacks.last?.containers.map(\.name) == ["web-nginx", "web-redis"])
        #expect(groups.stacks.last?.workingDir == "/tmp/stacks/web")
        #expect(groups.unmanaged.map(\.name) == ["bare"])
    }

    @Test func excludesItself() {
        let output = [
            psLine(name: "macerodactyl"),
            psLine(name: "other", image: "ghcr.io/x/macerodactyl:1"),
            psLine(name: "keeper"),
        ].joined(separator: "\n")

        let groups = DockerPSParser.group(DockerPSParser.parse(output))
        #expect(groups.all.map(\.name) == ["keeper"])
    }
}
