// ShotPrompt: take a Shottr capture, start typing, and the screenshot plus
// your words open as a new T3 Code thread. The todo board's "hover a card and
// type" launcher, for screenshots.
//
// Shottr saves every capture to ~/Pictures as SCR-*.png ("Save after capture" on).
// A new file there pops a small thumbnail icon by the mouse, which is where
// the capture region ended. Typing, or clicking the icon, opens the prompt
// panel. Both are non-activating: they take the keyboard without bringing this
// app forward, so no Accessibility or Input Monitoring permission is needed.
// Enter sends the prompt through `t3-dispatch --image`. The icon stays when you
// switch apps and goes on Esc, a Cmd/Ctrl shortcut, or 20 seconds idle. While
// the prompt is empty, Esc, a Cmd/Ctrl shortcut, switching apps, or 5 seconds
// idle closes the panel; once you have typed, only Esc does. The project
// picker in the panel (Tab, or click it) sends the thread to another T3 project.

import AppKit
import SQLite3

let home = FileManager.default.homeDirectoryForCurrentUser
let env = ProcessInfo.processInfo.environment
let captureDir = URL(fileURLWithPath: env["SHOT_PROMPT_CAPTURE_DIR"] ?? home.appendingPathComponent("Pictures").path)
let dispatchBin = env["SHOT_PROMPT_DISPATCH"] ?? home.appendingPathComponent(".local/bin/t3-dispatch").path
// The project folder the new thread opens in, unless you pick another.
let threadCwd = (env["SHOT_PROMPT_CWD"] ?? home.path) as NSString
// T3 Code's database, read only for its list of projects.
let t3Database = env["SHOT_PROMPT_T3_DB"] ?? home.appendingPathComponent(".t3/userdata/statev2.sqlite").path
let idleSeconds: TimeInterval = 5
// The icon waits longer: it is small and keeps out of the way.
let iconSeconds: TimeInterval = 20
// After you switch to another app, the icon leaves this soon.
let iconAwaySeconds: TimeInterval = 3
// The prompt grows up to this many lines, then scrolls.
let maxPromptLines: CGFloat = 6

struct Project {
    let title: String
    let root: String
}

// T3's projects, pinned first, then by latest thread activity. Folders that are
// gone are left out. Any error gives an empty list, and the panel then has no picker.
func loadProjects() -> [Project] {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    let uri = "file:\(t3Database)?mode=ro"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [] }
    sqlite3_busy_timeout(db, 500)
    let sql = """
        SELECT p.title, p.workspace_root FROM projection_projects p
        WHERE p.deleted_at IS NULL AND p.archived_at IS NULL
        ORDER BY p.pinned_at IS NULL,
                 (SELECT max(t.updated_at) FROM orchestration_v2_projection_threads t
                  WHERE t.project_id = p.project_id) IS NULL,
                 (SELECT max(t.updated_at) FROM orchestration_v2_projection_threads t
                  WHERE t.project_id = p.project_id) DESC,
                 p.title COLLATE NOCASE
        """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    var rows: [Project] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let t = sqlite3_column_text(stmt, 0), let r = sqlite3_column_text(stmt, 1) else { continue }
        let root = String(cString: r)
        if FileManager.default.fileExists(atPath: root) {
            rows.append(Project(title: String(cString: t), root: root))
        }
    }
    return rows
}

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
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
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    func start() {
        known = Set(listCaptures())
        let fd = open(captureDir.path, O_EVTONLY)
        guard fd >= 0 else { fatalError("cannot watch \(captureDir.path)") }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func listCaptures() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: captureDir.path)) ?? []
        // Shottr's "Auto" format saves photos-heavy captures as JPEG.
        let types = [".png", ".jpg", ".jpeg"]
        return names.filter { name in
            name.hasPrefix("SCR-") && types.contains { name.lowercased().hasSuffix($0) }
        }
    }

    private func scan() {
        let current = Set(listCaptures())
        let added = current.subtracting(known)
        known = current
        guard let name = added.sorted().last else { return }
        waitUntilWritten(captureDir.appendingPathComponent(name), lastSize: -1, tries: 0)
    }

    // Shottr can still be writing when the directory event fires.
    private func waitUntilWritten(_ url: URL, lastSize: Int, tries: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0 && size == lastSize || tries > 20 {
            if size > 0 { show(url) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.waitUntilWritten(url, lastSize: size, tries: tries + 1)
        }
    }

    private var hasText: Bool { !(field?.string.isEmpty ?? true) }

    private func show(_ url: URL) {
        // A new capture while typing replaces the screenshot, not the prompt.
        // While a send is running, the sent screenshot stays.
        if hasText {
            if field?.isEditable == false { return }
            image = url
            thumbnail?.image = NSImage(contentsOf: url)
            return
        }
        dismiss()
        image = url
        let size: CGFloat = 56
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

        // The mouse is where the capture region ended; sit just past it.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        var origin = NSPoint(x: mouse.x + 8, y: mouse.y - size - 8)
        let vis = screen.visibleFrame
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size - 8)
        p.setFrameOrigin(origin)

        icon = p
        p.orderFrontRegardless()
        p.makeKey()

        // Esc or Cmd/Ctrl (Cmd+V into another app) before any typing means the
        // capture was meant for something else: get out of the way. Any other
        // key on the icon opens the prompt and becomes its first character.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.menuOpen,
                  let w = event.window, w === self.panel || w === self.icon else { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }
            let mods = event.modifierFlags.intersection([.command, .control])
            if !mods.isEmpty && !self.hasText {
                self.dismiss()
                return nil
            }
            if w === self.icon {
                self.expand()
                self.field?.keyDown(with: event)
                return nil
            }
            return event
        }
        // Switching apps before typing means the capture was not for Claude,
        // so an empty prompt closes and the icon leaves soon after. After
        // typing the panel keeps its text; click it to keep going.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // The picker bringing this app forward, and handing the front back, are not switches.
            if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            if let r = self.returnTo, app?.processIdentifier == r.processIdentifier {
                self.returnTo = nil
                return
            }
            if self.panel != nil { self.dismissIfEmpty(); return }
            // Shottr itself can come forward around a capture; that is not a switch.
            if self.icon != nil && app?.bundleIdentifier != "cc.ffitch.shottr" {
                let left = self.idleTimer?.fireDate.timeIntervalSinceNow ?? 0
                if left > iconAwaySeconds { self.armIdle(iconAwaySeconds) }
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
        let width: CGFloat = 420, thumb: CGFloat = 64
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
        // The panel grows downward, so the prompt grows with it.
        sv.autoresizingMask = [.height]
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

        let projects = loadProjects()
        let s = NSTextField(labelWithString: projects.isEmpty
            ? "↩ new T3 thread · esc dismiss" : "↩ new thread · ⇥ project · esc")
        s.frame = NSRect(x: x, y: 12, width: w, height: 16)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        s.lineBreakMode = .byTruncatingTail
        content.addSubview(s)
        if !projects.isEmpty {
            let pp = makePicker(projects)
            pp.frame = NSRect(x: x, y: 8, width: w, height: 22)
            content.addSubview(pp)
            picker = pp
        }

        let screen = i.screen ?? NSScreen.main!
        var origin = NSPoint(x: anchor.minX, y: anchor.maxY - p.frame.height)
        let vis = screen.visibleFrame
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - width - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - p.frame.height - 8)
        p.setFrameOrigin(origin)

        panel = p; field = f; scroll = sv; thumbnail = iv; status = s
        layoutStatus()
        fitPrompt()
        p.orderFrontRegardless()
        p.makeKey()
        p.makeFirstResponder(f)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in self?.dismissIfEmpty() }
        armIdle()
    }

    // The project the thread opens in: SHOT_PROMPT_CWD first, then the rest.
    // Titles T3 shows twice get their parent folder.
    private func makePicker(_ projects: [Project]) -> NSPopUpButton {
        let pp = NSPopUpButton(frame: .zero, pullsDown: false)
        pp.isBordered = false
        pp.controlSize = .small
        pp.font = .systemFont(ofSize: 11)
        (pp.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        let start = threadCwd.standardizingPath
        var list = projects
        if let i = list.firstIndex(where: { ($0.root as NSString).standardizingPath == start }) {
            list.insert(list.remove(at: i), at: 0)
        } else {
            list.insert(Project(title: (start as NSString).lastPathComponent, root: start), at: 0)
        }
        var counts: [String: Int] = [:]
        list.forEach { counts[$0.title, default: 0] += 1 }
        for p in list {
            let parent = ((p.root as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let name = counts[p.title, default: 0] > 1 ? "\(p.title) · \(parent)" : p.title
            // Its own action, since Tab pops the menu up outside the button.
            let item = NSMenuItem(title: name, action: #selector(pickedProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.root
            item.toolTip = (p.root as NSString).abbreviatingWithTildeInPath
            pp.menu?.addItem(item)
        }
        pp.toolTip = "T3 project for the new thread (Tab)"
        // While the menu is open, the empty-panel timers and observers must not close it.
        menuObservers = [
            NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: pp.menu, queue: .main
            ) { [weak self] _ in
                self?.menuOpen = true
                self?.idleTimer?.invalidate()
            },
            NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: pp.menu, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.menuOpen = false
                self.panel?.makeKey()
                if let f = self.field { self.panel?.makeFirstResponder(f) }
                if !self.hasText { self.armIdle() }
            },
        ]
        return pp
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
        picker?.select(item)
        layoutStatus()
        if let f = field { panel?.makeFirstResponder(f) }
    }

    // The picker sits at the right edge, as wide as the chosen title; the hint
    // label takes the rest.
    private func layoutStatus() {
        guard let pp = picker, let s = status, let font = pp.font else { return }
        let right = (s.superview?.bounds.width ?? 0) - 12
        let title = (pp.titleOfSelectedItem ?? "") as NSString
        let pw = min(ceil(title.size(withAttributes: [.font: font]).width) + 26, 200)
        pp.frame = NSRect(x: right - pw + 6, y: 8, width: pw, height: 22)
        s.frame.size.width = max(right - pw - s.frame.minX - 4, 0)
    }

    private func armIdle(_ seconds: TimeInterval = idleSeconds) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismissIfEmpty()
        }
    }

    private func dismissIfEmpty() {
        if !hasText && !menuOpen { dismiss() }
    }

    func textDidChange(_ notification: Notification) {
        idleTimer?.invalidate()
        if !hasText { armIdle() }
        field?.needsDisplay = true
        fitPrompt()
    }

    // Grow the prompt (and the panel, downward from its top edge) to fit the
    // text, up to maxPromptLines; past that the prompt scrolls.
    private func fitPrompt() {
        guard let p = panel, let f = field, let sv = scroll,
              let lm = f.layoutManager, let tc = f.textContainer, let font = f.font else { return }
        // Measure at full width: a legacy scroller narrows the text, and text
        // that fits without one should not keep it.
        sv.hasVerticalScroller = false
        sv.tile()
        lm.ensureLayout(for: tc)
        let line = ceil(lm.defaultLineHeight(for: font))
        let used = ceil(lm.usedRect(for: tc).height), cap = line * maxPromptLines
        let h = min(max(used, line), cap)
        // A scroller only past the cap, so it does not flash on each new line.
        sv.hasVerticalScroller = used > cap
        (sv.contentView as? TopClipView)?.pinTop = used <= cap
        let top: CGFloat = 24, bottom: CGFloat = 42, thumb: CGFloat = 64
        let height = max(thumb + 20, bottom + h + top)
        if p.frame.height != height {
            var frame = p.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            if let vis = p.screen?.visibleFrame, frame.minY < vis.minY + 8 {
                frame.origin.y = vis.minY + 8
            }
            // The prompt and thumbnail follow the panel by autoresizing.
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

    // Once the prompt scrolls, fade the text into whichever edge hides more.
    private func updateFade() {
        guard let sv = scroll, let f = field,
              let mask = sv.contentView.layer?.mask as? CAGradientLayer else { return }
        let b = sv.contentView.bounds
        let scrolls = sv.hasVerticalScroller
        let above = scrolls && b.minY > 0.5
        let below = scrolls && b.maxY < f.frame.height - 0.5
        let edge = NSNumber(value: Double(min(24 / max(b.height, 1), 0.5)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = sv.contentView.layer?.bounds ?? .zero
        mask.colors = [above ? NSColor.clear : NSColor.black, NSColor.black, NSColor.black,
                       below ? NSColor.clear : NSColor.black].map(\.cgColor)
        mask.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
        CATransaction.commit()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { send(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        if selector == #selector(NSResponder.insertTab(_:)), let pp = picker {
            // After this key event returns, so the menu's tracking loop does not run inside it.
            DispatchQueue.main.async { self.openPicker(pp) }
            return true
        }
        return false
    }

    private func send() {
        guard let url = image, let f = field else { return }
        let prompt = f.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let cwd = picker?.selectedItem?.representedObject as? String ?? threadCwd as String
        f.isEditable = false
        picker?.isEnabled = false
        status?.stringValue = "launching…"
        DispatchQueue.global().async {
            let (ok, out) = dispatch(prompt: prompt, image: url, cwd: cwd)
            DispatchQueue.main.async {
                if ok {
                    // The thread is already open in T3; vanish at once, no fade.
                    self.panel?.animationBehavior = .none
                    self.dismiss()
                } else {
                    f.isEditable = true
                    self.picker?.isEnabled = true
                    self.status?.toolTip = out
                    self.status?.stringValue = "failed: " + out
                    self.status?.textColor = .systemRed
                    NSLog("ShotPrompt dispatch failed: %@", out)
                }
            }
        }
    }

    private func dismiss() {
        idleTimer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
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
    }
}

func dispatch(prompt: String, image: URL, cwd: String) -> (Bool, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: dispatchBin)
    task.arguments = ["--cwd", cwd, "--image", image.path, prompt]
    // A LaunchAgent starts with a bare PATH; t3-dispatch needs node and git.
    var childEnv = env
    childEnv["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    task.environment = childEnv
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return (false, error.localizedDescription) }
    task.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (task.terminationStatus == 0, out)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
