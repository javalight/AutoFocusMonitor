import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mouseMonitor: MouseDisplayMonitor!
    private var focusTracker: FocusTracker!
    private var enabled = true

    private let logPath = "/tmp/autofocusmonitor.log"

    private func log(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        log("launched. AX trusted at start: \(AXIsProcessTrusted())")

        if !ensureAccessibilityPermission() {
            log("not trusted; polling for grant")
            let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.log("trust acquired via polling")
                    self?.startCore()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            return
        }

        log("trusted at launch; starting")
        startCore()
    }

    private func startCore() {
        focusTracker = FocusTracker()
        focusTracker.start()

        mouseMonitor = MouseDisplayMonitor { [weak self] newDisplayID in
            guard let self = self, self.enabled else { return }
            self.focusTracker.activateLastWindow(on: newDisplayID)
        }
        mouseMonitor.start()
    }

    private func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: NSDictionary = [key: true]
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🖥"
            button.toolTip = "AutoFocusMonitor — \(Self.buildStamp)"
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        let buildItem = NSMenuItem(title: "Build: \(Self.buildStamp)", action: nil, keyEquivalent: "")
        buildItem.isEnabled = false
        menu.addItem(buildItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private static let buildStamp: String = {
        // Use the binary's modification time so each rebuild changes this string visibly.
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }()

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        if let button = statusItem.button {
            button.title = enabled ? "🖥" : "🚫"
        }
    }
}
