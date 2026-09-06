import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct EggEditorTests {
    private let base = #"""
        {"meta":{"version":"PTDL_v2","update_url":"https://example.com/e.json"},
         "name":"Old","author":"a","description":"d",
         "docker_images":{"Java 17":"ghcr.io/pterodactyl/yolks:java_17"},
         "startup":"java -jar {{SERVER_JARFILE}}",
         "config":{"files":"{}","startup":"{\"done\":\"Done \"}","logs":"{}","stop":"stop"},
         "scripts":{"installation":{"script":"echo v1","container":"debian","entrypoint":"bash"}},
         "features":["eula"],
         "variables":[{"name":"Jar","env_variable":"SERVER_JARFILE","default_value":"old.jar",
           "user_viewable":true,"user_editable":true,"rules":"required"}]}
        """#

    @Test func patchesFieldsAndPreservesUnmodeledOnes() throws {
        let edits = EggEdits(
            name: "New", startup: "java -Xmx1G -jar {{SERVER_JARFILE}}", stop: "^C",
            installScript: "echo v2",
            images: [(label: "Java 21", image: "ghcr.io/pterodactyl/yolks:java_21")],
            variables: [
                .init(
                    name: "Jar", description: "the jar", envVariable: "SERVER_JARFILE", defaultValue: "new.jar",
                    userViewable: true, userEditable: false, rules: ["required", "string"])
            ])
        let patched = try EggEditor.apply(edits, to: base)
        let egg = try EggParser.parse(patched)
        #expect(egg.name == "New")
        #expect(egg.startup.contains("-Xmx1G"))
        #expect(egg.configStop == "^C")
        #expect(egg.install.script == "echo v2")
        #expect(egg.install.container == "debian")  // untouched
        #expect(egg.dockerImages.first?.image == "ghcr.io/pterodactyl/yolks:java_21")
        #expect(egg.variables.first?.defaultValue == "new.jar")
        #expect(egg.variables.first?.userEditable == false)
        #expect(egg.variables.first?.rules == ["required", "string"])

        // Fields the editor didn't touch survive: meta.update_url + features.
        #expect(EggParser.updateURL(fromJSON: patched)?.absoluteString == "https://example.com/e.json")
        let root = try #require(
            (try JSONSerialization.jsonObject(with: Data(patched.utf8))) as? [String: Any])
        #expect((root["features"] as? [String]) == ["eula"])
        // config.startup (the done regex) was not in the edits → preserved.
        #expect(egg.doneStrings.contains("Done "))
    }

    @Test func onlyProvidedFieldsChange() throws {
        // An edit that touches nothing but the description leaves everything else.
        let patched = try EggEditor.apply(EggEdits(description: "updated only"), to: base)
        let egg = try EggParser.parse(patched)
        #expect(egg.eggDescription == "updated only")
        #expect(egg.name == "Old")
        #expect(egg.startup == "java -jar {{SERVER_JARFILE}}")
        #expect(egg.variables.count == 1)
    }

    @Test func rejectsNonObjectJSON() {
        #expect(throws: EggEditor.EditError.notAnObject) {
            _ = try EggEditor.apply(EggEdits(name: "x"), to: "[]")
        }
    }
}
