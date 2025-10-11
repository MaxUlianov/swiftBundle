import Cocoa

let MAX_ITEMS = 20

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var clipboardEntries: [String] = []
    var lastChangeCount: Int = -1
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // statusItem.button?.title = "Clip"
        // statusItem.button?.image = NSImage(named: NSImage.Name("YourImageName"))
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")

        // Initial menu setup
        updateMenu()

        // Start timer to check clipboard every 0.5 seconds
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                     selector: #selector(checkClipboard),
                                     userInfo: nil, repeats: true)
    }

    @objc func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        if currentChangeCount != lastChangeCount {
            if let copiedString = pasteboard.string(forType: .string),
               !copiedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !clipboardEntries.contains(copiedString) {

                if clipboardEntries.count == MAX_ITEMS {
                    clipboardEntries.removeFirst()
                }
                clipboardEntries.append(copiedString)

                updateMenu()
            }
            lastChangeCount = currentChangeCount
        }
    }

    func updateMenu() {
        let menu = NSMenu()

        // Truncate the item strings so the manu does not have super long strings
        // (purely visual)
        func truncatedTitle(_ title: String) -> String {
            if title.count > 20 {
                let index = title.index(title.startIndex, offsetBy: 20)
                return String(title[..<index]) + "..."
            } else {
                return title
            }
        }

        for entry in clipboardEntries.reversed() {
            let displayTitle = truncatedTitle(entry)
            let item = NSMenuItem(title: displayTitle, action: #selector(menuClicked(_:)), keyEquivalent: "")
            item.representedObject = entry
            menu.addItem(item)
            
            menu.addItem(NSMenuItem.separator())
        }

        statusItem.menu = menu
    }


    @objc func menuClicked(_ sender: NSMenuItem) {
        if let fullContent = sender.representedObject as? String {
            if let index = clipboardEntries.firstIndex(of: fullContent) {
                clipboardEntries.remove(at: index)
            }
            // updateMenu()
            pasteClipboardContent(fullContent)
        }
    }
}


func pasteClipboardContent(_ content: String) {
    // Copy content back to clipboard
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(content, forType: .string)
}