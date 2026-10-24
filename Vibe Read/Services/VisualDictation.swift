import AppKit
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.viberead.app", category: "ScreenMarks")

/// Screen marks during dictation: one recording and one transcription, so talking while
/// drawing never splits a sentence. Word timings place every screenshot at
/// the point in the text where it was marked.
enum VisualDictation {
    enum Part: Equatable {
        case text(String)
        case image(index: Int)
    }

    // MARK: - Placement

    /// Splits the transcript into `anchors.count + 1` pieces, one cut per
    /// screenshot. Anchors are the moments the user finished each mark. A mark
    /// finished in a pause goes into that pause. Otherwise the image goes to the
    /// nearest word gap, preferring a comma or full stop within
    /// `punctuationReach` seconds so it does not split a phrase.
    static func segmentTexts(
        transcript: String,
        words: [TimedWord],
        anchors: [TimeInterval],
        punctuationReach: TimeInterval = 0.7
    ) -> [String] {
        let text = transcript as NSString
        let gaps = wordGaps(in: text, words: words)
        guard !gaps.isEmpty else { return [transcript] + Array(repeating: "", count: anchors.count) }

        var positions: [Int] = []
        var minimumGap = 0
        for anchor in anchors {
            // Seconds between the anchor and the silence a gap spans.
            func distance(_ index: Int) -> TimeInterval {
                let gap = gaps[index]
                if anchor < gap.previousWordEnd { return gap.previousWordEnd - anchor }
                if anchor > gap.nextWordStart { return anchor - gap.nextWordStart }
                return 0
            }
            let candidates = gaps.indices.filter { $0 >= minimumGap }
            let nearest = candidates.min { distance($0) < distance($1) } ?? gaps.count - 1
            let gap = gaps[nearest]
            // Marking in silence: the image goes exactly there.
            let isPause = distance(nearest) == 0
                && gap.nextWordStart - gap.previousWordEnd >= 0.35
            let punctuated = candidates
                .filter { gaps[$0].isPunctuated && distance($0) <= punctuationReach }
                .min { distance($0) < distance($1) }
            let chosen = isPause ? nearest : (punctuated ?? nearest)
            positions.append(gaps[chosen].position)
            minimumGap = chosen
        }

        var pieces: [String] = []
        var previous = 0
        for position in positions + [text.length] {
            pieces.append(text.substring(with: NSRange(location: previous, length: position - previous)))
            previous = position
        }
        return pieces
    }

    /// Positions between words with their timing. Gap 0 is before the first
    /// word and the last gap is the end of the transcript.
    private struct Gap {
        let position: Int
        let previousWordEnd: TimeInterval
        let nextWordStart: TimeInterval
        let isPunctuated: Bool
    }

    private static func wordGaps(in text: NSString, words: [TimedWord]) -> [Gap] {
        // Find each timed word in the punctuated transcript. Providers return
        // words with or without punctuation, so attached punctuation is absorbed.
        var aligned: [(end: Int, start: TimeInterval, finish: TimeInterval)] = []
        var cursor = 0
        for word in words {
            let token = word.text.trimmingCharacters(in: .punctuationCharacters)
            guard !token.isEmpty, cursor < text.length else { continue }
            let range = text.range(
                of: token,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: cursor, length: text.length - cursor)
            )
            // A word that is missing or far away is skipped rather than
            // letting one mismatch derail the rest of the alignment.
            guard range.location != NSNotFound, range.location - cursor < 80 else { continue }
            var end = range.location + range.length
            while end < text.length,
                  let scalar = UnicodeScalar(text.character(at: end)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                end += 1
            }
            aligned.append((end, word.start, word.end))
            cursor = end
        }
        guard let first = aligned.first else { return [] }

        var gaps = [Gap(position: 0, previousWordEnd: -.infinity, nextWordStart: first.start, isPunctuated: false)]
        for index in aligned.indices {
            let isLast = index == aligned.count - 1
            let position = aligned[index].end
            let lastCharacter = position > 0 ? text.substring(with: NSRange(location: position - 1, length: 1)) : ""
            gaps.append(Gap(
                position: position,
                previousWordEnd: aligned[index].finish,
                nextWordStart: isLast ? .infinity : aligned[index + 1].start,
                isPunctuated: isLast || [".", ",", "?", "!", ";", ":", "…", "。", "，", "？", "！"].contains(lastCharacter)
            ))
        }
        return gaps
    }

    /// Spreads words evenly over the recording, weighted by length, for
    /// providers that return no word timings.
    static func estimatedWords(transcript: String, duration: TimeInterval) -> [TimedWord] {
        let tokens = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        let totalCharacters = max(1, tokens.reduce(0) { $0 + $1.count + 1 })
        var elapsed = 0
        return tokens.map { token in
            let start = duration * Double(elapsed) / Double(totalCharacters)
            elapsed += token.count + 1
            let end = duration * Double(elapsed - 1) / Double(totalCharacters)
            return TimedWord(text: token, start: start, end: end)
        }
    }

    static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: - Composition

    /// Interleaves transcribed segments with screenshots: text, image 1, text,
    /// image 2, text. Empty text segments are dropped.
    static func parts(segmentTexts: [String], imageCount: Int) -> [Part] {
        var parts: [Part] = []
        for index in 0..<max(segmentTexts.count, imageCount + 1) {
            if index < segmentTexts.count {
                let text = segmentTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(.text(text)) }
            }
            if index < imageCount { parts.append(.image(index: index)) }
        }
        return parts
    }

    /// Plain-text form for history and the clipboard fallback.
    static func plainText(parts: [Part], imageLabel: (Int) -> String) -> String {
        parts.map { part in
            switch part {
            case .text(let text): return text
            case .image(let index): return imageLabel(index)
            }
        }.joined(separator: " ")
    }

    /// Screenshots are kept briefly in the temporary directory so the
    /// clipboard fallback can reference them by path. Older ones are removed.
    static func saveCaptures(_ captures: [VisualCapture]) -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeRead", isDirectory: true)
            .appendingPathComponent("VisualCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for url in existing {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        return captures.enumerated().compactMap { index, capture in
            let url = directory.appendingPathComponent("vibe_\(stamp)_\(index + 1).png")
            do {
                try capture.pngData.write(to: url)
                return url
            } catch {
                return nil
            }
        }
    }

    // MARK: - Delivery

    /// Terminal apps (Claude Code, Codex CLI) take image pastes on Ctrl+V and
    /// still save and insert the image after reading the clipboard.
    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper"
    ]

    /// Pastes text and screenshots one after another into the target app,
    /// then restores the user's clipboard. Returns false if the target app
    /// lost focus or Accessibility is missing before anything was pasted, so
    /// the caller can fall back to the clipboard.
    @MainActor
    static func deliver(
        parts: [Part],
        captures: [VisualCapture],
        target: UniversalActionTarget,
        shouldContinue: () -> Bool
    ) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let isTerminal = terminalBundleIdentifiers.contains(target.bundleIdentifier)
        let isRemote = AccessibilityService.remoteDesktopBundleIdentifiers.contains(target.bundleIdentifier)
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
        }

        for (position, part) in parts.enumerated() {
            guard shouldContinue(), isFrontmost(target) else { return position > 0 }
            let started = CACurrentMediaTime()
            let provider: LazyPasteboardData
            var settle: TimeInterval
            switch part {
            case .text(let text):
                // Spaces keep words from touching the image placeholders.
                let leading = position > 0 ? " " : ""
                let trailing = position < parts.count - 1 ? " " : ""
                provider = LazyPasteboardData(text: leading + text + trailing)
                settle = 0.06
            case .image(let index):
                guard captures.indices.contains(index) else { continue }
                provider = LazyPasteboardData(png: captures[index].pngData)
                settle = isTerminal ? 0.5 : 0.15
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([provider.item])
            if isRemote {
                // Remote desktop apps need real Command key events and time to
                // sync the clipboard to the remote side before and after Cmd+V.
                try? await Task.sleep(nanoseconds: 250_000_000)
                _ = await Task.detached {
                    AccessibilityService.postShortcut(keyCode: 9, modifiers: .maskCommand, pressModifierKey: true)
                }.value
                settle = 1.0
            } else {
                postPaste(control: isTerminal && provider.isImage)
            }
            // Move on as soon as the app has read the clipboard, plus a short
            // pause for it to insert the content. Apps that never read the
            // data lazily fall back to the timeout.
            let deadline = started + 1.5
            while provider.firstReadAt == nil && CACurrentMediaTime() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            let readAfter = provider.firstReadAt.map { String(format: "%.0f ms", ($0 - started) * 1000) } ?? "timeout"
            log.notice("Pasted \(provider.isImage ? "image" : "text", privacy: .public), read after \(readAfter, privacy: .public), step took \(Int((CACurrentMediaTime() - started) * 1000), privacy: .public) ms")
        }
        return true
    }

    /// Supplies clipboard data only when an app asks for it, which tells us
    /// exactly when the paste was read instead of guessing with a fixed delay.
    @MainActor
    private final class LazyPasteboardData: NSObject, NSPasteboardItemDataProvider {
        let item = NSPasteboardItem()
        let isImage: Bool
        private(set) var firstReadAt: TimeInterval?
        private let text: String?
        private let png: Data?

        init(text: String) {
            self.text = text
            png = nil
            isImage = false
            super.init()
            item.setDataProvider(self, forTypes: [.string])
        }

        init(png: Data) {
            text = nil
            self.png = png
            isImage = true
            super.init()
            item.setDataProvider(self, forTypes: [.png, .tiff])
        }

        nonisolated func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            MainActor.assumeIsolated {
                if firstReadAt == nil { firstReadAt = CACurrentMediaTime() }
                switch type {
                case .string:
                    if let text { item.setString(text, forType: .string) }
                case .png:
                    if let png { item.setData(png, forType: .png) }
                case .tiff:
                    if let png, let tiff = NSImage(data: png)?.tiffRepresentation {
                        item.setData(tiff, forType: .tiff)
                    }
                default:
                    break
                }
            }
        }
    }

    private static func isFrontmost(_ target: UniversalActionTarget) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication else { return false }
        return application.processIdentifier == target.processIdentifier
    }

    private static func postPaste(control: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        let flags: CGEventFlags = control ? .maskControl : .maskCommand
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
