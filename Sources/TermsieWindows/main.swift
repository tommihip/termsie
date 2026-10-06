import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

tw_process_init()
MainQueue.shared.start()

// Secrets live in the Credential Manager. Scripted test runs may use a file instead, and a secret
// still used by an open tab is never deleted.
SecretStore.backend = CredentialSecretBackend()
SecretStore.testModeEnabled = DebugDriver.isActive
SecretStore.openTabs = { App.shared.windows.flatMap { $0.tabs.map { $0.snapshot() } } }

let code = App.shared.run()
App.shared.prepareForExit()
exit(code)
