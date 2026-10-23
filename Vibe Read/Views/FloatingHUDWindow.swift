import SwiftUI
import AppKit
import Combine
import ApplicationServices

/// Invalidates delayed work from an older HUD presentation.
///
/// Timers and AppKit animation completion handlers cannot always be cancelled
/// after they have been enqueued. Capturing this token makes those callbacks
/// harmless as soon as a newer presentation begins.
struct HUDPresentationTokenGuard: Sendable {
    typealias Token = UInt64

    private(set) var currentToken: Token = 0

    @discardableResult
    mutating func beginPresentation() -> Token {
        currentToken &+= 1
        return currentToken
    }

    func isCurrent(_ token: Token) -> Bool {
        token == currentToken
    }
}

/// Minimal pill indicator - top center of screen
/// Shows only when generating/playing, disappears when idle
/// Expands to show audio controls when playing or dictation controls when recording
@MainActor
class FloatingHUDController: NSObject, ObservableObject {
    static let shared = FloatingHUDController()

    private var window: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var hideTimer: Timer?
    private var currentVisualSize = CGSize(width: 48, height: 28)
    private var presentationGuard = HUDPresentationTokenGuard()

    enum HUDState: Equatable {
        case hidden
        case generating(message: String)  // Now includes descriptive message
        case playing
        case error
        // Dictation states
        case recording
        case recordingHandsFree  // Hands-free mode recording (green indicator)
        case recordingCommand  // Command mode recording (yellow indicator)
        case recordingSmart
        case recordingWarning(message: String)  // Time limit warning
        case transcribing
        case transcribingHandsFree  // Hands-free mode transcribing
        case transcribingCommand  // Command mode transcribing
        case transcribingSmart
        case transcribingSlow  // Taking longer than expected
        case dictationDone
        case clipboardConfirmation(returnKeyEnabled: Bool)
        case deliveryNotice(message: String)
        case cancelled  // With undo option
        case cancelledWhileTranscribing  // Cancelled during processing

        // Helper for backward compatibility
        static var generating: HUDState { .generating(message: "Generating...") }
    }

    @Published var state: HUDState = .hidden
    @Published var warningMessage: String = ""
    @Published var generatingMessage: String = "Generating..."
    @Published var undoProgress: CGFloat = 1.0  // 1.0 = full, 0.0 = expired

    // Track both TTS and dictation active states for side-by-side
    @Published var isTTSActive = false
    @Published var isDictationActive = false
    @Published var isHovering = false

    // Prevent race conditions during state transitions
    private var isHideAnimating = false

    // Pill size constants
    private let compactWidth: CGFloat = 48
    private let compactHeight: CGFloat = 28
    private let expandedWidth: CGFloat = 140
    private let expandedHeight: CGFloat = 32
    // Dictation recording pill size (compact like Wispr Flow)
    // Height includes space above for floating warnings/tooltips
    private let dictationWidth: CGFloat = 140
    private let smartDictationWidth: CGFloat = 190
    private let dictationPillHeight: CGFloat = 32
    private let dictationWindowHeight: CGFloat = 90  // Extra space for overlays above
    // Processing is normally brief, so keep this as quiet as the original HUD.
    private let transcribingSphereSize: CGFloat = 32
    private let smartProcessingWidth: CGFloat = 112
    // Cancelled/undo pill (minimal)
    private let cancelledWidth: CGFloat = 220
    private let cancelledHeight: CGFloat = 40
    private let clipboardConfirmationWidth: CGFloat = 310
    private let clipboardConfirmationHeight: CGFloat = 48
    private let deliveryNoticeWidth: CGFloat = 280
    private let deliveryNoticeHeight: CGFloat = 40
    // Warning pill (wider for message)
    private let warningWidth: CGFloat = 280
    private let warningHeight: CGFloat = 56
    // Combined TTS + Dictation pill
    private let combinedWidth: CGFloat = 290
    private let smartCombinedWidth: CGFloat = 340
    private let combinedHeight: CGFloat = 90  // Same height as dictation for overlays
    // TTS player pill (minimal)
    private let ttsPlayerWidth: CGFloat = 140
    private let ttsPlayerHeight: CGFloat = 32
    // Bottom padding above dock
    private let bottomPadding: CGFloat = 8
    // Give SwiftUI materials, borders, and shadows real pixels outside the pill.
    // The visible control still sits at `bottomPadding` above the work area.
    private let contentPadding: CGFloat = 12

    private var escapeMonitor: Any?
    private var speedBoostMonitor: Any?

    override init() {
        super.init()
        createWindow()
        observeTTSState()
        observeWindowEnvironment()
        setupKeyMonitors()
    }

    private func setupKeyMonitors() {
        // Escape key monitor for dictation cancel. Clipboard confirmation uses
        // exclusive Carbon hotkeys so Escape cannot leak into the foreground
        // application; when reservation fails, the prompt remains clickable.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let dictationState = DictationService.shared.state

            guard event.keyCode == 53 else { return }  // 53 = Escape key

            switch dictationState {
            case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning, .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
                DictationService.shared.cancel()
            default:
                break
            }
        }

        // Also add local monitor for when app is focused
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let dictationState = DictationService.shared.state

            guard event.keyCode == 53 else { return event }  // 53 = Escape key

            switch dictationState {
            case .clipboardConfirmation:
                DictationService.shared.keepExistingClipboard()
                return nil
            case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning, .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
                DictationService.shared.cancel()
                return nil  // Consume the event
            default:
                return event
            }
        }

        // 'G' key monitor for speed boost (when hovering over HUD)
        speedBoostMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Check if 'g' key (keyCode 5) and TTS is playing and user is hovering
            guard event.keyCode == 5,
                  self.isHovering,
                  InstantTTSService.shared.isSpeaking else {
                return event
            }

            InstantTTSService.shared.toggleSpeedBoost()
            return nil  // Consume the event
        }
    }

    deinit {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = speedBoostMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
    }

    private func createWindow() {
        let pillView = PillIndicatorView()
            .environmentObject(self)
            .padding(contentPadding)

        hostingView = NSHostingView(rootView: AnyView(pillView))
        let initialWindowSize = paddedWindowSize(for: currentVisualSize)
        hostingView?.frame = NSRect(origin: .zero, size: initialWindowSize)
        hostingView?.autoresizingMask = [.width, .height]

        window = NSPanel(
            contentRect: hostingView!.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window?.contentView = hostingView
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.level = .floating
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window?.isReleasedWhenClosed = false
        window?.isFloatingPanel = true
        window?.hidesOnDeactivate = false
        window?.becomesKeyOnlyIfNeeded = true
        window?.animationBehavior = .none
        // No window shadow: it drew a rim and a gap under the pill.
        window?.hasShadow = false
        window?.ignoresMouseEvents = true // Click-through by default

        applyWindowLayout()
    }

    private func updateWindowSize(expanded: Bool) {
        currentVisualSize = CGSize(
            width: expanded ? expandedWidth : compactWidth,
            height: expanded ? expandedHeight : compactHeight
        )
    }

    /// Prefer the display containing the focused app window. This follows a
    /// keyboard-driven workflow across displays and Spaces even when the mouse
    /// has not moved yet. Pointer location remains the permission-free fallback.
    private func targetScreen() -> NSScreen? {
        if let focusedWindowFrame = focusedWindowFrameInQuartzCoordinates(),
           let focusedScreen = screenWithLargestIntersection(with: focusedWindowFrame) {
            return focusedScreen
        }

        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Accessibility window coordinates and CGDisplayBounds both use the
    /// global Quartz coordinate space. Matching them directly avoids fragile
    /// top-left versus bottom-left conversions for vertically arranged screens.
    private func focusedWindowFrameInQuartzCoordinates() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedApplicationValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplicationValue
        ) == .success,
        let focusedApplicationValue,
        CFGetTypeID(focusedApplicationValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedApplication = focusedApplicationValue as! AXUIElement

        var focusedWindowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedApplication,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
        let focusedWindowValue,
        CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = focusedWindowValue as! AXUIElement

        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func screenWithLargestIntersection(with windowFrame: CGRect) -> NSScreen? {
        let matches = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let screenNumber = screen.deviceDescription[key] as? NSNumber else {
                return nil
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            let intersection = displayBounds.intersection(windowFrame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (screen, intersection.width * intersection.height)
        }
        return matches.max { $0.1 < $1.1 }?.0
    }

    private func paddedWindowSize(for visualSize: CGSize) -> CGSize {
        CGSize(
            width: visualSize.width + (contentPadding * 2),
            height: visualSize.height + (contentPadding * 2)
        )
    }

    private func applyWindowLayout(on screen: NSScreen? = nil) {
        guard let window, let screen = screen ?? targetScreen() else { return }

        let windowSize = paddedWindowSize(for: currentVisualSize)
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: round(visibleFrame.midX - (windowSize.width / 2)),
            y: round(visibleFrame.minY + bottomPadding - contentPadding),
            width: windowSize.width,
            height: windowSize.height
        )

        // Resize synchronously before SwiftUI swaps state-specific content.
        // This prevents a larger processing view from being drawn into stale bounds.
        window.setFrame(frame, display: true)
    }

    private func observeWindowEnvironment() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionVisibleHUD() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionVisibleHUD() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionVisibleHUD() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionVisibleHUD() }
            .store(in: &cancellables)
    }

    private func repositionVisibleHUD() {
        guard window?.isVisible == true else { return }
        applyWindowLayout()
        window?.orderFrontRegardless()
    }

    private func observeTTSState() {
        InstantTTSService.shared.$isLoading
            .combineLatest(
                InstantTTSService.shared.$isSpeaking,
                InstantTTSService.shared.$error
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading, isSpeaking, error in
                guard let self = self else { return }

                // Update isTTSActive FIRST, before state update
                let wasActive = self.isTTSActive
                self.isTTSActive = isLoading || isSpeaking

                print("[HUD] TTS state changed - loading: \(isLoading), speaking: \(isSpeaking), wasActive: \(wasActive), isActive: \(self.isTTSActive)")

                // Only proceed with state update if there's a meaningful change
                self.updateState(isLoading: isLoading, isSpeaking: isSpeaking, error: error)
            }
            .store(in: &cancellables)

        // Observe DictationService state
        DictationService.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dictationState in
                // Track if dictation is active (recording or transcribing)
                switch dictationState {
                case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning, .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
                    self?.isDictationActive = true
                default:
                    self?.isDictationActive = false
                }
                self?.handleDictationState(dictationState)
            }
            .store(in: &cancellables)

        // Observe undo countdown for progress bar
        DictationService.shared.$undoCountdown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] countdown in
                // Convert countdown (0-5s) to progress (0-1)
                self?.undoProgress = CGFloat(countdown / 5.0)
            }
            .store(in: &cancellables)
    }

    private func handleDictationState(_ dictationState: DictationService.State) {
        switch dictationState {
        case .idle:
            // Dictation terminal states temporarily own the HUD. When their
            // timers return to idle while read-aloud is still active, restore
            // the TTS presentation instead of leaving a stale Done/Error/Undo
            // pill that `hide()` correctly refuses to dismiss during speech.
            if isTTSActive {
                let tts = InstantTTSService.shared
                state = .hidden
                updateState(isLoading: tts.isLoading, isSpeaking: tts.isSpeaking, error: tts.error)
                warningMessage = ""
                return
            }
            // Only hide if we were showing dictation states
            if case .recording = state { hide() }
            else if case .recordingHandsFree = state { hide() }
            else if case .recordingCommand = state { hide() }
            else if case .recordingSmart = state { hide() }
            else if case .recordingWarning = state { hide() }
            else if case .transcribing = state { hide() }
            else if case .transcribingHandsFree = state { hide() }
            else if case .transcribingCommand = state { hide() }
            else if case .transcribingSmart = state { hide() }
            else if case .transcribingSlow = state { hide() }
            else if case .dictationDone = state { hide() }
            else if case .clipboardConfirmation = state { hide() }
            else if case .deliveryNotice = state { hide() }
            else if case .cancelled = state { hide() }
            else if case .cancelledWhileTranscribing = state { hide() }
            warningMessage = ""

        case .recording:
            state = .recording
            updateWindowSizeForDictation()
            show()

        case .recordingHandsFree:
            state = .recordingHandsFree
            updateWindowSizeForDictation()
            show()

        case .recordingCommand:
            state = .recordingCommand
            updateWindowSizeForDictation()
            show()

        case .recordingSmart:
            state = .recordingSmart
            updateWindowSizeForSmartDictation()
            show()

        case .recordingWarning(let message):
            warningMessage = message
            state = .recordingWarning(message: message)
            updateWindowSizeForWarning()
            show()

        case .transcribing:
            state = .transcribing
            updateWindowSizeForTranscribingSphere()
            show()

        case .transcribingHandsFree:
            state = .transcribingHandsFree
            updateWindowSizeForTranscribingSphere()
            show()

        case .transcribingCommand:
            state = .transcribingCommand
            updateWindowSizeForTranscribingSphere()
            show()

        case .transcribingSmart:
            state = .transcribingSmart
            updateWindowSizeForSmartProcessing()
            show()

        case .transcribingSlow:
            state = .transcribingSlow
            updateWindowSizeForSlowWarning()
            show()

        case .done:
            state = .dictationDone
            updateWindowSize(expanded: false)
            show()
            scheduleHide(after: 0.3)

        case .clipboardConfirmation(let returnKeyEnabled):
            state = .clipboardConfirmation(returnKeyEnabled: returnKeyEnabled)
            updateWindowSizeForClipboardConfirmation()
            show()

        case .deliveryNotice(let message):
            state = .deliveryNotice(message: message)
            updateWindowSizeForDeliveryNotice()
            show()
            scheduleDeliveryNoticeHide(after: 1.5)

        case .cancelled:
            state = .cancelled
            updateWindowSizeForCancelled()
            show()

        case .cancelledWhileTranscribing:
            state = .cancelledWhileTranscribing
            updateWindowSizeForCancelled()
            show()

        case .error(let message):
            warningMessage = message
            state = .error
            updateWindowSizeForWarning()
            show()
            scheduleHide(after: 4)
        }
    }

    private func updateWindowSizeForCancelled() {
        currentVisualSize = CGSize(width: cancelledWidth, height: cancelledHeight)
    }

    private func updateWindowSizeForWarning() {
        currentVisualSize = CGSize(width: warningWidth, height: warningHeight)
    }

    private func updateWindowSizeForClipboardConfirmation() {
        currentVisualSize = CGSize(
            width: clipboardConfirmationWidth,
            height: clipboardConfirmationHeight
        )
    }

    private func updateWindowSizeForDeliveryNotice() {
        currentVisualSize = CGSize(
            width: deliveryNoticeWidth,
            height: deliveryNoticeHeight
        )
    }

    private func updateWindowSizeForDictation() {
        // If TTS is also active, use combined width
        let useWidth = isTTSActive ? combinedWidth : dictationWidth
        currentVisualSize = CGSize(width: useWidth, height: dictationWindowHeight)
    }

    private func updateWindowSizeForSmartDictation() {
        let useWidth = isTTSActive ? smartCombinedWidth : smartDictationWidth
        currentVisualSize = CGSize(width: useWidth, height: dictationWindowHeight)
    }

    private func updateWindowSizeForTTSPlayer() {
        // If dictation is also active, use combined dimensions
        let useWidth: CGFloat
        if isDictationActive {
            if case .recordingSmart = state {
                useWidth = smartCombinedWidth
            } else {
                useWidth = combinedWidth
            }
        } else {
            useWidth = ttsPlayerWidth
        }
        let useHeight = isDictationActive ? combinedHeight : ttsPlayerHeight
        currentVisualSize = CGSize(width: useWidth, height: useHeight)
    }

    private func updateWindowSizeForTranscribingSphere() {
        currentVisualSize = CGSize(width: transcribingSphereSize, height: transcribingSphereSize)
    }

    private func updateWindowSizeForSmartProcessing() {
        currentVisualSize = CGSize(width: smartProcessingWidth, height: dictationPillHeight)
    }

    private func updateWindowSizeForSlowWarning() {
        let slowWidth: CGFloat = 280
        currentVisualSize = CGSize(width: slowWidth, height: warningHeight)
    }

    private func updateState(isLoading: Bool, isSpeaking: Bool, error: Error?) {
        cancelHideTimer()
        defer { updateWindowInteractivity() }

        print("[HUD] updateState - isLoading: \(isLoading), isSpeaking: \(isSpeaking), error: \(error != nil), dictationActive: \(isDictationActive)")

        // Clipboard delivery owns the HUD until the user decides or the
        // neutral notice expires. A concurrent TTS publisher must not replace
        // the prompt, and the notice timer restores its presentation later.
        if case .clipboardConfirmation = state { return }
        if case .deliveryNotice = state { return }

        if error != nil {
            state = .error
            updateWindowSize(expanded: false)
            show()
            scheduleHide(after: 2)
        } else if isLoading {
            // Don't override dictation states while loading TTS
            if !isDictationActive {
                showGenerating(message: generatingMessage.isEmpty ? "Generating audio..." : generatingMessage)
            }
        } else if isSpeaking {
            print("[HUD] Transitioning to PLAYING state")
            // Don't override dictation states - we'll show combined view
            if !isDictationActive {
                state = .playing
            }
            updateWindowSizeForTTSPlayer()
            show()
            // DON'T auto-hide when playing - user needs controls
            print("[HUD] Playing state - window visible: \(window?.isVisible ?? false), alpha: \(window?.alphaValue ?? 0)")
        } else {
            // Only hide if dictation is not active
            if !isDictationActive {
                updateWindowSize(expanded: false)
                hide()
            }
        }
    }

    private func setInteractive(_ interactive: Bool) {
        window?.ignoresMouseEvents = !interactive
    }

    private func updateWindowInteractivity() {
        // A concurrent TTS + dictation presentation renders player controls.
        // A standalone processing orb does not, so it remains click-through
        // instead of stealing clicks from the app beneath it.
        if isTTSActive && isDictationActive {
            setInteractive(true)
            return
        }

        switch state {
        case .generating, .playing,
             .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning,
             .transcribingSlow, .error, .clipboardConfirmation,
             .cancelled, .cancelledWhileTranscribing:
            setInteractive(true)
        case .hidden, .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart,
             .dictationDone, .deliveryNotice:
            setInteractive(false)
        }
    }

    private func cancelPendingWindowAnimations() {
        guard let window else { return }

        // A direct assignment supersedes an in-flight animator-proxy change.
        // The presentation token separately protects against an already
        // enqueued completion handler from that old animation.
        window.contentView?.layer?.removeAllAnimations()
        window.contentView?.superview?.layer?.removeAllAnimations()
        window.alphaValue = 1
    }

    func show() {
        // Every presentation invalidates callbacks belonging to the one before
        // it, including a timer that has already fired but not yet reached the
        // main actor.
        presentationGuard.beginPresentation()
        cancelHideTimer()
        cancelPendingWindowAnimations()
        isHideAnimating = false

        // A hotkey can be invoked on a different display or Space between uses.
        applyWindowLayout()
        updateWindowInteractivity()

        // Force window visible immediately (handles race conditions)
        window?.orderFrontRegardless()
    }

    func hide() {
        cancelHideTimer()

        // Don't hide if we're in a TTS active state - the player should stay visible
        if isTTSActive {
            print("[HUD] Blocking hide - TTS is active")
            return
        }

        guard window?.isVisible == true, window?.alphaValue ?? 0 > 0 else { return }
        guard !isHideAnimating else { return }

        let presentationToken = presentationGuard.currentToken
        isHideAnimating = true
        setInteractive(false)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.presentationGuard.isCurrent(presentationToken) else { return }

                // If TTS became active during animation, restore visibility
                if self.isTTSActive {
                    self.isHideAnimating = false
                    self.window?.alphaValue = 1
                    self.window?.orderFrontRegardless()
                    return
                }

                self.isHideAnimating = false
                self.window?.orderOut(nil)
                self.state = .hidden
            }
        })
    }

    // MARK: - Generating State Helpers

    /// Show generating state with a descriptive message
    func showGenerating(message: String) {
        generatingMessage = message
        state = .generating(message: message)
        updateWindowSizeForGenerating()
        show()
    }

    /// Update the generating message without changing state
    func updateGeneratingMessage(_ message: String) {
        generatingMessage = message
        if case .generating = state {
            state = .generating(message: message)
        }
    }

    /// Cancel current generation
    func cancelGenerating() {
        // Notify the TTS service to cancel
        InstantTTSService.shared.stop()
        hide()
    }

    private func updateWindowSizeForGenerating() {
        let genWidth: CGFloat = 200
        let genHeight: CGFloat = 40
        currentVisualSize = CGSize(width: genWidth, height: genHeight)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        cancelHideTimer()
        let presentationToken = presentationGuard.currentToken

        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.presentationGuard.isCurrent(presentationToken) else { return }
                self.hideTimer = nil
                // Don't hide while generating or playing
                if case .generating = self.state { return }
                if self.state == .playing { return }
                self.hide()
            }
        }
    }

    private func scheduleDeliveryNoticeHide(after seconds: TimeInterval) {
        cancelHideTimer()
        let presentationToken = presentationGuard.currentToken

        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.presentationGuard.isCurrent(presentationToken) else { return }
                guard case .deliveryNotice = self.state else { return }
                self.hideTimer = nil

                let tts = InstantTTSService.shared
                self.isTTSActive = tts.isLoading || tts.isSpeaking
                if tts.isLoading {
                    self.generatingMessage = "Generating audio..."
                    self.state = .generating(message: self.generatingMessage)
                    self.updateWindowSizeForGenerating()
                    self.show()
                } else if tts.isSpeaking {
                    self.state = .playing
                    self.updateWindowSizeForTTSPlayer()
                    self.show()
                } else {
                    self.hide()
                }
            }
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
}

// MARK: - Pill View

struct PillIndicatorView: View {
    @EnvironmentObject var controller: FloatingHUDController
    @ObservedObject private var ttsService = InstantTTSService.shared
    @State private var isHovering = false

    var body: some View {
        Group {
            // Check if both TTS and dictation are active - show combined view
            if controller.isTTSActive && controller.isDictationActive {
                combinedPill
            } else {
                // Show single state pill
                switch controller.state {
                case .generating:
                    generatingPill
                case .playing:
                    minimalAudioPlayerPill
                case .recording:
                    dictationRecordingPill(mode: .normal)
                case .recordingHandsFree:
                    dictationRecordingPill(mode: .handsFree)
                case .recordingCommand:
                    dictationRecordingPill(mode: .command)
                case .recordingSmart:
                    dictationRecordingPill(mode: .smart)
                case .recordingWarning:
                    dictationWarningPill
                case .transcribing, .transcribingHandsFree, .transcribingCommand:
                    transcribingSpherePill
                case .transcribingSmart:
                    smartTranscribingPill
                case .transcribingSlow:
                    slowTranscribingPill
                case .clipboardConfirmation(let returnKeyEnabled):
                    clipboardConfirmationPill(returnKeyEnabled: returnKeyEnabled)
                case .deliveryNotice(let message):
                    deliveryNoticePill(message: message)
                case .error:
                    errorPill
                case .cancelled:
                    cancelledPill
                case .cancelledWhileTranscribing:
                    cancelledWhileTranscribingPill
                default:
                    compactPill
                }
            }
        }
        .onHover { hovering in
            isHovering = hovering
            controller.setHovering(hovering)
        }
    }

    // MARK: - Generating Pill (with message and cancel)

    private var generatingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)

            Text(controller.generatingMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            HoverButton(
                action: { controller.cancelGenerating() },
                icon: "xmark",
                size: 20,
                iconSize: 9
            )
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    // Recording mode for display purposes
    enum RecordingDisplayMode {
        case normal
        case handsFree
        case command
        case smart
    }

    // MARK: - Combined TTS + Dictation Pill (side by side)

    private var combinedPill: some View {
        let displayMode: RecordingDisplayMode = {
            switch controller.state {
            case .recordingCommand: return .command
            case .recordingHandsFree: return .handsFree
            case .recordingSmart: return .smart
            default: return .normal
            }
        }()

        return VStack {
            Spacer()  // Push pill to bottom

            HStack(spacing: 8) {
                // TTS player section
                minimalAudioPlayerContent

                // Divider
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 20)

                // Dictation section
                dictationRecordingContent(mode: displayMode)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            )
        }
    }

    // MARK: - Compact Pill (generating, error, dictation states)

    private var compactPill: some View {
        HStack(spacing: 4) {
            compactIndicator
        }
        .frame(width: 48, height: 28)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        )
    }

    // MARK: - Minimal Audio Player Pill (clean, no moving parts)

    private var minimalAudioPlayerPill: some View {
        HStack(spacing: 8) {
            minimalAudioPlayerContent
        }
        .padding(.horizontal, 10)
        .frame(width: 140, height: 32)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    // Content view that can be used in combined pill
    private var minimalAudioPlayerContent: some View {
        HStack(spacing: 8) {
            // Play/Pause button
            Button(action: {
                ttsService.toggle()
            }) {
                Image(systemName: ttsService.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverScaleButtonStyle())

            // Static speaker icon (no animation)
            Image(systemName: ttsService.isPaused ? "speaker.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.accentColor)

            // Speed indicator - subtle, changes with boost
            Text(speedIndicatorText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(ttsService.isSpeedBoosted ? .accentColor : .secondary)
                .frame(minWidth: 24)
                .help(isHovering ? "Press 'g' to toggle speed" : "")

            // Stop/close button
            HoverButton(
                action: { ttsService.stop() },
                icon: "xmark",
                size: 18,
                iconSize: 8
            )
        }
    }

    private var speedIndicatorText: String {
        let rate = ttsService.isSpeedBoosted ? AppSettings.shared.speedBoostMultiplier : 1.0
        if rate == 1.0 {
            return "1x"
        } else {
            return String(format: "%.1fx", rate)
        }
    }

    // MARK: - Dictation Recording Pill (minimal, almost invisible)

    private func dictationRecordingPill(mode: RecordingDisplayMode) -> some View {
        DictationPillWithWarning(mode: mode)
    }

    // Content view that can be used in combined pill
    private func dictationRecordingContent(mode: RecordingDisplayMode) -> some View {
        DictationRecordingContentView(mode: mode)
    }

    // MARK: - Transcribing Indicator

    private var transcribingSpherePill: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            )
            .accessibilityLabel("Processing dictation")
            .allowsHitTesting(false)
    }

    private var smartTranscribingPill: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)

            Text("Smart edit")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(width: 112, height: 32)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        )
        .accessibilityLabel("Smart dictation is editing")
        .allowsHitTesting(false)
    }

    // MARK: - Clipboard Delivery

    private func clipboardConfirmationPill(returnKeyEnabled: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Paste failed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(returnKeyEnabled
                     ? "Return to copy · Esc keeps clipboard"
                     : "Choose Copy or Keep")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            clipboardChoiceButton("Copy") {
                DictationService.shared.confirmClipboardOverwrite()
            }

            clipboardChoiceButton("Keep") {
                DictationService.shared.keepExistingClipboard()
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 310, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paste failed. Choose whether to copy the dictation or keep the existing clipboard.")
    }

    private func clipboardChoiceButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func deliveryNoticePill(message: String) -> some View {
        Text(message)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(width: 280, height: 40)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .accessibilityLabel(message)
            .allowsHitTesting(false)
    }

    // MARK: - Recording Warning Pill (time limit approaching)

    private var dictationWarningPill: some View {
        VStack(spacing: 4) {
            // Top row: waveform + stop
            HStack(spacing: 8) {
                HoverButton(
                    action: { DictationService.shared.cancel() },
                    icon: "xmark",
                    size: 20,
                    iconSize: 9
                )

                AudioWaveformView()

                Button(action: {
                    DictationService.shared.toggle()
                }) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 10, height: 10)
                        .padding(6)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(HoverScaleButtonStyle())
            }

            // Warning message
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(controller.warningMessage)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 240, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        )
    }

    // MARK: - Slow Transcribing Pill

    private var slowTranscribingPill: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)

                Text("Taking longer than usual...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                HoverButton(
                    action: { DictationService.shared.cancel() },
                    icon: "xmark",
                    size: 18,
                    iconSize: 8
                )
            }

            Text("Your dictation is saved. You can retry in the app.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    // MARK: - Error Pill

    private var isPermissionError: Bool {
        let msg = controller.warningMessage.lowercased()
        return msg.contains("permission") || msg.contains("microphone") || msg.contains("accessibility")
    }

    private var isCleanupWarning: Bool {
        controller.warningMessage.lowercased().contains("cleanup")
    }

    private var errorPill: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isPermissionError ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(isPermissionError ? .orange : .secondary)

                Text(
                    isPermissionError
                        ? "Permission needed"
                        : (isCleanupWarning ? "Cleanup skipped" : "Something went wrong")
                )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                HoverButton(
                    action: {
                        FloatingHUDController.shared.hide()
                    },
                    icon: "xmark",
                    size: 18,
                    iconSize: 8
                )
            }

            HStack(spacing: 8) {
                Text(controller.warningMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if isPermissionError {
                    Spacer()
                    Button(action: openRelevantSettings) {
                        Text("Open Settings")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: isPermissionError ? 280 : 240, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    private func openRelevantSettings() {
        let msg = controller.warningMessage.lowercased()
        if msg.contains("microphone") {
            // Open microphone settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        } else if msg.contains("accessibility") {
            // Open accessibility settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            // Generic privacy settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(url)
            }
        }
        FloatingHUDController.shared.hide()
    }

    // MARK: - Cancelled Pill (with undo countdown)

    private var cancelledPill: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Cancelled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: {
                    DictationService.shared.undoCancel()
                }) {
                    Text("Undo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)

                HoverButton(
                    action: { DictationService.shared.dismissUndo() },
                    icon: "xmark",
                    size: 18,
                    iconSize: 8
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Progress bar - white line that shrinks over 5 seconds
            GeometryReader { geo in
                let progressWidth = max(0, min(geo.size.width, geo.size.width * controller.undoProgress))
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: progressWidth.isFinite ? progressWidth : 0, height: 2)
                    .animation(.linear(duration: 0.1), value: controller.undoProgress)
            }
            .frame(height: 2)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .frame(width: 220, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    // MARK: - Cancelled While Transcribing Pill

    private var cancelledWhileTranscribingPill: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Cancelled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: {
                    DictationService.shared.undoCancel()
                }) {
                    Text("Undo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)

                HoverButton(
                    action: { DictationService.shared.dismissUndo() },
                    icon: "xmark",
                    size: 18,
                    iconSize: 8
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Progress bar - white line that shrinks over 5 seconds
            GeometryReader { geo in
                let progressWidth = max(0, min(geo.size.width, geo.size.width * controller.undoProgress))
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: progressWidth.isFinite ? progressWidth : 0, height: 2)
                    .animation(.linear(duration: 0.1), value: controller.undoProgress)
            }
            .frame(height: 2)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .frame(width: 220, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    @ViewBuilder
    private var compactIndicator: some View {
        switch controller.state {
        case .hidden, .playing, .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning, .error, .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow, .clipboardConfirmation, .deliveryNotice, .cancelled, .cancelledWhileTranscribing, .generating:
            // These have their own expanded pills
            EmptyView()

        case .dictationDone:
            // Very subtle - just a small dot that quickly fades
            Circle()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 6, height: 6)
        }
    }

    private var compactBorderColor: Color {
        // Keep all borders subtle and uniform
        return .primary.opacity(0.08)
    }
}

// MARK: - Audio-Reactive Waveform

struct AudioWaveformView: View {
    @ObservedObject private var recorder = AudioRecorderService.shared

    // Number of bars in waveform
    private let barCount = 9

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(index: index, audioLevel: recorder.audioLevel)
            }
        }
        .frame(width: 50, height: 16)
    }
}

struct WaveformBar: View {
    let index: Int
    let audioLevel: Float

    // Each bar has a slightly different response for visual variety
    private var barMultiplier: CGFloat {
        let multipliers: [CGFloat] = [0.6, 0.8, 1.0, 0.9, 1.0, 0.9, 1.0, 0.8, 0.6]
        return multipliers[index % multipliers.count]
    }

    private var barHeight: CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 14
        let level = CGFloat(audioLevel) * barMultiplier
        return minHeight + (maxHeight - minHeight) * level
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.primary.opacity(0.5))
            .frame(width: 2.5, height: barHeight)
            .animation(.easeOut(duration: 0.08), value: audioLevel)
    }
}

// MARK: - Hover Button Component

struct HoverButton: View {
    let action: () -> Void
    let icon: String
    var size: CGFloat = 20
    var iconSize: CGFloat = 9

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(isHovered ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.15 : 0.08))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Hover Scale Button Style

struct HoverScaleButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : (isHovered ? 1.05 : 1.0))
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Dictation Pill With Warning (handles silence detection at pill level)

private struct DictationPillWithWarning: View {
    let mode: PillIndicatorView.RecordingDisplayMode

    @State private var showSilenceWarning = false
    @State private var silenceTimer: Timer?
    @State private var lastAudioDetectedTime = Date()

    @ObservedObject private var recorder = AudioRecorderService.shared

    var body: some View {
        VStack(spacing: 8) {
            // Silence warning at top (visible in the space above pill)
            if showSilenceWarning {
                SilenceWarningView()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer()

            // The actual pill at bottom
            HStack(spacing: 8) {
                DictationRecordingContentView(mode: mode)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .modifier(GlassCapsule())
        }
        .onAppear {
            startSilenceDetection()
        }
        .onDisappear {
            stopSilenceDetection()
        }
        .onChange(of: recorder.audioLevel) { newLevel in
            if newLevel > 0.05 {
                lastAudioDetectedTime = Date()
                if showSilenceWarning {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showSilenceWarning = false
                    }
                }
            }
        }
    }

    private func startSilenceDetection() {
        lastAudioDetectedTime = Date()
        showSilenceWarning = false

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let silenceDuration = Date().timeIntervalSince(lastAudioDetectedTime)
            if silenceDuration >= 4.0 && !showSilenceWarning {
                withAnimation(.easeOut(duration: 0.2)) {
                    showSilenceWarning = true
                }
            }
        }
    }

    private func stopSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}

/// Plain glass pill with no border or shadow.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

// MARK: - Dictation Recording Content (buttons and waveform)

private struct DictationRecordingContentView: View {
    let mode: PillIndicatorView.RecordingDisplayMode

    @State private var cancelHovered = false
    @State private var completeHovered = false

    private var completeLabel: String {
        switch mode {
        case .command: return "Send"
        case .smart: return "Send"
        case .handsFree: return "Done"
        case .normal: return "Done"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Cancel button with hover label
            LabeledHoverButton(
                action: { DictationService.shared.cancel() },
                icon: "xmark",
                label: "Cancel",
                size: 20,
                iconSize: 9,
                isHovered: $cancelHovered
            )

            if case .smart = mode {
                Label("Smart", systemImage: "wand.and.stars")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            // Audio-reactive waveform
            AudioWaveformView()

            // Stop/complete button with hover label
            CompleteButton(
                mode: mode,
                label: completeLabel,
                isHovered: $completeHovered
            )
        }
    }
}

// MARK: - Silence Warning View

private struct SilenceWarningView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)

                Text("No audio detected")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Text("Check if your mic is muted or working.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
    }
}

// MARK: - Labeled Hover Button (with floating label above)

private struct LabeledHoverButton: View {
    let action: () -> Void
    let icon: String
    let label: String
    var size: CGFloat = 20
    var iconSize: CGFloat = 9
    @Binding var isHovered: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(isHovered ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.15 : 0.08))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            // Floating label above the button
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                )
                .opacity(isHovered ? 1 : 0)
                .offset(y: isHovered ? -24 : -16)
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Complete Button (stop square with floating label above)

private struct CompleteButton: View {
    let mode: PillIndicatorView.RecordingDisplayMode
    let label: String
    @Binding var isHovered: Bool

    var body: some View {
        Button(action: {
            switch mode {
            case .command:
                DictationService.shared.toggleCommandMode()
            case .smart:
                DictationService.shared.toggleSmartDictation()
            case .handsFree:
                DictationService.shared.toggleHandsFree()
            case .normal:
                DictationService.shared.toggle()
            }
        }) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(isHovered ? 1.0 : 0.8))
                .frame(width: 10, height: 10)
                .padding(6)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.15 : 0.1))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .overlay(alignment: .top) {
            // Floating label above the button
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                )
                .opacity(isHovered ? 1 : 0)
                .offset(y: isHovered ? -24 : -16)
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
