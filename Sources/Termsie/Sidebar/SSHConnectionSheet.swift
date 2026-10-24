import AppKit

/// Edits where an SSH terminal connects and the credentials it logs in with, for a new SSH
/// terminal or an existing one.
///
/// A sheet rather than more rows in the terminal settings popover: the popover is already as
/// tall as a laptop allows, and a connection is set up once and then rarely touched.
///
/// Secrets typed here go straight to the Keychain on Save, each under a fresh reference (the old
/// one is offered for clean-up), and are never shown again: a saved one is only acknowledged.
final class SSHConnectionSheet: NSViewController, NSTextFieldDelegate {
    /// The connection when saved, or nil when the user turned the terminal back into a local shell.
    typealias Completion = (SSHConnection?) -> Void

    private var connection: SSHConnection
    /// True when the sheet creates a new terminal rather than editing one.
    private let isNew: Bool
    /// True when the terminal already connects over SSH, so it can be turned back into a shell.
    private let hadConnection: Bool
    private let completion: Completion
    /// References replaced or forgotten here, discarded once the new connection is saved.
    private var droppedRefs: [String] = []

    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let identityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyFileField = NSTextField()
    private let keyFileButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let storedKeyView = NSTextView()
    private let storedKeyScroll = NSScrollView()
    private let storedKeyStatus = NSTextField(labelWithString: "")
    private let importKeyButton = NSButton(title: "Import…", target: nil, action: nil)
    private let passwordField = NSSecureTextField()
    private let forgetPasswordButton = NSButton(title: "Forget", target: nil, action: nil)
    private let passphraseField = NSSecureTextField()
    private let forgetPassphraseButton = NSButton(title: "Forget", target: nil, action: nil)
    private let optionsView = NSTextView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    /// Views shown only for one kind of key.
    private var keyFileViews: [NSView] = []
    private var storedKeyViews: [NSView] = []
    /// Layout as built, with room for the tallest key controls. Everything from the key area up
    /// slides down when the chosen key needs less, and the sheet shrinks to match.
    private static let fullHeight: CGFloat = 604
    private static let keyAreaHeight: CGFloat = 106
    private var keyAreaBottom: CGFloat = 0
    private var builtY: [ObjectIdentifier: CGFloat] = [:]

    init(connection: SSHConnection?, creatingTerminal: Bool, completion: @escaping Completion) {
        self.connection = connection ?? SSHConnection()
        self.isNew = creatingTerminal
        self.hadConnection = connection != nil
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: Self.fullHeight))
        let pad: CGFloat = 20
        let width = root.bounds.width - 2 * pad
        var y = root.bounds.height - pad

        func label(_ text: String, x: CGFloat = pad, w: CGFloat? = nil) {
            let l = NSTextField(labelWithString: text)
            l.font = UIFonts.system(size: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: x, y: y - 16, width: w ?? width, height: 16)
            root.addSubview(l)
        }
        func hint(_ text: String, height: CGFloat = 14) -> NSTextField {
            let h = NSTextField(wrappingLabelWithString: text)
            h.font = UIFonts.system(size: 10)
            h.textColor = .tertiaryLabelColor
            h.frame = NSRect(x: pad, y: y - height, width: width, height: height)
            root.addSubview(h)
            return h
        }

        let title = NSTextField(labelWithString: isNew ? "New SSH Terminal" : "SSH Connection")
        title.font = UIFonts.system(size: 14, weight: .semibold)
        title.frame = NSRect(x: pad, y: y - 20, width: width, height: 20)
        root.addSubview(title)
        y -= 34

        label("Host")
        label("Port", x: pad + width - 80, w: 80)
        y -= 20
        hostField.frame = NSRect(x: pad, y: y - 22, width: width - 90, height: 22)
        hostField.placeholderString = "server.example.com or a Host from ~/.ssh/config"
        hostField.delegate = self
        root.addSubview(hostField)
        portField.frame = NSRect(x: pad + width - 80, y: y - 22, width: 80, height: 22)
        portField.placeholderString = "22"
        portField.delegate = self
        root.addSubview(portField)
        y -= 32

        label("User")
        y -= 20
        userField.frame = NSRect(x: pad, y: y - 22, width: width, height: 22)
        userField.placeholderString = "From ~/.ssh/config, or \(NSUserName())"
        userField.delegate = self
        root.addSubview(userField)
        y -= 32

        label("Private key")
        y -= 20
        identityPopUp.frame = NSRect(x: pad - 2, y: y - 24, width: width + 4, height: 24)
        for (title, identity) in [("Use ~/.ssh/config and the SSH agent", SSHConnection.Identity.automatic),
                                  ("Key file on this Mac", .keyFile),
                                  ("Private key stored in the Keychain", .storedKey)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = identity.rawValue
            identityPopUp.menu?.addItem(item)
        }
        identityPopUp.target = self
        identityPopUp.action = #selector(identityChanged)
        root.addSubview(identityPopUp)
        y -= 32

        // The key file and the stored key occupy the same space; only one shows.
        let keyTop = y
        keyFileField.frame = NSRect(x: pad, y: y - 22, width: width - 84, height: 22)
        keyFileField.placeholderString = "~/.ssh/id_ed25519"
        keyFileField.delegate = self
        keyFileButton.bezelStyle = .rounded
        keyFileButton.target = self
        keyFileButton.action = #selector(chooseKeyFile)
        keyFileButton.frame = NSRect(x: pad + width - 80, y: y - 23, width: 80, height: 24)
        root.addSubview(keyFileField)
        root.addSubview(keyFileButton)
        keyFileViews = [keyFileField, keyFileButton]

        y = keyTop
        storedKeyScroll.frame = NSRect(x: pad, y: y - 70, width: width, height: 70)
        storedKeyScroll.hasVerticalScroller = true
        storedKeyScroll.borderType = .bezelBorder
        storedKeyView.font = UIFonts.monospaced(size: 10, weight: .regular)
        storedKeyView.isRichText = false
        storedKeyView.isAutomaticQuoteSubstitutionEnabled = false
        storedKeyView.isAutomaticDashSubstitutionEnabled = false
        storedKeyView.isAutomaticTextReplacementEnabled = false
        storedKeyView.isContinuousSpellCheckingEnabled = false
        storedKeyView.autoresizingMask = [.width]
        storedKeyView.isVerticallyResizable = true
        storedKeyScroll.documentView = storedKeyView
        root.addSubview(storedKeyScroll)
        y -= 76
        storedKeyStatus.font = UIFonts.system(size: 10)
        storedKeyStatus.textColor = .secondaryLabelColor
        storedKeyStatus.frame = NSRect(x: pad, y: y - 18, width: width - 84, height: 16)
        root.addSubview(storedKeyStatus)
        importKeyButton.bezelStyle = .rounded
        importKeyButton.target = self
        importKeyButton.action = #selector(importKey)
        importKeyButton.frame = NSRect(x: pad + width - 80, y: y - 22, width: 80, height: 24)
        root.addSubview(importKeyButton)
        storedKeyViews = [storedKeyScroll, storedKeyStatus, importKeyButton]
        y -= 30
        keyAreaBottom = keyTop - Self.keyAreaHeight

        label("Password")
        y -= 20
        passwordField.frame = NSRect(x: pad, y: y - 22, width: width - 84, height: 22)
        passwordField.delegate = self
        root.addSubview(passwordField)
        forgetPasswordButton.bezelStyle = .rounded
        forgetPasswordButton.target = self
        forgetPasswordButton.action = #selector(forgetPassword)
        forgetPasswordButton.frame = NSRect(x: pad + width - 80, y: y - 23, width: 80, height: 24)
        root.addSubview(forgetPasswordButton)
        y -= 32

        label("Key passphrase")
        y -= 20
        passphraseField.frame = NSRect(x: pad, y: y - 22, width: width - 84, height: 22)
        passphraseField.delegate = self
        root.addSubview(passphraseField)
        forgetPassphraseButton.bezelStyle = .rounded
        forgetPassphraseButton.target = self
        forgetPassphraseButton.action = #selector(forgetPassphrase)
        forgetPassphraseButton.frame = NSRect(x: pad + width - 80, y: y - 23, width: 80, height: 24)
        root.addSubview(forgetPassphraseButton)
        y -= 26
        _ = hint("Both are kept in your Keychain and typed for you when ssh asks. Leave them empty to be asked in the terminal.", height: 26)
        y -= 34

        label("Extra ssh options (Key=Value, one per line)")
        y -= 20
        let optionsScroll = NSScrollView(frame: NSRect(x: pad, y: y - 48, width: width, height: 48))
        optionsScroll.hasVerticalScroller = true
        optionsScroll.borderType = .bezelBorder
        optionsView.font = UIFonts.monospaced(size: 11, weight: .regular)
        optionsView.isRichText = false
        optionsView.isAutomaticQuoteSubstitutionEnabled = false
        optionsView.isAutomaticDashSubstitutionEnabled = false
        optionsView.autoresizingMask = [.width]
        optionsView.isVerticallyResizable = true
        optionsScroll.documentView = optionsView
        root.addSubview(optionsScroll)
        y -= 54
        _ = hint("e.g. ProxyJump=bastion or ServerAliveInterval=30. Startup commands and the working folder in Terminal Settings run on the server.", height: 26)
        y -= 30

        messageLabel.font = UIFonts.system(size: 11)
        messageLabel.textColor = NSColor.hex(ConfigStore.shared.config.colors.bell)
        messageLabel.frame = NSRect(x: pad, y: 52, width: width, height: 30)
        root.addSubview(messageLabel)

        saveButton.title = isNew ? "Connect" : "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.frame = NSRect(x: pad + width - 100, y: 16, width: 100, height: 28)
        root.addSubview(saveButton)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: pad + width - 204, y: 16, width: 100, height: 28)
        root.addSubview(cancel)
        if hadConnection {
            let local = NSButton(title: "Use Local Shell", target: self, action: #selector(useLocalShell))
            local.bezelStyle = .rounded
            local.toolTip = "Turn this terminal back into an ordinary local shell, forgetting the connection."
            local.frame = NSRect(x: pad, y: 16, width: 130, height: 28)
            root.addSubview(local)
        }

        for sub in root.subviews { builtY[ObjectIdentifier(sub)] = sub.frame.minY }
        view = root
        load()
    }

    private func load() {
        hostField.stringValue = connection.host
        portField.stringValue = connection.port.map(String.init) ?? ""
        userField.stringValue = connection.user ?? ""
        identityPopUp.selectItem(at: SSHConnection.Identity.allCases.firstIndex(of: connection.identity) ?? 0)
        keyFileField.stringValue = connection.identityFile ?? ""
        optionsView.string = connection.options.joined(separator: "\n")
        refreshSecretStates()
        identityChanged()
    }

    /// A saved secret is shown as a placeholder only; typing replaces it.
    private func refreshSecretStates() {
        passwordField.placeholderString = connection.passwordRef != nil ? "Saved — type to replace" : "Not saved"
        forgetPasswordButton.isEnabled = connection.passwordRef != nil
        passphraseField.placeholderString = connection.passphraseRef != nil ? "Saved — type to replace" : "Not saved"
        forgetPassphraseButton.isEnabled = connection.passphraseRef != nil
        storedKeyStatus.stringValue = connection.privateKeyRef != nil
            ? "A key is stored. Paste or import another to replace it."
            : "Paste a private key above, or import one from a file."
    }

    private var selectedIdentity: SSHConnection.Identity {
        (identityPopUp.selectedItem?.representedObject as? String).flatMap(SSHConnection.Identity.init) ?? .automatic
    }

    @objc private func identityChanged() {
        let identity = selectedIdentity
        keyFileViews.forEach { $0.isHidden = identity != .keyFile }
        storedKeyViews.forEach { $0.isHidden = identity != .storedKey }
        let needed: CGFloat = switch identity {
        case .automatic: 0
        case .keyFile: 30
        case .storedKey: Self.keyAreaHeight
        }
        let slide = Self.keyAreaHeight - needed
        for sub in view.subviews {
            guard let y = builtY[ObjectIdentifier(sub)], y >= keyAreaBottom else { continue }
            sub.setFrameOrigin(NSPoint(x: sub.frame.minX, y: y - slide))
        }
        let size = NSSize(width: view.frame.width, height: Self.fullHeight - slide)
        if let window = view.window {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: window.isVisible)
        } else {
            view.setFrameSize(size)
        }
    }

    @objc private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.keyFileField.stringValue = ProcessInspector.abbreviateHome(url.path)
        }
    }

    @objc private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                self.messageLabel.stringValue = "That file could not be read as text."
                return
            }
            self.storedKeyView.string = text
            self.messageLabel.stringValue = ""
        }
    }

    @objc private func forgetPassword() {
        if let ref = connection.passwordRef { droppedRefs.append(ref) }
        connection.passwordRef = nil
        passwordField.stringValue = ""
        refreshSecretStates()
    }

    @objc private func forgetPassphrase() {
        if let ref = connection.passphraseRef { droppedRefs.append(ref) }
        connection.passphraseRef = nil
        passphraseField.stringValue = ""
        refreshSecretStates()
    }

    /// Whether a pasted key looks like a private key. A public key is the usual mistake.
    static func keyProblem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ssh-") || t.hasPrefix("ecdsa-") || t.hasPrefix("sk-") {
            return "That is a public key. Paste or import the private key (the file without .pub)."
        }
        guard t.hasPrefix("-----BEGIN"), t.contains("PRIVATE KEY-----") else {
            return "That does not look like a private key: it should start with -----BEGIN … PRIVATE KEY-----."
        }
        return nil
    }

    @objc private func save() {
        var draft = connection
        draft.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.user = user.isEmpty ? nil : user
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        if portText.isEmpty {
            draft.port = nil
        } else if let port = Int(portText) {
            draft.port = port
        } else {
            messageLabel.stringValue = "The port must be a number."
            return
        }
        draft.identity = selectedIdentity
        let keyFile = keyFileField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.identityFile = keyFile.isEmpty ? nil : keyFile
        draft.options = optionsView.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let pastedKey = storedKeyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.identity == .storedKey, !pastedKey.isEmpty, let problem = Self.keyProblem(pastedKey) {
            messageLabel.stringValue = problem
            return
        }
        // Checked before anything is stored, with a stand-in for a key about to be stored.
        var check = draft
        if draft.identity == .storedKey, !pastedKey.isEmpty { check.privateKeyRef = "pending" }
        if let problem = check.problem {
            messageLabel.stringValue = "Cannot save: \(problem)."
            return
        }

        let owner = draft.destination
        var dropped = droppedRefs
        func store(_ value: String, replacing old: String?, label: String) -> String? {
            let ref = SecretStore.newRef()
            guard SecretStore.setValue(value, for: ref, label: "Termsie: \(label) (\(owner))") else { return nil }
            if let old { dropped.append(old) }
            return ref
        }
        if !passwordField.stringValue.isEmpty {
            guard let ref = store(passwordField.stringValue, replacing: draft.passwordRef, label: "SSH password") else {
                messageLabel.stringValue = "The password could not be saved in the Keychain."
                return
            }
            draft.passwordRef = ref
        }
        if !passphraseField.stringValue.isEmpty {
            guard let ref = store(passphraseField.stringValue, replacing: draft.passphraseRef, label: "SSH key passphrase") else {
                messageLabel.stringValue = "The passphrase could not be saved in the Keychain."
                return
            }
            draft.passphraseRef = ref
        }
        if draft.identity == .storedKey, !pastedKey.isEmpty {
            guard let ref = store(pastedKey, replacing: draft.privateKeyRef, label: "SSH private key") else {
                messageLabel.stringValue = "The private key could not be saved in the Keychain."
                return
            }
            draft.privateKeyRef = ref
        }
        // A stored key nobody uses any more is not kept around.
        if draft.identity != .storedKey, let old = draft.privateKeyRef {
            dropped.append(old)
            draft.privateKeyRef = nil
        }
        passwordField.stringValue = ""
        passphraseField.stringValue = ""
        storedKeyView.string = ""
        close()
        completion(draft)
        SecretStore.discard(dropped)
    }

    @objc private func useLocalShell() {
        close()
        completion(nil)
        SecretStore.discard(connection.secretRefs + droppedRefs)
    }

    @objc private func cancel() {
        close()
    }

    private func close() {
        guard let window = view.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    func present(on window: NSWindow) {
        let sheet = NSWindow(contentViewController: self)
        sheet.styleMask = [.titled]
        window.beginSheet(sheet)
        sheet.makeFirstResponder(hadConnection ? passwordField : hostField)
    }
}
