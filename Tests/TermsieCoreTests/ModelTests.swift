import Foundation
import XCTest
@testable import TermsieCore

final class TerminalDefinitionTests: CoreTestCase {
    func testHandWrittenDefinitionDecodesWithDefaults() throws {
        let def = try JSONDecoder().decode(TerminalDefinition.self, from: Data(#"{"cwd": "~/src/api"}"#.utf8))
        XCTAssertTrue(def.id.hasPrefix("t-"))
        XCTAssertEqual(def.cwd, "~/src/api")
        XCTAssertTrue(def.runCommandsOnReopen)
        XCTAssertTrue(def.isolatedHistory)
        XCTAssertNil(def.frame)
        XCTAssertEqual(def.displayName, "api")
    }

    func testDegenerateFrameIsDropped() throws {
        let def = try JSONDecoder().decode(TerminalDefinition.self,
                                           from: Data(#"{"frame": [0, 0, 0, 1]}"#.utf8))
        XCTAssertNil(def.frame)
    }

    func testCommandsSkipBlankAndCommentedLines() {
        var def = TerminalDefinition()
        def.startupCommands = ["npm run dev", "  ", "# not this", "echo ok"]
        XCTAssertEqual(def.commands(isReopen: false), ["npm run dev", "echo ok"])
        def.runCommandsOnReopen = false
        XCTAssertEqual(def.commands(isReopen: true), [])
    }

    func testModificationSignatureIgnoresStackingAndFocus() {
        var a = TabLayout.single()
        var b = a
        b.terminals[0].z = 7
        b.selected = b.terminals[0].id
        XCTAssertEqual(a.modificationSignature(), b.modificationSignature())
        a.terminals[0].name = "api"
        XCTAssertNotEqual(a.modificationSignature(), b.modificationSignature())
    }

    func testRegeneratingIDsKeepsUntakenOnes() {
        let layout = TabLayout(terminals: [TerminalDefinition(id: "t-a"), TerminalDefinition(id: "t-b")],
                               selected: "t-a")
        let fresh = layout.regeneratingIDs(avoiding: ["t-a"])
        XCTAssertNotEqual(fresh.terminals[0].id, "t-a")
        XCTAssertEqual(fresh.terminals[1].id, "t-b")
        XCTAssertEqual(fresh.selected, fresh.terminals[0].id)
    }
}

final class WorkspaceFormatTests: CoreTestCase {
    func testVersionTwoWorkspace() throws {
        let json = #"{"version": 2, "name": "web", "layout": {"terminals": [{"id": "t-1", "name": "api"}]}}"#
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(ws.name, "web")
        XCTAssertEqual(ws.layout.terminals.map(\.id), ["t-1"])
    }

    func testVersionOneSplitTreeMigratesToFloatingTerminals() throws {
        let json = """
        {"name": "old", "layout": {"type": "split", "orientation": "horizontal", "sizes": [1, 3],
          "children": [{"type": "pane", "title": "left", "cwd": "~/a"},
                       {"type": "split", "orientation": "vertical",
                        "children": [{"title": "top", "command": "make"}, {"title": "bottom"}]}]}}
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        let terms = ws.layout.terminals
        XCTAssertEqual(terms.map(\.name), ["left", "top", "bottom"])
        XCTAssertEqual(terms[1].startupCommands, ["make"])
        XCTAssertEqual(terms.map(\.z), [0, 1, 2])
        let left = try XCTUnwrap(terms[0].fractionalFrame)
        XCTAssertEqual(left.width, 0.25, accuracy: 1e-9)
        let bottom = try XCTUnwrap(terms[2].fractionalFrame)
        XCTAssertEqual(bottom.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(bottom.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(bottom.maxX, 1, accuracy: 1e-9)
    }

    func testSessionReadsBothTabFormats() throws {
        let json = """
        {"windows": [{"frame": [0,0,800,600], "selectedTab": 1, "tabs": [
            {"type": "pane", "title": "legacy"},
            {"terminals": [{"id": "t-new"}]}
        ]}]}
        """
        let session = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(session.windows.count, 1)
        XCTAssertEqual(session.windows[0].tabs[0].terminals.first?.name, "legacy")
        XCTAssertEqual(session.windows[0].tabs[1].terminals.first?.id, "t-new")
    }

    func testSaveAndLoadRoundTrip() throws {
        let layout = TabLayout(terminals: [TerminalDefinition(id: "t-x", name: "x", cwd: "~/x")])
        try WorkspaceStore.save(Workspace(name: "round/trip", layout: layout))
        XCTAssertTrue(WorkspaceStore.list().contains("round-trip"))
        let loaded = try WorkspaceStore.load(name: "round-trip")
        XCTAssertEqual(loaded.layout.terminals.first?.cwd, "~/x")
    }

    func testFileSafeNames() {
        XCTAssertEqual(WorkspaceStore.fileSafeName("a/b"), "a-b")
        #if os(Windows)
        XCTAssertEqual(WorkspaceStore.fileSafeName(#"a\b:c*d?e"f<g>h|i"#), "a-b-c-d-e-f-g-h-i")
        #endif
    }
}

final class WorkspaceDocumentTests: CoreTestCase {
    func testJSONRoundTrip() throws {
        var def = TerminalDefinition(id: "t-1", name: "api", cwd: "~/api", startupCommands: ["make"])
        def.env = [EnvVar(name: "PORT", value: "3000")]
        var settings = WorkspaceSettings()
        settings.fontSize = 14
        let doc = WorkspaceDocument(settings: settings, definitions: [def])
        let parsed = try WorkspaceDocument(jsonText: doc.jsonText())
        XCTAssertEqual(parsed, doc)
    }

    func testBooleansAndNumbersAreToldApart() throws {
        // `true` must not pass as a number, nor `1` as a boolean, on any platform.
        XCTAssertThrowsError(try WorkspaceDocument(jsonText: #"{"terminals": [{"lineWrap": 1}]}"#))
        XCTAssertThrowsError(try WorkspaceDocument(jsonText: #"{"terminals": [{"fontSize": true}]}"#))
        let ok = try WorkspaceDocument(jsonText: #"{"terminals": [{"lineWrap": false, "fontSize": 12}]}"#)
        XCTAssertEqual(ok.terminals[0].lineWrap, false)
        XCTAssertEqual(ok.terminals[0].fontSize, 12)
    }

    func testUnknownKeyIsReported() {
        XCTAssertThrowsError(try WorkspaceDocument(jsonText: #"{"terminals": [{"startupCommand": "x"}]}"#)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("startupCommand"))
        }
    }

    func testShorthandVariablesAndScalars() throws {
        let doc = try WorkspaceDocument(jsonText: #"{"terminals": [{"env": {"A": 1, "B": true, "C": "x"}}]}"#)
        let env = doc.terminals[0].env
        XCTAssertEqual(env.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(env.map(\.value), ["1", "true", "x"])
    }

    func testSecretValuesNeverReachJSON() throws {
        let backend = MemorySecretBackend()
        SecretStore.backend = backend
        var doc = try WorkspaceDocument(jsonText: #"{"terminals": [{"env": [{"name": "TOKEN", "value": "hunter2", "secret": true}]}]}"#)
        let created = doc.stashSecrets()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(backend.values[created[0]], "hunter2")
        XCTAssertFalse(doc.jsonText().contains("hunter2"))
        XCTAssertEqual(doc.problems(environments: []), [])
    }
}

final class EnvironmentVariableTests: CoreTestCase {
    func testNames() {
        XCTAssertNil(EnvVar.problem(withName: "PATH_2"))
        XCTAssertNotNil(EnvVar.problem(withName: "2X"))
        XCTAssertNotNil(EnvVar.problem(withName: "A-B"))
        XCTAssertNotNil(EnvVar.problem(withName: "TERMSIE_X"))
    }

    func testTerminalOverridesWorkspaceAndMissingSecretsAreReported() {
        let backend = MemorySecretBackend()
        backend.values["s-1"] = "secret-value"
        SecretStore.backend = backend
        let workspace = [EnvVar(name: "A", value: "ws"), EnvVar(name: "B", value: "ws")]
        let terminal = [EnvVar(name: "A", value: "term"), EnvVar(name: "T", secret: true, secretRef: "s-1"),
                        EnvVar(name: "M", secret: true, secretRef: "s-missing")]
        let resolved = EnvVar.resolve([workspace, terminal])
        XCTAssertEqual(resolved.values["A"], "term")
        XCTAssertEqual(resolved.values["B"], "ws")
        XCTAssertEqual(resolved.values["T"], "secret-value")
        XCTAssertNil(resolved.values["M"])
        XCTAssertEqual(resolved.missing, ["M"])
    }

    func testSecretValueIsDroppedFromFiles() throws {
        let decoded = try JSONDecoder().decode(EnvVar.self, from: Data(#"{"name":"T","value":"leak","secret":true}"#.utf8))
        XCTAssertEqual(decoded.value, "")
        let encoded = String(decoding: try JSONEncoder().encode(EnvVar(name: "T", value: "leak", secret: true, secretRef: "s")), as: UTF8.self)
        XCTAssertFalse(encoded.contains("leak"))
    }
}

final class ConfigTests: CoreTestCase {
    func testEmptyConfigUsesPlatformDefaults() throws {
        let config = try JSONDecoder().decode(TermsieConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config, TermsieConfig())
        #if os(Windows)
        XCTAssertEqual(config.font.family, "Cascadia Mono")
        XCTAssertEqual(config.shellArgs, [])
        #else
        XCTAssertEqual(config.font.family, "Menlo")
        XCTAssertEqual(config.shellArgs, ["-l"])
        #endif
    }

    func testConfigDirectoryHonoursXDG() {
        let dir = ConfigStore.defaultConfigDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/x", "APPDATA": "C:\\AppData"])
        XCTAssertEqual(dir.lastPathComponent, "termsie")
        XCTAssertTrue(dir.path.contains("x"))
        #if os(Windows)
        let win = ConfigStore.defaultConfigDirectory(environment: ["APPDATA": "C:\\Users\\me\\AppData\\Roaming"])
        XCTAssertTrue(win.path.contains("Roaming"))
        #endif
    }

    func testEnvironmentTint() {
        var config = TermsieConfig()
        config.colors.background = "#000000"
        config.environments = [.init(id: "prod", label: "Prod", tint: "#ff0000", strength: 0.5)]
        let bg = config.backgroundRGBA(for: "prod")
        XCTAssertEqual(bg.r, 0.5, accuracy: 0.01)
        XCTAssertEqual(bg.g, 0, accuracy: 0.01)
        XCTAssertEqual(config.backgroundRGBA(for: nil), RGBA.hex("#000000"))
    }

    func testRGBA() {
        XCTAssertEqual(RGBA(hex: "#12141899")?.a ?? 0, Double(0x99) / 255, accuracy: 1e-9)
        XCTAssertNil(RGBA(hex: "#123"))
        XCTAssertEqual(RGBA.hex("#61afef").hexString, "#61afef")
        XCTAssertEqual(RGBA.ansi256(196, palette: []), RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(RGBA.ansi256(232, palette: []).r, 8.0 / 255, accuracy: 1e-9)
    }

    func testFontSpecClampsAndInherits() {
        var config = TermsieConfig()
        config.font.size = 13
        XCTAssertEqual(config.resolvedFontSpec(family: nil, size: 200).size, TermsieConfig.maxFontSize)
        XCTAssertEqual(config.resolvedFontSpec(family: "", size: nil).family, config.font.family)
        XCTAssertEqual(config.resolvedFontSpec(family: "Consolas", size: 9).family, "Consolas")
    }
}

final class ReleaseFeedTests: XCTestCase {
    func testVersions() {
        XCTAssertTrue(ReleaseFeed.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(ReleaseFeed.isNewer("v1.0", than: "0.99.1"))
        XCTAssertFalse(ReleaseFeed.isNewer("0.8.0", than: "0.8"))
        XCTAssertFalse(ReleaseFeed.isNewer("0.8.0", than: "0.8.1"))
    }

    func testParsesAssetsAndDigests() throws {
        let json = """
        {"tag_name": "v0.9.0", "html_url": "https://github.com/x/y/releases/tag/v0.9.0", "body": "notes",
         "assets": [
          {"name": "Termsie-0.9.0.dmg", "browser_download_url": "https://e/a.dmg", "digest": "sha256:aa"},
          {"name": "Termsie-0.9.0-windows-x64.zip", "browser_download_url": "https://e/w.zip", "digest": "sha256:bb"},
          {"name": "Termsie-0.9.0-windows-arm64.zip", "browser_download_url": "https://e/a.zip", "digest": null}
         ]}
        """
        let release = try ReleaseFeed.parse(Data(json.utf8))
        XCTAssertEqual(release.version, "0.9.0")
        XCTAssertEqual(release.windowsZip(arch: "x64")?.sha256, "bb")
        XCTAssertNil(release.windowsZip(arch: "arm64")?.sha256)
        XCTAssertEqual(release.windowsZip(arch: "arm64")?.url.absoluteString, "https://e/a.zip")
        XCTAssertThrowsError(try ReleaseFeed.parse(Data("{}".utf8)))
        XCTAssertEqual(ReleaseFeed.hex([0, 255, 16]), "00ff10")
    }
}
