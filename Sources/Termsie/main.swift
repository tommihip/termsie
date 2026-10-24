import AppKit

// Run by `ssh` as its SSH_ASKPASS helper: answer the prompt and exit, never becoming an app.
if SSHAskpass.isRequested { exit(SSHAskpass.run()) }

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
