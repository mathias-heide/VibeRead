import AppKit
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "com.viberead.app", category: "ScreenMarks")

/// One region the user marked while dictating. `offset` is measured from the
/// start of the recording so the screenshot can be placed where it was spoken.
struct VisualCapture: Sendable {
    let offset: TimeInterval
    let pngData: Data
}

/// Screen marking during dictation. While a recording runs, holding Ctrl and
/// moving the mouse draws a trail; releasing Ctrl screenshots the trail's
/// bounding box. The panels are click-through and never become key, so the
/// app underneath keeps working and keeps the cursor for the final paste.
final class VisualAnnotationOverlay {
    static let shared = VisualAnnotationOverlay()

    private var isArmed = false
    private var panels: [(screen: NSScreen, panel: NSPanel, view: OverlayDrawingView)] = []
    private var recordingStart: TimeInterval = 0
    private var captureTasks: [Task<VisualCapture?, Never>] = []
    private var monitors: [Any] = []

    // Current Ctrl-held mark, in global Cocoa screen coordinates.
    private var trail: [NSPoint] = []
    private var isMarking = false
    private var sampleTimer: Timer?

    private init() {}

    var isActive: Bool { isArmed }

    /// Called when a recording starts. Nothing is shown until Ctrl is held.
    func begin() {
        end()
        isArmed = true
        recordingStart = CACurrentMediaTime()
        log.notice("Armed for recording")
        let flags: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event.modifierFlags) }
        let keyDown: (NSEvent) -> Void = { [weak self] _ in self?.cancelMark() }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) {
            monitors.append(monitor)
        } else {
            log.error("Could not observe modifier keys")
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDown) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            flags(event)
            return event
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            keyDown(event)
            return event
        }) {
            monitors.append(monitor)
        }
    }

    /// Stops marking and hands back every capture, including ones whose
    /// screenshot is still in flight.
    func finish() -> [Task<VisualCapture?, Never>] {
        let tasks = captureTasks
        end()
        return tasks
    }

    func end() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        stopSampling()
        isMarking = false
        trail = []
        for entry in panels { entry.panel.orderOut(nil) }
        panels = []
        captureTasks = []
        isArmed = false
    }

    // MARK: - Marking

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.control, .command, .option, .shift, .function])
        // Ctrl on its own. Ctrl with fn is the voice action palette, and Ctrl
        // with other modifiers is somebody else's shortcut.
        let controlAlone = relevant == .control
        log.notice("Modifiers changed, ctrl alone: \(controlAlone, privacy: .public), marking: \(self.isMarking, privacy: .public)")
        if controlAlone && !isMarking {
            startMark()
        } else if !controlAlone && isMarking {
            if flags.contains(.control) {
                cancelMark()
            } else {
                finishMark()
            }
        }
    }

    private func startMark() {
        isMarking = true
        trail = [NSEvent.mouseLocation]
        showPanelsIfNeeded()
        setMarking(true)
        // Polling the pointer needs no extra permission and works over every app.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.samplePointer()
        }
    }

    private func samplePointer() {
        let point = NSEvent.mouseLocation
        guard point != trail.last else { return }
        trail.append(point)
        for entry in panels { entry.view.currentTrail = localPoints(trail, on: entry.screen) }
    }

    /// Ctrl was combined with a key (Ctrl+C) or another modifier: not a mark.
    private func cancelMark() {
        guard isMarking else { return }
        stopSampling()
        isMarking = false
        trail = []
        for entry in panels { entry.view.currentTrail = [] }
        setMarking(false)
    }

    private func finishMark() {
        stopSampling()
        isMarking = false
        let points = trail
        trail = []
        setMarking(false)
        for entry in panels { entry.view.currentTrail = [] }

        guard let first = points.first else { return }
        var bounds = NSRect(origin: first, size: .zero)
        for point in points { bounds = bounds.union(NSRect(origin: point, size: .zero)) }
        // A Ctrl tap without moving the mouse is not a mark.
        log.notice("Mark finished, \(points.count, privacy: .public) points, \(Int(bounds.width), privacy: .public)x\(Int(bounds.height), privacy: .public)")
        guard bounds.width >= 12 || bounds.height >= 12 else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // macOS shows its own prompt only once per app, so also open the
            // right Settings page. Marks work after access is granted and
            // Vibe Read is reopened.
            log.error("Screen Recording not granted")
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            NSSound.beep()
            for entry in panels { entry.view.currentTrail = [] }
            return
        }
        guard let screen = NSScreen.screens.max(by: {
            area($0.frame.intersection(bounds)) < area($1.frame.intersection(bounds))
        }) else { return }

        let number = captureTasks.count + 1
        for entry in panels {
            entry.view.addMark(points: localPoints(points, on: entry.screen), number: number)
        }
        // The image belongs with what was said up to the moment Ctrl is released.
        capture(globalRect: bounds, on: screen, at: CACurrentMediaTime())
    }

    private func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    private func setMarking(_ marking: Bool) {
        for entry in panels { entry.view.isMarking = marking }
    }

    private func area(_ rect: NSRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private func localPoints(_ points: [NSPoint], on screen: NSScreen) -> [NSPoint] {
        points.map { NSPoint(x: $0.x - screen.frame.minX, y: $0.y - screen.frame.minY) }
    }

    private func showPanelsIfNeeded() {
        guard panels.isEmpty else { return }
        for screen in NSScreen.screens {
            let panel = OverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            // Just below the HUD pill so it stays on top.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            let view = OverlayDrawingView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append((screen, panel, view))
        }
    }

    // MARK: - Capture

    private func capture(globalRect: NSRect, on screen: NSScreen, at markTime: TimeInterval) {
        // Measure from the first recorded sample when it is on the same clock;
        // otherwise fall back to when the recording was requested.
        var audioZero = recordingStart
        if let firstSample = AudioRecorderService.shared.firstSampleHostTime,
           abs(firstSample - recordingStart) < 3 {
            audioZero = firstSample
        }
        let offset = max(0, markTime - audioZero)
        // Pad the mark so the element keeps some context.
        let padded = globalRect.insetBy(dx: -12, dy: -12).intersection(screen.frame)
        // Display-local points with a top-left origin, as ScreenCaptureKit expects.
        let sourceRect = CGRect(
            x: padded.minX - screen.frame.minX,
            y: screen.frame.maxY - padded.maxY,
            width: padded.width,
            height: padded.height
        )
        let scale = screen.backingScaleFactor
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value

        let task = Task<VisualCapture?, Never> {
            guard let displayID,
                  let image = await Self.captureImage(displayID: displayID, sourceRect: sourceRect, scale: scale),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                log.error("Screenshot failed")
                return nil
            }
            log.notice("Screenshot captured at \(offset, privacy: .public)s")
            return VisualCapture(offset: offset, pngData: png)
        }
        captureTasks.append(task)
    }

    private static func captureImage(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        scale: CGFloat
    ) async -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            // Exclude Vibe Read itself so the marks and HUD are not in the shot.
            let ownApps = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = max(1, Int(sourceRect.width * scale))
            configuration.height = max(1, Int(sourceRect.height * scale))
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            log.error("Screen capture error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayDrawingView: NSView {
    var isMarking = false { didSet { needsDisplay = true } }
    var currentTrail: [NSPoint] = [] { didSet { needsDisplay = true } }
    private var marks: [(points: [NSPoint], number: Int, addedAt: TimeInterval)] = []
    private var fadeTimer: Timer?

    // Marks start fading as soon as Ctrl is released and are gone in 0.5 s.
    private static let visibleDuration: TimeInterval = 0
    private static let fadeDuration: TimeInterval = 0.5

    func addMark(points: [NSPoint], number: Int) {
        marks.append((points, number, CACurrentMediaTime()))
        needsDisplay = true
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.updateFade()
        }
    }

    private func updateFade() {
        let now = CACurrentMediaTime()
        let lifetime = Self.visibleDuration + Self.fadeDuration
        marks.removeAll { now - $0.addedAt >= lifetime }
        if marks.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        needsDisplay = true
    }

    private func opacity(of addedAt: TimeInterval) -> CGFloat {
        let fading = CACurrentMediaTime() - addedAt - Self.visibleDuration
        return CGFloat(max(0, min(1, 1 - fading / Self.fadeDuration)))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isMarking {
            // A faint tint and border while Ctrl is held show that the mouse
            // is marking.
            NSColor.black.withAlphaComponent(0.06).setFill()
            bounds.fill()
            NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            border.lineWidth = 4
            border.stroke()
        }

        for mark in marks {
            let alpha = opacity(of: mark.addedAt)
            NSColor.systemRed.withAlphaComponent(alpha).setStroke()
            path(for: mark.points).stroke()
            if let top = mark.points.max(by: { $0.y < $1.y }),
               let left = mark.points.min(by: { $0.x < $1.x }) {
                drawBadge(mark.number, at: NSPoint(x: left.x, y: top.y), alpha: alpha)
            }
        }
        if !currentTrail.isEmpty {
            NSColor.systemRed.setStroke()
            path(for: currentTrail).stroke()
        }
    }

    private func path(for points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        return path
    }

    private func drawBadge(_ number: Int, at point: NSPoint, alpha: CGFloat) {
        let badge = NSRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
        NSColor.systemRed.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
