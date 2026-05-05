import Cocoa
import ApplicationServices

private let focusChangedCallback: AXObserverCallback = { _, element, _, userData in
    guard let userData = userData else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(userData).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    DispatchQueue.main.async {
        tracker.recordFocus(for: pid)
    }
}

final class FocusTracker {
    private struct Entry {
        let pid: pid_t
        let window: AXUIElement
    }

    private var lastFocusedByDisplay: [CGDirectDisplayID: Entry] = [:]
    private var observers: [pid_t: AXObserver] = [:]

    func start() {
        for runningApp in NSWorkspace.shared.runningApplications where runningApp.activationPolicy == .regular {
            attachObserver(for: runningApp.processIdentifier)
            recordFocus(for: runningApp.processIdentifier)
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.attachObserver(for: app.processIdentifier)
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.detachObserver(for: app.processIdentifier)
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.recordFocus(for: app.processIdentifier)
            }
        }
    }

    private func attachObserver(for pid: pid_t) {
        guard observers[pid] == nil, pid > 0 else { return }
        var observer: AXObserver?
        let result = AXObserverCreate(pid, focusChangedCallback, &observer)
        guard result == .success, let obs = observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, appElement, kAXMainWindowChangedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, appElement, kAXWindowMovedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }

    private func detachObserver(for pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        for (k, v) in lastFocusedByDisplay where v.pid == pid {
            lastFocusedByDisplay.removeValue(forKey: k)
        }
    }

    func recordFocus(for pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard res == .success, let win = winRef else { return }
        let window = win as! AXUIElement
        guard let displayID = displayID(for: window) else { return }
        lastFocusedByDisplay[displayID] = Entry(pid: pid, window: window)
    }

    func activateLastWindow(on displayID: CGDirectDisplayID) {
        let known = lastFocusedByDisplay[displayID].map { "pid=\($0.pid)" } ?? "none"
        FileHandle.standardError.write(Data("[mma] activate request for display \(displayID), entry: \(known), tracked displays: \(lastFocusedByDisplay.count)\n".utf8))
        var didActivate = false
        if let entry = lastFocusedByDisplay[displayID], isWindowAlive(entry.window) {
            let alreadyActive: Bool = {
                guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == entry.pid else { return false }
                guard let frontWin = focusedWindow(of: entry.pid) else { return false }
                return CFEqual(frontWin, entry.window)
            }()
            if !alreadyActive {
                AXUIElementPerformAction(entry.window, kAXRaiseAction as CFString)
                NSRunningApplication(processIdentifier: entry.pid)?.activate()
                didActivate = true
            }
        } else {
            activateTopmostWindow(on: displayID)
            didActivate = true
        }

        // Activating an app raises ALL of its windows globally, including any it has
        // on other displays — which would cover whatever was previously frontmost there.
        // Re-raise each other display's last-known window (without activating its app)
        // so per-display visual state is preserved.
        if didActivate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.restoreOtherDisplays(except: displayID)
            }
        }
    }

    private func restoreOtherDisplays(except activeDisplay: CGDirectDisplayID) {
        for (otherID, entry) in lastFocusedByDisplay where otherID != activeDisplay {
            guard isWindowAlive(entry.window) else { continue }
            AXUIElementPerformAction(entry.window, kAXRaiseAction as CFString)
        }
    }

    private func activateTopmostWindow(on displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        let infoList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in infoList {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bDict = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bDict["X"] ?? 0, y: bDict["Y"] ?? 0,
                              width: bDict["Width"] ?? 0, height: bDict["Height"] ?? 0)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if bounds.contains(center) {
                if let pid = w[kCGWindowOwnerPID as String] as? pid_t {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                    return
                }
            }
        }
    }

    private func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard res == .success, let w = winRef else { return nil }
        return (w as! AXUIElement)
    }

    private func isWindowAlive(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
    }

    private func displayID(for window: AXUIElement) -> CGDirectDisplayID? {
        // AX position/size are in CG coords (top-left origin, main display at 0,0) — same as CGDisplayBounds.
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        let rect = CGRect(origin: pos, size: size)

        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let result = CGGetDisplaysWithRect(rect, 16, &displays, &count)
        if result == .success && count > 0 {
            return displays[0]
        }
        return nil
    }
}
