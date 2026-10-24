import Foundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics

enum PasteFailure: Equatable {
    case accessibilityDenied
    case targetChanged
    case eventUnavailable
    case clipboardUnavailable
}

enum AutoPasteOutcome: Equatable {
    case pasted
    case failed(PasteFailure)

    var didPaste: Bool {
        if case .pasted = self { return true }
        return false
    }
}

struct ClipboardObservation: Equatable {
    let changeCount: Int
    let hasContent: Bool
}

enum ClipboardReplacementOutcome: Equatable {
    case copied
    case changed
    case unavailable
}

/// Permission and focused-application operations that macOS protects behind
/// Accessibility. Reserved ordinary shortcuts do not depend on this service.
class AccessibilityService: ObservableObject {
    static let shared = AccessibilityService()

    @Published var hasAccessibilityPermission = false
    /// Screen Recording is used only to screenshot areas marked with Ctrl
    /// during dictation. macOS may report a new grant only after a relaunch.
    @Published var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @Published var isPollingForPermission = false

    private var permissionPollingTimer: Timer?
    private var pollingStartTime: Date?

    private init() {
        _ = checkPermission()
    }

    // MARK: - Accessibility Permission

    /// Check if app has accessibility permissions
    @discardableResult
    func checkPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        let permissionWasGranted = hasAccessibilityPermission
        hasAccessibilityPermission = trusted
        print("[Accessibility] Permission: \(trusted ? "GRANTED" : "NOT GRANTED")")

        if trusted && !permissionWasGranted {
            stopPermissionPolling()
            // Notify keyboard service to start monitoring
            KeyboardShortcutService.shared.retryEventTapSetup()
        }

        return trusted
    }

    /// Request accessibility permission - this DOES show a system dialog
    func requestAccessibilityPermission() {
        print("[Accessibility] Requesting permission (will show dialog)...")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let trusted = checkPermission()
        print("[Accessibility] Dialog shown, current status: \(trusted ? "granted" : "pending")")

        // Start polling in case user grants it in System Settings
        if !trusted {
            startPollingForAccessibility()
        }
    }

    /// Open System Settings to Accessibility pane
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permission Polling

    /// Start polling for Accessibility permission
    private func startPollingForAccessibility() {
        stopPermissionPolling()
        isPollingForPermission = true
        pollingStartTime = Date()

        print("[Accessibility] Started polling for permission...")

        permissionPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollForAccessibilityPermission()
        }
    }

    private func pollForAccessibilityPermission() {
        if let startTime = pollingStartTime, Date().timeIntervalSince(startTime) > 120 {
            print("[Accessibility] Stopped polling (timeout)")
            stopPermissionPolling()
            return
        }

        let granted = checkPermission()
        if granted {
            print("[Accessibility] Permission detected!")
            stopPermissionPolling()
        }
    }

    func stopPermissionPolling() {
        permissionPollingTimer?.invalidate()
        permissionPollingTimer = nil
        isPollingForPermission = false
        pollingStartTime = nil
    }

    /// Manually refresh permission status
    func refreshAllPermissions() {
        _ = checkPermission()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    /// Requests every missing permission in one go. Microphone access is
    /// still requested by the first recording.
    func requestMissingPermissions() {
        if !hasAccessibilityPermission {
            requestAccessibilityPermission()
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Get Selected Text

    /// Get the currently selected text from the frontmost application
    /// Returns nil if no text is selected or accessibility permission is denied
    func getSelectedText() -> String? {
        guard checkPermission() else {
            print("[Accessibility] Cannot get selection - no permission")
            return nil
        }

        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()

        // Get the focused application
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        guard appResult == .success, let appElement = focusedApp else {
            print("[Accessibility] Could not get focused application")
            return nil
        }

        // Get the focused UI element within the application
        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            appElement as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard elementResult == .success, let element = focusedElement else {
            print("[Accessibility] Could not get focused element")
            return nil
        }

        // Try to get selected text directly
        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        if textResult == .success, let text = selectedText as? String, !text.isEmpty {
            // Selected text can contain passwords, private messages, or other
            // sensitive content. Never include it in console output.
            print("[Accessibility] Got selected text via AX")
            return text
        }

        // Fallback: try selected text range
        var selectedTextRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedTextRange
        )

        if rangeResult == .success {
            // Get text for the range
            var textForRange: AnyObject?
            let paramResult = AXUIElementCopyParameterizedAttributeValue(
                element as! AXUIElement,
                kAXStringForRangeParameterizedAttribute as CFString,
                selectedTextRange!,
                &textForRange
            )

            if paramResult == .success, let text = textForRange as? String, !text.isEmpty {
                print("[Accessibility] Got selected text via range")
                return text
            }
        }

        // Do not synthesize Cmd+C here. That approach can mutate or partially
        // restore rich clipboard contents. Callers can offer the existing
        // clipboard as an explicit, visibly labelled source instead.
        print("[Accessibility] No selected text found via AX")
        return nil
    }

    /// Remote desktop apps send keys to another computer. They track modifier
    /// state from real modifier key events, so a V that only carries the
    /// Command flag arrives as a bare "v". They also sync the clipboard to the
    /// remote side on their own schedule, so the paste needs more time.
    static let remoteDesktopBundleIdentifiers: Set<String> = [
        "tv.parsec.www",
        "com.microsoft.rdc.macos",
        "com.p5sys.jump.mac.viewer",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
        "com.carriez.rustdesk"
    ]

    /// Events for a shortcut such as Cmd+V. With `pressModifierKey`, the key is
    /// wrapped in real Command (or Control) key down and up events, like a
    /// physical keyboard. Returns nil if an event could not be constructed.
    static func shortcutEvents(
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        pressModifierKey: Bool
    ) -> [CGEvent]? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return nil
        }
        keyDown.flags = modifiers
        keyUp.flags = modifiers
        guard pressModifierKey else { return [keyDown, keyUp] }

        // kVK_Command = 55, kVK_Control = 59. CoreGraphics turns these into
        // flagsChanged events with the matching modifier flags.
        let modifierKey: CGKeyCode = modifiers.contains(.maskCommand) ? 55 : 59
        guard let modifierDown = CGEvent(keyboardEventSource: source, virtualKey: modifierKey, keyDown: true),
              let modifierUp = CGEvent(keyboardEventSource: source, virtualKey: modifierKey, keyDown: false) else {
            return nil
        }
        return [modifierDown, keyDown, keyUp, modifierUp]
    }

    /// Post a shortcut. Returning false means the event could not be
    /// constructed, so callers can keep a clipboard fallback. With real
    /// modifier keys, short gaps let remote apps see the modifier first; call
    /// that variant off the main thread.
    @discardableResult
    static func postShortcut(
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        pressModifierKey: Bool
    ) -> Bool {
        guard let events = shortcutEvents(
            keyCode: keyCode,
            modifiers: modifiers,
            pressModifierKey: pressModifierKey
        ) else { return false }
        for (index, event) in events.enumerated() {
            if pressModifierKey && (index == 1 || index == 3) {
                usleep(30_000)
            }
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    static func isRemoteDesktop(_ target: UniversalActionTarget?) -> Bool {
        let bundleIdentifier = target?.bundleIdentifier.isEmpty == false
            ? target?.bundleIdentifier
            : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return remoteDesktopBundleIdentifiers.contains(bundleIdentifier ?? "")
    }

    /// Cmd+V for paste. Remote desktop apps get real Command key events, sent
    /// after a short wait so they have synced the clipboard to the remote side.
    private static func postPasteShortcut(remote: Bool) -> Bool {
        guard remote else {
            return postShortcut(keyCode: 9, modifiers: .maskCommand, pressModifierKey: false)
        }
        guard shortcutEvents(keyCode: 9, modifiers: .maskCommand, pressModifierKey: true) != nil else {
            return false
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.25) {
            postShortcut(keyCode: 9, modifiers: .maskCommand, pressModifierKey: true)
        }
        return true
    }

    /// Remote desktop apps read the clipboard late, so keep the transcript on
    /// it longer before the user's clipboard comes back.
    private static func restoreDelay(remote: Bool) -> TimeInterval {
        remote ? 1.5 : 0.35
    }

    // MARK: - Paste Text

    /// Observe whether replacing the clipboard needs the user's consent.
    /// Any pasteboard type counts as content, including images and rich text.
    func clipboardObservation() -> ClipboardObservation {
        Self.clipboardObservation(pasteboard: .general)
    }

    static func clipboardObservation(pasteboard: NSPasteboard) -> ClipboardObservation {
        ClipboardObservation(
            changeCount: pasteboard.changeCount,
            hasContent: !(pasteboard.types?.isEmpty ?? true)
        )
    }

    /// Replace the clipboard only if it has not changed since the prompt was
    /// shown. This prevents a stale Return press from destroying newer data.
    func replaceClipboardIfUnchanged(
        _ text: String,
        expectedChangeCount: Int
    ) -> ClipboardReplacementOutcome {
        Self.replaceClipboardIfUnchanged(
            text,
            expectedChangeCount: expectedChangeCount,
            pasteboard: .general
        )
    }

    static func replaceClipboardIfUnchanged(
        _ text: String,
        expectedChangeCount: Int,
        pasteboard: NSPasteboard
    ) -> ClipboardReplacementOutcome {
        guard pasteboard.changeCount == expectedChangeCount else { return .changed }
        let previousItems = (pasteboard.pasteboardItems ?? []).map {
            PasteboardItemSnapshot(item: $0)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(previousItems, to: pasteboard)
            return .unavailable
        }
        return .copied
    }

    /// Attempt automatic paste while preserving the user's existing rich
    /// clipboard. A known failure never replaces the clipboard.
    func pasteTextPreservingClipboardWithOutcome(
        _ text: String,
        expectedTarget: UniversalActionTarget? = nil
    ) -> AutoPasteOutcome {
        let remote = Self.isRemoteDesktop(expectedTarget)
        let outcome = Self.deliverTextPreservingClipboard(
            text,
            expectedTarget: expectedTarget,
            pasteboard: .general,
            hasAccessibilityPermission: checkPermission(),
            currentTarget: {
                guard let application = NSWorkspace.shared.frontmostApplication else {
                    return nil
                }
                return UniversalActionTarget(
                    bundleIdentifier: application.bundleIdentifier ?? "",
                    processIdentifier: application.processIdentifier,
                    applicationName: application.localizedName ?? "the original app"
                )
            },
            postPasteShortcut: {
                Self.postPasteShortcut(remote: remote)
            },
            scheduleRestore: { restore in
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay(remote: remote)) {
                    restore()
                }
            }
        )

        switch outcome {
        case .pasted:
            print("[Accessibility] Paste shortcut posted; previous clipboard scheduled for restore")
        case .failed(.accessibilityDenied):
            print("[Accessibility] Cannot paste without Accessibility permission")
        case .failed(.targetChanged):
            print("[Accessibility] Paste target changed")
        case .failed(.eventUnavailable):
            print("[Accessibility] Paste shortcut unavailable")
        case .failed(.clipboardUnavailable):
            print("[Accessibility] Could not stage text for paste")
        }

        return outcome
    }

    /// Paste text for an explicit action such as Cmd+E Apply. Unlike completed
    /// dictation delivery, this keeps the user's existing clipboard intact.
    @discardableResult
    func pasteText(
        _ text: String,
        expectedTarget: UniversalActionTarget? = nil
    ) -> Bool {
        let remote = Self.isRemoteDesktop(expectedTarget)
        return Self.deliverTextPreservingClipboard(
            text,
            expectedTarget: expectedTarget,
            pasteboard: .general,
            hasAccessibilityPermission: checkPermission(),
            currentTarget: Self.frontmostApplicationTarget,
            postPasteShortcut: {
                Self.postPasteShortcut(remote: remote)
            },
            scheduleRestore: { restore in
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay(remote: remote)) {
                    restore()
                }
            }
        ).didPaste
    }

    /// Deterministic core for automatic paste and explicit actions. It stages
    /// text only long enough to post Cmd+V, then restores the old clipboard.
    static func deliverTextPreservingClipboard(
        _ text: String,
        expectedTarget: UniversalActionTarget?,
        pasteboard: NSPasteboard,
        hasAccessibilityPermission: Bool,
        currentTarget: () -> UniversalActionTarget?,
        postPasteShortcut: () -> Bool,
        scheduleRestore: (@escaping () -> Void) -> Void
    ) -> AutoPasteOutcome {
        guard hasAccessibilityPermission else {
            return .failed(.accessibilityDenied)
        }
        if let expectedTarget,
           !targetMatches(expectedTarget, currentTarget()) {
            return .failed(.targetChanged)
        }

        let previousItems = (pasteboard.pasteboardItems ?? []).map {
            PasteboardItemSnapshot(item: $0)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(previousItems, to: pasteboard)
            return .failed(.clipboardUnavailable)
        }
        let temporaryChangeCount = pasteboard.changeCount

        // Snapshotting a lazy pasteboard can take time, so validate again at
        // the actual event-posting boundary.
        if let expectedTarget,
           !targetMatches(expectedTarget, currentTarget()) {
            if pasteboard.changeCount == temporaryChangeCount {
                restore(previousItems, to: pasteboard)
            }
            return .failed(.targetChanged)
        }

        guard postPasteShortcut() else {
            if pasteboard.changeCount == temporaryChangeCount {
                restore(previousItems, to: pasteboard)
            }
            return .failed(.eventUnavailable)
        }

        scheduleRestore {
            guard pasteboard.changeCount == temporaryChangeCount else { return }
            restore(previousItems, to: pasteboard)
        }
        return .pasted
    }

    private static func targetMatches(
        _ expected: UniversalActionTarget,
        _ current: UniversalActionTarget?
    ) -> Bool {
        guard let current else { return false }
        return expected.processIdentifier == current.processIdentifier
            && (expected.bundleIdentifier.isEmpty
                || expected.bundleIdentifier == current.bundleIdentifier)
    }

    private static func frontmostApplicationTarget() -> UniversalActionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return UniversalActionTarget(
            bundleIdentifier: application.bundleIdentifier ?? "",
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "the original app"
        )
    }

    private static func restore(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = snapshots.map(\.pasteboardItem)
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - Get Frontmost App Info

    /// Get info about the frontmost application (for debugging)
    func getFrontmostAppInfo() -> (name: String, bundleId: String)? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return (
            name: frontApp.localizedName ?? "Unknown",
            bundleId: frontApp.bundleIdentifier ?? "Unknown"
        )
    }
}

private struct PasteboardItemSnapshot {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]

    init(item: NSPasteboardItem) {
        values = item.types.compactMap { type in
            item.data(forType: type).map { (type, $0) }
        }
    }

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        for value in values {
            item.setData(value.data, forType: value.type)
        }
        return item
    }
}

// MARK: - Key Codes Reference
// Common key codes for macOS:
// C = 8, V = 9, R = 15, Space = 49
// Command = .maskCommand, Shift = .maskShift, Option = .maskAlternate
