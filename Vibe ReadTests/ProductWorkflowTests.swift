import AppKit
import Foundation
import Testing
@testable import Vibe_Read

struct ProductWorkflowTests {
    @Test @MainActor func matchingPasteTargetRestoresThePreviousClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Previous clipboard", forType: .string)
        let target = UniversalActionTarget(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            applicationName: "Editor"
        )
        var posted = false

        let outcome = AccessibilityService.deliverTextPreservingClipboard(
            "Finished dictation",
            expectedTarget: target,
            pasteboard: pasteboard,
            hasAccessibilityPermission: true,
            currentTarget: { target },
            postPasteShortcut: {
                posted = true
                return true
            },
            scheduleRestore: { restore in restore() }
        )

        #expect(outcome == .pasted)
        #expect(posted)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
    }

    @Test @MainActor func changedPasteTargetLeavesClipboardUntouched() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Previous clipboard", forType: .string)
        let slack = UniversalActionTarget(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            processIdentifier: 42,
            applicationName: "Slack"
        )
        let codex = UniversalActionTarget(
            bundleIdentifier: "com.openai.codex",
            processIdentifier: 84,
            applicationName: "Codex"
        )
        var posted = false

        let outcome = AccessibilityService.deliverTextPreservingClipboard(
            "Recoverable dictation",
            expectedTarget: slack,
            pasteboard: pasteboard,
            hasAccessibilityPermission: true,
            currentTarget: { codex },
            postPasteShortcut: {
                posted = true
                return true
            },
            scheduleRestore: { restore in restore() }
        )

        #expect(outcome == .failed(.targetChanged))
        #expect(!posted)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
    }

    @Test @MainActor func deniedAccessibilityLeavesClipboardUntouched() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Previous clipboard", forType: .string)
        let target = UniversalActionTarget(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            applicationName: "Editor"
        )
        var posted = false

        let outcome = AccessibilityService.deliverTextPreservingClipboard(
            "Recoverable dictation",
            expectedTarget: target,
            pasteboard: pasteboard,
            hasAccessibilityPermission: false,
            currentTarget: { target },
            postPasteShortcut: {
                posted = true
                return true
            },
            scheduleRestore: { restore in restore() }
        )

        #expect(outcome == .failed(.accessibilityDenied))
        #expect(!posted)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
    }

    @Test @MainActor func explicitActionPasteRestoresThePreviousClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Previous clipboard", forType: .string)
        let target = UniversalActionTarget(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            applicationName: "Editor"
        )
        var posted = false

        let outcome = AccessibilityService.deliverTextPreservingClipboard(
            "Explicit action output",
            expectedTarget: target,
            pasteboard: pasteboard,
            hasAccessibilityPermission: true,
            currentTarget: { target },
            postPasteShortcut: {
                posted = true
                return true
            },
            scheduleRestore: { restore in restore() }
        )

        #expect(outcome == .pasted)
        #expect(posted)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
    }

    @Test @MainActor func emptyClipboardCanAcceptFallbackWithoutAPrompt() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let observation = AccessibilityService.clipboardObservation(pasteboard: pasteboard)

        #expect(!observation.hasContent)
        #expect(
            AccessibilityService.replaceClipboardIfUnchanged(
                "Fallback dictation",
                expectedChangeCount: observation.changeCount,
                pasteboard: pasteboard
            ) == .copied
        )
        #expect(pasteboard.string(forType: .string) == "Fallback dictation")
    }

    @Test @MainActor func staleClipboardConfirmationCannotOverwriteNewerContent() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        let observation = AccessibilityService.clipboardObservation(pasteboard: pasteboard)
        #expect(observation.hasContent)

        pasteboard.clearContents()
        pasteboard.setString("Newer clipboard", forType: .string)
        #expect(
            AccessibilityService.replaceClipboardIfUnchanged(
                "Fallback dictation",
                expectedChangeCount: observation.changeCount,
                pasteboard: pasteboard
            ) == .changed
        )
        #expect(pasteboard.string(forType: .string) == "Newer clipboard")
    }

    @Test @MainActor func delayedRestoreDoesNotClobberANewerClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        let target = UniversalActionTarget(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            applicationName: "Editor"
        )
        var delayedRestore: (() -> Void)?

        let outcome = AccessibilityService.deliverTextPreservingClipboard(
            "Finished dictation",
            expectedTarget: target,
            pasteboard: pasteboard,
            hasAccessibilityPermission: true,
            currentTarget: { target },
            postPasteShortcut: { true },
            scheduleRestore: { delayedRestore = $0 }
        )
        #expect(outcome == .pasted)
        #expect(pasteboard.string(forType: .string) == "Finished dictation")

        pasteboard.clearContents()
        pasteboard.setString("Newer clipboard", forType: .string)
        delayedRestore?()
        #expect(pasteboard.string(forType: .string) == "Newer clipboard")
    }

    @Test @MainActor func targetIsRecheckedAfterClipboardSnapshot() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Previous clipboard", forType: .string)
        let slack = UniversalActionTarget(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            processIdentifier: 42,
            applicationName: "Slack"
        )
        let codex = UniversalActionTarget(
            bundleIdentifier: "com.openai.codex",
            processIdentifier: 84,
            applicationName: "Codex"
        )
        var targetChecks = 0
        var posted = false

        let outcome = AccessibilityService.deliverTextPreservingClipboard(
            "Finished dictation",
            expectedTarget: slack,
            pasteboard: pasteboard,
            hasAccessibilityPermission: true,
            currentTarget: {
                targetChecks += 1
                return targetChecks == 1 ? slack : codex
            },
            postPasteShortcut: {
                posted = true
                return true
            },
            scheduleRestore: { restore in restore() }
        )

        #expect(outcome == .failed(.targetChanged))
        #expect(!posted)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
    }

    @Test func elevenLabsTTSUsesDirectCurrentContract() async throws {
        let capture = ProductRequestCapture()
        let client = ElevenLabsTTSClient { request in
            await capture.record(request)
            return (
                Data("synthetic-mp3".utf8),
                try productResponse(for: request, status: 200, contentType: "audio/mpeg")
            )
        }
        let settings = ElevenLabsVoiceSettings(
            stability: 0.4,
            similarityBoost: 0.8,
            style: 0.2,
            useSpeakerBoost: true,
            speed: 1.1
        )
        let output = try await client.synthesize(
            text: "Read this",
            voiceID: "voice-123",
            modelID: "eleven_multilingual_v2",
            settings: settings,
            apiKey: "synthetic-secret"
        )
        #expect(output == Data("synthetic-mp3".utf8))
        let capturedRequest = await capture.lastRequest
        let request = try #require(capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/text-to-speech/voice-123")
        #expect(request.url?.query == "output_format=mp3_44100_128")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["text"] as? String == "Read this")
        #expect(json["model_id"] as? String == "eleven_multilingual_v2")
        let voice = try #require(json["voice_settings"] as? [String: Any])
        #expect(voice["stability"] as? Double == 0.4)
        #expect(voice["similarity_boost"] as? Double == 0.8)
        #expect(voice["use_speaker_boost"] as? Bool == true)
        #expect(!String(data: body, encoding: .utf8)!.contains("synthetic-secret"))
    }

    @Test func elevenLabsVoicesAreExplicitlyLoadedAndSorted() async throws {
        let capture = ProductRequestCapture()
        let client = ElevenLabsTTSClient { request in
            await capture.record(request)
            let data = Data(#"{"voices":[{"voice_id":"z","name":"Zoey","labels":{}},{"voice_id":"a","name":"Adam","labels":{"accent":"American"}}]}"#.utf8)
            return (data, try productResponse(for: request, status: 200))
        }
        let voices = try await client.listVoices(apiKey: "voice-key")
        #expect(voices.map(\.name) == ["Adam", "Zoey"])
        let capturedRequest = await capture.lastRequest
        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/v2/voices")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "voice-key")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "page_size", value: "100")))
        #expect(query.contains(URLQueryItem(name: "include_total_count", value: "false")))
    }

    @Test func elevenLabsVoiceListPaginatesAndDeduplicates() async throws {
        let capture = ProductRequestCapture()
        let client = ElevenLabsTTSClient { request in
            await capture.record(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let token = query.first(where: { $0.name == "next_page_token" })?.value
            let body: String
            if token == "page two" {
                body = #"{"voices":[{"voice_id":"a","name":"Adam"},{"voice_id":"b","name":"Bella","labels":{"accent":"British"}}],"has_more":false}"#
            } else {
                body = #"{"voices":[{"voice_id":"a","name":"Adam","labels":{}}],"has_more":true,"next_page_token":"page two"}"#
            }
            return (Data(body.utf8), try productResponse(for: request, status: 200))
        }

        let voices = try await client.listVoices(apiKey: "voice-key")
        #expect(voices.map(\.name) == ["Adam", "Bella"])
        #expect(voices.first?.labels.isEmpty == true)
        #expect(voices.last?.detail == "British")
        let requests = await capture.requests
        #expect(requests.count == 2)
        #expect(requests[1].url?.absoluteString.contains("next_page_token=page%20two") == true)
    }

    @Test func elevenLabsVoiceSearchCoversMetadataWithoutCaseSensitivity() {
        let voice = ElevenLabsVoice(
            voiceID: "voice-a",
            name: "Maya",
            category: "premade",
            description: "Warm narration",
            labels: ["accent": "Danish", "use_case": "Audiobook"]
        )
        #expect(voice.matches(searchTerm: "maya"))
        #expect(voice.matches(searchTerm: "DANISH"))
        #expect(voice.matches(searchTerm: "narration"))
        #expect(voice.matches(searchTerm: "audio"))
        #expect(!voice.matches(searchTerm: "French"))
    }

    @Test func elevenLabsVoiceRefreshReconcilesSelections() {
        let adam = ElevenLabsVoice(voiceID: "voice-a", name: "Adam")
        let bella = ElevenLabsVoice(voiceID: "voice-b", name: "Bella")
        let voices = [adam, bella]

        #expect(
            InstantTTSService.reconciledVoice(
                selectedVoiceID: "voice-b",
                availableVoices: voices
            ) == bella
        )
        #expect(
            InstantTTSService.reconciledVoice(
                selectedVoiceID: "stale-account-voice",
                availableVoices: voices
            ) == adam
        )
        #expect(
            InstantTTSService.reconciledVoice(
                selectedVoiceID: "voice-a",
                availableVoices: []
            ) == nil
        )
    }

    @Test @MainActor func cancellingPlaybackCancelsAnActivePrefetch() async {
        let prefetchProbe = ProductCancellationProbe()
        let playbackProbe = ProductCancellationProbe()
        let prefetchedTask = Task<Data, Error> {
            await prefetchProbe.markStarted()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return Data("should-not-complete".utf8)
            } catch {
                await prefetchProbe.markCancelled()
                throw error
            }
        }
        let playbackTask = Task { @MainActor in
            try await InstantTTSService.finishCurrentChunkAndAwaitPrefetch(
                prefetchedTask
            ) {
                await playbackProbe.markStarted()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }

        for _ in 0..<200 {
            if await prefetchProbe.didStart, await playbackProbe.didStart { break }
            await Task.yield()
        }
        #expect(await prefetchProbe.didStart)
        #expect(await playbackProbe.didStart)

        playbackTask.cancel()
        _ = try? await playbackTask.value
        for _ in 0..<200 {
            if await prefetchProbe.didCancel { break }
            await Task.yield()
        }
        #expect(await prefetchProbe.didCancel)
    }

    @Test func elevenLabsRejectsEmptyPreviewBeforeTransport() async throws {
        let capture = ProductRequestCapture()
        let client = ElevenLabsTTSClient { request in
            await capture.record(request)
            return (
                Data("unexpected".utf8),
                try productResponse(for: request, status: 200, contentType: "audio/mpeg")
            )
        }
        let settings = ElevenLabsVoiceSettings(
            stability: 0.5,
            similarityBoost: 0.75,
            style: 0,
            useSpeakerBoost: true,
            speed: 1
        )

        await #expect(throws: ElevenLabsTTSError.emptyText) {
            try await client.synthesize(
                text: "   \n",
                voiceID: "voice-a",
                modelID: "eleven_flash_v2_5",
                settings: settings,
                apiKey: "voice-key"
            )
        }
        #expect(await capture.requests.isEmpty)
    }

    @Test func longReadAloudTextSplitsAtHumanBoundaries() {
        let text = "First sentence. Second sentence is longer. Third sentence ends here."
        let chunks = InstantTTSService.splitIntoChunks(text, maximumCharacters: 28)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 28 })
        #expect(chunks.joined(separator: " ").contains("First sentence"))
        #expect(chunks.joined(separator: " ").contains("Third sentence"))
    }

    @Test func copiedURLsAreClassifiedWithoutBrowserAutomation() throws {
        let wiki = try #require(ContentExtractionService.normalizedWebURL(
            from: " https://en.wikipedia.org/wiki/Swift_(programming_language)#History "
        ))
        #expect(wiki.fragment == nil)
        #expect(ContentExtractionService.kind(for: wiki) == .wikipedia)

        let youtube = try #require(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=4"))
        #expect(ContentExtractionService.kind(for: youtube) == .youtube)
        #expect(ContentExtractionService.youtubeVideoID(from: youtube) == "dQw4w9WgXcQ")
        #expect(ContentExtractionService.normalizedWebURL(from: "file:///etc/passwd") == nil)
        #expect(ContentExtractionService.normalizedWebURL(from: "not a URL") == nil)
    }

    @Test func articleExtractionRemovesPageChromeAndKeepsReadableText() async throws {
        let html = """
        <html><head><title>A useful page</title><style>bad css</style></head>
        <body><nav>Navigation noise</nav><article><h1>A useful page</h1>
        <p>This is the first useful paragraph with enough text to be extracted safely.</p>
        <p>This is a second useful paragraph that makes the article longer and readable.</p>
        <script>privateTracker()</script></article></body></html>
        """
        let service = ContentExtractionService { request in
            (Data(html.utf8), try productResponse(for: request, status: 200, contentType: "text/html"))
        }
        let url = try #require(URL(string: "https://example.com/article"))
        let extracted = try await service.extract(url)
        #expect(extracted.kind == .article)
        #expect(extracted.title == "A useful page")
        #expect(extracted.text?.contains("first useful paragraph") == true)
        #expect(extracted.text?.contains("Navigation noise") == false)
        #expect(extracted.text?.contains("privateTracker") == false)
    }

    @Test @MainActor func localLibraryPersistsWithoutAnAccountOrServer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeReadLibraryTests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LocalLibraryStore(fileURL: file)
        let saved = try #require(store.saveText(
            "A local note worth keeping for later.",
            title: "Local note"
        ))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(saved.kind == .selection)

        let reloaded = LocalLibraryStore(fileURL: file)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items.first?.title == "Local note")
        #expect(reloaded.items.first?.text == "A local note worth keeping for later.")
    }
}

private actor ProductRequestCapture {
    private(set) var requests: [URLRequest] = []
    var lastRequest: URLRequest? { requests.last }
    func record(_ request: URLRequest) { requests.append(request) }
}

private actor ProductCancellationProbe {
    private(set) var didStart = false
    private(set) var didCancel = false

    func markStarted() { didStart = true }
    func markCancelled() { didCancel = true }
}

private func productResponse(
    for request: URLRequest,
    status: Int,
    contentType: String = "application/json"
) throws -> HTTPURLResponse {
    guard let url = request.url else { throw ProductTestFailure.missingURL }
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": contentType]
    ) else { throw ProductTestFailure.invalidResponse }
    return response
}

struct PasteShortcutTests {
    @Test func remoteDesktopPasteWrapsVInRealCommandKeyEvents() throws {
        let events = try #require(AccessibilityService.shortcutEvents(
            keyCode: 9,
            modifiers: .maskCommand,
            pressModifierKey: true
        ))

        #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 9, 9, 55])
        #expect(events[0].flags.contains(.maskCommand))
        #expect(events[1].flags.contains(.maskCommand))
        #expect(events[2].flags.contains(.maskCommand))
        #expect(!events[3].flags.contains(.maskCommand))
        #expect(AccessibilityService.remoteDesktopBundleIdentifiers.contains("tv.parsec.www"))
    }

    @Test func localPasteStaysASingleCommandV() throws {
        let events = try #require(AccessibilityService.shortcutEvents(
            keyCode: 9,
            modifiers: .maskCommand,
            pressModifierKey: false
        ))

        #expect(events.map(\.type) == [.keyDown, .keyUp])
        #expect(events.allSatisfy { $0.flags.contains(.maskCommand) })
    }
}

private enum ProductTestFailure: Error {
    case missingURL
    case invalidResponse
}
