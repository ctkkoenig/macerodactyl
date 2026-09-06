import Foundation
import Testing

@testable import MacerodactylKit

// A realistic PTDL_v2 Forge egg: docker_images map, bash `$(...)` startup,
// config.startup as a JSON-encoded string, string rules, and mixed-type
// default_value / user_viewable / user_editable to exercise coercion.
private let forgeV2 = """
    {
      "_comment": "an unknown key that must be ignored",
      "meta": { "version": "PTDL_v2", "update_url": null },
      "exported_at": "2024-01-01T00:00:00+00:00",
      "name": "Forge Minecraft",
      "author": "test@example.com",
      "description": "A Forge server",
      "features": ["eula", "java_version"],
      "docker_images": {
        "Java 21": "ghcr.io/pterodactyl/yolks:java_21",
        "Java 17": "ghcr.io/pterodactyl/yolks:java_17"
      },
      "file_denylist": [],
      "startup": "java -Xms128M -XX:MaxRAMPercentage=95.0 $( [[ ! -f unix_args.txt ]] && printf %s \\"-jar {{SERVER_JARFILE}}\\" || printf %s \\"@unix_args.txt\\" )",
      "config": {
        "files": "{\\"server.properties\\":{\\"parser\\":\\"properties\\"}}",
        "startup": "{\\"done\\":\\")! For help, type \\"}",
        "logs": "{}",
        "stop": "stop"
      },
      "scripts": {
        "installation": {
          "script": "#!/bin/bash\\napt update\\necho installing",
          "container": "ghcr.io/pterodactyl/installers:debian",
          "entrypoint": "bash"
        }
      },
      "variables": [
        {
          "name": "Server Jar File",
          "description": "The jar to run",
          "env_variable": "SERVER_JARFILE",
          "default_value": "server.jar",
          "user_viewable": true,
          "user_editable": true,
          "rules": "required|regex:/^([a-z]+)(.jar)$/"
        },
        {
          "name": "Build Type",
          "description": "recommended or latest",
          "env_variable": "BUILD_TYPE",
          "default_value": "recommended",
          "user_viewable": 1,
          "user_editable": 0,
          "rules": "required|string"
        },
        {
          "name": "Max Players",
          "description": "cap",
          "env_variable": "MAX_PLAYERS",
          "default_value": 20,
          "user_viewable": true,
          "user_editable": true
        }
      ]
    }
    """

// A PTDL_v1 egg: a single top-level `image`, `done` as an array, and a variable
// with no `rules` key at all.
private let bungeeV1 = """
    {
      "meta": { "version": "PTDL_v1" },
      "name": "Bungeecord",
      "author": "old@example.com",
      "description": "Proxy",
      "image": "quay.io/pterodactyl/core:java",
      "startup": "java -Xms128M -Xmx{{SERVER_MEMORY}}M -jar {{SERVER_JARFILE}}",
      "config": {
        "files": "{}",
        "startup": "{\\"done\\":[\\"Listening on \\",\\"Started\\"]}",
        "logs": "{\\"custom\\":false}",
        "stop": "end"
      },
      "scripts": {
        "installation": {
          "script": "#!/bin/ash\\necho hi",
          "container": "alpine:3.4",
          "entrypoint": "ash"
        }
      },
      "variables": [
        {
          "name": "Jar File",
          "env_variable": "SERVER_JARFILE",
          "default_value": "bungeecord.jar",
          "user_viewable": true,
          "user_editable": true
        }
      ]
    }
    """

@Suite struct EggParserTests {
    @Test func parsesV2CoreFields() throws {
        let egg = try EggParser.parse(forgeV2)
        #expect(egg.metaVersion == "PTDL_v2")
        #expect(egg.name == "Forge Minecraft")
        #expect(egg.author == "test@example.com")
        #expect(egg.features == ["eula", "java_version"])
        #expect(egg.configStop == "stop")
        #expect(egg.install.container == "ghcr.io/pterodactyl/installers:debian")
        #expect(egg.install.entrypoint == "bash")
        #expect(egg.install.isRunnable)
    }

    @Test func normalizesDockerImageMapDeterministically() throws {
        let egg = try EggParser.parse(forgeV2)
        // Two images, ordered deterministically by label (JSON object order is
        // not preserved, so we sort for stability).
        #expect(egg.dockerImages.count == 2)
        #expect(egg.dockerImages.map(\.label) == ["Java 17", "Java 21"])
        #expect(egg.defaultImage == "ghcr.io/pterodactyl/yolks:java_17")
        #expect(egg.declaresImage("ghcr.io/pterodactyl/yolks:java_21"))
    }

    @Test func normalizesDoneStringVsArray() throws {
        let v2 = try EggParser.parse(forgeV2)
        #expect(v2.doneStrings == [")! For help, type "])
        let v1 = try EggParser.parse(bungeeV1)
        #expect(v1.doneStrings == ["Listening on ", "Started"])
    }

    @Test func coercesMixedVariableTypes() throws {
        let egg = try EggParser.parse(forgeV2)
        let byEnv = Dictionary(uniqueKeysWithValues: egg.variables.map { ($0.envVariable, $0) })
        // Numeric default coerces to a clean integer string, never "true".
        #expect(byEnv["MAX_PLAYERS"]?.defaultValue == "20")
        // Integer 1/0 for viewable/editable coerce to real bools.
        #expect(byEnv["BUILD_TYPE"]?.userViewable == true)
        #expect(byEnv["BUILD_TYPE"]?.userEditable == false)
        // String rules split on '|'.
        #expect(byEnv["SERVER_JARFILE"]?.rules == ["required", "regex:/^([a-z]+)(.jar)$/"])
        // Missing rules key becomes [].
        let v1 = try EggParser.parse(bungeeV1)
        #expect(v1.variables.first?.rules == [])
    }

    @Test func parsesV1SingleImage() throws {
        let egg = try EggParser.parse(bungeeV1)
        #expect(egg.metaVersion == "PTDL_v1")
        #expect(egg.dockerImages == [.init(label: "quay.io/pterodactyl/core:java", image: "quay.io/pterodactyl/core:java")])
        #expect(egg.defaultImage == "quay.io/pterodactyl/core:java")
    }

    @Test func ignoresUnknownKeysAndKeepsConfigBlocksVerbatim() throws {
        let egg = try EggParser.parse(forgeV2)
        // The `_comment`/`exported_at` keys don't break parsing, and the JSON-
        // encoded config.files block is preserved as a string.
        #expect(egg.configFiles.contains("server.properties"))
    }

    @Test func rejectsNonJSONAndMissingStartup() {
        #expect(throws: EggParser.ParseError.notJSON) { try EggParser.parse("not json {") }
        #expect(throws: EggParser.ParseError.missingStartup) {
            try EggParser.parse("{\"name\":\"x\"}")
        }
    }
}

@Suite struct EggValidatorTests {
    @Test func cleanEggHasNoWarnings() throws {
        let egg = try EggParser.parse(forgeV2)
        #expect(EggValidator.validate(egg).isEmpty)
    }

    @Test func flagsUnknownVersionAndBadEnvAndDuplicates() {
        let egg = PterodactylEgg(
            metaVersion: "PTDL_v9",
            name: "x",
            dockerImages: [],
            startup: "run",
            install: .init(script: "echo", container: "", entrypoint: "bash"),
            variables: [
                .init(name: "A", envVariable: "1BAD", defaultValue: ""),
                .init(name: "B", envVariable: "DUP", defaultValue: ""),
                .init(name: "C", envVariable: "DUP", defaultValue: ""),
            ])
        let kinds = Set(EggValidator.validate(egg).map(\.kind))
        #expect(kinds.contains(.unsupportedMetaVersion))
        #expect(kinds.contains(.noDockerImage))
        #expect(kinds.contains(.installScriptWithoutContainer))
        #expect(kinds.contains(.invalidEnvVariableName))
        #expect(kinds.contains(.duplicateEnvVariable))
    }
}

@Suite struct VariableResolverTests {
    private func runtime(mem: Int = 2048, port: Int = 25566) -> ServerRuntimeContext {
        ServerRuntimeContext(memoryMiB: mem, port: port, uuid: "uuid-1", timezone: "UTC")
    }

    @Test func editableOverrideWinsButNonEditableKeepsDefault() throws {
        let egg = try EggParser.parse(forgeV2)
        let env = VariableResolver.environment(
            egg: egg,
            values: ["SERVER_JARFILE": "forge.jar", "BUILD_TYPE": "latest", "MAX_PLAYERS": "50"],
            runtime: runtime())
        #expect(env["SERVER_JARFILE"] == "forge.jar")  // editable → override
        #expect(env["BUILD_TYPE"] == "recommended")  // NOT editable → default, ignore override
        #expect(env["MAX_PLAYERS"] == "50")  // editable → override
    }

    @Test func magicVariablesArePresentAndAuthoritative() throws {
        let egg = try EggParser.parse(forgeV2)
        let env = VariableResolver.environment(egg: egg, values: [:], runtime: runtime(mem: 4096, port: 30000))
        #expect(env["SERVER_MEMORY"] == "4096")
        #expect(env["SERVER_PORT"] == "30000")
        #expect(env["SERVER_IP"] == "0.0.0.0")
        #expect(env["TZ"] == "UTC")
    }

    @Test func substitutesSimpleStartup() throws {
        let egg = try EggParser.parse(bungeeV1)
        let result = VariableResolver.resolveStartup(egg: egg, values: [:], runtime: runtime(mem: 1024))
        #expect(result.startup.value == "java -Xms128M -Xmx1024M -jar bungeecord.jar")
        #expect(result.startup.unknownVariables.isEmpty)
    }

    @Test func substitutesInsideBashStartupPreservingShellSyntax() throws {
        let egg = try EggParser.parse(forgeV2)
        let result = VariableResolver.resolveStartup(egg: egg, values: [:], runtime: runtime())
        // The {{SERVER_JARFILE}} inside the $() expression is replaced; the shell
        // syntax around it is left untouched for the container's own bash.
        #expect(result.startup.value.contains("-jar server.jar"))
        #expect(result.startup.value.contains("$( [[ ! -f unix_args.txt ]]"))
        #expect(result.startup.value.contains("printf %s"))
    }

    @Test func unknownPlaceholderBecomesEmptyAndIsReported() {
        let result = VariableResolver.substitute("start {{FOO}}-{{SERVER_PORT}}", environment: ["SERVER_PORT": "25565"])
        #expect(result.value == "start -25565")
        #expect(result.unknownVariables == ["FOO"])
    }

    @Test func noPlaceholdersReturnsTemplateUnchanged() {
        let result = VariableResolver.substitute("plain command --flag", environment: [:])
        #expect(result.value == "plain command --flag")
        #expect(result.unknownVariables.isEmpty)
    }
}
