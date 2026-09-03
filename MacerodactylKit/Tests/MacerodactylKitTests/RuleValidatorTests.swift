import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct RuleValidatorTests {
    private func check(_ value: String?, _ rules: [String]) -> String? {
        RuleValidator.validate(value: value, rules: rules, label: "Field")
    }

    @Test func requiredRejectsEmpty() {
        #expect(check("", ["required", "string"]) != nil)
        #expect(check(nil, ["required"]) != nil)
        #expect(check("x", ["required", "string"]) == nil)
    }

    @Test func emptyOptionalPasses() {
        #expect(check("", ["nullable", "string"]) == nil)
        #expect(check("", ["string"]) == nil)  // not required → empty ok
    }

    @Test func numericAndInteger() {
        #expect(check("12", ["required", "numeric"]) == nil)
        #expect(check("1.5", ["numeric"]) == nil)
        #expect(check("abc", ["numeric"]) != nil)
        #expect(check("1.5", ["integer"]) != nil)
        #expect(check("7", ["integer"]) == nil)
    }

    @Test func inRule() {
        #expect(check("recommended", ["required", "in:recommended,latest"]) == nil)
        #expect(check("nope", ["in:recommended,latest"]) != nil)
    }

    @Test func maxMinAsLengthForStringsAndValueForNumbers() {
        #expect(check("toolongvalue", ["string", "max:5"]) != nil)  // length
        #expect(check("ok", ["string", "max:5"]) == nil)
        #expect(check("9", ["numeric", "max:5"]) != nil)  // value
        #expect(check("3", ["numeric", "max:5"]) == nil)
        #expect(check("ab", ["string", "min:3"]) != nil)
    }

    @Test func regexRule() {
        let jarRule = ["required", #"regex:/^([\w\d._-]+)(\.jar)$/"#]
        #expect(check("server.jar", jarRule) == nil)
        #expect(check("server.txt", jarRule) != nil)
    }

    @Test func eggLevelValidatesEditableEffectiveValues() throws {
        let egg = PterodactylEgg(
            metaVersion: "PTDL_v2", name: "e", dockerImages: [.init(label: "i", image: "i")], startup: "run",
            variables: [
                .init(
                    name: "Jar", envVariable: "SERVER_JARFILE", defaultValue: "server.jar", userEditable: true,
                    rules: ["required", #"regex:/\.jar$/"#]),
                .init(
                    name: "Build", envVariable: "BUILD", defaultValue: "recommended", userEditable: false,
                    rules: ["required", "in:recommended,latest"]),
            ])
        // Valid override + a locked var using its (valid) default → no violations.
        #expect(RuleValidator.validate(egg: egg, values: ["SERVER_JARFILE": "paper.jar"]).isEmpty)
        // Bad override on the editable var → one violation for that env var.
        let bad = RuleValidator.validate(egg: egg, values: ["SERVER_JARFILE": "paper.zip"])
        #expect(bad.map(\.variable) == ["SERVER_JARFILE"])
        // A locked var's user input is ignored (default used), so no violation.
        #expect(RuleValidator.validate(egg: egg, values: ["BUILD": "garbage"]).isEmpty)
    }
}
