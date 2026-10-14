import Foundation
import XCTest
import SwiftTerm
@testable import TermsieCore
#if os(Windows)
import ucrt
#endif

/// Points the config directory at a throwaway folder before anything touches `ConfigStore`,
/// so no test ever reads or writes the real configuration.
enum TestEnvironment {
    static let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("termsie-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setVariable("XDG_CONFIG_HOME", dir.path)
        return dir
    }()

    static func prepare() {
        _ = root
        _ = ConfigStore.shared
    }

    static func setVariable(_ name: String, _ value: String) {
        #if os(Windows)
        _ = _putenv_s(name, value)
        #else
        setenv(name, value, 1)
        #endif
    }
}

class CoreTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestEnvironment.prepare()
    }
}

/// Secret values held in memory, standing in for the Keychain or Credential Manager.
final class MemorySecretBackend: SecretBackend {
    var values: [String: String] = [:]
    func value(for ref: String) -> String? { values[ref] }
    func setValue(_ value: String, for ref: String, label: String) -> Bool { values[ref] = value; return true }
    func remove(_ ref: String) { values.removeValue(forKey: ref) }
}

/// The least a SwiftTerm terminal needs to run without a view.
final class HeadlessDelegate: TerminalDelegate {
    var sent: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
}

func makeTerminal(cols: Int = 40, rows: Int = 10, scrollback: Int = 500) -> (Terminal, HeadlessDelegate) {
    let delegate = HeadlessDelegate()
    let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
    let terminal = Terminal(delegate: delegate, options: options)
    return (terminal, delegate)
}
