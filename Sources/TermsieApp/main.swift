import Foundation
import CTermsieHost
import TermsieCore

tw_process_init()
MainQueue.shared.start()

// Secrets live in the system's store. Scripted test runs may use a file instead, and a secret
// still used by an open tab is never deleted.
SecretStore.backend = SystemSecretBackend()
SecretStore.testModeEnabled = DebugDriver.isActive
SecretStore.openTabs = { App.shared.windows.flatMap { $0.tabs.map { $0.snapshot() } } }

let code = App.shared.run()
App.shared.prepareForExit()
exit(code)
