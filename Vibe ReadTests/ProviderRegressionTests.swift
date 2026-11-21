import Foundation
import Testing
@testable import Vibe_Read

struct ProviderRegressionTests {
    @Test func networkFailureUsesLocalTranscription() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let service = APIService(
            transport: { _ in throw URLError(.timedOut) },
            localFallback: { _ in "Local recovery" },
            dictationConfiguration: { .elevenLabs(.init(apiKey: "test", languageCode: nil)) }
        )
        let result = try await service.transcribeDictation(audioURL: fixture.audioURL)
        #expect(result.rawTranscript == "Local recovery")
    }

    @Test func elevenLabsUsesNativeScribeV2ContractWithoutLeakingOtherSecrets() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                return .init(data: Data(#"{"text":"  Synthetic transcript.  "}"#.utf8), statusCode: 200)
            },
            dictationConfiguration: {
                .elevenLabs(.init(apiKey: "eleven-secret", languageCode: "da"))
            },
            textActionConfiguration: {
                .openRouter(.init(apiKey: "unrelated-text-secret", model: "synthetic/text"))
            }
        )

        let result = try await service.transcribeDictation(
            audioURL: fixture.audioURL,
            vocabulary: ["private-vocabulary"]
        )
        let recordedRequest = await capture.lastRequest
        let request = try #require(recordedRequest)
        #expect(request.url == APIService.elevenLabsSpeechToTextURL)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "eleven-secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == APIService.transcriptionTimeout)

        let multipart = try multipartBody(request)
        #expect(multipart.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        #expect(multipart.contains("name=\"language_code\"\r\n\r\nda\r\n"))
        #expect(multipart.contains("name=\"tag_audio_events\"\r\n\r\nfalse\r\n"))
        #expect(multipart.contains("name=\"timestamps_granularity\"\r\n\r\nnone\r\n"))
        #expect(multipart.contains("filename=\"dictation.m4a\""))
        #expect(multipart.contains("synthetic-audio-payload"))
        #expect(!multipart.contains("private-vocabulary"))
        #expect(!multipart.contains("eleven-secret"))
        #expect(!multipart.contains("unrelated-text-secret"))
        #expect(result == .init(rawTranscript: "Synthetic transcript.", polishedText: "Synthetic transcript.", durationMs: nil))
    }

    @Test func groqUsesMultipartSpeechEndpointModelLanguageAndBoundedVocabulary() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                return .init(data: Data(#"{"text":"Groq transcript"}"#.utf8), statusCode: 200)
            },
            dictationConfiguration: {
                .groq(
                    .init(
                        apiKey: "groq-secret",
                        model: "whisper-large-v3-turbo",
                        languageCode: "en"
                    )
                )
            },
            textActionConfiguration: {
                .groq(.init(apiKey: "groq-secret", model: "openai/gpt-oss-20b"))
            }
        )

        _ = try await service.transcribeDictation(
            audioURL: fixture.audioURL,
            vocabulary: ["VibeRead", "VibeRead", "Summer\nEngine"]
        )
        let recordedRequest = await capture.lastRequest
        let request = try #require(recordedRequest)
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer groq-secret")
        let multipart = try multipartBody(request)
        #expect(multipart.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"))
        #expect(multipart.contains("name=\"language\"\r\n\r\nen\r\n"))
        #expect(multipart.contains("name=\"prompt\"\r\n\r\nVibeRead, Summer Engine\r\n"))
        #expect(!multipart.contains("groq-secret"))
    }

    @Test func openRouterUsesOfficialJSONBase64TranscriptionContract() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                return .init(data: Data(#"{"text":"OpenRouter transcript"}"#.utf8), statusCode: 200)
            },
            dictationConfiguration: {
                .openRouter(
                    .init(
                        apiKey: "router-secret",
                        model: "openai/gpt-4o-transcribe",
                        languageCode: nil
                    )
                )
            },
            textActionConfiguration: {
                .openRouter(.init(apiKey: "router-secret", model: "openai/gpt-5.6-luna"))
            }
        )

        _ = try await service.transcribeDictation(audioURL: fixture.audioURL)
        let recordedRequest = await capture.lastRequest
        let request = try #require(recordedRequest)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer router-secret")
        let requestBody = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        #expect(object["model"] as? String == "openai/gpt-4o-transcribe")
        #expect(object["temperature"] as? Double == 0)
        #expect(object["language"] == nil)
        let input = try #require(object["input_audio"] as? [String: Any])
        #expect(input["format"] as? String == "m4a")
        let encodedAudio = try #require(input["data"] as? String)
        #expect(Data(base64Encoded: encodedAudio) == Data("synthetic-audio-payload".utf8))
        #expect(!String(decoding: requestBody, as: UTF8.self).contains("router-secret"))
    }

    @Test func openAIGPTTranscribeUsesLanguagesAndKeywordsContract() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                return .init(data: Data(#"{"text":"OpenAI transcript"}"#.utf8), statusCode: 200)
            },
            dictationConfiguration: {
                .openAI(.init(apiKey: "openai-secret", model: "gpt-transcribe", languageCode: "da"))
            },
            textActionConfiguration: {
                .openAI(.init(apiKey: "openai-secret", model: "gpt-5.6-luna"))
            }
        )

        _ = try await service.transcribeDictation(
            audioURL: fixture.audioURL,
            vocabulary: ["VibeRead", "Mathias"]
        )
        let recordedRequest = await capture.lastRequest
        let request = try #require(recordedRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        let multipart = try multipartBody(request)
        #expect(multipart.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        #expect(multipart.contains("name=\"languages[]\"\r\n\r\nda\r\n"))
        #expect(multipart.contains("name=\"keywords[]\"\r\n\r\nVibeRead\r\n"))
        #expect(multipart.contains("name=\"keywords[]\"\r\n\r\nMathias\r\n"))
    }

    @Test func successfulSpeechSurvivesTextCleanupFailure() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        let counter = RequestCounter()
        let service = APIService(
            transport: { _ in
                let index = await counter.increment()
                if index == 1 {
                    return .init(data: Data(#"{"text":"Never lose these words"}"#.utf8), statusCode: 200)
                }
                return .init(
                    data: Data(#"{"error":{"message":"Synthetic cleanup outage"}}"#.utf8),
                    statusCode: 503
                )
            },
            dictationConfiguration: {
                .elevenLabs(.init(apiKey: "eleven-secret", languageCode: nil))
            },
            textActionConfiguration: {
                .openRouter(.init(apiKey: "router-secret", model: "openai/gpt-5.6-luna"))
            }
        )

        let result = try await service.transcribeDictation(
            audioURL: fixture.audioURL,
            transformPrompt: "Clean this up"
        )
        #expect(result.rawTranscript == "Never lose these words")
        #expect(result.polishedText == "Never lose these words")
        #expect(result.warning?.contains("text cleanup failed") == true)
        #expect(result.warning?.contains("Synthetic cleanup outage") == true)
    }

    @Test func missingKeyFailsBeforeTransportAndDoesNotExposeSecret() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                return .init(data: Data(), statusCode: 200)
            },
            dictationConfiguration: {
                .groq(.init(apiKey: "", model: "whisper-large-v3-turbo", languageCode: nil))
            },
            textActionConfiguration: {
                .groq(.init(apiKey: "", model: "openai/gpt-oss-20b"))
            }
        )

        do {
            _ = try await service.transcribeDictation(audioURL: fixture.audioURL)
            Issue.record("Expected missing-key failure")
        } catch let error as APIService.APIError {
            guard case .missingAPIKey(.groq) = error else {
                Issue.record("Expected Groq missing-key error, got \(error)")
                return
            }
        }
        let recordedRequest = await capture.lastRequest
        #expect(recordedRequest == nil)
    }

    @Test func oversizedAudioAndHeaderInjectionFailBeforeTransport() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let capture = RequestCapture()

        #expect(APIService.maximumAudioFileBytes == 25_000_000)

        let oversizedHandle = try FileHandle(forWritingTo: fixture.audioURL)
        try oversizedHandle.truncate(atOffset: UInt64(APIService.maximumAudioFileBytes + 1))
        try oversizedHandle.close()
        let oversizedService = APIService(
            transport: { request in
                await capture.record(request)
                return .init(data: Data(), statusCode: 200)
            },
            dictationConfiguration: {
                .groq(.init(apiKey: "safe-key", model: "whisper-large-v3-turbo", languageCode: nil))
            },
            textActionConfiguration: {
                .groq(.init(apiKey: "safe-key", model: "openai/gpt-oss-20b"))
            }
        )
        do {
            _ = try await oversizedService.transcribeDictation(audioURL: fixture.audioURL)
            Issue.record("Expected an audio-size failure")
        } catch let error as APIService.APIError {
            guard case .audioFileTooLarge(maximumMegabytes: 25) = error else {
                Issue.record("Expected 25 MB audio limit, got \(error)")
                return
            }
        }
        let requestAfterOversizedAudio = await capture.lastRequest
        #expect(requestAfterOversizedAudio == nil)

        let smallAudioURL = fixture.root.appendingPathComponent("small.m4a")
        try Data("small-audio".utf8).write(to: smallAudioURL)
        let unsafeKeyService = APIService(
            transport: { request in
                await capture.record(request)
                return .init(data: Data(), statusCode: 200)
            },
            dictationConfiguration: {
                .groq(
                    .init(
                        apiKey: "key\r\nInjected: value",
                        model: "whisper-large-v3-turbo",
                        languageCode: nil
                    )
                )
            },
            textActionConfiguration: {
                .groq(.init(apiKey: "safe-key", model: "openai/gpt-oss-20b"))
            }
        )
        do {
            _ = try await unsafeKeyService.transcribeDictation(audioURL: smallAudioURL)
            Issue.record("Expected an unsafe-key failure")
        } catch let error as APIService.APIError {
            guard case .invalidConfiguration = error else {
                Issue.record("Expected invalid configuration, got \(error)")
                return
            }
        }
        let requestAfterUnsafeKey = await capture.lastRequest
        #expect(requestAfterUnsafeKey == nil)
    }

    @Test func freshM4AAndWAVAreAcceptedByEveryDictationProvider() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        for fileExtension in ["m4a", "wav"] {
            let audioURL = try fixture.makeAudioURL(fileExtension: fileExtension)
            for providerCase in syntheticDictationProviderCases() {
                let capture = RequestCapture()
                let service = syntheticAPIService(
                    configuration: providerCase.configuration,
                    capture: capture
                )

                let result = try await service.transcribeDictation(audioURL: audioURL)
                let request = await capture.lastRequest
                #expect(request != nil, "\(providerCase.name) must accept .\(fileExtension)")
                #expect(result.rawTranscript == "Synthetic transcript")
            }
        }
    }

    @Test func hostedProvidersRejectLegacyCAFAndAIFFamilyBeforeTransport() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let hostedCases = Array(syntheticDictationProviderCases().prefix(4))

        for fileExtension in ["caf", "aif", "aiff"] {
            let audioURL = try fixture.makeAudioURL(fileExtension: fileExtension)
            for providerCase in hostedCases {
                let capture = RequestCapture()
                let service = syntheticAPIService(
                    configuration: providerCase.configuration,
                    capture: capture
                )

                do {
                    _ = try await service.transcribeDictation(audioURL: audioURL)
                    Issue.record("Expected \(providerCase.name) to reject .\(fileExtension)")
                } catch let error as APIService.APIError {
                    guard case .unsupportedAudioFormat(let provider, let format) = error else {
                        Issue.record("Expected unsupportedAudioFormat, got \(error)")
                        continue
                    }
                    #expect(provider == providerCase.name)
                    #expect(format == fileExtension)
                }
                let request = await capture.lastRequest
                #expect(request == nil)
            }
        }
    }

    @Test func AACIsRejectedByGroqAndOpenAIButAcceptedByOpenRouter() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let audioURL = try fixture.makeAudioURL(fileExtension: "aac")
        let cases = syntheticDictationProviderCases()

        for providerCase in [cases[1], cases[3]] {
            let capture = RequestCapture()
            let service = syntheticAPIService(
                configuration: providerCase.configuration,
                capture: capture
            )
            do {
                _ = try await service.transcribeDictation(audioURL: audioURL)
                Issue.record("Expected \(providerCase.name) to reject .aac")
            } catch let error as APIService.APIError {
                guard case .unsupportedAudioFormat(let provider, let format) = error else {
                    Issue.record("Expected unsupportedAudioFormat, got \(error)")
                    continue
                }
                #expect(provider == providerCase.name)
                #expect(format == "aac")
            }
            let request = await capture.lastRequest
            #expect(request == nil)
        }

        let openRouter = cases[2]
        let acceptedCapture = RequestCapture()
        let acceptedService = syntheticAPIService(
            configuration: openRouter.configuration,
            capture: acceptedCapture
        )
        _ = try await acceptedService.transcribeDictation(audioURL: audioURL)
        let acceptedRequest = await acceptedCapture.lastRequest
        #expect(acceptedRequest != nil)
    }

    @Test func MP4IsRejectedByOpenRouterBeforeTransport() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let audioURL = try fixture.makeAudioURL(fileExtension: "mp4")
        let openRouter = syntheticDictationProviderCases()[2]
        let capture = RequestCapture()
        let service = syntheticAPIService(
            configuration: openRouter.configuration,
            capture: capture
        )

        do {
            _ = try await service.transcribeDictation(audioURL: audioURL)
            Issue.record("Expected OpenRouter to reject .mp4")
        } catch let error as APIService.APIError {
            guard case .unsupportedAudioFormat(let provider, let format) = error else {
                Issue.record("Expected unsupportedAudioFormat, got \(error)")
                return
            }
            #expect(provider == "OpenRouter")
            #expect(format == "mp4")
        }
        let request = await capture.lastRequest
        #expect(request == nil)
    }

    @Test func customProviderRemainsPermissiveForLegacyRetryFormats() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let custom = syntheticDictationProviderCases()[4]

        for fileExtension in ["caf", "aif", "aiff", "aac", "mp4"] {
            let audioURL = try fixture.makeAudioURL(fileExtension: fileExtension)
            let capture = RequestCapture()
            let service = syntheticAPIService(
                configuration: custom.configuration,
                capture: capture
            )

            _ = try await service.transcribeDictation(audioURL: audioURL)
            let request = await capture.lastRequest
            #expect(request != nil, "Custom provider must remain permissive for .\(fileExtension)")
        }
    }

    @Test func draftConnectionTestsUseTransientConfigurationsWithoutUserContent() async throws {
        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                if request.url?.host == "api.groq.com" {
                    return .init(
                        data: Data(#"{"data":[{"id":"whisper-large-v3-turbo"}]}"#.utf8),
                        statusCode: 200
                    )
                }
                return .init(data: Data(#"{"status":"ok"}"#.utf8), statusCode: 200)
            },
            dictationConfiguration: {
                Issue.record("Stored dictation configuration must not be read")
                throw SyntheticError.unexpectedLoader
            },
            textActionConfiguration: {
                Issue.record("Stored text configuration must not be read")
                throw SyntheticError.unexpectedLoader
            }
        )

        let speechResult = try await service.testDictationConnection(
            configuration: .groq(
                .init(
                    apiKey: "transient-groq-key",
                    model: "whisper-large-v3-turbo",
                    languageCode: nil
                )
            )
        )
        let recordedSpeechRequest = await capture.lastRequest
        let speechRequest = try #require(recordedSpeechRequest)
        #expect(speechRequest.url?.absoluteString == "https://api.groq.com/openai/v1/models")
        #expect(speechRequest.httpMethod == "GET")
        #expect(speechRequest.httpBody == nil)
        #expect(speechResult.validation == .credentialEndpointAndModelListing)
        #expect(speechResult.selectedModelWasListed)
        #expect(!speechResult.selectedModelWasExercised)
        #expect(!speechResult.userContentWasUploaded)

        let textResult = try await service.testTextActionConnection(
            configuration: .customOpenAICompatible(
                .init(
                    baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                    apiKey: "",
                    model: "local-model"
                )
            )
        )
        let recordedTextRequest = await capture.lastRequest
        let textRequest = try #require(recordedTextRequest)
        #expect(textRequest.url?.absoluteString == "http://127.0.0.1:11434/v1/models")
        #expect(textRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(textResult.validation == .credentialAndEndpoint)
        #expect(!textResult.selectedModelWasListed)
        #expect(!textResult.selectedModelWasExercised)
        #expect(!textResult.userContentWasUploaded)
    }

    @Test func elevenLabsConnectionVerificationAcceptsAnEndpointWithoutScribeInItsCatalog() async throws {
        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                return .init(
                    data: Data(#"[{"model_id":"eleven_multilingual_v2"}]"#.utf8),
                    statusCode: 200
                )
            },
            dictationConfiguration: {
                .elevenLabs(.init(apiKey: "unused", languageCode: nil))
            },
            textActionConfiguration: {
                .openRouter(.init(apiKey: "unused", model: "unused"))
            }
        )

        let result = try await service.testDictationConnection(
            configuration: .elevenLabs(
                .init(apiKey: "synthetic-eleven-key", languageCode: nil)
            )
        )
        let recordedRequest = await capture.lastRequest
        let request = try #require(recordedRequest)

        #expect(request.url == APIService.elevenLabsModelsURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-eleven-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
        #expect(result.providerName == "ElevenLabs")
        #expect(result.validation == .credentialAndEndpoint)
        #expect(!result.selectedModelWasListed)
        #expect(!result.selectedModelWasExercised)
        #expect(!result.userContentWasUploaded)
    }

    @Test func elevenLabsConnectionVerificationTreats401And403AsUnauthorized() async throws {
        for statusCode in [401, 403] {
            let service = APIService(
                transport: { _ in
                    .init(data: Data(#"{"detail":"synthetic rejection"}"#.utf8), statusCode: statusCode)
                },
                dictationConfiguration: {
                    .elevenLabs(.init(apiKey: "unused", languageCode: nil))
                },
                textActionConfiguration: {
                    .openRouter(.init(apiKey: "unused", model: "unused"))
                }
            )

            do {
                _ = try await service.testDictationConnection(
                    configuration: .elevenLabs(
                        .init(apiKey: "synthetic-eleven-key", languageCode: nil)
                    )
                )
                Issue.record("Expected HTTP \(statusCode) to be unauthorized")
            } catch let error as APIService.APIError {
                guard case .unauthorized(let credential) = error else {
                    Issue.record("Expected unauthorized, got \(error)")
                    continue
                }
                #expect(credential == .elevenLabs)
            }
        }
    }

    @Test func connectionTestRejectsAFirstClassModelTypoEvenWithValidCredentials() async throws {
        let service = APIService(
            transport: { _ in
                .init(
                    data: Data(#"{"data":[{"id":"whisper-large-v3-turbo"}]}"#.utf8),
                    statusCode: 200
                )
            },
            dictationConfiguration: {
                .groq(.init(apiKey: "unused", model: "unused", languageCode: nil))
            },
            textActionConfiguration: {
                .groq(.init(apiKey: "unused", model: "unused"))
            }
        )

        do {
            _ = try await service.testDictationConnection(
                configuration: .groq(
                    .init(
                        apiKey: "valid-synthetic-key",
                        model: "whisper-large-v3-turpo",
                        languageCode: nil
                    )
                )
            )
            Issue.record("Expected the unlisted model to be rejected")
        } catch let error as APIService.APIError {
            guard case .modelNotListed(let provider, let model) = error else {
                Issue.record("Expected modelNotListed, got \(error)")
                return
            }
            #expect(provider == "Groq")
            #expect(model == "whisper-large-v3-turpo")
        }
    }

    @Test func openRouterDictationVerificationUsesTheTranscriptionCatalog() async throws {
        let capture = RequestCapture()
        let service = APIService(
            transport: { request in
                await capture.record(request)
                return .init(
                    data: Data(#"{"data":[{"id":"openai/gpt-4o-transcribe"}]}"#.utf8),
                    statusCode: 200
                )
            },
            dictationConfiguration: {
                .openRouter(
                    .init(
                        apiKey: "unused",
                        model: "openai/gpt-4o-transcribe",
                        languageCode: nil
                    )
                )
            },
            textActionConfiguration: {
                .openRouter(.init(apiKey: "unused", model: "openai/gpt-5.6-luna"))
            }
        )

        let result = try await service.testDictationConnection(
            configuration: .openRouter(
                .init(
                    apiKey: "synthetic-router-key",
                    model: "openai/gpt-4o-transcribe",
                    languageCode: nil
                )
            )
        )
        let recordedRequest = await capture.lastRequest
        let request = try #require(recordedRequest)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )

        #expect(components.path == "/api/v1/models")
        #expect(
            components.queryItems
                == [URLQueryItem(name: "output_modalities", value: "transcription")]
        )
        #expect(result.selectedModelWasListed)
        #expect(!result.userContentWasUploaded)
    }

    @Test func textProvidersUseIndependentChatEndpointsModelsAndCredentials() async throws {
        let cases: [(TextActionProviderConfiguration, String, String, String)] = [
            (
                .groq(.init(apiKey: "groq-text-key", model: "openai/gpt-oss-20b")),
                "https://api.groq.com/openai/v1/chat/completions",
                "Bearer groq-text-key",
                "openai/gpt-oss-20b"
            ),
            (
                .openRouter(.init(apiKey: "router-text-key", model: "openai/gpt-5.6-luna")),
                "https://openrouter.ai/api/v1/chat/completions",
                "Bearer router-text-key",
                "openai/gpt-5.6-luna"
            ),
            (
                .openAI(.init(apiKey: "openai-text-key", model: "gpt-5.6-luna")),
                "https://api.openai.com/v1/chat/completions",
                "Bearer openai-text-key",
                "gpt-5.6-luna"
            ),
            (
                .customOpenAICompatible(
                    .init(
                        baseURL: URL(string: "https://text.example.test/v1")!,
                        apiKey: "custom-text-key",
                        model: "custom-text-model"
                    )
                ),
                "https://text.example.test/v1/chat/completions",
                "Bearer custom-text-key",
                "custom-text-model"
            )
        ]

        for (configuration, expectedURL, expectedAuthorization, expectedModel) in cases {
            let capture = RequestCapture()
            let service = APIService(
                transport: { request in
                    await capture.record(request)
                    return .init(
                        data: Data(#"{"choices":[{"message":{"role":"assistant","content":"Result"}}]}"#.utf8),
                        statusCode: 200
                    )
                },
                dictationConfiguration: {
                    .elevenLabs(.init(apiKey: "unrelated", languageCode: nil))
                },
                textActionConfiguration: { configuration }
            )

            let transformed = try await service.transformText("Input", systemPrompt: "Instruction")
            #expect(transformed == "Result")
            let recordedRequest = await capture.lastRequest
            let request = try #require(recordedRequest)
            #expect(request.url?.absoluteString == expectedURL)
            #expect(request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization)
            let requestBody = try #require(request.httpBody)
            let payload = try #require(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            #expect(payload["model"] as? String == expectedModel)
        }
    }

    @Test func providerErrorsAreDecodedSafelyAndBounded() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }

        let longMessage = "never-echo-this-key " + String(repeating: "x", count: 500)
            + "\nsecret-looking-tail"
        let body = try JSONSerialization.data(withJSONObject: ["error": ["detail": longMessage]])
        let service = APIService(
            transport: { _ in .init(data: body, statusCode: 429) },
            dictationConfiguration: {
                .groq(.init(apiKey: "never-echo-this-key", model: "whisper-large-v3-turbo", languageCode: nil))
            },
            textActionConfiguration: {
                .groq(.init(apiKey: "never-echo-this-key", model: "openai/gpt-oss-20b"))
            }
        )

        do {
            _ = try await service.transcribeDictation(audioURL: fixture.audioURL)
            Issue.record("Expected provider error")
        } catch let error as APIService.APIError {
            guard case .provider(let provider, let status, let message) = error else {
                Issue.record("Expected decoded provider error, got \(error)")
                return
            }
            #expect(provider == "Groq")
            #expect(status == 429)
            #expect(message.count <= 300)
            #expect(!message.contains("\n"))
            #expect(!message.contains("never-echo-this-key"))
            #expect(!error.localizedDescription.contains("never-echo-this-key"))
        }
    }

    @Test @MainActor func initializationStatusRefreshAndReadinessNeverReadSecrets() {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        fixture.secrets.values["elevenlabs_api_key"] = "must-not-be-read"
        fixture.defaults.set(
            true,
            forKey: AIProviderSettings.StorageKey.credentialConfigured(.elevenLabs)
        )

        let settings = fixture.makeSettings()
        #expect(fixture.secrets.reads.isEmpty)
        #expect(!settings.needsDictationSetup)
        #expect(settings.credentialStatus(for: .elevenLabs) == .configured)
        for credential in ProviderCredential.allCases {
            _ = settings.credentialStatus(for: credential)
        }
        settings.refreshCredentialStatuses()
        #expect(fixture.secrets.reads.isEmpty)
    }

    @Test @MainActor func environmentFileStaysTheCredentialSourceWithoutKeychainAccess() throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeReadEnvironmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(".env.local")
        try "ELEVENLABS_API_KEY=first-local-value\n"
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let settings = fixture.makeSettings()
        try settings.useEnvironmentFile(fileURL, for: .elevenLabs)

        #expect(fixture.secrets.reads.isEmpty)
        #expect(fixture.secrets.writes.isEmpty)
        #expect(settings.environmentFileURL(for: .elevenLabs) == fileURL)
        #expect(settings.environmentFileDisplayName(for: .elevenLabs) == ".env.local")
        #expect(!settings.needsDictationSetup)

        guard case .elevenLabs(let first) = try settings.dictationConfiguration() else {
            Issue.record("Expected ElevenLabs configuration")
            return
        }
        #expect(first.apiKey == "first-local-value")
        #expect(fixture.secrets.reads.isEmpty)

        try "ELEVENLABS_API_KEY=updated-local-value\n"
            .write(to: fileURL, atomically: true, encoding: .utf8)
        guard case .elevenLabs(let updated) = try settings.dictationConfiguration() else {
            Issue.record("Expected updated ElevenLabs configuration")
            return
        }
        #expect(updated.apiKey == "updated-local-value")
        #expect(fixture.secrets.reads.isEmpty)
        #expect(fixture.secrets.writes.isEmpty)

        try settings.clearAPIKey(for: .elevenLabs)
        #expect(fixture.secrets.deletes.isEmpty)
        #expect(settings.environmentFileURL(for: .elevenLabs) == nil)
        #expect(settings.needsDictationSetup)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor func unmarkedBlankConfigurationIsMissingWithoutReadingSecrets() {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        fixture.secrets.values["groq_api_key"] = "unmarked-secret"
        let settings = fixture.makeSettings()

        do {
            _ = try settings.dictationConfiguration(
                provider: .groq,
                model: "whisper-large-v3-turbo",
                language: .automatic,
                customBaseURL: "",
                replacementAPIKey: "   "
            )
            Issue.record("Expected an unmarked blank configuration to be missing")
        } catch let error as AIProviderSettings.ConfigurationError {
            #expect(error == .missingAPIKey(.groq))
        } catch {
            Issue.record("Expected missingAPIKey, got \(error)")
        }
        #expect(fixture.secrets.reads.isEmpty)
    }

    @Test @MainActor func transientReplacementBuildsDraftWithoutReadingOrPersistingSecrets() throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        fixture.secrets.values["openai_api_key"] = "unmarked-saved-value"
        let settings = fixture.makeSettings()

        guard case .openAI(let draft) = try settings.textActionConfiguration(
            provider: .openAI,
            model: "gpt-5.6-luna",
            customBaseURL: "",
            replacementAPIKey: " transient-openai-key "
        ) else {
            Issue.record("Expected OpenAI text draft")
            return
        }
        #expect(draft.apiKey == "transient-openai-key")
        #expect(fixture.secrets.reads.isEmpty)
        #expect(fixture.secrets.writes.isEmpty)
        #expect(fixture.secrets.values["openai_api_key"] == "unmarked-saved-value")
    }

    @Test @MainActor func markedConfigurationReadsOnlySelectedAccountOnceAndThenUsesCache() throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        fixture.secrets.values["groq_api_key"] = "saved-groq-key"
        fixture.secrets.values["openai_api_key"] = "unrelated-key"
        fixture.defaults.set(
            true,
            forKey: AIProviderSettings.StorageKey.credentialConfigured(.groq)
        )
        let settings = fixture.makeSettings()

        for _ in 0..<2 {
            guard case .groq(let draft) = try settings.dictationConfiguration(
                provider: .groq,
                model: "whisper-large-v3",
                language: .danish,
                customBaseURL: "",
                replacementAPIKey: ""
            ) else {
                Issue.record("Expected Groq dictation configuration")
                return
            }
            #expect(draft.apiKey == "saved-groq-key")
            #expect(draft.model == "whisper-large-v3")
            #expect(draft.languageCode == "da")
        }
        #expect(fixture.secrets.reads == ["groq_api_key"])
    }

    @Test @MainActor func blankLoopbackConfigurationsNeedNoSecretRead() throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.makeSettings()

        guard case .customOpenAICompatible(let speech) = try settings.dictationConfiguration(
            provider: .customOpenAICompatible,
            model: "local-stt",
            language: .automatic,
            customBaseURL: "http://127.0.0.1:11434/v1",
            replacementAPIKey: ""
        ), case .customOpenAICompatible(let text) = try settings.textActionConfiguration(
            provider: .customOpenAICompatible,
            model: "local-chat",
            customBaseURL: "http://localhost:11434/v1",
            replacementAPIKey: ""
        ) else {
            Issue.record("Expected loopback configurations")
            return
        }
        #expect(speech.apiKey.isEmpty)
        #expect(text.apiKey.isEmpty)
        #expect(fixture.secrets.reads.isEmpty)
    }

    @Test @MainActor func saveSetsMarkerWithoutReadbackAndRemovalClearsItWithoutReading() throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.makeSettings()
        let marker = AIProviderSettings.StorageKey.credentialConfigured(.groq)

        try settings.saveAPIKey(" saved-groq-key ", for: .groq)
        #expect(fixture.secrets.writes.count == 1)
        #expect(fixture.secrets.writes.first?.account == "groq_api_key")
        #expect(fixture.secrets.writes.first?.value == "saved-groq-key")
        #expect(fixture.defaults.bool(forKey: marker))
        #expect(settings.credentialStatus(for: .groq) == .configured)
        #expect(fixture.secrets.reads.isEmpty)

        try settings.clearAPIKey(for: .groq)
        #expect(fixture.secrets.deletes == ["groq_api_key"])
        #expect(!fixture.defaults.bool(forKey: marker))
        #expect(settings.credentialStatus(for: .groq) == .missing)
        #expect(fixture.secrets.reads.isEmpty)
    }

    @Test @MainActor func genericLegacySecretIsNeverReadOrUsedAutomatically() {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("openAICompatible", forKey: "dictationProvider")
        fixture.defaults.set("https://api.groq.com/openai/v1", forKey: "aiProviderBaseURL")
        fixture.defaults.set("whisper-large-v3-turbo", forKey: "aiProviderTranscriptionModel")
        fixture.secrets.values["ai_provider_api_key"] = "legacy-generic-key"

        let settings = fixture.makeSettings()
        #expect(settings.dictationProvider == .groq)
        #expect(settings.credentialStatus(for: .groq) == .missing)
        do {
            _ = try settings.dictationConfiguration()
            Issue.record("Expected legacy generic secret to be ignored")
        } catch let error as AIProviderSettings.ConfigurationError {
            #expect(error == .missingAPIKey(.groq))
        } catch {
            Issue.record("Expected missingAPIKey, got \(error)")
        }
        #expect(fixture.secrets.reads.isEmpty)
        #expect(fixture.secrets.writes.isEmpty)
    }

    @Test @MainActor func previousBuildKeyIsReadOnlyAfterExplicitRecovery() throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        fixture.previousSecrets.values["elevenlabs_api_key"] = "existing-eleven-key"
        let settings = fixture.makeSettings()

        #expect(fixture.previousSecrets.reads.isEmpty)
        try settings.recoverPreviousAPIKey(for: .elevenLabs)

        #expect(fixture.previousSecrets.reads == ["elevenlabs_api_key"])
        #expect(fixture.secrets.writes.count == 1)
        #expect(fixture.secrets.writes.first?.account == "elevenlabs_api_key")
        #expect(fixture.secrets.writes.first?.value == "existing-eleven-key")
        #expect(settings.credentialStatus(for: .elevenLabs) == .configured)
    }

    @Test @MainActor func URLValidationAllowsHTTPSAndLoopbackOnly() throws {
        #expect(
            AIProviderSettings.validatedProviderURL(" HTTPS://API.GROQ.COM/openai/v1/// ")?.absoluteString
                == "https://api.groq.com/openai/v1"
        )
        #expect(
            AIProviderSettings.validatedProviderURL("http://127.0.0.1:11434/v1/")?.absoluteString
                == "http://127.0.0.1:11434/v1"
        )
        #expect(
            AIProviderSettings.validatedProviderURL("http://[::1]:11434/v1")?.absoluteString
                == "http://[::1]:11434/v1"
        )

        for rejected in [
            "", "api.example.com/v1", "http://api.example.com/v1",
            "http://127.0.0.1.example.com/v1", "file://localhost/tmp/provider",
            "https://user:password@api.example.com/v1",
            "https://api.example.com/v1?api_key=secret",
            "https://api.example.com/v1#fragment"
        ] {
            #expect(AIProviderSettings.validatedProviderURL(rejected) == nil)
        }
    }
}

private actor RequestCapture {
    private(set) var lastRequest: URLRequest?

    func record(_ request: URLRequest) {
        lastRequest = request
    }
}

private actor RequestCounter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private enum SyntheticError: Error {
    case unexpectedLoader
}

private struct ProviderFixture {
    let root: URL
    let audioURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeReadProviderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audioURL = root.appendingPathComponent("synthetic.m4a")
        try Data("synthetic-audio-payload".utf8).write(to: audioURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeAudioURL(fileExtension: String) throws -> URL {
        let url = root.appendingPathComponent("synthetic-\(UUID().uuidString).\(fileExtension)")
        try Data("synthetic-audio-payload".utf8).write(to: url)
        return url
    }
}

private struct SyntheticDictationProviderCase {
    let name: String
    let configuration: DictationProviderConfiguration
}

private func syntheticDictationProviderCases() -> [SyntheticDictationProviderCase] {
    [
        .init(
            name: "ElevenLabs",
            configuration: .elevenLabs(.init(apiKey: "synthetic-key", languageCode: nil))
        ),
        .init(
            name: "Groq",
            configuration: .groq(
                .init(
                    apiKey: "synthetic-key",
                    model: "whisper-large-v3-turbo",
                    languageCode: nil
                )
            )
        ),
        .init(
            name: "OpenRouter",
            configuration: .openRouter(
                .init(
                    apiKey: "synthetic-key",
                    model: "openai/gpt-4o-transcribe",
                    languageCode: nil
                )
            )
        ),
        .init(
            name: "OpenAI",
            configuration: .openAI(
                .init(
                    apiKey: "synthetic-key",
                    model: "gpt-transcribe",
                    languageCode: nil
                )
            )
        ),
        .init(
            name: "Custom provider",
            configuration: .customOpenAICompatible(
                .init(
                    baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                    apiKey: "",
                    model: "synthetic-local-model",
                    languageCode: nil
                )
            )
        )
    ]
}

private func syntheticAPIService(
    configuration: DictationProviderConfiguration,
    capture: RequestCapture
) -> APIService {
    APIService(
        transport: { request in
            await capture.record(request)
            return .init(
                data: Data(#"{"text":"Synthetic transcript"}"#.utf8),
                statusCode: 200
            )
        },
        dictationConfiguration: { configuration },
        textActionConfiguration: {
            .openRouter(.init(apiKey: "unused", model: "unused"))
        }
    )
}

private final class SyntheticSecretStore {
    var values: [String: String] = [:]
    var reads: [String] = []
    var writes: [(account: String, value: String)] = []
    var deletes: [String] = []

    func read(_ account: String) throws -> String? {
        reads.append(account)
        return values[account]
    }

    func write(_ value: String, account: String) throws {
        values[account] = value
        writes.append((account, value))
    }

    func delete(_ account: String) throws {
        values.removeValue(forKey: account)
        deletes.append(account)
    }
}

@MainActor
private final class SettingsFixture {
    let suiteName = "VibeReadProviderTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = SyntheticSecretStore()
    let previousSecrets = SyntheticSecretStore()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeSettings() -> AIProviderSettings {
        AIProviderSettings(
            defaults: defaults,
            readSecret: { [secrets] account in try secrets.read(account) },
            readPreviousSecret: { [previousSecrets] account in
                try previousSecrets.read(account)
            },
            writeSecret: { [secrets] value, account in try secrets.write(value, account: account) },
            deleteSecret: { [secrets] account in try secrets.delete(account) }
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func multipartBody(_ request: URLRequest) throws -> String {
    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    return String(decoding: try #require(request.httpBody), as: UTF8.self)
}
