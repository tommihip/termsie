import AppKit
import TermsieCore

// Secrets live in the login Keychain. Scripted test runs may use a file instead, and a secret
// still used by an open tab is never deleted.
SecretStore.backend = KeychainSecretBackend()
SecretStore.testModeEnabled = DebugDriver.isActive
SecretStore.openTabs = { AppDelegate.shared.controllers.map { $0.snapshot() } }

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
