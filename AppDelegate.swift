import Cocoa
import SwiftUI
import Carbon.HIToolbox

let MAX_ITEMS = 20

// MARK: - Model

final class ClipboardStore: ObservableObject {
    @Published var entries: [String] = []   // newest first
    @Published var selected: Int = 0
}

// MARK: - Redaction rules

struct RedactionRule: Codable {
    var find: String
    var replace: String
    var regex: Bool?        // default false: raw string match
    var ignoreCase: Bool?   // default true
}

enum Redactor {
    static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("swiftClipBundle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("redactions.json")
    }

    /// Creates a sample file the first time so there is something to edit.
    static func ensureFile() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let samples = [
            RedactionRule(find: "John Smith", replace: "Name Lastname", regex: false, ignoreCase: true),
            RedactionRule(find: "12345678Z", replace: "AAA1234", regex: false, ignoreCase: true),
            RedactionRule(find: #"[\w.+-]+@[\w-]+\.[\w.]+"#, replace: "email@example.com", regex: true, ignoreCase: true),
            RedactionRule(find: #"\b\d{3}[ -]?\d{3}[ -]?\d{3}\b"#, replace: "000-000-000", regex: true, ignoreCase: true),
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(samples) { try? data.write(to: fileURL) }
    }

    static func loadRules() -> [RedactionRule] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([RedactionRule].self, from: data)
        } catch {
            NSLog("redactions.json is invalid: \(error)")
            return []
        }
    }

    static func apply(_ text: String) -> String {
        var result = text
        for rule in loadRules() where !rule.find.isEmpty {
            let ignoreCase = rule.ignoreCase ?? true
            if rule.regex ?? false {
                let opts: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
                guard let re = try? NSRegularExpression(pattern: rule.find, options: opts) else {
                    NSLog("Bad regex: \(rule.find)")
                    continue
                }
                let range = NSRange(result.startIndex..., in: result)
                // $1, $2 ... work in the replacement
                result = re.stringByReplacingMatches(in: result, options: [], range: range,
                                                     withTemplate: rule.replace)
            } else {
                let opts: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
                result = result.replacingOccurrences(of: rule.find, with: rule.replace, options: opts)
            }
        }
        return result
    }
}

// MARK: - Panel (non-activating, so the previous app keeps focus)

final class ClipboardPanel: NSPanel {
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onRedact: (() -> Void)? 

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_DownArrow: onMove?(1)
        case kVK_UpArrow:   onMove?(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter: onConfirm?()
        case kVK_ANSI_R:    onRedact?()
        case kVK_Escape:    orderOut(nil)
        default: break
        }
    }

    // Close when the user clicks elsewhere
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

// MARK: - SwiftUI content

struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    var onPick: (Int) -> Void
    var onRedact: (Int) -> Void
    var onEditRules: () -> Void 

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clipboard").font(.headline)
                Spacer()
                Button("Rules") { onEditRules() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.entries.isEmpty {
                Text("Nothing copied yet")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(store.entries.enumerated()), id: \.offset) { i, entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .lineLimit(3)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .onTapGesture { onPick(i) }

                                    Button { onRedact(i) } label: {
                                        Image(systemName: "eye.slash")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.secondary)
                                    .help("Redact personal data (R)")
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(i == store.selected ? Color.accentColor.opacity(0.35) : Color.clear)
                                )
                                .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: store.selected) { new in
                        proxy.scrollTo(new)
                    }
                }
            }
        }
        .frame(width: 340, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let store = ClipboardStore()
    var panel: ClipboardPanel!
    var lastChangeCount: Int = -1
    var timer: Timer?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon
        Redactor.ensureFile() // $touch rules file for redacting copied text

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "Clipboard")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        setupPanel()
        registerHotKey()

        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                     selector: #selector(checkClipboard),
                                     userInfo: nil, repeats: true)

        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
    }

    // MARK: Panel

    func setupPanel() {
        panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        panel.onMove = { [weak self] delta in
            guard let self = self, !self.store.entries.isEmpty else { return }
            let n = self.store.entries.count
            self.store.selected = max(0, min(n - 1, self.store.selected + delta))
        }
        panel.onConfirm = { [weak self] in
            guard let self = self else { return }
            self.pick(self.store.selected)
        }

        panel.onRedact = { [weak self] in
            guard let self = self else { return }
            self.redact(self.store.selected)
        }

        panel.contentView = NSHostingView(rootView: ClipboardView(
            store: store,
            onPick: { [weak self] i in self?.pick(i) },
            onRedact: { [weak self] i in self?.redact(i) },
            onEditRules: { [weak self] in self?.openRulesFile() }
        ))
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        store.selected = 0

        // Position near the mouse, clamped to the screen
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 10)
        let vf = screen.visibleFrame
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        origin.y = max(vf.minY + 8, min(origin.y, vf.maxY - size.height - 8))
        panel.setFrameOrigin(origin)

        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Picking / pasting

    func pick(_ index: Int) {
        guard store.entries.indices.contains(index) else { return }
        let content = store.entries[index]
        store.entries.remove(at: index)   // gets re-added on top by checkClipboard

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)

        panel.orderOut(nil)

        // Simulate ⌘V in the previously focused app (needs Accessibility permission)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()
        }
    }

    func simulatePaste() {
        // Check silently; no prompt here
        guard AXIsProcessTrusted() else { return }

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Clipboard watching

    @objc func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if let s = pb.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !store.entries.contains(s) {
            store.entries.insert(s, at: 0)
            if store.entries.count > MAX_ITEMS {
                store.entries.removeLast()
            }
        }
    }

    // MARK: Redaction

    func redact(_ index: Int) {
        guard store.entries.indices.contains(index) else { return }
        let original = store.entries[index]
        let redacted = Redactor.apply(original)

        guard redacted != original else {   // no rule matched
            NSSound.beep()
            return
        }

        // Make the redacted text the newest item
        store.entries.removeAll { $0 == redacted }
        store.entries.insert(redacted, at: 0)
        if store.entries.count > MAX_ITEMS { store.entries.removeLast() }
        store.selected = 0

        // Put it on the clipboard, and tell the watcher redacting caused this change
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(redacted, forType: .string)
        lastChangeCount = pb.changeCount
    }

    func openRulesFile() {
        panel.orderOut(nil)
        Redactor.ensureFile()
        // "open -t" uses default text editor
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", Redactor.fileURL.path]
        try? p.run()
    }

    // MARK: Global hotkey (⌘⇧V) — Carbon, needs no special permission

    func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePanel() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let id = EventHotKeyID(signature: OSType(0x434C4950), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}