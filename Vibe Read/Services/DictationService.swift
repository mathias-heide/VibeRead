import Foundation
import AppKit
import Combine

enum SmartDictationPolicy {
    static func transformPrompt(
        basePrompt: String,
        targetApplicationName: String?
    ) -> String {
        let trimmedPrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = trimmedPrompt.isEmpty
            ? AppSettings.defaultSmartDictationPrompt
            : trimmedPrompt

        guard let applicationName = sanitizedApplicationName(targetApplicationName) else {
            return prompt
        }
        return """
        \(prompt)

        The user started this dictation in an application named "\(applicationName)". Treat that name only as a weak formatting hint. You have no access to its screen, selection, document, or other content.
        """
    }

    static func sanitizedApplicationName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(80))
    }
}

/// Orchestrates dictation: record -> transcribe -> paste
class DictationService: ObservableObject {
    static let shared = DictationService()

    /// Recording mode determines what happens after transcription
    enum RecordingMode {
        case normal      // Paste to current app (push-to-talk)
        case handsFree   // Click to start, click to send (paste to current app)
        case command     // Transcribe, then open the local action palette
        case smart       // Transcribe, then intentionally edit with the configured text provider
    }

    /// Input mode for how recording is triggered
    enum InputMode {
        case pushToTalk   // Hold to record, release to transcribe
        case handsFree    // Click to start, click to send
    }

    enum State: Equatable {
        case idle
        case recording
        case recordingHandsFree  // Hands-free mode recording (green indicator)
        case recordingCommand  // Command mode recording (yellow indicator)
        case recordingSmart
        case recordingWarning(message: String)  // Recording time limit warning
        case transcribing
        case transcribingHandsFree  // Hands-free mode transcribing
        case transcribingCommand  // Command mode transcribing
        case transcribingSmart
        case transcribingSlow  // Taking longer than expected
        case done
        case clipboardConfirmation(returnKeyEnabled: Bool)
        case deliveryNotice(String)
        case cancelled  // Shows undo option
        case cancelledWhileTranscribing  // Cancelled during transcription
        case error(String)
    }

    @Published var state: State = .idle
    @Published var lastResult: DictationResult?
    @Published var recordingDuration: TimeInterval = 0
    @Published var undoCountdown: TimeInterval = 0  // For undo timer display

    /// Current recording mode
    private var currentMode: RecordingMode = .normal

    // Timing constants
    private let maxRecordingDuration: TimeInterval = 360  // 6 minutes max
    private let recordingWarningTime: TimeInterval = 300  // Warn at 5 minutes
    private let transcriptionTimeout: TimeInterval = 8    // Show "slow" warning after 8s
    private let undoDuration: TimeInterval = 5  // 5 seconds to undo

    private let recorder = AudioRecorderService.shared
    private var recordingURL: URL?
    private var recordingTimer: Timer?
    private var transcriptionStartTime: Date?
    private var transcriptionTimeoutTimer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    private var activeTranscriptionID: UUID?
    private var activeTempAudioURL: URL?
    private var activeSavedAudioURL: URL?
    private var activeDurationMs: Int?
    private var activeClientID: UUID?
    private var activePasteTarget: UniversalActionTarget?
    private var activeContextApplicationName: String?
    /// Screenshots marked with Ctrl during a normal or hands-free recording.
    /// Kept until the recording is delivered or discarded so Undo after
    /// Cancel still has them.
    private var visualCaptureTasks: [Task<VisualCapture?, Never>] = []

    private struct PendingClipboardCopy {
        let id: UUID
        let text: String
        let expectedChangeCount: Int
    }
    private var pendingClipboardCopy: PendingClipboardCopy?
    private var clipboardConfirmationTimer: Timer?
    private var deliveryNoticeTimer: Timer?

    private struct PendingMicrophoneStart {
        let id: UUID
        let mode: RecordingMode
        let contextApplicationName: String?
        let requiresHeldShortcut: Bool
        var shouldStartAfterPermission: Bool
    }
    private var pendingMicrophoneStart: PendingMicrophoneStart?

    // Undo support
    private var pendingCancelURL: URL?  // Audio file pending deletion
    private var pendingCancelSavedURL: URL?
    private var pendingCancelDurationMs: Int?
    private var pendingCancelClientID: UUID?
    private var pendingCancelPasteTarget: UniversalActionTarget?
    private var pendingCancelContextApplicationName: String?
    private var pendingCancelCapturesTargetOnUndo = false
    private var undoTimer: Timer?

    private init() {}

    /// Lets shortcut routing distinguish an idle recorder from one that is
    /// already waiting on the system permission sheet. The value is nonsecret
    /// and checking it never touches microphone or provider permissions.
    var isAwaitingMicrophonePermission: Bool {
        pendingMicrophoneStart != nil
    }

    static func transformPrompt(
        for mode: RecordingMode,
        smartPrompt: String,
        targetApplicationName: String?
    ) -> String? {
        guard case .smart = mode else { return nil }
        return SmartDictationPolicy.transformPrompt(
            basePrompt: smartPrompt,
            targetApplicationName: targetApplicationName
        )
    }

    static func hardTimeout(for mode: RecordingMode) -> TimeInterval {
        switch mode {
        case .smart:
            // Smart Dictation has two bounded network stages. Leave enough
            // time for the text stage to fail normally so APIService can
            // return the successful raw transcript instead.
            return APIService.transcriptionTimeout + APIService.textActionTimeout + 5
        case .normal, .handsFree, .command:
            return APIService.transcriptionTimeout
        }
    }

    /// Hands-free recording is a true toggle. The second fn press should stop
    /// immediately instead of waiting for the key-up event, which macOS does
    /// not always deliver consistently while a global recording is active.
    var isHandsFreeRecording: Bool {
        guard currentMode == .handsFree else { return false }
        switch state {
        case .recordingHandsFree, .recordingWarning:
            return true
        default:
            return false
        }
    }

    /// Toggle dictation - start if idle, stop if recording (push-to-talk style)
    func toggle() {
        switch state {
        case .idle, .done, .error, .clipboardConfirmation, .deliveryNotice:
            beginRecording(mode: .normal)
        case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning:
            stopAndTranscribe()
        case .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
            // Ignore - wait for transcription
            break
        case .cancelled, .cancelledWhileTranscribing:
            // If clicking again while cancelled, dismiss and start new
            dismissUndo()
            beginRecording(mode: .normal)
        }
    }

    /// Toggle hands-free dictation - click to start, click to send
    func toggleHandsFree() {
        switch state {
        case .idle, .done, .error, .clipboardConfirmation, .deliveryNotice:
            beginRecording(mode: .handsFree)
        case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning:
            stopAndTranscribe()
        case .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
            // Ignore - wait for transcription
            break
        case .cancelled, .cancelledWhileTranscribing:
            dismissUndo()
            beginRecording(mode: .handsFree)
        }
    }

    /// Start command mode dictation - sends to AI provider after transcription
    func toggleCommandMode() {
        switch state {
        case .idle, .done, .error, .clipboardConfirmation, .deliveryNotice:
            beginRecording(mode: .command)
        case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning:
            stopAndTranscribe()
        case .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
            // Ignore - wait for transcription
            break
        case .cancelled, .cancelledWhileTranscribing:
            dismissUndo()
            beginRecording(mode: .command)
        }
    }

    /// Smart dictation is deliberately separate from normal fn dictation.
    /// It performs speech-to-text first, then asks the configured text model
    /// to turn spoken instructions into finished text.
    func toggleSmartDictation() {
        switch state {
        case .idle, .done, .error, .clipboardConfirmation, .deliveryNotice:
            beginRecording(mode: .smart)
        case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning:
            stopAndTranscribe()
        case .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
            break
        case .cancelled, .cancelledWhileTranscribing:
            dismissUndo()
            beginRecording(mode: .smart)
        }
    }

    /// Start push-to-talk recording (called when fn key is pressed)
    func startPushToTalk() {
        switch state {
        case .idle, .done, .error, .clipboardConfirmation, .deliveryNotice:
            beginRecording(mode: .normal, requiresHeldShortcut: true)
        default:
            break
        }
    }

    /// End push-to-talk recording (called when fn key is released)
    func endPushToTalk() {
        switch state {
        case .recording, .recordingWarning:
            // Only end if we're in normal push-to-talk mode (not hands-free)
            if currentMode == .normal {
                stopAndTranscribe()
            }
        case .idle:
            // On first use the system permission sheet can outlive the held
            // chord. Releasing push-to-talk invalidates that pending start so
            // approval cannot begin a recording after the user let go.
            if pendingMicrophoneStart?.requiresHeldShortcut == true {
                pendingMicrophoneStart?.shouldStartAfterPermission = false
                activePasteTarget = nil
                activeContextApplicationName = nil
            }
        default:
            break
        }
    }

    /// Cancel current recording/transcription - shows undo option
    func cancel() {
        switch state {
        case .recording, .recordingHandsFree, .recordingCommand, .recordingSmart, .recordingWarning:
            cancelRecordingWithUndo()
        case .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart, .transcribingSlow:
            cancelTranscriptionWithUndo()
        case .clipboardConfirmation:
            keepExistingClipboard()
        case .deliveryNotice:
            state = .idle
        default:
            break
        }
    }

    /// Called when user clicks Undo within the countdown
    func undoCancel() {
        stopUndoTimer()

        if let url = pendingCancelURL {
            let savedURL = pendingCancelSavedURL
            let durationMs = pendingCancelDurationMs
            let clientID = pendingCancelClientID
            let pasteTarget = pendingCancelCapturesTargetOnUndo
                ? Self.frontmostApplicationTarget()
                : pendingCancelPasteTarget
            let contextApplicationName = pendingCancelContextApplicationName
            pendingCancelURL = nil
            pendingCancelSavedURL = nil
            pendingCancelDurationMs = nil
            pendingCancelClientID = nil
            pendingCancelPasteTarget = nil
            pendingCancelContextApplicationName = nil
            pendingCancelCapturesTargetOnUndo = false

            // Recording cannot be resumed, but the captured audio can be sent
            // again. Reuse its retained copy so undo does not create an orphan.
            state = transcriptionState(for: currentMode)
            transcriptionStartTime = Date()
            startTranscriptionTimer()
            transcribeAudio(
                url: url,
                durationMs: durationMs,
                existingSavedURL: savedURL,
                clientID: clientID,
                pasteTarget: pasteTarget,
                contextApplicationName: contextApplicationName
            )
        }

        print("[Dictation] Undo - resuming transcription")
    }

    /// Dismiss the undo prompt immediately (user closed it)
    func dismissUndo() {
        stopUndoTimer()
        cleanupPendingCancel()
        state = .idle
    }

    private func cancelRecordingWithUndo() {
        stopRecordingTimer()
        if VisualAnnotationOverlay.shared.isActive {
            visualCaptureTasks = VisualAnnotationOverlay.shared.finish()
        }
        // Stop recording but keep the file for potential undo
        if let url = recorder.stopRecording() {
            pendingCancelURL = url
        }
        pendingCancelSavedURL = nil
        pendingCancelDurationMs = Int(recordingDuration * 1_000)
        pendingCancelClientID = nil
        pendingCancelPasteTarget = nil
        pendingCancelContextApplicationName = activeContextApplicationName
        pendingCancelCapturesTargetOnUndo = true

        recordingURL = nil
        activePasteTarget = nil
        activeContextApplicationName = nil
        recordingDuration = 0
        state = .cancelled
        undoCountdown = undoDuration
        startUndoTimer()
        playSubtleSound()
        print("[Dictation] Cancelled with undo option")
    }

    private func cancelTranscriptionWithUndo() {
        stopTranscriptionTimer()
        // Invalidate before cancelling: even if URLSession races and returns a
        // response, the old generation is no longer allowed to save or paste.
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeTranscriptionID = nil
        pendingCancelURL = activeTempAudioURL ?? recordingURL
        pendingCancelSavedURL = activeSavedAudioURL
        pendingCancelDurationMs = activeDurationMs
        pendingCancelClientID = activeClientID
        pendingCancelPasteTarget = activePasteTarget
        pendingCancelContextApplicationName = activeContextApplicationName
        pendingCancelCapturesTargetOnUndo = false
        clearActiveTranscriptionResources()
        recordingURL = nil

        state = .cancelledWhileTranscribing
        undoCountdown = undoDuration
        startUndoTimer()
        print("[Dictation] Transcription cancelled with undo option")
    }

    private func startUndoTimer() {
        undoTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.undoCountdown -= 0.1
            if self.undoCountdown <= 0 {
                self.stopUndoTimer()
                self.cleanupPendingCancel()
                self.state = .idle
            }
        }
    }

    private func stopUndoTimer() {
        undoTimer?.invalidate()
        undoTimer = nil
    }

    private func cleanupPendingCancel() {
        if let url = pendingCancelURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let savedURL = pendingCancelSavedURL, savedURL != pendingCancelURL {
            try? FileManager.default.removeItem(at: savedURL)
        }
        pendingCancelURL = nil
        pendingCancelSavedURL = nil
        pendingCancelDurationMs = nil
        pendingCancelClientID = nil
        pendingCancelPasteTarget = nil
        pendingCancelContextApplicationName = nil
        pendingCancelCapturesTargetOnUndo = false
        visualCaptureTasks = []
    }

    private func beginRecording(
        mode: RecordingMode,
        requiresHeldShortcut: Bool = false
    ) {
        clearPendingClipboardConfirmation()
        visualCaptureTasks = []

        // The permission sheet is asynchronous while the public state remains
        // idle. Ignore repeated shortcut starts until that exact request has
        // resolved so they cannot replace its mode or target.
        guard pendingMicrophoneStart == nil else { return }

        // Smart Dictation may use the starting app name as bounded context.
        // Delivery is intentionally chosen later, when the user presses Send.
        let contextApplicationName = Self.frontmostApplicationTarget()?.applicationName
        currentMode = mode
        activePasteTarget = nil
        activeContextApplicationName = contextApplicationName
        performStartRecording(
            mode: mode,
            contextApplicationName: contextApplicationName,
            requiresHeldShortcut: requiresHeldShortcut
        )
    }

    private func performStartRecording(
        mode: RecordingMode,
        contextApplicationName: String?,
        requiresHeldShortcut: Bool
    ) {
        do {
            recordingURL = try recorder.startRecording()
            currentMode = mode
            activePasteTarget = nil
            activeContextApplicationName = contextApplicationName
            recordingDuration = 0

            switch mode {
            case .normal:
                state = .recording
                VisualAnnotationOverlay.shared.begin()
            case .handsFree:
                state = .recordingHandsFree
                VisualAnnotationOverlay.shared.begin()
            case .command:
                state = .recordingCommand
            case .smart:
                state = .recordingSmart
            }

            startRecordingTimer()
            playSubtleSound()

            print("[Dictation] Recording started (mode: \(mode))")
        } catch let error as AudioRecorderService.RecordingError where error == .permissionNotRequested {
            // First use. Bind the callback to this exact generation so a stale
            // response can never start a later operation or use mutable mode /
            // focus state from another shortcut.
            let request = PendingMicrophoneStart(
                id: UUID(),
                mode: mode,
                contextApplicationName: contextApplicationName,
                requiresHeldShortcut: requiresHeldShortcut,
                shouldStartAfterPermission: true
            )
            pendingMicrophoneStart = request
            state = .idle
            recorder.requestPermission { [weak self] granted in
                guard let self,
                      let pendingRequest = self.pendingMicrophoneStart,
                      pendingRequest.id == request.id else { return }
                self.pendingMicrophoneStart = nil
                guard pendingRequest.shouldStartAfterPermission else {
                    self.activePasteTarget = nil
                    self.activeContextApplicationName = nil
                    return
                }
                if granted {
                    self.currentMode = pendingRequest.mode
                    self.activePasteTarget = nil
                    self.activeContextApplicationName = pendingRequest.contextApplicationName
                    self.performStartRecording(
                        mode: pendingRequest.mode,
                        contextApplicationName: pendingRequest.contextApplicationName,
                        requiresHeldShortcut: pendingRequest.requiresHeldShortcut
                    )
                } else {
                    self.activePasteTarget = nil
                    self.activeContextApplicationName = nil
                    self.state = .error("Microphone permission denied")
                }
            }
        } catch {
            activePasteTarget = nil
            activeContextApplicationName = nil
            state = .error(error.localizedDescription)
            print("[Dictation] Failed to start: \(error)")
        }
    }

    // MARK: - Recording Timer

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateRecordingDuration()
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func updateRecordingDuration() {
        recordingDuration += 1

        // Check for warning threshold
        if recordingDuration >= recordingWarningTime && recordingDuration < maxRecordingDuration {
            let remaining = Int(maxRecordingDuration - recordingDuration)
            state = .recordingWarning(message: "\(remaining)s left")
        }

        // Auto-stop at max duration
        if recordingDuration >= maxRecordingDuration {
            print("[Dictation] Max recording duration reached, auto-stopping")
            stopAndTranscribe()
        }
    }

    private func stopAndTranscribe() {
        stopRecordingTimer()

        // The app containing the cursor when Send is pressed is the intended
        // destination. Hold this target through the provider request, then
        // revalidate it immediately before posting Cmd+V.
        let pasteTarget = Self.frontmostApplicationTarget()
        if VisualAnnotationOverlay.shared.isActive {
            visualCaptureTasks = VisualAnnotationOverlay.shared.finish()
        }

        guard let url = recorder.stopRecording() else {
            activePasteTarget = nil
            activeContextApplicationName = nil
            state = .error("No recording to process")
            return
        }

        state = transcriptionState(for: currentMode)

        playStopSound()  // Satisfying "sent" sound
        transcriptionStartTime = Date()
        startTranscriptionTimer()
        print("[Dictation] Processing (mode: \(currentMode))...")

        let recordedDurationMs = Int(recordingDuration * 1_000)
        transcribeAudio(
            url: url,
            durationMs: recordedDurationMs,
            pasteTarget: pasteTarget,
            contextApplicationName: activeContextApplicationName
        )
    }

    private func transcribeAudio(
        url: URL,
        durationMs: Int? = nil,
        existingSavedURL: URL? = nil,
        clientID existingClientID: UUID? = nil,
        pasteTarget capturedPasteTarget: UniversalActionTarget?,
        contextApplicationName capturedContextApplicationName: String?
    ) {
        transcriptionTask?.cancel()
        let savedURL = existingSavedURL ?? saveAudioForHistory(tempURL: url)
        let mode = currentMode  // Capture mode before async

        let clientID = existingClientID ?? UUID()
        // The destination is captured at Send, not when recording begins and
        // not after the provider returns. A nil capture remains fail-closed.
        let pasteTarget = capturedPasteTarget
        // Normal fn, hands-free, and command-palette dictation remain direct
        // speech-to-text. Only the explicit Smart shortcut invokes a text model.
        let transformPrompt = Self.transformPrompt(
            for: mode,
            smartPrompt: AppSettings.shared.smartDictationPrompt,
            targetApplicationName: capturedContextApplicationName
        )
        let transcriptionID = UUID()
        activeTranscriptionID = transcriptionID
        activeTempAudioURL = url
        activeSavedAudioURL = savedURL
        activeDurationMs = durationMs
        activeClientID = clientID
        activePasteTarget = pasteTarget
        activeContextApplicationName = capturedContextApplicationName

        let captureTasks = visualCaptureTasks

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                var collectedCaptures: [VisualCapture] = []
                for task in captureTasks {
                    if let capture = await task.value { collectedCaptures.append(capture) }
                }
                let captures = collectedCaptures
                let result: DictationResult
                let visualParts: [VisualDictation.Part]
                if captures.isEmpty {
                    visualParts = []
                    result = try await APIService.shared.transcribeDictation(
                        audioURL: url,
                        vocabulary: AppSettings.shared.customVocabulary,
                        transformPrompt: transformPrompt,
                        clientId: clientID.uuidString
                    )
                } else {
                    visualParts = try await Self.transcribeVisual(audioURL: url, captures: captures)
                    let imagePaths = VisualDictation.saveCaptures(captures)
                    let text = VisualDictation.plainText(parts: visualParts) { index in
                        imagePaths.indices.contains(index)
                            ? "[Image \(index + 1): \(imagePaths[index].path)]"
                            : "[Image \(index + 1)]"
                    }
                    result = DictationResult(rawTranscript: text, polishedText: text, durationMs: nil)
                }
                try Task.checkCancellation()

                await MainActor.run {
                    guard self.activeTranscriptionID == transcriptionID,
                          !Task.isCancelled else { return }
                    self.stopTranscriptionTimer()
                    self.lastResult = result
                    var completionWarning = result.warning
                    var clipboardFallbackText: String?
                    self.recordingDuration = 0

                    DictationStore.shared.add(
                        result,
                        audioURL: savedURL,
                        durationMs: durationMs,
                        clientId: clientID
                    )

                    // Handle based on mode
                    if !visualParts.isEmpty {
                        self.deliverVisual(
                            parts: visualParts,
                            captures: captures,
                            fallbackText: result.polishedText,
                            pasteTarget: pasteTarget,
                            tempAudioURL: url
                        )
                        return
                    }
                    switch mode {
                    case .normal, .handsFree, .smart:
                        if case .smart = mode, result.warning != nil {
                            completionWarning = AppSettings.shared.autoPasteAfterDictation
                                ? "Smart edit was unavailable. Your raw dictation was pasted."
                                : "Smart edit was unavailable. Your raw dictation was saved."
                        }
                        if AppSettings.shared.autoPasteAfterDictation {
                            if let pasteTarget {
                                let outcome = AccessibilityService.shared
                                    .pasteTextPreservingClipboardWithOutcome(
                                        result.polishedText,
                                        expectedTarget: pasteTarget
                                    )
                                switch outcome {
                                case .pasted:
                                    if case .smart = mode, result.warning != nil {
                                        completionWarning = "Smart edit was unavailable. Raw dictation pasted."
                                    }
                                case .failed:
                                    clipboardFallbackText = result.polishedText
                                }
                            } else {
                                clipboardFallbackText = result.polishedText
                            }
                        }
                    case .command:
                        // Voice-driven command mode feeds the local action
                        // palette instead of leaking text into a browser URL.
                        AppDelegate.toggleActionPalette(prefilledText: result.polishedText)
                    }

                    try? FileManager.default.removeItem(at: url)
                    self.recordingURL = nil
                    self.transcriptionTask = nil
                    self.activeTranscriptionID = nil
                    self.clearActiveTranscriptionResources()

                    if let clipboardFallbackText {
                        self.offerClipboardFallback(clipboardFallbackText)
                    } else {
                        self.state = completionWarning.map(State.error) ?? .done

                        if completionWarning != nil {
                            self.scheduleErrorDismissal()
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    if case .done = self.state {
                                        self.state = .idle
                                    }
                                }
                            }
                        }
                    }
                }

                print("[Dictation] Transcription completed")
            } catch {
                let wasCancelled = Task.isCancelled || error is CancellationError
                await MainActor.run {
                    guard self.activeTranscriptionID == transcriptionID,
                          !wasCancelled else { return }
                    self.stopTranscriptionTimer()
                    self.state = .error(error.localizedDescription)
                    self.recordingDuration = 0
                    // Provider errors can echo request content. Surface the
                    // localized message in the UI, but keep it out of logs.
                    print("[Dictation] Transcription failed")

                    try? FileManager.default.removeItem(at: url)
                    if let saved = savedURL {
                        DictationStore.shared.addFailed(
                            audioURL: saved,
                            durationMs: durationMs,
                            clientId: clientID
                        )
                    }
                    self.recordingURL = nil
                    self.transcriptionTask = nil
                    self.activeTranscriptionID = nil
                    self.clearActiveTranscriptionResources()

                    self.scheduleErrorDismissal()
                }
            }
        }
    }

    /// Transcribes the whole recording once, so speech that overlaps drawing
    /// stays intact, then places each screenshot using word timings.
    private static func transcribeVisual(
        audioURL: URL,
        captures: [VisualCapture]
    ) async throws -> [VisualDictation.Part] {
        let transcript = try await APIService.shared.transcribeWithWordTimings(
            audioURL: audioURL,
            vocabulary: AppSettings.shared.customVocabulary
        )
        let words = transcript.words ?? VisualDictation.estimatedWords(
            transcript: transcript.text,
            duration: VisualDictation.audioDuration(of: audioURL)
        )
        let texts = VisualDictation.segmentTexts(
            transcript: transcript.text,
            words: words,
            anchors: captures.map(\.offset)
        )
        return VisualDictation.parts(segmentTexts: texts, imageCount: captures.count)
    }

    /// Escape during delivery cancels it; any other state means it is over.
    private var isDeliveringVisual: Bool {
        switch state {
        case .transcribing, .transcribingHandsFree, .transcribingSlow: return true
        default: return false
        }
    }

    /// Pastes text and screenshots in spoken order. The HUD stays in its
    /// processing state until the last paste so no new recording can start
    /// while the clipboard is being used.
    private func deliverVisual(
        parts: [VisualDictation.Part],
        captures: [VisualCapture],
        fallbackText: String,
        pasteTarget: UniversalActionTarget?,
        tempAudioURL: URL
    ) {
        try? FileManager.default.removeItem(at: tempAudioURL)
        recordingURL = nil
        transcriptionTask = nil
        activeTranscriptionID = nil
        visualCaptureTasks = []
        clearActiveTranscriptionResources()

        Task { @MainActor [weak self] in
            var delivered = false
            if AppSettings.shared.autoPasteAfterDictation, let pasteTarget {
                delivered = await VisualDictation.deliver(
                    parts: parts,
                    captures: captures,
                    target: pasteTarget,
                    shouldContinue: { [weak self] in self?.isDeliveringVisual == true }
                )
            }
            guard let self, self.isDeliveringVisual else { return }
            if delivered {
                self.state = .done
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    if case .done = self?.state { self?.state = .idle }
                }
            } else {
                // Image paths keep the screenshots usable from the clipboard.
                self.offerClipboardFallback(fallbackText)
            }
        }
    }

    private func transcriptionState(for mode: RecordingMode) -> State {
        switch mode {
        case .normal: return .transcribing
        case .handsFree: return .transcribingHandsFree
        case .command: return .transcribingCommand
        case .smart: return .transcribingSmart
        }
    }

    // MARK: - Clipboard Fallback

    /// A failed automatic paste never destroys an occupied clipboard. Empty
    /// clipboards can accept the result immediately; otherwise the user gets a
    /// short, explicit confirmation and the dictation remains in History.
    private func offerClipboardFallback(_ text: String) {
        clearPendingClipboardConfirmation()
        let accessibility = AccessibilityService.shared
        let observation = accessibility.clipboardObservation()

        guard observation.hasContent else {
            switch accessibility.replaceClipboardIfUnchanged(
                text,
                expectedChangeCount: observation.changeCount
            ) {
            case .copied:
                showDeliveryNotice("Copied to clipboard · Paste with Cmd+V")
            case .changed:
                let refreshed = accessibility.clipboardObservation()
                if refreshed.hasContent {
                    presentClipboardConfirmation(text, observation: refreshed)
                } else {
                    showDeliveryNotice("Dictation saved in History")
                }
            case .unavailable:
                showDeliveryNotice("Clipboard unavailable · Dictation saved")
            }
            return
        }

        presentClipboardConfirmation(text, observation: observation)
    }

    private func presentClipboardConfirmation(
        _ text: String,
        observation: ClipboardObservation
    ) {
        let request = PendingClipboardCopy(
            id: UUID(),
            text: text,
            expectedChangeCount: observation.changeCount
        )
        pendingClipboardCopy = request

        let returnKeyEnabled = KeyboardShortcutService.shared.beginClipboardConfirmation(
            onConfirm: { [weak self] in
                self?.confirmClipboardOverwrite(requestID: request.id)
            },
            onKeep: { [weak self] in
                self?.keepExistingClipboard(requestID: request.id)
            }
        )
        state = .clipboardConfirmation(returnKeyEnabled: returnKeyEnabled)

        clipboardConfirmationTimer = Timer.scheduledTimer(
            withTimeInterval: 8,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.keepExistingClipboard(requestID: request.id)
            }
        }
    }

    /// Called by Return or the visible Copy button.
    func confirmClipboardOverwrite() {
        guard let requestID = pendingClipboardCopy?.id else { return }
        confirmClipboardOverwrite(requestID: requestID)
    }

    private func confirmClipboardOverwrite(requestID: UUID) {
        guard let request = pendingClipboardCopy,
              request.id == requestID else { return }

        let outcome = AccessibilityService.shared.replaceClipboardIfUnchanged(
            request.text,
            expectedChangeCount: request.expectedChangeCount
        )
        clearPendingClipboardConfirmation()

        switch outcome {
        case .copied:
            showDeliveryNotice("Copied to clipboard · Paste with Cmd+V")
        case .changed:
            showDeliveryNotice("Clipboard changed · Dictation saved in History")
        case .unavailable:
            showDeliveryNotice("Clipboard unavailable · Dictation saved")
        }
    }

    /// Called by Escape, timeout, or the visible Keep button.
    func keepExistingClipboard() {
        guard let requestID = pendingClipboardCopy?.id else { return }
        keepExistingClipboard(requestID: requestID)
    }

    private func keepExistingClipboard(requestID: UUID) {
        guard pendingClipboardCopy?.id == requestID else { return }
        clearPendingClipboardConfirmation()
        showDeliveryNotice("Clipboard kept · Dictation saved in History")
    }

    private func clearPendingClipboardConfirmation() {
        guard pendingClipboardCopy != nil || clipboardConfirmationTimer != nil else { return }
        clipboardConfirmationTimer?.invalidate()
        clipboardConfirmationTimer = nil
        pendingClipboardCopy = nil
        KeyboardShortcutService.shared.endClipboardConfirmation()
    }

    private func showDeliveryNotice(_ message: String) {
        deliveryNoticeTimer?.invalidate()
        state = .deliveryNotice(message)
        deliveryNoticeTimer = Timer.scheduledTimer(
            withTimeInterval: 1.6,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .deliveryNotice = self.state {
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - Transcription Timer

    private func startTranscriptionTimer() {
        transcriptionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkTranscriptionTimeout()
        }
    }

    private func stopTranscriptionTimer() {
        transcriptionTimeoutTimer?.invalidate()
        transcriptionTimeoutTimer = nil
        transcriptionStartTime = nil
    }

    private func checkTranscriptionTimeout() {
        guard let startTime = transcriptionStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)

        // Show a slow warning for either the speech or optional Smart step.
        if elapsed >= transcriptionTimeout {
            switch state {
            case .transcribing, .transcribingHandsFree, .transcribingCommand, .transcribingSmart:
                state = .transcribingSlow
            default:
                break
            }
        }

        // Hard timeout - give up
        if elapsed >= Self.hardTimeout(for: currentMode) {
            failActiveTranscriptionDueToTimeout()
        }
    }

    private func failActiveTranscriptionDueToTimeout() {
        guard activeTranscriptionID != nil else {
            stopTranscriptionTimer()
            state = .error("Request timed out. Check your connection and try again.")
            scheduleErrorDismissal()
            return
        }

        let tempURL = activeTempAudioURL
        let savedURL = activeSavedAudioURL
        let durationMs = activeDurationMs
        let clientID = activeClientID

        // Invalidate the generation before cancelling. A provider that ignores
        // transport cancellation still cannot commit a late response.
        activeTranscriptionID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pendingMicrophoneStart = nil
        clearActiveTranscriptionResources()
        stopTranscriptionTimer()
        recordingDuration = 0
        recordingURL = nil

        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        if let savedURL {
            DictationStore.shared.addFailed(
                audioURL: savedURL,
                durationMs: durationMs,
                clientId: clientID
            )
        }

        state = .error("Request timed out. The recording was kept so you can retry it.")
        scheduleErrorDismissal()
    }

    private func clearActiveTranscriptionResources() {
        activeTempAudioURL = nil
        activeSavedAudioURL = nil
        activeDurationMs = nil
        activeClientID = nil
        activePasteTarget = nil
        activeContextApplicationName = nil
    }

    /// Cancels in-flight private work and removes audio that has not yet been
    /// committed to local history. Used by explicit history deletion and a
    /// normal application shutdown so neither path can be undone by a late
    /// provider response.
    func discardActiveWork() {
        stopRecordingTimer()
        VisualAnnotationOverlay.shared.end()
        visualCaptureTasks = []
        stopTranscriptionTimer()
        stopUndoTimer()
        clearPendingClipboardConfirmation()
        deliveryNoticeTimer?.invalidate()
        deliveryNoticeTimer = nil

        activeTranscriptionID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pendingMicrophoneStart = nil

        var uncommittedAudio = Set<URL>()
        [recordingURL, activeTempAudioURL, activeSavedAudioURL,
         pendingCancelURL, pendingCancelSavedURL].forEach { url in
            if let url { uncommittedAudio.insert(url) }
        }
        if recordingURL != nil, let stoppedURL = recorder.stopRecording() {
            uncommittedAudio.insert(stoppedURL)
        }
        for url in uncommittedAudio {
            try? FileManager.default.removeItem(at: url)
        }

        recordingURL = nil
        clearActiveTranscriptionResources()
        pendingCancelURL = nil
        pendingCancelSavedURL = nil
        pendingCancelDurationMs = nil
        pendingCancelClientID = nil
        pendingCancelPasteTarget = nil
        pendingCancelContextApplicationName = nil
        pendingCancelCapturesTargetOnUndo = false
        lastResult = nil
        recordingDuration = 0
        undoCountdown = 0
        state = .idle
    }

    private static func frontmostApplicationTarget() -> UniversalActionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return UniversalActionTarget(
            bundleIdentifier: application.bundleIdentifier ?? "",
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "the original app"
        )
    }

    private func scheduleErrorDismissal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .error = self.state {
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - Sound

    private func playSubtleSound() {
        guard AppSettings.shared.dictationSoundEffectsEnabled else { return }
        // Use Tink for a subtle click when starting recording
        if let sound = NSSound(named: "Tink") {
            sound.volume = 0.3
            sound.play()
        }
    }

    private func playStopSound() {
        guard AppSettings.shared.dictationSoundEffectsEnabled else { return }
        // Use Pop for a satisfying "sent" sound when stopping recording
        if let sound = NSSound(named: "Pop") {
            sound.volume = 0.4
            sound.play()
        }
    }

    private func playSuccessSound() {
        guard AppSettings.shared.dictationSoundEffectsEnabled else { return }
        // Use Glass for a satisfying completion sound when text is pasted
        if let sound = NSSound(named: "Glass") {
            sound.volume = 0.3
            sound.play()
        }
    }

    /// Save audio to permanent location for history/retry
    private func saveAudioForHistory(tempURL: URL) -> URL? {
        guard let dir = DictationStore.shared.userDictationsDirectory else { return nil }

        // Create directory if needed
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileExtension = tempURL.pathExtension.isEmpty ? "m4a" : tempURL.pathExtension.lowercased()
        let filename = "dictation_\(UUID().uuidString).\(fileExtension)"
        let destURL = dir.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return destURL
        } catch {
            print("[Dictation] Failed to save audio for history: \(error)")
            return nil
        }
    }
}
