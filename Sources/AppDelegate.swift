import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mouseMonitor: MouseDisplayMonitor!
    private var focusTracker: FocusTracker!
    private var enabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        FileHandle.standardError.write(Data("[mma] launched. AX trusted: \(AXIsProcessTrusted())\n".utf8))

        if !ensureAccessibilityPermission() {
            // First launch: prompt fired. Wait for user to grant, then re-check on a timer.
            let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.startCore()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            return
        }

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
            button.toolTip = "Mouse Monitor Activate"
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        if let button = statusItem.button {
            button.title = enabled ? "🖥" : "🚫"
        }
    }
}
