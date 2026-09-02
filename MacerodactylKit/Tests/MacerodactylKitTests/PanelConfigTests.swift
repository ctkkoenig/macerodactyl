import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct PanelConfigTests {
    @Test func defaultsAreSane() {
        let config = PanelConfig()
        #expect(config.port == AppSettings.defaultPanelPort)
        #expect(config.bindLAN == false)
        #expect(config.tlsEnabled == false)
        #expect(config.dockerPathOverride == nil)
        #expect(config.stacksRoot.hasSuffix("stacks"))
    }

    @Test func roundTripsThroughJSON() throws {
        let original = PanelConfig(
            port: 30000, bindLAN: true, dockerPathOverride: "/opt/homebrew/bin/docker",
            stacksRoot: "/tmp/stacks", tlsEnabled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PanelConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test func tolerantDecodeFillsMissingKeys() throws {
        // An older config file with only some keys still decodes.
        let json = Data(#"{"port": 28000, "bindLAN": true}"#.utf8)
        let config = try JSONDecoder().decode(PanelConfig.self, from: json)
        #expect(config.port == 28000)
        #expect(config.bindLAN == true)
        #expect(config.tlsEnabled == false)  // defaulted
        #expect(config.dockerPathOverride == nil)  // defaulted
    }

    @Test func stacksRootURLExpandsTilde() {
        let config = PanelConfig(stacksRoot: "~/mystacks")
        #expect(config.stacksRootURL.path.hasSuffix("/mystacks"))
        #expect(!config.stacksRootURL.path.contains("~"))
    }
}
