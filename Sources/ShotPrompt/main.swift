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
// the prompt is empty, Esc, switching apps, or 5 seconds idle closes the
// panel; once you have typed, only Esc does. Cmd shortcuts in the panel edit
// the prompt. Dictation (holding Fn, or Wispr Flow using the microphone with
// any hotkey or hands-free) opens the prompt from the icon and keeps an empty
// prompt open while you talk and a little after. The project
// picker in the panel (Tab, or click it) sends the thread to another T3 project.
// With the pasteIntoT3 setting on, a capture taken in T3 Code skips all of
// that and lands in the chat open there, as if you pressed Cmd+V in it.

// This file is the AppKit shell: windows, views, event monitors, timers and
// observers. Every decision it acts on lives in ShotPromptCore, which has the tests.

import AppKit
import Carbon.HIToolbox
import CoreAudio
import ShotPromptCore

let config = Config(environment: ProcessInfo.processInfo.environment,
                    home: FileManager.default.homeDirectoryForCurrentUser)

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
    private let watcher = CaptureWatcher(directory: config.captureDir)
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
    private var lastAppObserver: NSObjectProtocol?
    // Counts captures, so a paste still waiting for T3 gives way to a newer one.
    private var captures = 0

    func start() {
        watcher.onCapture = { [weak self] url in self?.show(url) }
        do { try watcher.start() } catch { fatalError("cannot watch \(config.captureDir.path)") }
        lastApp = NSWorkspace.shared.frontmostApplication.flatMap { Self.bystander($0) ? nil : $0 }
        lastAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !Self.bystander(app) else { return }
            self?.lastApp = app
        }
    }

    private static func bystander(_ app: NSRunningApplication) -> Bool {
        isBystander(bundleID: app.bundleIdentifier,
                    isSelf: app.processIdentifier == ProcessInfo.processInfo.processIdentifier)
    }

    private var hasText: Bool { !(field?.string.isEmpty ?? true) }

    private func show(_ url: URL) {
        captures += 1
        let app = capturedApp(front: NSWorkspace.shared.frontmostApplication, previous: lastApp,
                              isBystander: Self.bystander)
        let toT3 = pastesIntoT3(enabled: UserDefaults.standard.bool(forKey: pasteIntoT3Key),
                                capturedBundleID: app?.bundleIdentifier)
        // A new capture while typing replaces the screenshot, not the prompt.
        // While a send is running, the sent screenshot stays.
        switch captureAction(hasText: hasText, editable: field?.isEditable ?? true, pasteIntoT3: toT3) {
        case .ignore:
            return
        case .replaceImage:
            image = url
            thumbnail?.image = NSImage(contentsOf: url)
            return
        case .pasteIntoT3:
            dismiss()
            paste(url, into: app!)
        case .showIcon:
            showIcon(url)
        }
    }

    // Pastes the capture into the chat open in T3: the image goes on the
    // clipboard, T3's composer takes the focus (also away from a selection in
    // the chat or in an HTML render), then Cmd+V goes to T3. Driving another
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
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setData(png, forType: .png)
                    Self.commandV(to: app)
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

    // Cmd+V, posted to T3 itself so it cannot land in another app.
    private static func commandV(to app: NSRunningApplication) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
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

        let projects = loadProjects(databasePath: config.t3Database)
        let s = NSTextField(labelWithString: statusHint(hasProjects: !projects.isEmpty))
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
        p.setFrameOrigin(panelOrigin(iconFrame: anchor, panelHeight: p.frame.height, visible: screen.visibleFrame))

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
    private func makePicker(_ projects: [Project]) -> NSPopUpButton {
        let pp = NSPopUpButton(frame: .zero, pullsDown: false)
        pp.isBordered = false
        pp.controlSize = .small
        pp.font = .systemFont(ofSize: 11)
        (pp.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        for entry in pickerEntries(projects: projects, defaultRoot: config.threadCwd) {
            // Its own action, since Tab pops the menu up outside the button.
            let item = NSMenuItem(title: entry.name, action: #selector(pickedProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.root
            item.toolTip = entry.toolTip
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
                                           maxLines: maxPromptLines)
        // A scroller only past the cap, so it does not flash on each new line.
        sv.hasVerticalScroller = fit.scrolls
        (sv.contentView as? TopClipView)?.pinTop = !fit.scrolls
        if p.frame.height != fit.panelHeight {
            let frame = grownFrame(p.frame, height: fit.panelHeight, visible: p.screen?.visibleFrame)
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
        guard let prompt = sendablePrompt(f.string) else { return }
        let cwd = picker?.selectedItem?.representedObject as? String ?? config.threadCwd
        f.isEditable = false
        picker?.isEnabled = false
        status?.stringValue = "launching…"
        DispatchQueue.global().async {
            let (ok, out) = dispatch(executable: config.dispatchBin, prompt: prompt, image: url, cwd: cwd,
                                     environment: config.environment, home: config.home)
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
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()

// The phone receiver (ios/README.md): on only when receiverPort and
// receiverToken are set. Read once at launch; restart the agent after a change.
var receiver: ReceiverServer?
if let settings = receiverSettings(port: UserDefaults.standard.integer(forKey: receiverPortKey),
                                   token: UserDefaults.standard.string(forKey: receiverTokenKey)) {
    let context = ReceiverContext(
        token: settings.token, defaultRoot: config.threadCwd,
        projects: { loadProjects(databasePath: config.t3Database) },
        saveImage: imageSaver(dir: FileManager.default.temporaryDirectory.appendingPathComponent("ShotPrompt-phone")),
        dispatch: { prompt, image, cwd in
            dispatch(executable: config.dispatchBin, prompt: prompt, image: image, cwd: cwd,
                     environment: config.environment, home: config.home)
        })
    do {
        receiver = try ReceiverServer(port: settings.port) { handle($0, context) }
        receiver?.start { error in
            NSLog("ShotPrompt receiver on 127.0.0.1:%d: %@", Int(settings.port), error ?? "listening")
        }
    } catch {
        NSLog("ShotPrompt receiver could not start: %@", error.localizedDescription)
    }
}
app.run()
