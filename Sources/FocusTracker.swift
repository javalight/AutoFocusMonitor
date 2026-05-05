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
    // After we activate or raise a window in pid X, that app frequently emits its own
    // focus-change notifications as it settles (e.g. Chrome auto-flipping its main window).
    // Ignore recordFocus from X for a short window so those knock-on events don't overwrite
    // entries that the user genuinely set by clicking.
    private var suppressUntil: [pid_t: Date] = [:]
    private let suppressionDuration: TimeInterval = 0.5

    private let logPath = "/tmp/autofocusmonitor.log"
    private func log(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    private func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid\(pid)"
    }

    private func logDisplayLayout() {
        // Dump all CGDisplays with bounds.
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        for i in 0..<Int(count) {
            let id = ids[i]
            let b = CGDisplayBounds(id)
            log("CGDisplay \(id): bounds=(\(b.origin.x),\(b.origin.y) \(b.size.width)x\(b.size.height))")
        }
        // Dump NSScreens with their reported NSScreenNumber so we can spot mismatches.
        for (i, screen) in NSScreen.screens.enumerated() {
            let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            log("NSScreen[\(i)] NSScreenNumber=\(n) frame=(\(screen.frame.origin.x),\(screen.frame.origin.y) \(screen.frame.size.width)x\(screen.frame.size.height))")
        }
    }

    private func isUserWindow(_ window: AXUIElement) -> Bool {
        // Allow standard windows, dialogs, and similar interactive popups. We used to
        // require kAXStandardWindowSubrole, which dropped real save/confirm dialogs the
        // user genuinely focuses. Keep the size + title checks below — those still filter
        // out transient ghosts (Chrome's split-tab drag previews etc.) without rejecting
        // legitimate popups.
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""
        if title.isEmpty { return false }

        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        if let val = sizeRef {
            var size = CGSize.zero
            AXValueGetValue(val as! AXValue, .cgSize, &size)
            if size.width < 50 || size.height < 50 { return false }
        }
        return true
    }

    private func windowTitle(_ window: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref)
        return (ref as? String) ?? "(no title)"
    }

    func start() {
        logDisplayLayout()
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
        if let until = suppressUntil[pid], Date() < until {
            return
        }
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard res == .success, let win = winRef else { return }
        let window = win as! AXUIElement

        // Filter out transient/ghost windows that Chrome (and others) briefly focus during
        // operations like split-tab — drag previews, popups, drawers, sheets. Tracking them
        // pollutes our state because they aren't windows the user actually wants restored.
        if !isUserWindow(window) {
            return
        }

        guard let displayID = displayID(for: window) else { return }

        // The same window can only live on one display. Drop any stale references
        // to this window that other displays may be holding (e.g. user dragged it across).
        let staleKeys = lastFocusedByDisplay.compactMap { (k, v) -> CGDirectDisplayID? in
            (k != displayID && CFEqual(v.window, window)) ? k : nil
        }
        for k in staleKeys {
            lastFocusedByDisplay.removeValue(forKey: k)
        }

        lastFocusedByDisplay[displayID] = Entry(pid: pid, window: window)
    }

    private func validatedEntry(for displayID: CGDirectDisplayID) -> Entry? {
        guard let entry = lastFocusedByDisplay[displayID] else { return nil }
        guard isWindowAlive(entry.window),
              self.displayID(for: entry.window) == displayID else {
            lastFocusedByDisplay.removeValue(forKey: displayID)
            return nil
        }
        return entry
    }

    func activateLastWindow(on displayID: CGDirectDisplayID) {
        if let entry = validatedEntry(for: displayID) {
            // The recorded AXUIElement can drift over time (apps recreate windows internally,
            // references go stale). Re-discover the actual window of this pid currently on
            // the target display so we're aiming at the live window, not a memory of one.
            let liveWindow = resolveLiveWindow(pid: entry.pid, on: displayID, hint: entry.window)
            let alreadyActive: Bool = {
                guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == entry.pid else { return false }
                guard let frontWin = focusedWindow(of: entry.pid) else { return false }
                return CFEqual(frontWin, liveWindow)
            }()
            if !CFEqual(liveWindow, entry.window) {
                lastFocusedByDisplay[displayID] = Entry(pid: entry.pid, window: liveWindow)
            }
            if !alreadyActive {
                bringWindowForward(pid: entry.pid, window: liveWindow)
            }
        } else {
            activateTopmostWindow(on: displayID)
        }
    }

    private func resolveLiveWindow(pid: pid_t, on displayID: CGDirectDisplayID, hint: AXUIElement) -> AXUIElement {
        // If the hint is still alive and on the right display, prefer it (preserves the
        // user's exact click choice across crosses).
        if isWindowAlive(hint), self.displayID(for: hint) == displayID, isUserWindow(hint) {
            return hint
        }
        // Otherwise enumerate the app's current windows and pick whichever is on the target
        // display. This handles cases where the app rebuilt its window list internally and
        // our stored reference is stale or referring to a different window than what's
        // currently visible.
        let appEl = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement] {
            for w in windows where isUserWindow(w) && self.displayID(for: w) == displayID {
                return w
            }
        }
        return hint
    }

    private func bringWindowForward(pid: pid_t, window: AXUIElement) {
        suppressUntil[pid] = Date().addingTimeInterval(suppressionDuration)
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        applyMainWindowSetters(appEl: appEl, window: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: pid)?.activate()
            // Immediate post-active correction for apps that ignore setters during their
            // own activate-time logic (VS Code / Electron). When this lands fast enough,
            // there's no visible wrong-window flash.
            self?.applyMainWindowSetters(appEl: appEl, window: window)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            // Conditional retry: only fire if VS Code's restore was still in flight and
            // ate our immediate correction. This way the no-flicker path stays no-flicker
            // and we only pay the brief flash when the race goes the other way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                guard let self = self,
                      let actual = self.focusedWindow(of: pid),
                      !CFEqual(actual, window) else { return }
                self.applyMainWindowSetters(appEl: appEl, window: window)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
    }

    private func applyMainWindowSetters(appEl: AXUIElement, window: AXUIElement) {
        AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

@discardableResult
    private func activateTopmostWindow(on displayID: CGDirectDisplayID) -> pid_t? {
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
                    return pid
                }
            }
        }
        return nil
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
