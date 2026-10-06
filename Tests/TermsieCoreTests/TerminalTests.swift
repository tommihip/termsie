import Foundation
import XCTest
import SwiftTerm
@testable import TermsieCore

final class CommandMarkTests: XCTestCase {
    func testSequencesSplitAcrossReads() {
        let scanner = CommandMarkScanner()
        let stream = Array("ab\u{1b}]133;A\u{07}prompt\u{1b}]133;B\u{1b}\\x\u{1b}[2Jy\u{1b}]133;C\u{07}".utf8)
        var events: [CommandMarkScanner.Event] = []
        for split in stream.indices {
            scanner.reset()
            events = scanner.scan(stream[..<split]).map(\.event) + scanner.scan(stream[split...]).map(\.event)
            XCTAssertEqual(events, [.promptStart, .inputStart, .screenCleared, .commandStart], "split at \(split)")
        }
    }

    func testPartialClearsAreNotEvents() {
        let scanner = CommandMarkScanner()
        XCTAssertTrue(scanner.scan(ArraySlice(Array("\u{1b}[J\u{1b}[1J\u{1b}[0J".utf8))).isEmpty)
        XCTAssertEqual(scanner.scan(ArraySlice(Array("\u{1b}[3J".utf8))).map(\.event), [.scrollbackCleared])
    }

    func testLifecycle() {
        var state = CommandMarkState()
        XCTAssertFalse(state.hasMarks)
        state.apply(.promptStart)
        XCTAssertFalse(state.newestPromptOwnsACommand(liveJob: true) == false && state.reportsCommandLifecycle)
        XCTAssertTrue(state.newestPromptOwnsACommand(liveJob: true))
        state.apply(.commandStart)
        XCTAssertTrue(state.reportsCommandLifecycle)
        state.apply(.promptStart)
        XCTAssertFalse(state.newestPromptOwnsACommand(liveJob: true))
    }
}

final class TextCaptureTests: CoreTestCase {
    func testRowCountAndText() {
        let (terminal, _) = makeTerminal(cols: 20, rows: 5)
        for i in 0..<12 { terminal.feed(text: "line \(i)\r\n") }
        let capture = TerminalTextCapture(terminal)
        XCTAssertEqual(capture.rowCount, 13)
        XCTAssertEqual(capture.screenTopRow, 8)
        XCTAssertEqual(capture.lastContentRow(), 11)
        XCTAssertTrue(capture.text(rows: 0...1).contains("line 0"))
    }

    func testPromptRowsComeFromMarks() {
        let (terminal, _) = makeTerminal(cols: 30, rows: 6)
        terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}a b\r\n")
        terminal.feed(text: "\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}")
        let capture = TerminalTextCapture(terminal)
        XCTAssertEqual(capture.promptRows(limit: 5), [2, 0])
        XCTAssertEqual(capture.inputText(rows: 0...0), "ls")
    }

    func testTidied() {
        XCTAssertEqual(TerminalTextCapture.tidied("\n a  \nb\t\n\n", enabled: true), " a\nb")
        XCTAssertEqual(TerminalTextCapture.strippingPromptPrefix("user@host ~ % git status"), "git status")
        XCTAssertEqual(TerminalTextCapture.strippingPromptPrefix("PS C:\\src> dir"), "dir")
    }
}

final class OutputSnapshotTests: CoreTestCase {
    func testCaptureKeepsColourAndDropsIdlePrompt() throws {
        let (terminal, _) = makeTerminal(cols: 30, rows: 6)
        terminal.feed(text: "plain\r\n\u{1b}[31mred\u{1b}[0m text\r\n")
        terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}")
        let text = try XCTUnwrap(OutputSnapshot.capture(terminal, lines: 100, dropIdlePrompt: true))
        XCTAssertTrue(text.hasPrefix("plain"))
        XCTAssertTrue(text.contains("\u{1b}[0;31mred"))
        XCTAssertFalse(text.contains("$"))
    }

    func testAlternateScreenIsNotCaptured() {
        let (terminal, _) = makeTerminal()
        terminal.feed(text: "keep\r\n\u{1b}[?1049hfull screen")
        XCTAssertNil(OutputSnapshot.capture(terminal, lines: 10))
    }

    func testSaveReplayDiscard() throws {
        let (terminal, _) = makeTerminal()
        terminal.feed(text: "hello\r\n")
        OutputSnapshot.save(terminal, key: "t-snapshot", lines: 10, atPrompt: false)
        let replay = try XCTUnwrap(OutputSnapshot.replay(key: "t-snapshot"))
        XCTAssertTrue(replay.hasPrefix("hello"))
        XCTAssertTrue(replay.contains(OutputSnapshot.ruleMarker))
        OutputSnapshot.discard(key: "t-snapshot")
        XCTAssertNil(OutputSnapshot.load(key: "t-snapshot"))
    }
}

final class GeometryTests: XCTestCase {
    func testTileGridSharesEdges() {
        let canvas = NSRect(x: 0, y: 0, width: 1001, height: 601)
        let rects = Arrange.tileGrid(in: canvas, count: 5)
        XCTAssertEqual(rects.count, 5)
        XCTAssertEqual(rects[0].maxX, rects[1].minX)
        XCTAssertEqual(rects[2].maxX, canvas.maxX)
        XCTAssertEqual(rects[3].maxX, rects[4].minX)
        XCTAssertEqual(rects[4].maxX, canvas.maxX)
        XCTAssertEqual(rects.last?.maxY, canvas.maxY)
    }

    func testHalvesCoverTheCanvas() {
        let c = NSRect(x: 10, y: 20, width: 301, height: 201)
        XCTAssertEqual(Arrange.half(.left, in: c).maxX, Arrange.half(.right, in: c).minX)
        XCTAssertEqual(Arrange.half(.right, in: c).maxX, c.maxX)
    }

    func testZonesInBothCoordinateSystems() {
        let b = NSRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertNil(PaneChrome.zone(at: NSPoint(x: 100, y: 50), in: b))
        XCTAssertEqual(PaneChrome.zone(at: NSPoint(x: 1, y: 99), in: b), .topLeft)
        XCTAssertEqual(PaneChrome.zone(at: NSPoint(x: 1, y: 99), in: b, flipped: true), .bottomLeft)
        XCTAssertEqual(PaneChrome.zone(at: NSPoint(x: 100, y: 1), in: b, flipped: true), .top)
        let offset = NSRect(x: 50, y: 50, width: 200, height: 100)
        XCTAssertEqual(PaneChrome.zone(at: NSPoint(x: 249, y: 100), in: offset, flipped: true), .right)
    }

    func testProposeRespectsMinimumSize() {
        let start = NSRect(x: 0, y: 0, width: 300, height: 200)
        let shrunk = PaneChrome.propose(start, zone: .left, delta: NSPoint(x: 500, y: 0))
        XCTAssertEqual(shrunk.width, PaneChrome.minSize.width)
        XCTAssertEqual(shrunk.maxX, start.maxX)
    }
}

final class PlatformTests: XCTestCase {
    func testHomePath() {
        XCTAssertEqual(HomePath.abbreviate("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(HomePath.abbreviate("/Users/me/src", home: "/Users/me/"), "~/src")
        XCTAssertEqual(HomePath.abbreviate("/Users/meow", home: "/Users/me"), "/Users/meow")
        XCTAssertEqual(HomePath.lastComponent("C:\\src\\api\\"), "api")
        XCTAssertEqual(HomePath.lastComponent("/a/b"), "b")
        #if os(Windows)
        XCTAssertEqual(HomePath.abbreviate("c:\\users\\me\\src", home: "C:\\Users\\Me"), "~\\src")
        XCTAssertEqual(HomePath.expand("~/src/api", home: "C:\\Users\\me"), "C:\\Users\\me\\src\\api")
        #else
        XCTAssertEqual(HomePath.expand("~/src", home: "/home/me"), "/home/me/src")
        #endif
    }

    func testShellKinds() {
        XCTAssertEqual(ShellKind.of("C:\\Program Files\\PowerShell\\7\\pwsh.exe"), .pwsh)
        XCTAssertEqual(ShellKind.of("powershell.exe"), .powershell)
        XCTAssertEqual(ShellKind.of("C:\\Windows\\System32\\cmd.exe"), .cmd)
        XCTAssertEqual(ShellKind.of("/bin/zsh"), .zsh)
        XCTAssertEqual(ShellKind.of("-zsh"), .zsh)
        XCTAssertEqual(ShellKind.of("C:/Program Files/Git/bin/bash.exe"), .bash)
        XCTAssertEqual(ShellKind.of("wsl.exe"), .wsl)
        XCTAssertEqual(ShellKind.displayName("C:\\x\\pwsh.exe"), "pwsh")
    }

    func testJSONShape() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"t":true,"o":1,"z":0,"d":1.5}"#.utf8)) as! [String: Any]
        XCTAssertTrue(JSONShape.isBool(parsed["t"]!))
        XCTAssertFalse(JSONShape.isBool(parsed["o"]!))
        XCTAssertFalse(JSONShape.isBool(parsed["z"]!))
        XCTAssertTrue(JSONShape.isNumber(parsed["d"]!))
        XCTAssertFalse(JSONShape.isNumber(parsed["t"]!))
    }
}

final class ShellIntegrationTests: CoreTestCase {
    private func config() -> TermsieConfig {
        var c = TermsieConfig()
        c.shellIntegration = "auto"
        return c
    }

    func testPowerShellIsShimmedThroughAScriptBlock() throws {
        let plan = ShellIntegration.prepare(shell: "C:\\Program Files\\PowerShell\\7\\pwsh.exe", shellArgs: [],
                                            paneKey: "t-ps", commands: ["Get-Date", "npm run dev"],
                                            isolateHistory: true, config: config(), inheritedEnv: [:])
        XCTAssertEqual(plan.mode, .powershell)
        XCTAssertTrue(plan.runsStartupCommands)
        XCTAssertEqual(plan.environment["TERMSIE_STARTUP_COUNT"], "2")
        XCTAssertEqual(plan.environment["TERMSIE_STARTUP_2"], "npm run dev")
        XCTAssertEqual(plan.environment["TERMSIE_MARKS"], "1")
        XCTAssertNotNil(plan.environment["TERMSIE_HISTFILE"])
        XCTAssertEqual(Array(plan.shellArgs.prefix(3)), ["-NoLogo", "-NoExit", "-Command"])
        let command = try XCTUnwrap(plan.shellArgs.last)
        XCTAssertTrue(command.hasPrefix(". ([scriptblock]::Create([IO.File]::ReadAllText('"))
        let dir = PaneStateStore.directory(for: "t-ps").appendingPathComponent(ShimScripts.powerShellFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testPowerShellScriptArgumentsDisableTheShim() {
        let plan = ShellIntegration.prepare(shell: "pwsh", shellArgs: ["-File", "x.ps1"], paneKey: "t-f",
                                            commands: [], isolateHistory: true, config: config(), inheritedEnv: [:])
        XCTAssertEqual(plan.mode, .disabled)
        XCTAssertEqual(plan.shellArgs, ["-File", "x.ps1"])
    }

    func testUserArgumentsAreKeptAndNotDuplicated() {
        let args = ShimScripts.powerShellArguments(scriptPath: "C:\\it's\\termsie.ps1", userArgs: ["-NoExit"])
        XCTAssertEqual(args.filter { $0 == "-NoExit" }.count, 1)
        XCTAssertTrue(args.last!.contains("C:\\it''s\\termsie.ps1"))
    }

    func testCmdAndWslAreLeftAlone() {
        for shell in ["C:\\Windows\\System32\\cmd.exe", "wsl.exe"] {
            let plan = ShellIntegration.prepare(shell: shell, shellArgs: [], paneKey: "t-c", commands: ["dir"],
                                                isolateHistory: true, config: config(), inheritedEnv: [:])
            XCTAssertEqual(plan.mode, .disabled, shell)
            XCTAssertFalse(plan.runsStartupCommands)
        }
    }

    func testIntegrationOffMeansNothing() {
        var c = config()
        c.shellIntegration = "off"
        let plan = ShellIntegration.prepare(shell: "pwsh.exe", shellArgs: [], paneKey: "t-o", commands: [],
                                            isolateHistory: true, config: c, inheritedEnv: [:])
        XCTAssertEqual(plan.mode, .disabled)
        XCTAssertEqual(plan.shellArgs, [])
    }

    func testPowerShellScriptAvoidsSevenOnlySyntax() {
        let script = ShimScripts.powerShell
        XCTAssertFalse(script.contains(" ?? "), "?? needs PowerShell 7")
        XCTAssertFalse(script.contains(" && "), "&& needs PowerShell 7")
        XCTAssertEqual(script.filter { $0 == "{" }.count, script.filter { $0 == "}" }.count)
        XCTAssertEqual(script.filter { $0 == "(" }.count, script.filter { $0 == ")" }.count)
    }

    func testZshShimStillUsesZdotdir() {
        let plan = ShellIntegration.prepare(shell: "/bin/zsh", shellArgs: ["-l"], paneKey: "t-z", commands: [],
                                            isolateHistory: true, config: config(), inheritedEnv: [:])
        XCTAssertEqual(plan.mode, .zsh)
        XCTAssertNotNil(plan.environment["ZDOTDIR"])
        XCTAssertEqual(plan.shellArgs, ["-l"])
    }
}

final class CanvasGeometryTests: XCTestCase {
    func testFractionRoundTripAndReachability() {
        let g = CanvasGeometry(bounds: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let f = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let r = g.rect(for: f)
        XCTAssertEqual(r, CGRect(x: 100, y: 120, width: 500, height: 300))
        XCTAssertEqual(g.fraction(for: r).minX, 0.1, accuracy: 1e-9)
        // Far off to the right is pulled back until enough of it shows.
        let off = g.rect(for: CGRect(x: 0.95, y: 0.9, width: 0.5, height: 0.5))
        XCTAssertLessThanOrEqual(off.minX, 1000 - PaneChrome.keepVisible)
        XCTAssertLessThanOrEqual(off.minY, 600 - min(PaneChrome.keepVisible, off.height))
    }

    func testSnapsToNeighbourEdges() {
        let g = CanvasGeometry(bounds: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let other = CGRect(x: 500, y: 0, width: 300, height: 300)
        let proposed = CGRect(x: 205, y: 5, width: 290, height: 200)   // right edge at 495, top at 5
        let snapped = g.resolve(proposed, others: [other], zone: .move, snapping: true)
        XCTAssertEqual(snapped.maxX, 500)
        XCTAssertEqual(snapped.minY, 0)
        XCTAssertEqual(g.resolve(proposed, others: [other], zone: .move, snapping: false), proposed)
    }

    func testNeighbourFocus() {
        let active = CGRect(x: 0, y: 0, width: 100, height: 100)
        let right = CGRect(x: 120, y: 0, width: 100, height: 100)
        let below = CGRect(x: 0, y: 120, width: 100, height: 100)
        XCTAssertEqual(CanvasGeometry.neighbor(of: active, in: [right, below], direction: .right), 0)
        XCTAssertEqual(CanvasGeometry.neighbor(of: active, in: [right, below], direction: .down), 1)
        XCTAssertNil(CanvasGeometry.neighbor(of: active, in: [right, below], direction: .left))
    }
}
