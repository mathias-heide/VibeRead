import Foundation

struct DictationResult: Codable, Equatable, Sendable {
    let rawTranscript: String
    let polishedText: String
    let durationMs: Int?
    let warning: String?

    init(
        rawTranscript: String,
        polishedText: String,
        durationMs: Int?,
        warning: String? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.polishedText = polishedText
        self.durationMs = durationMs
        self.warning = warning
    }
}

/// A word with its position in the recording, in seconds.
struct TimedWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// A transcript plus word timings when the provider returns them.
struct TimedTranscript: Sendable {
    let text: String
    let words: [TimedWord]?
}

struct APITransportResponse: Sendable {
    let data: Data
    let statusCode: Int
}

struct ProviderConnectionTestResult: Equatable, Sendable {
    enum Validation: Equatable, Sendable {
        /// The provider endpoint accepted the credential. The selected model
        /// was deliberately not invoked, so testing stays free of user content.
        case credentialAndEndpoint
        /// The provider's model catalog also contained the selected model.
        /// The model itself was not invoked and no user content was sent.
        case credentialEndpointAndModelListing
    }

    let providerName: String
    let validation: Validation
    let selectedModelWasListed: Bool
    let selectedModelWasExercised: Bool
    let userContentWasUploaded: Bool
    let message: String
}

/// Direct provider clients for independent dictation and Cmd+E configuration.
/// Requests go from the Mac to the selected provider. Vibe Read has no relay.
actor APIService {
    static let shared = APIService()

    static let elevenLabsSpeechToTextURL = URL(
        string: "https://api.elevenlabs.io/v1/speech-to-text"
    )!
    static let elevenLabsModelsURL = URL(string: "https://api.elevenlabs.io/v1/models")!
    static let elevenLabsModelID = AIProviderCatalog.elevenLabsSpeechModel
    static let transcriptionTimeout: TimeInterval = 60
    static let textActionTimeout: TimeInterval = 45
    static let connectionTestTimeout: TimeInterval = 15
    /// A portable ceiling across the supported transcription APIs. It also
    /// prevents accidental unbounded reads before a provider request starts.
    static let maximumAudioFileBytes = 25_000_000
    static let maximumAudioMegabytes = 25

    typealias Transport = @Sendable (URLRequest) async throws -> APITransportResponse
    typealias DictationConfigurationLoader =
        @Sendable () async throws -> DictationProviderConfiguration
    typealias TextActionConfigurationLoader =
        @Sendable () async throws -> TextActionProviderConfiguration

    enum APIError: Error, LocalizedError {
        case network(Error)
        case invalidResponse
        case unauthorized(ProviderCredential)
        case server(provider: String, statusCode: Int)
        case invalidPayload(provider: String)
        case missingAPIKey(ProviderCredential)
        case invalidConfiguration(String)
        case provider(provider: String, statusCode: Int, message: String)
        case emptyTranscript(String)
        case modelNotListed(provider: String, model: String)
        case audioFileTooLarge(maximumMegabytes: Int)
        case unsupportedAudioFormat(provider: String, format: String)

        var errorDescription: String? {
            switch self {
            case .network(let error):
                if (error as? URLError)?.code == .timedOut {
                    return "The provider request timed out"
                }
                return "Network error. \(error.localizedDescription)"
            case .invalidResponse:
                return "The provider returned an invalid response"
            case .unauthorized(let credential):
                return "The \(credential.displayName) API key was rejected"
            case .server(let provider, let statusCode):
                return "\(provider) returned HTTP \(statusCode)"
            case .invalidPayload(let provider):
                return "Could not read the response from \(provider)"
            case .missingAPIKey(let credential):
                return "Add your \(credential.displayName) API key in Settings"
            case .invalidConfiguration(let message):
                return message
            case .provider(let provider, _, let message):
                return "\(provider) returned this error. \(message)"
            case .emptyTranscript(let provider):
                return "\(provider) returned no transcript"
            case .modelNotListed(let provider, _):
                return "The selected model is not listed by \(provider)"
            case .audioFileTooLarge(let maximumMegabytes):
                return "The recording exceeds the \(maximumMegabytes) MB upload limit"
            case .unsupportedAudioFormat(let provider, let format):
                return "\(provider) cannot retry .\(format) audio. Use a WAV or M4A recording."
            }
        }
    }

    private let transport: Transport
    private let loadDictationConfiguration: DictationConfigurationLoader
    private let loadTextActionConfiguration: TextActionConfigurationLoader

    init(
        transport: Transport? = nil,
        dictationConfiguration: @escaping DictationConfigurationLoader = {
            try await MainActor.run { try AIProviderSettings.shared.dictationConfiguration() }
        },
        textActionConfiguration: @escaping TextActionConfigurationLoader = {
            try await MainActor.run { try AIProviderSettings.shared.textActionConfiguration() }
        }
    ) {
        self.transport = transport ?? Self.makeDefaultTransport()
        loadDictationConfiguration = dictationConfiguration
        loadTextActionConfiguration = textActionConfiguration
    }

    func transcribeDictation(
        audioURL: URL,
        vocabulary: [String] = [],
        transformPrompt: String? = nil,
        clientId: String? = nil
    ) async throws -> DictationResult {
        _ = clientId // Retained for compatibility with migrated local history.

        let raw = try await transcribeAudio(
            audioURL: audioURL,
            vocabulary: vocabulary,
            wordTimings: false
        ).text

        guard let transformPrompt = Self.nonempty(transformPrompt) else {
            return DictationResult(rawTranscript: raw, polishedText: raw, durationMs: nil)
        }

        do {
            let polished = try await transformText(raw, systemPrompt: transformPrompt)
            return DictationResult(rawTranscript: raw, polishedText: polished, durationMs: nil)
        } catch {
            // Speech recognition already succeeded. A missing text key or a
            // cleanup outage must never discard the user's words.
            return DictationResult(
                rawTranscript: raw,
                polishedText: raw,
                durationMs: nil,
                warning: Self.cleanupWarning(for: error)
            )
        }
    }

    /// Draw and Dictate needs to know when each word was spoken. ElevenLabs,
    /// Groq, and OpenAI whisper-1 return word timings; other providers return
    /// plain text and the caller estimates positions instead.
    func transcribeWithWordTimings(
        audioURL: URL,
        vocabulary: [String] = []
    ) async throws -> TimedTranscript {
        try await transcribeAudio(audioURL: audioURL, vocabulary: vocabulary, wordTimings: true)
    }

    private func transcribeAudio(
        audioURL: URL,
        vocabulary: [String],
        wordTimings: Bool
    ) async throws -> TimedTranscript {
        if let fileSize = try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > Self.maximumAudioFileBytes {
            throw APIError.audioFileTooLarge(
                maximumMegabytes: Self.maximumAudioMegabytes
            )
        }
        let audio = try Data(contentsOf: audioURL)
        guard audio.count <= Self.maximumAudioFileBytes else {
            throw APIError.audioFileTooLarge(
                maximumMegabytes: Self.maximumAudioMegabytes
            )
        }
        let fileExtension = Self.normalizedAudioExtension(audioURL.pathExtension)
        let configuration = try await loadDictationConfiguration()
        try Self.validateAudioFormat(fileExtension, for: configuration)

        switch configuration {
        case .elevenLabs(let elevenLabs):
            return try await transcribeWithElevenLabs(
                audio: audio,
                fileExtension: fileExtension,
                configuration: elevenLabs,
                wordTimings: wordTimings
            )
        case .groq(let groq):
            return try await transcribeWithGroq(
                audio: audio,
                fileExtension: fileExtension,
                vocabulary: vocabulary,
                configuration: groq,
                wordTimings: wordTimings
            )
        case .openRouter(let openRouter):
            return try await transcribeWithOpenRouter(
                audio: audio,
                fileExtension: fileExtension,
                configuration: openRouter
            )
        case .openAI(let openAI):
            return try await transcribeWithOpenAI(
                audio: audio,
                fileExtension: fileExtension,
                vocabulary: vocabulary,
                configuration: openAI,
                wordTimings: wordTimings
            )
        case .customOpenAICompatible(let custom):
            return try await transcribeWithCustomProvider(
                audio: audio,
                fileExtension: fileExtension,
                vocabulary: vocabulary,
                configuration: custom
            )
        }
    }

    func transformText(_ text: String, systemPrompt: String) async throws -> String {
        let configuration = try await loadTextActionConfiguration()
        let endpoint = try textEndpoint(for: configuration)

        let payload = ChatRequest(
            model: endpoint.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text)
            ],
            temperature: 0.2
        )
        var request = URLRequest(
            url: endpoint.baseURL.appendingPathComponent("chat/completions"),
            timeoutInterval: Self.textActionTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addBearerAuthorization(endpoint.apiKey, to: &request)

        let data = try await send(
            request,
            providerName: endpoint.providerName,
            credential: endpoint.credential
        )
        let response: ChatResponse
        do {
            response = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw APIError.invalidPayload(provider: endpoint.providerName)
        }
        guard let output = response.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            throw APIError.provider(
                provider: endpoint.providerName,
                statusCode: 200,
                message: "The text action returned no text"
            )
        }
        return output
    }

    @discardableResult
    func testDictationConnection() async throws -> ProviderConnectionTestResult {
        let configuration = try await loadDictationConfiguration()
        return try await testDictationConnection(configuration: configuration)
    }

    /// Tests an unsaved Settings draft, including a transient key, without
    /// activating or persisting any of it.
    @discardableResult
    func testDictationConnection(
        configuration: DictationProviderConfiguration
    ) async throws -> ProviderConnectionTestResult {
        let request = try connectionRequest(for: configuration)
        let data = try await send(
            request.request,
            providerName: request.providerName,
            credential: request.credential
        )
        return try connectionTestResult(
            data: data,
            providerName: request.providerName,
            selectedModel: request.selectedModel,
            userContentDescription: "audio"
        )
    }

    @discardableResult
    func testTextActionConnection() async throws -> ProviderConnectionTestResult {
        let configuration = try await loadTextActionConfiguration()
        return try await testTextActionConnection(configuration: configuration)
    }

    /// Tests an unsaved Settings draft, including a transient key, without
    /// activating or persisting any of it.
    @discardableResult
    func testTextActionConnection(
        configuration: TextActionProviderConfiguration
    ) async throws -> ProviderConnectionTestResult {
        let endpoint = try textEndpoint(for: configuration)
        var request = URLRequest(
            url: endpoint.baseURL.appendingPathComponent("models"),
            timeoutInterval: Self.connectionTestTimeout
        )
        request.httpMethod = "GET"
        addBearerAuthorization(endpoint.apiKey, to: &request)
        let data = try await send(
            request,
            providerName: endpoint.providerName,
            credential: endpoint.credential
        )
        return try connectionTestResult(
            data: data,
            providerName: endpoint.providerName,
            selectedModel: endpoint.model,
            userContentDescription: "text"
        )
    }

    @discardableResult
    func testElevenLabsConnection() async throws -> ProviderConnectionTestResult {
        let configuration = try await loadDictationConfiguration()
        guard case .elevenLabs = configuration else {
            throw APIError.invalidConfiguration("Select ElevenLabs dictation before testing it")
        }
        return try await testDictationConnection(configuration: configuration)
    }

    @discardableResult
    func testOpenAICompatibleConnection() async throws -> ProviderConnectionTestResult {
        try await testTextActionConnection()
    }

    private func transcribeWithElevenLabs(
        audio: Data,
        fileExtension: String,
        configuration: ElevenLabsDictationConfiguration,
        wordTimings: Bool = false
    ) async throws -> TimedTranscript {
        try requireAPIKey(configuration.apiKey, for: .elevenLabs)

        let boundary = UUID().uuidString
        var body = Data()
        appendMultipartField(
            name: "model_id",
            value: Self.elevenLabsModelID,
            boundary: boundary,
            to: &body
        )
        appendMultipartField(
            name: "tag_audio_events",
            value: "false",
            boundary: boundary,
            to: &body
        )
        appendMultipartField(
            name: "timestamps_granularity",
            value: wordTimings ? "word" : "none",
            boundary: boundary,
            to: &body
        )
        if let languageCode = Self.nonempty(configuration.languageCode) {
            appendMultipartField(
                name: "language_code",
                value: languageCode,
                boundary: boundary,
                to: &body
            )
        }
        appendMultipartFile(
            name: "file",
            filename: "dictation.\(fileExtension)",
            contentType: Self.audioContentType(for: fileExtension),
            data: audio,
            boundary: boundary,
            to: &body
        )
        finishMultipart(boundary: boundary, body: &body)

        var request = URLRequest(
            url: Self.elevenLabsSpeechToTextURL,
            timeoutInterval: Self.transcriptionTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")

        let data = try await send(
            request,
            providerName: ProviderCredential.elevenLabs.displayName,
            credential: .elevenLabs
        )
        return try decodeTranscript(from: data, providerName: "ElevenLabs")
    }

    private func transcribeWithGroq(
        audio: Data,
        fileExtension: String,
        vocabulary: [String],
        configuration: GroqDictationConfiguration,
        wordTimings: Bool = false
    ) async throws -> TimedTranscript {
        try requireAPIKey(configuration.apiKey, for: .groq)
        try requireModel(configuration.model, feature: "Groq dictation")

        var fields = openAIMultipartFields(
            model: configuration.model,
            languageField: "language",
            languageCode: configuration.languageCode,
            vocabulary: vocabulary,
            includeKeywords: false
        )
        if wordTimings { Self.requestWordTimestamps(in: &fields) }
        let request = makeMultipartTranscriptionRequest(
            baseURL: AIProviderSettings.groqProviderBaseURL,
            apiKey: configuration.apiKey,
            audio: audio,
            fileExtension: fileExtension,
            fields: fields
        )
        let data = try await send(request, providerName: "Groq", credential: .groq)
        return try decodeTranscript(from: data, providerName: "Groq")
    }

    private func transcribeWithOpenRouter(
        audio: Data,
        fileExtension: String,
        configuration: OpenRouterDictationConfiguration
    ) async throws -> TimedTranscript {
        try requireAPIKey(configuration.apiKey, for: .openRouter)
        try requireModel(configuration.model, feature: "OpenRouter dictation")

        let payload = OpenRouterTranscriptionRequest(
            model: configuration.model,
            inputAudio: .init(data: audio.base64EncodedString(), format: fileExtension),
            language: Self.nonempty(configuration.languageCode),
            temperature: 0
        )
        var request = URLRequest(
            url: AIProviderSettings.openRouterProviderBaseURL
                .appendingPathComponent("audio/transcriptions"),
            timeoutInterval: Self.transcriptionTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addBearerAuthorization(configuration.apiKey, to: &request)

        let data = try await send(request, providerName: "OpenRouter", credential: .openRouter)
        return try decodeTranscript(from: data, providerName: "OpenRouter")
    }

    private func transcribeWithOpenAI(
        audio: Data,
        fileExtension: String,
        vocabulary: [String],
        configuration: OpenAIDictationConfiguration,
        wordTimings: Bool = false
    ) async throws -> TimedTranscript {
        try requireAPIKey(configuration.apiKey, for: .openAI)
        try requireModel(configuration.model, feature: "OpenAI dictation")

        let usesGPTTranscribeContract = configuration.model == "gpt-transcribe"
        var fields = openAIMultipartFields(
            model: configuration.model,
            languageField: usesGPTTranscribeContract ? "languages[]" : "language",
            languageCode: configuration.languageCode,
            vocabulary: vocabulary,
            includeKeywords: usesGPTTranscribeContract
        )
        // Only whisper-1 supports verbose_json with word timestamps.
        if wordTimings && configuration.model == "whisper-1" {
            Self.requestWordTimestamps(in: &fields)
        }
        let request = makeMultipartTranscriptionRequest(
            baseURL: AIProviderSettings.openAIProviderBaseURL,
            apiKey: configuration.apiKey,
            audio: audio,
            fileExtension: fileExtension,
            fields: fields
        )
        let data = try await send(request, providerName: "OpenAI", credential: .openAI)
        return try decodeTranscript(from: data, providerName: "OpenAI")
    }

    private func transcribeWithCustomProvider(
        audio: Data,
        fileExtension: String,
        vocabulary: [String],
        configuration: CustomOpenAICompatibleDictationConfiguration
    ) async throws -> TimedTranscript {
        guard let baseURL = AIProviderSettings.validatedProviderURL(
            configuration.baseURL.absoluteString
        ) else {
            throw APIError.invalidConfiguration("The custom provider URL is not safe")
        }
        if !baseURL.isLoopbackProvider {
            try requireAPIKey(configuration.apiKey, for: .customDictation)
        } else {
            try validateOptionalAPIKey(configuration.apiKey)
        }
        try requireModel(configuration.model, feature: "custom dictation")

        let fields = openAIMultipartFields(
            model: configuration.model,
            languageField: "language",
            languageCode: configuration.languageCode,
            vocabulary: vocabulary,
            includeKeywords: false
        )
        let request = makeMultipartTranscriptionRequest(
            baseURL: baseURL,
            apiKey: configuration.apiKey,
            audio: audio,
            fileExtension: fileExtension,
            fields: fields
        )
        let data = try await send(
            request,
            providerName: "Custom provider",
            credential: .customDictation
        )
        return try decodeTranscript(from: data, providerName: "Custom provider")
    }

    private func openAIMultipartFields(
        model: String,
        languageField: String,
        languageCode: String?,
        vocabulary: [String],
        includeKeywords: Bool
    ) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "json")
        ]
        if let languageCode = Self.nonempty(languageCode) {
            fields.append((languageField, languageCode))
        }
        let terms = Self.normalizedVocabulary(vocabulary)
        if !terms.isEmpty {
            fields.append(("prompt", String(terms.joined(separator: ", ").prefix(800))))
            if includeKeywords {
                fields.append(contentsOf: terms.prefix(100).map { ("keywords[]", $0) })
            }
        }
        return fields
    }

    private static func requestWordTimestamps(in fields: inout [(String, String)]) {
        fields.removeAll { $0.0 == "response_format" }
        fields.append(("response_format", "verbose_json"))
        fields.append(("timestamp_granularities[]", "word"))
    }

    private func makeMultipartTranscriptionRequest(
        baseURL: URL,
        apiKey: String,
        audio: Data,
        fileExtension: String,
        fields: [(String, String)]
    ) -> URLRequest {
        let boundary = UUID().uuidString
        var body = Data()
        appendMultipartFile(
            name: "file",
            filename: "dictation.\(fileExtension)",
            contentType: Self.audioContentType(for: fileExtension),
            data: audio,
            boundary: boundary,
            to: &body
        )
        for (name, value) in fields {
            appendMultipartField(name: name, value: value, boundary: boundary, to: &body)
        }
        finishMultipart(boundary: boundary, body: &body)

        var request = URLRequest(
            url: baseURL.appendingPathComponent("audio/transcriptions"),
            timeoutInterval: Self.transcriptionTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        addBearerAuthorization(apiKey, to: &request)
        return request
    }

    private func decodeTranscript(from data: Data, providerName: String) throws -> TimedTranscript {
        let response: TranscriptionResponse
        do {
            response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            throw APIError.invalidPayload(provider: providerName)
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIError.emptyTranscript(providerName) }
        // ElevenLabs uses `text` and also lists spacing entries; Whisper uses `word`.
        let words = response.words?.compactMap { word -> TimedWord? in
            guard word.type == nil || word.type == "word",
                  let value = (word.text ?? word.word)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let start = word.start,
                  let end = word.end else { return nil }
            return TimedWord(text: value, start: start, end: end)
        }
        return TimedTranscript(text: text, words: words?.isEmpty == false ? words : nil)
    }

    private func connectionRequest(
        for configuration: DictationProviderConfiguration
    ) throws -> ConnectionRequest {
        switch configuration {
        case .elevenLabs(let config):
            try requireAPIKey(config.apiKey, for: .elevenLabs)
            var request = URLRequest(
                url: Self.elevenLabsModelsURL,
                timeoutInterval: Self.connectionTestTimeout
            )
            request.httpMethod = "GET"
            request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
            return .init(
                request: request,
                providerName: "ElevenLabs",
                credential: .elevenLabs,
                selectedModel: nil
            )
        case .groq(let config):
            return try bearerConnectionRequest(
                baseURL: AIProviderSettings.groqProviderBaseURL,
                apiKey: config.apiKey,
                providerName: "Groq",
                credential: .groq,
                selectedModel: config.model
            )
        case .openRouter(let config):
            return try bearerConnectionRequest(
                baseURL: AIProviderSettings.openRouterProviderBaseURL,
                apiKey: config.apiKey,
                providerName: "OpenRouter",
                credential: .openRouter,
                selectedModel: config.model,
                modelQueryItems: [
                    URLQueryItem(name: "output_modalities", value: "transcription")
                ]
            )
        case .openAI(let config):
            return try bearerConnectionRequest(
                baseURL: AIProviderSettings.openAIProviderBaseURL,
                apiKey: config.apiKey,
                providerName: "OpenAI",
                credential: .openAI,
                selectedModel: config.model
            )
        case .customOpenAICompatible(let config):
            guard let baseURL = AIProviderSettings.validatedProviderURL(
                config.baseURL.absoluteString
            ) else {
                throw APIError.invalidConfiguration("The custom provider URL is not safe")
            }
            if !baseURL.isLoopbackProvider {
                try requireAPIKey(config.apiKey, for: .customDictation)
            } else {
                try validateOptionalAPIKey(config.apiKey)
            }
            var request = URLRequest(
                url: baseURL.appendingPathComponent("models"),
                timeoutInterval: Self.connectionTestTimeout
            )
            request.httpMethod = "GET"
            addBearerAuthorization(config.apiKey, to: &request)
            return .init(
                request: request,
                providerName: "Custom provider",
                credential: .customDictation,
                selectedModel: config.model
            )
        }
    }

    private func bearerConnectionRequest(
        baseURL: URL,
        apiKey: String,
        providerName: String,
        credential: ProviderCredential,
        selectedModel: String,
        modelQueryItems: [URLQueryItem] = []
    ) throws -> ConnectionRequest {
        try requireAPIKey(apiKey, for: credential)
        let modelsURL = baseURL.appendingPathComponent("models")
        let requestURL: URL
        if modelQueryItems.isEmpty {
            requestURL = modelsURL
        } else {
            guard var components = URLComponents(
                url: modelsURL,
                resolvingAgainstBaseURL: false
            ) else {
                throw APIError.invalidConfiguration("The provider model-list URL is invalid")
            }
            components.queryItems = modelQueryItems
            guard let filteredURL = components.url else {
                throw APIError.invalidConfiguration("The provider model-list URL is invalid")
            }
            requestURL = filteredURL
        }
        var request = URLRequest(
            url: requestURL,
            timeoutInterval: Self.connectionTestTimeout
        )
        request.httpMethod = "GET"
        addBearerAuthorization(apiKey, to: &request)
        return .init(
            request: request,
            providerName: providerName,
            credential: credential,
            selectedModel: selectedModel
        )
    }

    private func textEndpoint(
        for configuration: TextActionProviderConfiguration
    ) throws -> TextEndpoint {
        switch configuration {
        case .groq(let config):
            try requireAPIKey(config.apiKey, for: .groq)
            try requireModel(config.model, feature: "Groq Cmd+E")
            return .init(
                baseURL: AIProviderSettings.groqProviderBaseURL,
                apiKey: config.apiKey,
                model: config.model,
                providerName: "Groq",
                credential: .groq
            )
        case .openRouter(let config):
            try requireAPIKey(config.apiKey, for: .openRouter)
            try requireModel(config.model, feature: "OpenRouter Cmd+E")
            return .init(
                baseURL: AIProviderSettings.openRouterProviderBaseURL,
                apiKey: config.apiKey,
                model: config.model,
                providerName: "OpenRouter",
                credential: .openRouter
            )
        case .openAI(let config):
            try requireAPIKey(config.apiKey, for: .openAI)
            try requireModel(config.model, feature: "OpenAI Cmd+E")
            return .init(
                baseURL: AIProviderSettings.openAIProviderBaseURL,
                apiKey: config.apiKey,
                model: config.model,
                providerName: "OpenAI",
                credential: .openAI
            )
        case .customOpenAICompatible(let config):
            guard let baseURL = AIProviderSettings.validatedProviderURL(
                config.baseURL.absoluteString
            ) else {
                throw APIError.invalidConfiguration("The custom provider URL is not safe")
            }
            if !baseURL.isLoopbackProvider {
                try requireAPIKey(config.apiKey, for: .customText)
            } else {
                try validateOptionalAPIKey(config.apiKey)
            }
            try requireModel(config.model, feature: "custom Cmd+E")
            return .init(
                baseURL: baseURL,
                apiKey: config.apiKey,
                model: config.model,
                providerName: "Custom provider",
                credential: .customText
            )
        }
    }

    private func requireAPIKey(_ apiKey: String, for credential: ProviderCredential) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.missingAPIKey(credential)
        }
        try validateOptionalAPIKey(apiKey)
    }

    private func validateOptionalAPIKey(_ apiKey: String) throws {
        guard apiKey.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw APIError.invalidConfiguration("The API key contains unsupported characters")
        }
    }

    private func requireModel(_ model: String, feature: String) throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.invalidConfiguration("Choose a model for \(feature)")
        }
    }

    private func addBearerAuthorization(_ apiKey: String, to request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func send(
        _ request: URLRequest,
        providerName: String,
        credential: ProviderCredential
    ) async throws -> Data {
        let response: APITransportResponse
        do {
            response = try await transport(request)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(error)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw APIError.unauthorized(credential)
        }
        guard (200...299).contains(response.statusCode) else {
            if let decodedMessage = Self.providerErrorMessage(from: response.data) {
                let message = Self.redactingRequestSecrets(decodedMessage, from: request)
                throw APIError.provider(
                    provider: providerName,
                    statusCode: response.statusCode,
                    message: message
                )
            }
            throw APIError.server(provider: providerName, statusCode: response.statusCode)
        }
        return response.data
    }

    private func connectionTestResult(
        data: Data,
        providerName: String,
        selectedModel: String?,
        userContentDescription: String
    ) throws -> ProviderConnectionTestResult {
        if let selectedModel,
           let listedModels = Self.listedModelIDs(from: data) {
            guard listedModels.contains(selectedModel) else {
                throw APIError.modelNotListed(provider: providerName, model: selectedModel)
            }
            return ProviderConnectionTestResult(
                providerName: providerName,
                validation: .credentialEndpointAndModelListing,
                selectedModelWasListed: true,
                selectedModelWasExercised: false,
                userContentWasUploaded: false,
                message: "Connection, API key, and selected model listing verified. No \(userContentDescription) was uploaded, so the model was not exercised."
            )
        }

        let catalogNote = selectedModel == nil && providerName == "ElevenLabs"
            ? "The API key was accepted by ElevenLabs' model catalog. Scribe v2 was not invoked."
            : "This endpoint did not return a standard model list."
        return ProviderConnectionTestResult(
            providerName: providerName,
            validation: .credentialAndEndpoint,
            selectedModelWasListed: false,
            selectedModelWasExercised: false,
            userContentWasUploaded: false,
            message: "Connection and API key verified. \(catalogNote) No \(userContentDescription) was uploaded, so the selected model was not exercised."
        )
    }

    /// Accepts the OpenAI-compatible `{ data: [{ id }] }` shape and generic
    /// top-level / `{ models: [...] }` model-list shapes.
    private static func listedModelIDs(from data: Data) -> Set<String>? {
        guard !data.isEmpty, data.count <= 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let list: [Any]
        if let array = object as? [Any] {
            list = array
        } else if let dictionary = object as? [String: Any],
                  let array = dictionary["data"] as? [Any] {
            list = array
        } else if let dictionary = object as? [String: Any],
                  let array = dictionary["models"] as? [Any] {
            list = array
        } else {
            return nil
        }

        return Set(list.compactMap { item in
            guard let dictionary = item as? [String: Any] else { return nil }
            for key in ["id", "model_id", "modelId"] {
                if let id = dictionary[key] as? String, let normalized = nonempty(id) {
                    return normalized
                }
            }
            return nil
        })
    }

    private func appendMultipartField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    private func finishMultipart(boundary: String, body: inout Data) {
        body.append(Data("--\(boundary)--\r\n".utf8))
    }

    private static func makeDefaultTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.transcriptionTimeout
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration)

        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            return APITransportResponse(data: data, statusCode: http.statusCode)
        }
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= 1_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let candidate = findProviderMessage(in: object, depth: 0)
        guard let candidate else { return nil }
        let flattened = candidate
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(300))
    }

    private static func redactingRequestSecrets(
        _ message: String,
        from request: URLRequest
    ) -> String {
        var secrets: [String] = []
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            secrets.append(authorization)
            if authorization.lowercased().hasPrefix("bearer ") {
                secrets.append(String(authorization.dropFirst("bearer ".count)))
            }
        }
        if let elevenLabsKey = request.value(forHTTPHeaderField: "xi-api-key") {
            secrets.append(elevenLabsKey)
        }

        return secrets.reduce(message) { redacted, secret in
            guard !secret.isEmpty else { return redacted }
            return redacted.replacingOccurrences(of: secret, with: "[redacted]")
        }
    }

    private static func findProviderMessage(in value: Any, depth: Int) -> String? {
        guard depth <= 4 else { return nil }
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            for key in ["message", "detail", "error_description", "error"] {
                if let nested = dictionary[key],
                   let message = findProviderMessage(in: nested, depth: depth + 1) {
                    return message
                }
            }
        }
        if let array = value as? [Any] {
            let messages = array.prefix(3).compactMap {
                findProviderMessage(in: $0, depth: depth + 1)
            }
            if !messages.isEmpty { return messages.joined(separator: ". ") }
        }
        return nil
    }

    private static func normalizedAudioExtension(_ value: String) -> String {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 8,
              normalized.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 48 && scalar.value <= 57
                    || scalar.value >= 97 && scalar.value <= 122
              }) else {
            return "m4a"
        }
        return normalized
    }

    private static func validateAudioFormat(
        _ fileExtension: String,
        for configuration: DictationProviderConfiguration
    ) throws {
        let unsupportedLegacyFormats: Set<String> = ["caf", "aif", "aiff"]
        if unsupportedLegacyFormats.contains(fileExtension) {
            let providerName: String
            switch configuration {
            case .elevenLabs: providerName = "ElevenLabs"
            case .groq: providerName = "Groq"
            case .openRouter: providerName = "OpenRouter"
            case .openAI: providerName = "OpenAI"
            case .customOpenAICompatible: return
            }
            throw APIError.unsupportedAudioFormat(
                provider: providerName,
                format: fileExtension
            )
        }

        switch configuration {
        case .groq:
            guard fileExtension != "aac" else {
                throw APIError.unsupportedAudioFormat(provider: "Groq", format: fileExtension)
            }
        case .openAI:
            guard fileExtension != "aac" else {
                throw APIError.unsupportedAudioFormat(provider: "OpenAI", format: fileExtension)
            }
        case .openRouter:
            guard fileExtension != "mp4" else {
                throw APIError.unsupportedAudioFormat(
                    provider: "OpenRouter",
                    format: fileExtension
                )
            }
        case .elevenLabs, .customOpenAICompatible:
            break
        }
    }

    private static func normalizedVocabulary(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let limited = String(normalized.prefix(50))
            guard seen.insert(limited.lowercased()).inserted else { return nil }
            return limited
        }
    }

    private static func cleanupWarning(for error: Error) -> String {
        let detail = error.localizedDescription
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let suffix = detail.isEmpty ? "" : " \(String(detail.prefix(180)))"
        return "The transcript was kept, but text cleanup failed.\(suffix)"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func audioContentType(for fileExtension: String) -> String {
        switch fileExtension {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mp4", "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        default: return "application/octet-stream"
        }
    }
}

private struct ConnectionRequest: Sendable {
    let request: URLRequest
    let providerName: String
    let credential: ProviderCredential
    let selectedModel: String?
}

private struct TextEndpoint: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
    let providerName: String
    let credential: ProviderCredential
}

private struct TranscriptionResponse: Decodable, Sendable {
    struct Word: Decodable, Sendable {
        let text: String?
        let word: String?
        let start: TimeInterval?
        let end: TimeInterval?
        let type: String?
    }

    let text: String
    let words: [Word]?

    enum CodingKeys: String, CodingKey { case text, words }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        // Timings are optional extras; a surprising shape must never cost the transcript.
        words = try? container.decodeIfPresent([Word].self, forKey: .words)
    }
}

private struct OpenRouterTranscriptionRequest: Encodable, Sendable {
    struct InputAudio: Encodable, Sendable {
        let data: String
        let format: String
    }

    let model: String
    let inputAudio: InputAudio
    let language: String?
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
        case language
        case temperature
    }
}

private struct ChatRequest: Encodable, Sendable {
    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct ChatResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        let message: ChatRequest.Message
    }
    let choices: [Choice]
}
