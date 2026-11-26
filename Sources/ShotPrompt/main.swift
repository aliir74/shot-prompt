// ShotPrompt: take a screenshot (macOS's own or Shottr's), start typing, and the screenshot plus
// your words open as a new T3 Code thread. The todo board's "hover a card and
// type" launcher, for screenshots.
//
// macOS saves its captures to the Desktop (or the screencapture "location"),
// Shottr to ~/Pictures as SCR-*.png ("Save after capture" on); both tag the
// file as a screen capture. A new one in either folder pops a small thumbnail icon by the mouse, which is where
// the capture region ended. Typing, or clicking the icon, opens the prompt
// panel. Both are non-activating: they take the keyboard without bringing this
// app forward, so no Accessibility or Input Monitoring permission is needed.
// Enter sends the prompt through `t3-dispatch --image`. The icon stays when you
// switch apps and goes on Esc, a Cmd/Ctrl shortcut, or 20 seconds idle. While
// the prompt is empty, Esc, switching apps, or 5 seconds idle closes the
// panel; once you have typed, only Esc does. Cmd shortcuts in the panel edit
// the prompt. Dictation (holding Fn, or Wispr Flow using the microphone with
// any hotkey or hands-free) opens the prompt from the icon and keeps an empty
// prompt open while you talk and a little after. The project
// picker in the panel (Tab, or click it) sends the thread to another T3 project.
// With the pasteIntoT3 setting on, a capture taken in T3 Code skips all of
// that and lands in the chat open there, as if you pressed Cmd+V in it,
// on a new line when text comes before the caret.
// Each capture also reads the window it was taken in (app, title, page
// address or file). The panel shows that as chips you can remove, the prompt
// carries it in a <capture-context> block, and it picks the T3 project. The
// menu bar menu holds the privacy settings for it. With the drag that made
// the capture known, it also names the UI element under it and can add a
// shot of the whole window with the capture outlined. A capture taken while
// you type adds to the prompt's screenshots.

// This file is the AppKit shell: windows, views, event monitors, timers and
// observers. Every decision it acts on lives in ShotPromptCore, which has the tests.

import AppKit
import Carbon.HIToolbox
import CoreAudio
import ServiceManagement
import ShotPromptCore

// Posted by the settings menu after each change, so an open panel follows it.
let settingsChangedNotification = Notification.Name("ShotPromptSettingsChanged")

let config = Config(environment: ProcessInfo.processInfo.environment,
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    screenshotLocation: UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"))

// Where Enter sends: read at every use, so a change in the menu applies at once.
func currentTarget() -> Target {
    currentTarget(stored: UserDefaults.standard.string(forKey: targetKey),
                  dispatchFromEnvironment: config.dispatchFromEnvironment, isInstalled: isInstalled)
}

func isInstalled(_ t: Target) -> Bool {
    if let cli = t.executable { return cliPath(cli) != nil }
    if let id = t.bundleID { return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }
    if t == .clipboard { return true }
    return FileManager.default.isExecutableFile(atPath: config.dispatchBin)
}

func cliPath(_ name: String) -> String? {
    findExecutable(name, in: cliSearchPath(home: config.home))
}

var recentFolders: [String] { UserDefaults.standard.stringArray(forKey: recentFoldersKey) ?? [] }

// T3's projects (when T3 is there) and the folders you sent to.
func allProjects() -> [Project] {
    mergeProjects(t3: loadProjects(databasePath: config.t3Database), recent: recentFolders)
}

func defaultFolder() -> String {
    startFolder(environment: config.cwdFromEnvironment, recent: recentFolders, home: config.home)
}

// Screenshots copied for a CLI or chat app to read after the panel is gone; kept a day.
let stagedRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ShotPrompt/sent")

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Cmd+A, Cmd+V and the other edit shortcuts, which a menu bar would map.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let m = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let name = editCommand(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                  command: m.contains(.command), shift: m.contains(.shift),
                                  option: m.contains(.option), control: m.contains(.control)),
           let responder = firstResponder, responder.tryToPerform(Selector(name), with: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// The capture icon. It handles the click itself, so the click opens the
// prompt instead of moving the window, and works before the icon is key.
final class ClickView: NSView {
    var onClick: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// NSTextView has no placeholder of its own.
final class PromptTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        (placeholder as NSString).draw(
            at: NSPoint(x: x, y: textContainerInset.height),
            withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }
}

// A thin rounded knob with no track, like an overlay scroller, whichever
// scroller style the system picks.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 8 }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let r = rect(for: .knob).insetBy(dx: 2, dy: 2)
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }
}

// While the text fits, stay at the top: the text view scrolls to the caret on
// a new line before the panel has grown to show it.
final class TopClipView: NSClipView {
    var pinTop = true

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        if pinTop { r.origin.y = 0 }
        return r
    }
}

final class Controller: NSObject, NSTextViewDelegate {
    private let watchers = config.captureDirs.map { CaptureWatcher(directory: $0) }
    private var icon: PromptPanel?
    private var panel: PromptPanel?
    private var field: PromptTextView?
    private var scroll: NSScrollView?
    private var clipObservers: [NSObjectProtocol] = []
    private var thumbnail: NSImageView?
    private var status: NSTextField?
    private var picker: NSPopUpButton?
    private var menuOpen = false
    // The app the Tab picker took the front from, until it is back in front.
    private var returnTo: NSRunningApplication?
    private var menuObservers: [NSObjectProtocol] = []
    private var image: URL?
    private var idleTimer: Timer?
    private var keyMonitor: Any?
    private var fnMonitor: Any?
    // Dictation: Fn is down, a dictation app has the microphone (checked
    // by micTimer), and when either was last seen.
    private var fnHeld = false
    private var micLive = false
    private var micTimer: Timer?
    private var dictationEndedAt: Date?
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    // The last app to come forward that is neither Shottr nor this one: the
    // app a capture is taken in, while Shottr is in front for the capture.
    private var lastApp: NSRunningApplication?
    // The apps that came forward and when, to find the one in front at the capture.
    private var appHistory: [(app: NSRunningApplication, since: Date)] = []
    private var lastAppObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    // Counts captures, so a paste still waiting for T3 gives way to a newer one.
    private var captures = 0
    // Counts context reads. Only a new first capture or a dismiss makes a
    // pending read stale; a capture added to the prompt does not.
    private var contextReads = 0
    // The captured window as read (it stays on this Mac), the context the
    // prompt carries (after the settings and any chip you removed), and its chips.
    private var window: WindowInfo?
    private var serverFolder: String?
    private var context = CaptureContext()
    private var autoProject = false
    private var chipViews: [NSButton] = []
    private var chipsHeight: CGFloat = 0
    // The height the panel is animating to. Its frame mid-animation is not
    // the target, and two fits in a row (the chips clearing, then coming
    // back) would otherwise skip the second and leave the first's height.
    private var panelTarget: CGFloat = 0
    private var projects: [Project] = []
    // You chose a project in the picker, so the window no longer picks one.
    private var pickedByHand = false
    // Chips you removed, kept out when a settings change rebuilds the context.
    private var removedKinds = Set<ContextKind>()
    // Captures added while typing, after the first; each shows as a thumbnail chip.
    private var extraImages: [URL] = []
    private var extraChips: [NSButton] = []
    // The last mouse down anywhere, and the last drag (a down and up apart),
    // in AppKit screen points: a capture's drag, which says where and when it
    // was. A click after it does not replace it. Mouse events need no permission.
    private var mouseDown: CGPoint?
    private var drag: (down: CGPoint, up: CGPoint, at: Date)?
    private var mouseMonitor: Any?

    func start() {
        for watcher in watchers {
            watcher.onCapture = { [weak self] url in self?.show(url) }
            // A folder that is missing, or that macOS keeps from this app, is skipped.
            do { try watcher.start() } catch { NSLog("ShotPrompt: cannot watch %@", watcher.directory.path) }
        }
        lastApp = NSWorkspace.shared.frontmostApplication.flatMap { Self.bystander($0) ? nil : $0 }
        if let a = lastApp { appHistory = [(a, .distantPast)] }
        lastAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !Self.bystander(app) else { return }
            guard let self else { return }
            self.lastApp = app
            self.appHistory = Array((self.appHistory + [(app, Date())]).suffix(appHistoryLimit))
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: settingsChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshContext() }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            if e.type == .leftMouseDown { self.mouseDown = point; return }
            if let down = self.mouseDown, hypot(point.x - down.x, point.y - down.y) >= 2 {
                self.drag = (down, point, Date())
            }
        }
    }

    private static func bystander(_ app: NSRunningApplication) -> Bool {
        isBystander(bundleID: app.bundleIdentifier,
                    isSelf: app.processIdentifier == ProcessInfo.processInfo.processIdentifier)
    }

    private var hasText: Bool { !(field?.string.isEmpty ?? true) }

    private func show(_ url: URL) {
        captures += 1
        // A drag that made this capture dates it; macOS may save it seconds later.
        let dragged = dragRegion(of: url) != nil ? drag?.at : nil
        let moment = captureMoment(fileCreated: creationDate(url), mouseUp: dragged, now: Date())
        // The app in front when the capture was taken, not when its file came.
        let app = appInFront(at: moment, history: appHistory)
            ?? capturedApp(front: NSWorkspace.shared.frontmostApplication, previous: lastApp,
                           isBystander: Self.bystander)
        let toT3 = pastesIntoT3(enabled: UserDefaults.standard.bool(forKey: pasteIntoT3Key),
                                capturedBundleID: app?.bundleIdentifier)
        // A new capture while typing joins the prompt's screenshots. While a
        // send is running, the sent screenshots stay.
        switch captureAction(hasText: hasText, editable: field?.isEditable ?? true,
                             count: 1 + extraImages.count, pasteIntoT3: toT3) {
        case .ignore:
            return
        case .addImage:
            extraImages.append(url)
            layoutChips()
        case .full:
            status?.stringValue = "\(maxCaptures) captures at most; remove one to add another"
        case .pasteIntoT3:
            dismiss()
            paste(url, into: app!)
        case .showIcon:
            showIcon(url)
            readContext(app, image: url)
        }
    }

    // Where the capture was on screen (top-left coordinates): macOS's captures
    // say so; for others, the last drag when its size matches the image. Nil
    // for other window and fullscreen captures.
    private func captureRegion(of url: URL) -> CGRect? {
        captureRect(attribute: extendedAttribute(screenCaptureRectAttribute, of: url)) ?? dragRegion(of: url)
    }

    // The last drag's rectangle (top-left coordinates), when its size matches the image.
    private func dragRegion(of url: URL) -> CGRect? {
        guard let d = drag, let pixels = pixelSize(of: url), let primary = NSScreen.screens.first else { return nil }
        let screen = NSScreen.screens.first { $0.frame.contains(d.up) } ?? primary
        return ShotPromptCore.captureRegion(down: d.down, up: d.up, upAge: Date().timeIntervalSince(d.at),
                                            imagePixels: pixels, scale: screen.backingScaleFactor)
            .map { topLeft($0, primaryHeight: primary.frame.height) }
    }

    // Reads the captured window off the main thread (Accessibility calls can
    // take a moment), then shows its chips and picks its project. A newer
    // capture makes the result stale. An excluded app is not read at all.
    private func readContext(_ app: NSRunningApplication?, image: URL) {
        contextReads += 1
        let read = contextReads
        window = nil; serverFolder = nil; context = CaptureContext(); removedKinds = []
        let settings = ContextSettings(value: { UserDefaults.standard.object(forKey: $0) })
        autoProject = settings.autoProject
        applyContext()
        guard let app, !settings.excludes(app.bundleIdentifier) else { return }
        let region = captureRegion(of: image)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var w = Self.readWindow(app, settings: settings)
            if settings.element, let r = region { w.element = Self.element(at: center(r), in: app) }
            if settings.windowShot, CGPreflightScreenCaptureAccess() {
                w.windowShot = Self.windowShot(of: app, region: region, capture: image)
            }
            let server = settings.autoProject ? Self.serverFolder(w) : nil
            DispatchQueue.main.async {
                guard let self, read == self.contextReads else { return Self.discard(w.windowShot) }
                self.window = w
                self.serverFolder = server
                self.refreshContext()
            }
        }
    }

    // The app, and through Accessibility its focused window's title and
    // AXDocument (a browser's page address, a document app's file), else the
    // address of the page in its web area (Electron apps). Safari shows its
    // address to neither. Without the Accessibility grant, only the app.
    private static func readWindow(_ app: NSRunningApplication, settings: ContextSettings) -> WindowInfo {
        var w = WindowInfo(appName: app.localizedName, bundleID: app.bundleIdentifier)
        guard settings.needsAccessibility, AXIsProcessTrusted() else { return w }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 0.5)
        guard let focused = axValue(a, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return w }
        let win = focused as! AXUIElement
        w.title = axValue(win, kAXTitleAttribute) as? String
        w.document = axValue(win, kAXDocumentAttribute) as? String
        if cleanURL(w.document, keepQuery: true) == nil {
            w.webURL = webAreaURL(in: win)
        }
        return w
    }

    // The element under a point, with its ancestors, when it belongs to the
    // captured app (and not, say, the icon this app shows over the capture).
    private static func element(at point: CGPoint, in app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var hit: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let first = hit, AXUIElementGetPid(first, &pid) == .success, pid == app.processIdentifier
        else { return nil }
        var nodes: [ElementInfo] = []
        var node: AXUIElement? = first
        while let e = node, nodes.count < 8 {
            nodes.append(ElementInfo(
                role: axValue(e, kAXRoleAttribute) as? String, subrole: axValue(e, kAXSubroleAttribute) as? String,
                title: axValue(e, kAXTitleAttribute) as? String, label: axValue(e, kAXDescriptionAttribute) as? String,
                value: axValue(e, kAXValueAttribute) as? String, domID: axValue(e, "AXDOMIdentifier") as? String,
                classes: axValue(e, "AXDOMClassList") as? [String] ?? []))
            node = axValue(e, kAXParentAttribute).flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
            }
        }
        return describeElement(nodes)
    }

    // The captured app's window as an image, through `screencapture -l`
    // (Screen Recording), with the capture outlined when its place is known.
    // Nil when the capture already is the whole window.
    private static func windowShot(of app: NSRunningApplication, region: CGRect?, capture: URL) -> URL? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = info.compactMap { w -> ListedWindow? in
            guard let id = w[kCGWindowNumber as String] as? Int, let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = (w[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
            return ListedWindow(id: id, pid: pid, layer: w[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds)
        }
        guard let win = pickWindow(windows, pid: app.processIdentifier, at: region.map(center)) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShotPrompt-window")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("window-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(win.id), out.path]
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0, let shot = pixelSize(of: out) else { discard(out); return nil }
        if let cap = pixelSize(of: capture), !windowShotAdds(capturePixels: cap, shotPixels: shot) {
            discard(out)
            return nil
        }
        if let r = region, let box = outlineRect(region: r, window: win.bounds, shotPixels: shot) {
            drawOutline(on: out, rect: box)
        }
        return out
    }

    // Deletes a window shot: it holds what you cropped out, so it lives only
    // until the prompt is sent (the dispatch has uploaded it by then) or dropped.
    private static func discard(_ url: URL?) {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // The first web area's address, breadth first, within a bounded walk.
    private static func webAreaURL(in window: AXUIElement) -> String? {
        var queue = ArraySlice([window])
        var visited = 0
        let deadline = Date().addingTimeInterval(webAreaSearchSeconds)
        while let e = queue.popFirst(), visited < webAreaSearchLimit, Date() < deadline {
            visited += 1
            if axValue(e, kAXRoleAttribute) as? String == "AXWebArea", let u = axValue(e, "AXURL") {
                return (u as? URL)?.absoluteString ?? u as? String
            }
            queue.append(contentsOf: axValue(e, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return nil
    }

    // The folder of the server behind a localhost page, through lsof.
    private static func serverFolder(_ w: WindowInfo) -> String? {
        guard let port = localPort(w.document) ?? localPort(w.webURL),
              let pid = lsofField(lsof(["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]), "p") else { return nil }
        return lsofField(lsof(["-a", "-p", pid, "-d", "cwd", "-Fn"]), "n")
    }

    private static func lsof(_ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // Shows the context in the open panel and lets the window pick the project.
    private func applyContext() {
        layoutChips()
        guard autoProject, !pickedByHand, let pp = picker, let w = window,
              let root = matchProject(w, serverFolder: serverFolder, projects: projects),
              let item = pp.itemArray.first(where: { $0.representedObject as? String == root }) else { return }
        pp.select(item)
        pp.toolTip = "T3 project for the new thread, picked from the window you captured (Tab to change)"
        layoutStatus()
    }

    // One removable chip per piece of context, between the prompt and the
    // status row. The prompt moves up to make room.
    private func layoutChips() {
        guard let content = panel?.contentView, scroll != nil else { return }
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = contextChips(context).map { chip in
            let b = NSButton(title: chip.label, target: self, action: #selector(removeChip(_:)))
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = .systemFont(ofSize: 10)
            b.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
            b.imagePosition = .imageTrailing
            b.lineBreakMode = .byTruncatingTail
            b.refusesFirstResponder = true
            b.identifier = NSUserInterfaceItemIdentifier(chip.kind.rawValue)
            b.toolTip = chip.detail + "\nSent with the prompt. Click to leave it out."
            return b
        }
        for (i, url) in extraImages.enumerated() {
            let thumb = NSImage(size: NSSize(width: 22, height: 12), flipped: false) { r in
                NSImage(contentsOf: url)?.draw(in: r)
                return true
            }
            let b = NSButton(title: "Capture \(i + 2)", target: self, action: #selector(removeImage(_:)))
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = .systemFont(ofSize: 10)
            b.image = thumb
            b.imagePosition = .imageLeading
            b.refusesFirstResponder = true
            b.tag = i
            b.toolTip = "Capture \(i + 2), sent with the prompt. Click to remove it."
            chipViews.append(b)
        }
        let layout = chipLayout(widths: chipViews.map { $0.fittingSize.width },
                                x: PanelMetrics.thumb + 20, maxX: PanelMetrics.width - 12)
        for (b, f) in zip(chipViews, layout.frames) {
            b.frame = NSRect(x: f.minX, y: PanelMetrics.bottom - 10 + layout.height - f.maxY,
                             width: f.width, height: f.height)
            content.addSubview(b)
        }
        chipsHeight = layout.height
        fitPrompt()
    }

    @objc private func removeImage(_ sender: NSButton) {
        guard extraImages.indices.contains(sender.tag) else { return }
        extraImages.remove(at: sender.tag)
        layoutChips()
        refocus()
    }

    @objc private func removeChip(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = ContextKind(rawValue: raw) else { return }
        removedKinds.insert(kind)
        context = context.removing(kind)
        layoutChips()
        refocus()
    }

    // The settings menu from the gear in the panel: the same menu as the menu
    // bar icon, which a full menu bar can hide. A change shows at once in the chips.
    @objc private func openSettings(_ sender: NSButton) {
        let menu = settingsMenu.newMenu()
        menuObservers += holdOpen(while: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // Builds the context from the window as read with the settings as they are
    // now, not as they were at the capture: a change in either menu, even
    // while the read was still running, shows in the chips and in what Enter sends.
    private func refreshContext() {
        let settings = ContextSettings(value: { UserDefaults.standard.object(forKey: $0) })
        autoProject = settings.autoProject
        if let w = window {
            context = removedKinds.reduce(buildContext(w, settings: settings)) { $0.removing($1) }
        }
        applyContext()
    }

    // Pastes the capture into the chat open in T3: the image goes on the
    // clipboard, T3's composer takes the focus (also away from a selection in
    // the chat or in an HTML render), Shift+Enter starts a new line after any
// text, then Cmd+V goes to T3. Driving another
    // app needs the Accessibility permission. Without it, or when T3 shows no
    // chat, the icon shows as usual, so the capture is never lost.
    private func paste(_ url: URL, into app: NSRunningApplication) {
        let ask = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(ask) else {
            NSLog("ShotPrompt: pasting into T3 needs Accessibility (System Settings > Privacy & Security)")
            return showIcon(url)
        }
        guard let png = pngData(of: url) else { return showIcon(url) }
        let t3 = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(t3, 1)
        // Electron builds its accessibility tree only once a client asks for it.
        AXUIElementSetAttributeValue(t3, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Shottr can still be in front.
        if !app.isActive { AXUIElementSetAttributeValue(t3, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
        let deadline = Date().addingTimeInterval(pasteWaitSeconds)
        let capture = captures
        func attempt() {
            // A newer capture took over the screen, as it does from an icon.
            guard capture == captures else { return }
            if app.isActive, let composer = Self.composer(in: t3) {
                AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                // The focus reaches T3's page a moment after it is set. The
                // clipboard is set right before Cmd+V, so each paste sends its own image.
                DispatchQueue.main.asyncAfter(deadline: .now() + pastePollSeconds) {
                    if breaksLineBeforePaste(text: Self.axValue(composer, kAXValueAttribute) as? String,
                                             caret: Self.caret(in: composer)) {
                        Self.key(kVK_Return, flags: .maskShift, to: app)
                    }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setData(png, forType: .png)
                    Self.key(kVK_ANSI_V, flags: .maskCommand, to: app)
                }
                return
            }
            guard Date() < deadline else {
                NSLog("ShotPrompt: T3 shows no chat to paste into")
                return showIcon(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pastePollSeconds) { attempt() }
        }
        attempt()
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    // T3's chat composer in its focused window, else in any of its windows.
    private static func composer(in t3: AXUIElement) -> AXUIElement? {
        var roots = axValue(t3, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let w = axValue(t3, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            roots = [w as! AXUIElement]
        }
        return findComposer(
            roots: roots, limit: composerSearchLimit,
            children: { axValue($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] },
            isComposer: { e in
                isComposer(role: axValue(e, kAXRoleAttribute) as? String,
                           classes: axValue(e, "AXDOMClassList") as? [String] ?? [])
            },
            isFocused: { axValue($0, kAXFocusedAttribute) as? Bool == true })
    }

    // Where the caret sits in the composer, or nil when T3 does not say.
    private static func caret(in composer: AXUIElement) -> Int? {
        guard let value = axValue(composer, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range.location : nil
    }

    // A key press (Shift+Enter, Cmd+V), posted to T3 itself so it cannot land in another app.
    private static func key(_ code: Int, flags: CGEventFlags, to app: NSRunningApplication) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            event?.flags = flags
            event?.postToPid(app.processIdentifier)
        }
    }

    // The icon by the mouse for a new capture.
    private func showIcon(_ url: URL) {
        dismiss()
        image = url
        let size = iconSize
        let p = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        content.material = .hudWindow
        content.state = .active
        // A layer cornerRadius leaves the blur's square corners drawn as white;
        // a mask image clips the material itself and the window shadow follows it.
        content.maskImage = NSImage(size: content.bounds.size, flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            return true
        }
        p.contentView = content

        let iv = NSImageView(frame: content.bounds.insetBy(dx: 6, dy: 6))
        iv.image = NSImage(contentsOf: url)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        content.addSubview(iv)
        // A speech bubble on the corner says "ask about this".
        let badge = NSImageView(frame: NSRect(x: size - 22, y: 2, width: 20, height: 20))
        badge.image = NSImage(systemSymbolName: "bubble.left.circle.fill", accessibilityDescription: nil)
        badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [.white, .controlAccentColor]))
        content.addSubview(badge)
        let click = ClickView(frame: content.bounds)
        click.toolTip = "Type or click to ask Claude about this capture"
        click.onClick = { [weak self] in self?.expand() }
        content.addSubview(click)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        p.setFrameOrigin(iconOrigin(mouse: mouse, visible: screen.visibleFrame))

        icon = p
        p.orderFrontRegardless()
        p.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let w = event.window
            let ours = !self.menuOpen && w != nil && (w === self.panel || w === self.icon)
            switch keyAction(isOurs: ours, isEscape: event.keyCode == 53,
                             commandOrControl: !event.modifierFlags.intersection([.command, .control]).isEmpty,
                             onIcon: w === self.icon) {
            case .pass:
                return event
            case .dismiss:
                self.dismiss()
                return nil
            case .expandAndType:
                self.expand()
                self.field?.keyDown(with: event)
                return nil
            }
        }
        fnMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, !self.menuOpen else { return event }
            switch fnAction(keyCode: event.keyCode, fnDown: event.modifierFlags.contains(.function),
                            onIcon: self.icon != nil) {
            case .none: break
            case .expandAndHold:
                self.expand()
                self.fnHeld = true
            case .hold:
                self.fnHeld = true
            case .release:
                self.fnHeld = false; self.dictationEndedAt = Date()
                if !self.hasText { self.armIdle(dictationGraceSeconds) }
            }
            return event
        }
        micTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.micLive = Self.dictationMicLive()
            guard self.micLive else { return }
            self.dictationEndedAt = Date()
            if expandsForDictation(micLive: true, onIcon: self.icon != nil) { self.expand() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            switch activationAction(
                activatedPID: app?.processIdentifier, activatedBundleID: app?.bundleIdentifier,
                ownPID: ProcessInfo.processInfo.processIdentifier,
                returnToPID: self.returnTo?.processIdentifier,
                panelOpen: self.panel != nil, iconOpen: self.icon != nil,
                iconTimeLeft: self.idleTimer?.fireDate.timeIntervalSinceNow ?? 0,
                dictating: self.dictating) {
            case .none: break
            case .clearReturn: self.returnTo = nil
            case .dismissIfEmpty: self.dismissIfEmpty()
            case .shortenIcon(let seconds): self.armIdle(seconds)
            }
        }
        armIdle(iconSeconds)
    }

    // Opens the prompt panel where the icon was.
    private func expand() {
        guard let i = icon, let url = image else { return }
        let anchor = i.frame
        i.orderOut(nil)
        icon = nil
        let width = PanelMetrics.width, thumb = PanelMetrics.thumb
        let p = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: thumb + 20),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSVisualEffectView(frame: p.contentView!.bounds)
        content.material = .hudWindow
        content.state = .active
        content.autoresizingMask = [.width, .height]
        p.contentView = content

        let iv = NSImageView(frame: NSRect(x: 10, y: 10, width: thumb, height: thumb))
        iv.image = NSImage(contentsOf: url)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        iv.autoresizingMask = [.minYMargin]
        content.addSubview(iv)

        let x = thumb + 20, w = width - x - 12
        let sv = NSScrollView(frame: NSRect(x: x, y: 42, width: w, height: 18))
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.autohidesScrollers = true
        // It sits under the transparent title bar; without this AppKit insets
        // its top and the last line hides behind a scroller.
        sv.automaticallyAdjustsContentInsets = false
        sv.verticalScroller = ThinScroller()
        let clip = TopClipView()
        clip.drawsBackground = false
        sv.contentView = clip
        // fitPrompt sets its frame: its height, and its bottom above the chips.
        sv.autoresizingMask = []
        let f = PromptTextView(frame: NSRect(origin: .zero, size: sv.contentSize))
        f.placeholder = "Type to ask Claude about this capture"
        f.font = .systemFont(ofSize: 15)
        f.drawsBackground = false
        f.isRichText = false
        f.allowsUndo = true
        f.isAutomaticQuoteSubstitutionEnabled = false
        f.isAutomaticDashSubstitutionEnabled = false
        f.focusRingType = .none
        f.textContainerInset = .zero
        f.textContainer?.lineFragmentPadding = 0
        f.textContainer?.widthTracksTextView = true
        f.isVerticallyResizable = true
        f.isHorizontallyResizable = false
        f.autoresizingMask = [.width]
        f.minSize = NSSize(width: 0, height: 0)
        f.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        f.delegate = self
        sv.documentView = f
        content.addSubview(sv)
        clip.wantsLayer = true
        clip.layer?.mask = CAGradientLayer()
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            clipObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: clip, queue: .main) { [weak self] _ in self?.updateFade() })
        }

        let target = currentTarget()
        projects = target.usesProject ? allProjects() : []
        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                            target: self, action: #selector(openSettings(_:)))
        gear.isBordered = false
        gear.refusesFirstResponder = true
        gear.contentTintColor = .secondaryLabelColor
        gear.frame = NSRect(x: x - 2, y: 10, width: 18, height: 18)
        gear.toolTip = "What each capture sends, and other settings"
        content.addSubview(gear)
        let s = NSTextField(labelWithString: statusHint(hasProjects: target.usesProject, target: target))
        s.frame = NSRect(x: x + 20, y: 12, width: w - 20, height: 16)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        s.lineBreakMode = .byTruncatingTail
        content.addSubview(s)
        if target.usesProject {
            let pp = makePicker(projects)
            pp.frame = NSRect(x: x, y: 8, width: w, height: 22)
            content.addSubview(pp)
            picker = pp
        }

        let screen = i.screen ?? NSScreen.main!
        p.setFrameOrigin(panelOrigin(iconFrame: anchor, panelHeight: p.frame.height, visible: screen.visibleFrame))

        panel = p; field = f; scroll = sv; thumbnail = iv; status = s
        layoutStatus()
        applyContext()
        p.orderFrontRegardless()
        p.makeKey()
        p.makeFirstResponder(f)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in self?.dismissIfEmpty() }
        armIdle()
    }

    // The project the thread opens in: SHOT_PROMPT_CWD first, then the rest.
    private func makePicker(_ projects: [Project]) -> NSPopUpButton {
        let pp = NSPopUpButton(frame: .zero, pullsDown: false)
        pp.isBordered = false
        pp.controlSize = .small
        pp.font = .systemFont(ofSize: 11)
        (pp.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        for entry in pickerEntries(projects: projects, defaultRoot: defaultFolder()) {
            // Its own action, since Tab pops the menu up outside the button.
            let item = NSMenuItem(title: entry.name, action: #selector(pickedProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.root
            item.toolTip = entry.toolTip
            pp.menu?.addItem(item)
        }
        pp.toolTip = "Project folder to work in (Tab). Add folders in the menu bar menu."
        menuObservers += holdOpen(while: pp.menu!)
        return pp
    }

    // While a menu is open, the empty-panel timers and observers must not close the panel.
    private func holdOpen(while menu: NSMenu) -> [NSObjectProtocol] {
        [
            NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main
            ) { [weak self] _ in
                self?.menuOpen = true
                self?.idleTimer?.invalidate()
            },
            NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.menuOpen = false
                self.panel?.makeKey()
                if let f = self.field { self.panel?.makeFirstResponder(f) }
                if !self.hasText { self.armIdle() }
            },
        ]
    }

    // A menu takes arrow keys only while its app is active, so ShotPrompt comes
    // forward for the menu and then gives the front back to the app you were in.
    private func openPicker(_ pp: NSPopUpButton) {
        returnTo = NSWorkspace.shared.frontmostApplication
        if returnTo?.processIdentifier == ProcessInfo.processInfo.processIdentifier { returnTo = nil }
        NSApp.activate(ignoringOtherApps: true)
        // A menu shown while the switch is still settling closes at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.picker === pp else { return }
            pp.menu?.popUp(positioning: pp.selectedItem, at: .zero, in: pp)
            // The panel takes the keyboard back once this app has stepped back;
            // a key panel loses the keyboard while its app is still giving up the front.
            guard let back = self.returnTo, back.activate() else { self.refocus(); return }
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                if let t = token { NotificationCenter.default.removeObserver(t) }
                self?.refocus()
            }
        }
    }

    private func refocus() {
        panel?.makeKey()
        if let f = field { panel?.makeFirstResponder(f) }
    }

    @objc private func pickedProject(_ item: NSMenuItem) {
        pickedByHand = true
        picker?.select(item)
        layoutStatus()
        if let f = field { panel?.makeFirstResponder(f) }
    }

    private func layoutStatus() {
        guard let pp = picker, let s = status, let font = pp.font else { return }
        let title = (pp.titleOfSelectedItem ?? "") as NSString
        let l = statusLayout(containerWidth: s.superview?.bounds.width ?? 0,
                             titleWidth: title.size(withAttributes: [.font: font]).width,
                             hintMinX: s.frame.minX)
        pp.frame = l.pickerFrame
        s.frame.size.width = l.hintWidth
    }

    private func armIdle(_ seconds: TimeInterval = idleSeconds) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismissIfEmpty()
        }
    }

    // The Fn flag is also read live, in case the dictation app keeps the
    // Fn events from reaching this panel.
    private var dictating: Bool {
        dictationHolds(active: fnHeld || micLive || NSEvent.modifierFlags.contains(.function),
                       endedAt: dictationEndedAt, now: Date())
    }

    // Whether a dictation app (Wispr Flow) is recording from the microphone.
    // Core Audio lists each process using audio; no permission is needed.
    private static func dictationMicLive() -> Bool {
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &processes) == noErr else { return false }
        return processes.contains { process in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return false }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = address(kAudioProcessPropertyBundleID)
            // A process without a bundle ID leaves it nil, which is no dictation app.
            _ = AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundle)
            return isDictationApp(bundleID: bundle?.takeRetainedValue() as String?)
        }
    }

    private func dismissIfEmpty() {
        if hasText || menuOpen { return }
        // Still dictating: look again later instead of closing.
        if dictating { return armIdle() }
        dismiss()
    }

    func textDidChange(_ notification: Notification) {
        idleTimer?.invalidate()
        if !hasText { armIdle() }
        field?.needsDisplay = true
        fitPrompt()
    }

    // Grow the prompt (and the panel, downward from its top edge) to fit the text.
    private func fitPrompt() {
        guard let p = panel, let f = field, let sv = scroll,
              let lm = f.layoutManager, let tc = f.textContainer, let font = f.font else { return }
        // Measure at full width: a legacy scroller narrows the text, and text
        // that fits without one should not keep it.
        sv.hasVerticalScroller = false
        sv.tile()
        lm.ensureLayout(for: tc)
        let fit = ShotPromptCore.fitPrompt(usedHeight: lm.usedRect(for: tc).height,
                                           lineHeight: lm.defaultLineHeight(for: font),
                                           maxLines: maxPromptLines, chips: chipsHeight)
        // A scroller only past the cap, so it does not flash on each new line.
        sv.hasVerticalScroller = fit.scrolls
        (sv.contentView as? TopClipView)?.pinTop = !fit.scrolls
        sv.frame = NSRect(x: sv.frame.minX, y: PanelMetrics.bottom + chipsHeight,
                          width: sv.frame.width, height: fit.height)
        if panelTarget != fit.panelHeight {
            panelTarget = fit.panelHeight
            let frame = grownFrame(p.frame, height: fit.panelHeight, visible: p.screen?.visibleFrame)
            // The thumbnail keeps to the top edge by autoresizing.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = p.isVisible ? 0.12 : 0
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(frame, display: true)
            } completionHandler: {
                f.scrollRangeToVisible(f.selectedRange())
            }
        }
        f.scrollRangeToVisible(f.selectedRange())
        updateFade()
    }

    private func updateFade() {
        guard let sv = scroll, let f = field,
              let mask = sv.contentView.layer?.mask as? CAGradientLayer else { return }
        let fd = fade(visible: sv.contentView.bounds, documentHeight: f.frame.height,
                      scrolls: sv.hasVerticalScroller)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = sv.contentView.layer?.bounds ?? .zero
        mask.colors = [fd.top ? NSColor.clear : NSColor.black, NSColor.black, NSColor.black,
                       fd.bottom ? NSColor.clear : NSColor.black].map(\.cgColor)
        mask.locations = [0, NSNumber(value: fd.edge), NSNumber(value: 1 - fd.edge), 1]
        CATransaction.commit()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch textCommand(NSStringFromSelector(selector), hasPicker: picker != nil) {
        case .send: send()
        case .dismiss: dismiss()
        case .openPicker:
            // After this key event returns, so the menu's tracking loop does not run inside it.
            let pp = picker!
            DispatchQueue.main.async { self.openPicker(pp) }
        case .none: return false
        }
        return true
    }

    private func send() {
        guard let url = image, let f = field else { return }
        guard let typed = sendablePrompt(f.string) else { return }
        let prompt = promptWithContext(typed, context, captures: 1 + extraImages.count)
        let images = [url] + [context.windowShot].compactMap { $0 } + extraImages
        let cwd = picker?.selectedItem?.representedObject as? String ?? defaultFolder()
        f.isEditable = false
        picker?.isEnabled = false
        chipViews.forEach { $0.isEnabled = false }
        status?.stringValue = "launching…"
        let target = currentTarget()
        if target.usesProject {
            UserDefaults.standard.set(rememberFolder(cwd, in: recentFolders), forKey: recentFoldersKey)
        }
        DispatchQueue.global().async {
            let (ok, out) = Self.deliver(target, prompt: prompt, images: images, cwd: cwd)
            DispatchQueue.main.async {
                if ok {
                    // The thread or terminal is already open; vanish at once, no fade.
                    self.panel?.animationBehavior = .none
                    self.dismiss()
                } else {
                    f.isEditable = true
                    self.picker?.isEnabled = true
                    self.chipViews.forEach { $0.isEnabled = true }
                    self.status?.toolTip = out
                    self.status?.stringValue = "failed: " + out
                    self.status?.textColor = .systemRed
                    NSLog("ShotPrompt dispatch failed: %@", out)
                }
            }
        }
    }

    // Sends to the target, off the main thread. A terminal or chat app gets
    // copies of the images, since the window shot is deleted when the panel goes.
    private static func deliver(_ target: Target, prompt: String, images: [URL], cwd: String)
        -> (ok: Bool, output: String) {
        switch target {
        case .command:
            return dispatch(executable: config.dispatchBin, prompt: prompt, images: images, cwd: cwd,
                            environment: config.environment, home: config.home)
        case .clipboard:
            // One clipboard item with both: a chat box takes the image, a text field the prompt.
            guard let png = images.first.flatMap(pngData(of:)) else { return (false, "cannot read the screenshot") }
            DispatchQueue.main.sync {
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                item.setString(prompt, forType: .string)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item])
            }
            return (true, "")
        case .claudeApp, .chatGPT:
            // Without Accessibility the keys cannot reach the app: say so and keep what you typed.
            let ask = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(ask) else {
                return (false, "allow ShotPrompt in Privacy & Security > Accessibility, then press Enter again")
            }
        case .claudeCode, .codex, .cursorAgent:
            break
        }
        pruneStaged(in: stagedRoot, now: Date(), maxAge: 24 * 3600)
        let folder = stagedRoot.appendingPathComponent(UUID().uuidString)
        let staged: [URL]
        do { staged = try stageImages(images, in: folder) } catch { return (false, error.localizedDescription) }
        if let id = target.bundleID {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                return (false, "\(target.title) is not installed")
            }
            DispatchQueue.main.async { ChatPaster.paste(images: staged, prompt: prompt, into: app) }
            return (true, "")
        }
        let script = folder.appendingPathComponent("ShotPrompt.command")
        let text = terminalScript(target, executable: target.executable.flatMap(cliPath), prompt: prompt,
                                  images: staged, cwd: cwd)
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch { return (false, error.localizedDescription) }
        // The default app for .command files: Terminal, or iTerm or another that took them.
        return NSWorkspace.shared.open(script) ? (true, "") : (false, "could not open a terminal")
    }

    private func dismiss() {
        idleTimer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let m = fnMonitor { NSEvent.removeMonitor(m) }
        fnMonitor = nil
        micTimer?.invalidate()
        micTimer = nil
        fnHeld = false; micLive = false; dictationEndedAt = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        activationObserver = nil; resignObserver = nil
        clipObservers.forEach(NotificationCenter.default.removeObserver)
        clipObservers = []
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers = []
        menuOpen = false
        returnTo = nil
        icon?.orderOut(nil)
        icon = nil
        panel?.orderOut(nil)
        panel = nil; field = nil; scroll = nil; thumbnail = nil; status = nil; picker = nil; image = nil
        chipViews = []; chipsHeight = 0; panelTarget = 0; projects = []; pickedByHand = false
        Self.discard(window?.windowShot)
        contextReads += 1
        window = nil; serverFolder = nil; context = CaptureContext(); removedKinds = []; extraImages = []
    }
}

// The menu bar icon's menu: what each capture sends, and the apps that send
// nothing. Each item writes the same UserDefaults key `defaults write` would,
// and every capture reads them again, so a change applies to the next capture.
final class SettingsMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?

    func start() {
        if UserDefaults.standard.object(forKey: showMenuBarIconKey) as? Bool == false { return }
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        i.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "ShotPrompt")
        i.menu = newMenu()
        item = i
    }

    // A menu filled each time it opens. The panel's gear pops up its own copy.
    func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    // Built each time it opens, so it shows the current settings and apps.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = ContextSettings(value: { UserDefaults.standard.object(forKey: $0) })
        let target = currentTarget()
        let sendTo = NSMenuItem(title: "Send to: \(target.title)", action: nil, keyEquivalent: "")
        sendTo.submenu = targetsMenu(target)
        menu.addItem(sendTo)
        let add = NSMenuItem(title: "Add project folder…", action: #selector(addFolder), keyEquivalent: "")
        add.target = self
        add.toolTip = "Folders show in the panel's picker; the ones you send to are added on their own."
        menu.addItem(add)
        if !runByLaunchAgent {
            let login = NSMenuItem(title: "Open at login", action: #selector(flipLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(header("Send with each capture"))
        menu.addItem(toggle("App name", ContextSettingKey.app, s.app))
        menu.addItem(toggle("Window title", ContextSettingKey.title, s.title, needsAX: true))
        menu.addItem(toggle("Page address or file", ContextSettingKey.url, s.url, needsAX: true))
        let query = toggle("Keep ?query and #fragment in addresses", ContextSettingKey.urlQuery, s.urlQuery)
        query.indentationLevel = 1
        query.isEnabled = s.url
        query.toolTip = "They often hold an email address, a token or a search."
        menu.addItem(query)
        menu.addItem(toggle("UI element under the capture", ContextSettingKey.element, s.element, needsAX: true))
        let shot = toggle("Whole window, capture outlined", ContextSettingKey.windowShot, s.windowShot,
                          needsScreen: true)
        shot.toolTip = "A second image: everything you cropped out of the window. Needs Screen Recording."
        menu.addItem(shot)
        let excluded = NSMenuItem(title: "Never from these apps", action: nil, keyEquivalent: "")
        excluded.submenu = appsMenu(s.excludedApps)
        menu.addItem(excluded)
        menu.addItem(.separator())
        let pick = toggle("Pick the project from the captured window", ContextSettingKey.autoProject,
                          s.autoProject, needsAX: true)
        pick.toolTip = "Reads the window on this Mac only; nothing extra goes into the prompt."
        menu.addItem(pick)
        menu.addItem(toggle("Paste captures taken in T3 into its chat", pasteIntoT3Key,
                            UserDefaults.standard.bool(forKey: pasteIntoT3Key), needsAX: true))
        if (s.needsAccessibility || UserDefaults.standard.bool(forKey: pasteIntoT3Key)) && !AXIsProcessTrusted() {
            menu.addItem(.separator())
            let ax = NSMenuItem(title: "Allow Accessibility for titles, addresses and projects…",
                                action: #selector(openAccessibility), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        if s.windowShot && !CGPreflightScreenCaptureAccess() {
            let sr = NSMenuItem(title: "Allow Screen Recording for the window shot…",
                                action: #selector(openScreenRecording), keyEquivalent: "")
            sr.target = self
            menu.addItem(sr)
        }
    }

    // Every target; one not installed is shown, and disabled, so you know it exists.
    private func targetsMenu(_ current: Target) -> NSMenu {
        let menu = NSMenu()
        for t in Target.allCases {
            let installed = isInstalled(t)
            let m = NSMenuItem(title: installed ? t.title : "\(t.title) (not found)",
                               action: installed ? #selector(pickTarget(_:)) : nil, keyEquivalent: "")
            m.target = self
            m.state = t == current ? .on : .off
            m.representedObject = t.rawValue
            if t == .command { m.toolTip = config.dispatchBin }
            menu.addItem(m)
        }
        return menu
    }

    @objc private func pickTarget(_ m: NSMenuItem) {
        UserDefaults.standard.set(m.representedObject as? String, forKey: targetKey)
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var list = recentFolders
        for url in panel.urls.reversed() { list = rememberFolder(url.path, in: list) }
        UserDefaults.standard.set(list, forKey: recentFoldersKey)
    }

    @objc private func flipLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("ShotPrompt: open at login: %@", error.localizedDescription)
        }
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func header(_ title: String) -> NSMenuItem {
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        h.isEnabled = false
        return h
    }

    private func toggle(_ title: String, _ key: String, _ on: Bool, needsAX: Bool = false,
                        needsScreen: Bool = false) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: #selector(flip(_:)), keyEquivalent: "")
        m.target = self
        m.state = on ? .on : .off
        m.representedObject = [key, needsAX, needsScreen] as [Any]
        return m
    }

    @objc private func flip(_ m: NSMenuItem) {
        guard let info = m.representedObject as? [Any], let key = info[0] as? String,
              let needsAX = info[1] as? Bool, let needsScreen = info[2] as? Bool else { return }
        let on = m.state != .on
        UserDefaults.standard.set(on, forKey: key)
        NotificationCenter.default.post(name: settingsChangedNotification, object: nil)
        if on && needsScreen && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        // Turning on something that reads windows asks for the grant it needs.
        if on && needsAX {
            let ask = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(ask)
        }
    }

    // Excluded apps first (checked), then the other open apps. Clicking one
    // adds it to the list or takes it off.
    private func appsMenu(_ excluded: [String]) -> NSMenu {
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        var names: [String: String] = [:]
        for app in running { names[app.bundleIdentifier!] = app.localizedName }
        func name(_ id: String) -> String {
            if let n = names[id] { return n }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
            return id
        }
        let others = Set(running.map { $0.bundleIdentifier! }).subtracting(excluded)
        let byName = { (a: String, b: String) in name(a).localizedCaseInsensitiveCompare(name(b)) == .orderedAscending }
        for id in excluded.sorted(by: byName) + others.sorted(by: byName) {
            let m = NSMenuItem(title: name(id), action: #selector(flipApp(_:)), keyEquivalent: "")
            m.target = self
            m.state = excluded.contains(id) ? .on : .off
            m.representedObject = id
            m.toolTip = id
            menu.addItem(m)
        }
        return menu
    }

    @objc private func flipApp(_ m: NSMenuItem) {
        guard let id = m.representedObject as? String else { return }
        var list = ContextSettings(value: { UserDefaults.standard.object(forKey: $0) }).excludedApps
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        UserDefaults.standard.set(list, forKey: ContextSettingKey.excludedApps)
        NotificationCenter.default.post(name: settingsChangedNotification, object: nil)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// Pastes screenshots and a prompt into a desktop chat app: it comes
// forward, Cmd+N opens a new chat, then each image and the prompt go in
// through the clipboard and Cmd+V. You read it over and press Enter there.
// Posting keys needs Accessibility, which the send checks first; should the
// grant go in between, the first image stays on the clipboard to paste yourself.
enum ChatPaster {
    static func paste(images: [URL], prompt: String, into appURL: URL) {
        let trusted = AXIsProcessTrusted()
        let pb = NSPasteboard.general
        let open = NSWorkspace.OpenConfiguration()
        open.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: open) { app, _ in
            DispatchQueue.main.async {
                guard trusted, let app else {
                    pb.clearContents()
                    if let png = images.first.flatMap(pngData(of:)) { pb.setData(png, forType: .png) }
                    NSLog("ShotPrompt: pasting into a chat app needs Accessibility; the screenshot is on the clipboard")
                    return
                }
                var steps: [() -> Void] = [{ key(kVK_ANSI_N, to: app) }]
                for url in images {
                    guard let png = pngData(of: url) else { continue }
                    steps.append { pb.clearContents(); pb.setData(png, forType: .png); key(kVK_ANSI_V, to: app) }
                }
                steps.append { pb.clearContents(); pb.setString(prompt, forType: .string); key(kVK_ANSI_V, to: app) }
                run(steps, waitingFor: app, deadline: Date().addingTimeInterval(5))
            }
        }
    }

    // Waits for the app to be in front (it may still be starting), then runs
    // each step with a pause, so the chat has taken the last paste.
    private static func run(_ steps: [() -> Void], waitingFor app: NSRunningApplication, deadline: Date) {
        guard app.isActive || Date() > deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(steps, waitingFor: app, deadline: deadline) }
            return
        }
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.5, execute: step)
        }
    }

    private static func key(_ code: Int, to app: NSRunningApplication) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            event?.flags = .maskCommand
            event?.postToPid(app.processIdentifier)
        }
    }
}

// build.sh's LaunchAgent starts this app and restarts it; it needs no login item.
let runByLaunchAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "io.github.aliir74.shot-prompt"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// One copy at a time: a login item and the LaunchAgent could both start one.
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    NSLog("ShotPrompt is already running")
    exit(0)
}
pruneStaged(in: stagedRoot, now: Date(), maxAge: 24 * 3600)
// The first launch from a download opens at login from then on; the menu turns it off.
let loginItemOfferedKey = "loginItemOffered"
let inApplications = isInApplicationsFolder(Bundle.main.bundlePath, home: config.home)
if !runByLaunchAgent && inApplications && !UserDefaults.standard.bool(forKey: loginItemOfferedKey) {
    UserDefaults.standard.set(true, forKey: loginItemOfferedKey)
    try? SMAppService.mainApp.register()
}
// Said once, on the first launch outside the LaunchAgent: what to do, and where the settings are.
let welcomedKey = "welcomed"
if !runByLaunchAgent && Bundle.main.bundleIdentifier != nil && !UserDefaults.standard.bool(forKey: welcomedKey) {
    // Run from the disk image or Downloads, it says so every launch until moved.
    if inApplications { UserDefaults.standard.set(true, forKey: welcomedKey) }
    // Once the run loop is up, so the alert comes forward like any app's.
    DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = "ShotPrompt is running"
        alert.informativeText = welcomeText(target: currentTarget(), inApplications: inApplications)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
let controller = Controller()
controller.start()
let settingsMenu = SettingsMenu()
settingsMenu.start()

// The phone receiver (ios/README.md): on only when receiverPort and
// receiverToken are set. Read once at launch; restart the agent after a change.
var receiver: ReceiverServer?
if let settings = receiverSettings(port: UserDefaults.standard.integer(forKey: receiverPortKey),
                                   token: UserDefaults.standard.string(forKey: receiverTokenKey)) {
    let context = ReceiverContext(
        token: settings.token, defaultRoot: defaultFolder(),
        projects: { allProjects() },
        saveImage: imageSaver(dir: FileManager.default.temporaryDirectory.appendingPathComponent("ShotPrompt-phone")),
        dispatch: { prompt, image, cwd in
            dispatch(executable: config.dispatchBin, prompt: prompt, images: [image], cwd: cwd,
                     environment: config.environment, home: config.home)
        })
    do {
        receiver = try ReceiverServer(port: settings.port, onReply: { request, response in
            NSLog("ShotPrompt receiver: %@", replyLogLine(request, response))
        }) { handle($0, context) }
        receiver?.start { error in
            NSLog("ShotPrompt receiver on 127.0.0.1:%d: %@", Int(settings.port), error ?? "listening")
        }
    } catch {
        NSLog("ShotPrompt receiver could not start: %@", error.localizedDescription)
    }
}
app.run()
