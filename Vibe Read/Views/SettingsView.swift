import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case providers = "Providers"
        case readAloud = "Read Aloud"
        case shortcuts = "Shortcuts"
        case storage = "Local Data"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gear"
            case .providers: return "key"
            case .readAloud: return "speaker.wave.2"
            case .shortcuts: return "keyboard"
            case .storage: return "internaldrive"
            case .about: return "info.circle"
            }
        }
    }

    init(startsOnProvider: Bool = false) {
        _tab = State(initialValue: startsOnProvider ? .providers : .general)
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("Settings")
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(tab.rawValue).font(.title2.bold())
                    Spacer()
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)

                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .general:
                            LocalGeneralSettings {
                                tab = .providers
                            }
                        case .providers: ProviderConfigurationSettingsView()
                        case .readAloud: LocalReadAloudSettings()
                        case .shortcuts: LocalShortcutSettings()
                        case .storage: LocalDataSettingsView()
                        case .about: LocalAboutSettings()
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(width: 880, height: 700)
        .onAppear {
            if AIProviderSettings.shared.needsDictationSetup {
                tab = .providers
            }
        }
    }
}

private struct LocalGeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var accessibility = AccessibilityService.shared
    @ObservedObject private var providers = AIProviderSettings.shared
    let onOpenProviders: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: "Permissions") {
                Label(
                    accessibility.hasAccessibilityPermission
                        ? "Accessibility access granted"
                        : "Selected text, function-key shortcuts, and pasting need Accessibility",
                    systemImage: accessibility.hasAccessibilityPermission
                        ? "checkmark.circle.fill"
                        : "accessibility"
                )
                .foregroundColor(accessibility.hasAccessibilityPermission ? .green : .secondary)

                Label(
                    accessibility.hasScreenRecordingPermission
                        ? "Screen Recording access granted"
                        : "Marking the screen with Ctrl while dictating needs Screen Recording",
                    systemImage: accessibility.hasScreenRecordingPermission
                        ? "checkmark.circle.fill"
                        : "rectangle.dashed"
                )
                .foregroundColor(accessibility.hasScreenRecordingPermission ? .green : .secondary)

                if !accessibility.hasAccessibilityPermission || !accessibility.hasScreenRecordingPermission {
                    HStack {
                        Button("Request Access") {
                            accessibility.requestMissingPermissions()
                        }
                        Button("Open System Settings") {
                            if accessibility.hasAccessibilityPermission {
                                accessibility.openScreenRecordingSettings()
                            } else {
                                accessibility.openAccessibilitySettings()
                            }
                        }
                        Button("Check Again") {
                            accessibility.refreshAllPermissions()
                        }
                        .disabled(accessibility.isPollingForPermission)
                    }
                }

                Text("Choose Request Access once, then turn on Vibe Read in the macOS prompts. Accessibility is required for Fn shortcuts and pasting into other apps; ordinary shortcuts such as Cmd + E work without it. Screen Recording is only used to screenshot areas you mark with Ctrl during dictation, and macOS may ask you to reopen Vibe Read after granting it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsSection(title: "Dictation") {
                Toggle("Paste after dictation", isOn: $settings.autoPasteAfterDictation)
                Toggle("Sound effects", isOn: $settings.dictationSoundEffectsEnabled)
            }

            SettingsSection(title: "Smart Dictation") {
                Text("Normal Fn dictation stays fast and stops after speech-to-text. Use Smart Dictation when you want spoken instructions turned into finished text.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Label(
                        smartDictationIsReady
                            ? "Ready with \(providers.textActionProvider.displayName)"
                            : "Text provider not configured",
                        systemImage: smartDictationIsReady
                            ? "checkmark.circle.fill"
                            : "circle.dashed"
                    )
                    .foregroundColor(smartDictationIsReady ? .green : .secondary)

                    Spacer()

                    Text(settings.primaryShortcut(for: .smartDictation)?.displayString ?? "Not set")
                        .font(.system(.body, design: .monospaced))
                }

                if !smartDictationIsReady {
                    Button("Set Up Text Provider", action: onOpenProviders)
                }

                DisclosureGroup("Edit Smart Dictation instructions") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The raw transcript, these instructions, and the sanitized name of the original app are sent only when you use Smart Dictation.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextEditor(text: $settings.smartDictationPrompt)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 132)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12))
                            }

                        HStack {
                            Spacer()
                            Button("Restore Default Instructions") {
                                settings.smartDictationPrompt = AppSettings.defaultSmartDictationPrompt
                            }
                            .disabled(
                                settings.smartDictationPrompt == AppSettings.defaultSmartDictationPrompt
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }

            SettingsSection(title: "Appearance") {
                Picker("Theme", selection: $settings.themeMode) {
                    Text("System").tag(ThemeMode.system)
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var smartDictationIsReady: Bool {
        let hasModel = !providers.selectedTextActionModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return hasModel
            && (providers.hasTextAPIKey || providers.textProviderAllowsEmptyAPIKey)
    }
}

private struct LocalReadAloudSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var tts = InstantTTSService.shared
    @AppStorage("readAloud.elevenLabs.previewPhrase") private var previewPhrase =
        "Hello. This is how I sound when reading for you."
    @State private var voiceSearch = ""
    private let voices = InstantTTSService.availableVoices
    private let maximumPreviewCharacters = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: "Voice") {
                Picker("Provider", selection: $settings.readAloudProvider) {
                    ForEach(ReadAloudProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                if settings.readAloudProvider == .elevenLabs {
                    Picker("Model", selection: $settings.elevenLabsTTSModel) {
                        Text("Multilingual v2 · stable long-form").tag("eleven_multilingual_v2")
                        Text("Flash v2.5 · fastest and lower cost").tag("eleven_flash_v2_5")
                        Text("Eleven v3 · most expressive").tag("eleven_v3")
                    }

                    selectedElevenLabsVoice

                    HStack(spacing: 10) {
                        Button {
                            tts.refreshElevenLabsVoices()
                        } label: {
                            Label(
                                tts.elevenLabsVoices.isEmpty ? "Load Voices" : "Reload Voices",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(tts.isLoadingVoices)

                        if tts.isLoadingVoices {
                            ProgressView().controlSize(.small)
                            Text("Loading your voices…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if !tts.elevenLabsVoices.isEmpty {
                            Text("\(tts.elevenLabsVoices.count) available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    if let error = tts.voiceLoadingError {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if tts.elevenLabsVoices.isEmpty {
                        Text("Choose Load Voices to browse the voices available to your ElevenLabs account.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        voiceBrowser
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Preview phrase").font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(previewPhrase.count)/\(maximumPreviewCharacters)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        TextEditor(text: $previewPhrase)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(7)
                            .frame(minHeight: 58, maxHeight: 82)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.12))
                            }

                        HStack(spacing: 10) {
                            if tts.isPreviewLoading || tts.isPreviewPlaying {
                                Button {
                                    tts.stopPreview()
                                } label: {
                                    Label("Stop Preview", systemImage: "stop.fill")
                                }
                            } else {
                                Button {
                                    tts.previewVoice(
                                        voiceId: settings.elevenLabsVoiceId,
                                        text: previewPhrase
                                    )
                                } label: {
                                    Label("Preview Voice", systemImage: "play.fill")
                                }
                                .disabled(
                                    settings.elevenLabsVoiceId.isEmpty
                                        || previewPhrase.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty
                                )
                            }

                            if tts.isPreviewLoading {
                                ProgressView().controlSize(.small)
                                Text("Generating preview…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if tts.isPreviewPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(.secondary)
                                Text("Playing \(selectedVoiceName)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }

                    Label(
                        "Previews generate new audio and use ElevenLabs credits. Vibe Read contacts ElevenLabs only when you choose Load Voices, Preview Voice, or Read.",
                        systemImage: "creditcard"
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = tts.error {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Picker("Voice", selection: $settings.preferredVoiceId) {
                        ForEach(voices, id: \.identifier) { voice in
                            Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                        }
                    }
                    if tts.isPreviewPlaying {
                        Button("Stop Preview") { tts.stopPreview() }
                    } else {
                        Button("Preview") {
                            tts.previewVoice(voiceId: settings.preferredVoiceId)
                        }
                    }
                    Text("macOS voices run entirely on this Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            SettingsSection(title: "Playback") {
                HStack {
                    Text("Speed")
                    Slider(value: playbackSpeed, in: playbackSpeedRange, step: 0.05)
                    Text(String(format: "%.2fx", playbackSpeed.wrappedValue)).monospacedDigit()
                }
                if settings.readAloudProvider == .elevenLabs {
                    DisclosureGroup("Voice tuning") {
                        VStack(alignment: .leading, spacing: 10) {
                            voiceSlider("Stability", value: $settings.voiceStability)
                            voiceSlider("Similarity", value: $settings.voiceSimilarityBoost)
                            voiceSlider("Style", value: $settings.voiceStyle)
                            Toggle("Speaker boost", isOn: $settings.voiceSpeakerBoost)
                        }
                        .padding(.top, 8)
                    }
                }
                if settings.readAloudProvider == .macOS, let error = tts.error {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .onAppear {
            if settings.readAloudProvider == .macOS,
               !voices.contains(where: { $0.identifier == settings.preferredVoiceId }),
               let defaultVoice = AVSpeechSynthesisVoice(
                language: Locale.current.language.languageCode?.identifier ?? "en"
               ) ?? voices.first {
                settings.preferredVoiceId = defaultVoice.identifier
            }
        }
        .onChange(of: previewPhrase) { value in
            if value.count > maximumPreviewCharacters {
                previewPhrase = String(value.prefix(maximumPreviewCharacters))
            }
        }
        .onChange(of: settings.readAloudProvider) { _ in
            tts.stopPreview()
        }
        .onDisappear {
            tts.stopPreview()
        }
    }

    private var filteredElevenLabsVoices: [ElevenLabsVoice] {
        tts.elevenLabsVoices.filter { $0.matches(searchTerm: voiceSearch) }
    }

    private var selectedVoice: ElevenLabsVoice? {
        tts.elevenLabsVoices.first { $0.voiceID == settings.elevenLabsVoiceId }
    }

    private var selectedVoiceName: String {
        let savedName = settings.elevenLabsVoiceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedVoice?.name
            ?? (savedName.isEmpty ? "No voice selected" : savedName)
    }

    private var playbackSpeedRange: ClosedRange<Double> {
        settings.readAloudProvider == .elevenLabs ? 0.7...1.2 : 0.6...1.8
    }

    private var playbackSpeed: Binding<Double> {
        Binding(
            get: {
                if settings.readAloudProvider == .elevenLabs {
                    return min(1.2, max(0.7, settings.voiceSpeed))
                }
                return settings.voiceSpeed
            },
            set: { settings.voiceSpeed = $0 }
        )
    }

    private var selectedElevenLabsVoice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedVoiceName).font(.headline)
                Text(
                    selectedVoice?.detail
                        ?? (settings.elevenLabsVoiceId.isEmpty
                            ? "Load voices to choose one"
                            : "Saved ElevenLabs voice")
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("Selected")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.1))
        }
    }

    private var voiceBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search by name, accent, or use", text: $voiceSearch)
                    .textFieldStyle(.plain)
                if !voiceSearch.isEmpty {
                    Button {
                        voiceSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12))
            }

            if filteredElevenLabsVoices.isEmpty {
                Text("No voices match \"\(voiceSearch)\".")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredElevenLabsVoices) { voice in
                            Button {
                                if tts.previewingVoiceId != nil {
                                    tts.stopPreview()
                                }
                                settings.elevenLabsVoiceId = voice.voiceID
                                settings.elevenLabsVoiceName = voice.name
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(
                                        systemName: voice.voiceID == settings.elevenLabsVoiceId
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundColor(
                                        voice.voiceID == settings.elevenLabsVoiceId
                                            ? .primary
                                            : .secondary
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(voice.name)
                                            .font(.body.weight(.medium))
                                            .foregroundColor(.primary)
                                        Text(voice.detail)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    voice.voiceID == settings.elevenLabsVoiceId
                                        ? Color.primary.opacity(0.055)
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .frame(height: min(238, CGFloat(max(1, filteredElevenLabsVoices.count)) * 57))
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.1))
                }
            }
        }
    }

    private func voiceSlider(_ name: String, value: Binding<Double>) -> some View {
        HStack {
            Text(name).frame(width: 72, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 34)
        }
    }
}

private struct LocalShortcutSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var shortcutService = KeyboardShortcutService.shared
    @State private var editingAction: ShortcutAction?
    @State private var editingShortcutID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("All shortcuts are stored locally. Cmd+E is an ordinary action and can be rebound here.")
                .foregroundColor(.secondary)

            ForEach(shortcutService.shortcutRegistrationFailures.keys.sorted(), id: \.self) { action in
                if let message = shortcutService.shortcutRegistrationFailures[action] {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.displayName).font(.headline)
                        Text(action.description).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(settings.primaryShortcut(for: action)?.displayString ?? "Not set")
                        .font(.system(.body, design: .monospaced))
                    Button("Change") {
                        editingAction = action
                        editingShortcutID = settings.primaryShortcut(for: action)?.id
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button("Reset Shortcuts") { settings.resetShortcutsToDefault() }
        }
        .sheet(item: $editingAction) { action in
            ShortcutEditorSheet(action: action, existingShortcutId: editingShortcutID)
                .environmentObject(settings)
                .dismissableSheet()
        }
    }
}

private struct LocalDataSettingsView: View {
    @ObservedObject private var store = DictationStore.shared
    @ObservedObject private var library = LocalLibraryStore.shared
    @State private var confirmingClearHistory = false
    @State private var confirmingClearAudio = false
    @State private var confirmingClearLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: "Audio retention") {
                Picker("Delete recordings", selection: Binding(
                    get: { store.audioRetention },
                    set: { store.audioRetention = $0 }
                )) {
                    ForEach(DictationStore.AudioRetention.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Text(audioRetentionExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsSection(title: "Storage") {
                Button("Open Dictations Folder") {
                    if let url = DictationStore.dictationsDirectory { NSWorkspace.shared.open(url) }
                }
                Button("Delete All Audio…", role: .destructive) { confirmingClearAudio = true }
                Button("Delete All History and Audio…", role: .destructive) { confirmingClearHistory = true }
            }

            SettingsSection(title: "Library") {
                Text("\(library.items.count) saved item\(library.items.count == 1 ? "" : "s")")
                    .foregroundColor(.secondary)
                Button("Open Library Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LocalLibraryStore.defaultFileURL])
                }
                Button("Delete Saved Library…", role: .destructive) {
                    confirmingClearLibrary = true
                }
                .disabled(library.items.isEmpty)
            }

            Label("Dictation history and your Library are stored in Application Support/VibeRead. Nothing is synced.", systemImage: "internaldrive")
                .font(.caption)
                .foregroundColor(.secondary)

            if let persistenceError = store.persistenceError {
                Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Delete all retained audio?", isPresented: $confirmingClearAudio) {
            Button("Delete Audio", role: .destructive) { store.deleteAllAudio() }
        }
        .confirmationDialog("Delete all dictation history and audio?", isPresented: $confirmingClearHistory) {
            Button("Delete Everything", role: .destructive) { store.clearAll() }
        }
        .confirmationDialog("Delete every saved Library item?", isPresented: $confirmingClearLibrary) {
            Button("Delete Library", role: .destructive) { library.removeAll() }
        }
    }

    private var audioRetentionExplanation: String {
        switch store.audioRetention {
        case .immediately:
            return "Audio is deleted as soon as its history row is saved. Failed recordings cannot be retried. Transcripts remain until you delete them."
        case .oneDay:
            return "Audio is kept for one day so failed recordings can be retried. Transcripts remain until you delete them."
        case .sevenDays:
            return "Audio is kept for seven days by default so failed recordings can be retried. Transcripts remain until you delete them."
        case .thirtyDays:
            return "Audio is kept for thirty days so failed recordings can be retried. Transcripts remain until you delete them."
        case .never:
            return "Audio and transcripts remain on this Mac until you delete them."
        }
    }
}

private struct LocalAboutSettings: View {
    private let sourceURL = URL(string: "https://github.com/mathias-heide/VibeRead")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
    }

    private var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable().frame(width: 64, height: 64)
            Text("Vibe Read").font(.title.bold())
            Text(build.map { "Version \(version) (\($0))" } ?? "Version \(version)")
                .foregroundColor(.secondary)
            Text("A small, local-first macOS app for dictation, read-aloud, and rebindable text actions. No accounts, subscriptions, analytics, or Vibe Read cloud.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Vibe Read never checks for updates in the background. Open-source builds are updated by pulling the repository and rebuilding locally.")
                .font(.caption)
                .foregroundColor(.secondary)
            Link("Source & Updates", destination: sourceURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
