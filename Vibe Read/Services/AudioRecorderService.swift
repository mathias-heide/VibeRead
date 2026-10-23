import AVFoundation
import Foundation
import Combine
import CoreAudio

/// Audio recorder for dictation with device selection support
/// Uses AVCaptureSession for device selection + AVAssetWriter for proper AAC encoding
/// Provides real-time audio level metering for waveform visualization
class AudioRecorderService: NSObject, ObservableObject {
    static let shared = AudioRecorderService()

    @Published var isRecording = false
    @Published var hasPermission = false
    @Published var audioLevel: Float = 0  // 0 to 1, normalized audio level

    private var captureSession: AVCaptureSession?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var currentRecordingURL: URL?
    private var isWriterStarted = false
    /// Host-clock time (CACurrentMediaTime base) of the first recorded sample,
    /// which is time zero in the audio file. Draw and Dictate uses it to line
    /// circles up with provider word timestamps.
    private(set) var firstSampleHostTime: TimeInterval?
    private var sampleCount = 0  // For throttling audio level updates
    private var detectedSampleRate: Double = 44100  // Will be updated from actual device

    private let captureQueue = DispatchQueue(label: "com.viberead.audio.capture")
    private let transientRecordingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeRead", isDirectory: true)
        .appendingPathComponent("Recordings", isDirectory: true)

    override init() {
        super.init()
        // Only check status on init, don't request permission
        updatePermissionStatus()
        cleanupStaleTransientRecordings()
    }

    /// Updates the permission status without triggering a request
    private func updatePermissionStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermission = true
        default:
            hasPermission = false
        }
    }

    /// Check and update permission status (does not request)
    func checkPermission() {
        updatePermissionStatus()
    }

    /// Explicitly request microphone permission - call from onboarding
    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermission = true
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.hasPermission = granted
                    completion(granted)
                }
            }
        default:
            hasPermission = false
            completion(false)
        }
    }

    // MARK: - Device Selection

    /// Gets all available input devices for UI
    func getAvailableInputDevices() -> [AudioDevice] {
        let discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 14.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone],
                mediaType: .audio,
                position: .unspecified
            )
        }

        return discoverySession.devices
            .filter { device in
                let name = device.localizedName.lowercased()
                let isVirtual = name.contains("teams") || name.contains("zoom") ||
                               name.contains("virtual") || name.contains("aggregate")
                return !isVirtual
            }
            .map { AudioDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Gets the preferred input device based on user settings
    private func getPreferredCaptureDevice() -> AVCaptureDevice? {
        let selectedId = AppSettings.shared.selectedMicrophoneId

        let discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 14.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone],
                mediaType: .audio,
                position: .unspecified
            )
        }
        let allDevices = discoverySession.devices

        // If user selected a specific device, try to use it
        if selectedId != "auto" && selectedId != "builtin" && !selectedId.isEmpty {
            if let device = allDevices.first(where: { $0.uniqueID == selectedId }) {
                // Device names and stable hardware IDs can identify the user or
                // their equipment, so they are intentionally not logged.
                print("[AudioRecorder] Using user-selected microphone")
                return device
            }
        }

        // Filter devices
        let builtInMic = allDevices.first { $0.localizedName.lowercased().contains("macbook") }
        let externalDevices = allDevices.filter { device in
            let name = device.localizedName.lowercased()
            let isBuiltIn = name.contains("macbook") || name.contains("built-in")
            let isVirtual = name.contains("teams") || name.contains("zoom") || name.contains("virtual")
            return !isBuiltIn && !isVirtual
        }

        // Auto-detect: prefer external/Bluetooth if connected
        if selectedId == "auto" || selectedId.isEmpty {
            if let external = externalDevices.first {
                print("[AudioRecorder] Auto-detect: using external microphone")
                return external
            }
        }

        // Builtin or fallback
        if let builtIn = builtInMic {
            print("[AudioRecorder] Using built-in microphone")
            return builtIn
        }

        return allDevices.first
    }

    /// Check if a device is likely a Bluetooth device
    private func isBluetoothDevice(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        // Common Bluetooth indicators
        return name.contains("airpods") ||
               name.contains("bluetooth") ||
               name.contains("wireless") ||
               name.contains("bt") ||
               name.contains("headset") ||
               name.contains("headphone") ||
               name.contains("earbuds") ||
               name.contains("buds") ||
               // If it's not built-in and not a USB mic, it's likely Bluetooth
               (!name.contains("macbook") && !name.contains("built-in") && !name.contains("usb"))
    }

    /// Get the native sample rate for a device (helps with Bluetooth)
    private func getNativeSampleRate(for device: AVCaptureDevice) -> Double {
        // For Bluetooth HFP profile, sample rate is typically 8000 or 16000
        // For regular mics, it's usually 44100 or 48000

        // Try to detect from device formats
        for format in device.formats {
            let desc = format.formatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                let sampleRate = asbd.pointee.mSampleRate
                print("[AudioRecorder] Device format: \(sampleRate)Hz, \(asbd.pointee.mChannelsPerFrame) ch")

                // Prefer higher sample rates when available
                if sampleRate >= 16000 {
                    return sampleRate
                }
            }
        }

        // Bluetooth HFP typically uses 16000Hz
        if isBluetoothDevice(device) {
            print("[AudioRecorder] Bluetooth device detected, using 16000Hz")
            return 16000
        }

        return 44100
    }

    // MARK: - Recording

    func startRecording() throws -> URL {
        firstSampleHostTime = nil
        // Always recheck permission right before recording
        updatePermissionStatus()

        // If permission never requested, throw special error so caller can request it
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            throw RecordingError.permissionNotRequested
        }

        guard hasPermission else {
            throw RecordingError.noPermission
        }

        // Get the preferred device
        guard let device = getPreferredCaptureDevice() else {
            throw RecordingError.noDeviceAvailable
        }

        // Detect sample rate for this device
        let deviceSampleRate = getNativeSampleRate(for: device)
        self.detectedSampleRate = deviceSampleRate
        print("[AudioRecorder] Using sample rate: \(deviceSampleRate)Hz")

        // Create capture session
        let session = AVCaptureSession()

        // For Bluetooth devices, we may need to configure the session preset
        if isBluetoothDevice(device) {
            // Use a more compatible preset for Bluetooth
            if session.canSetSessionPreset(.low) {
                session.sessionPreset = .low
                print("[AudioRecorder] Set session preset to .low for Bluetooth compatibility")
            }
        }

        // Add input from selected device
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                print("[AudioRecorder] Cannot add microphone input")
                throw RecordingError.cannotConfigureSession
            }
            session.addInput(input)
            print("[AudioRecorder] Added input successfully")
        } catch {
            print("[AudioRecorder] Failed to create input: \(error.localizedDescription)")
            throw RecordingError.cannotConfigureSession
        }

        // Add data output for capturing audio samples
        let dataOutput = AVCaptureAudioDataOutput()
        dataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(dataOutput) else {
            print("[AudioRecorder] Cannot add audio output")
            throw RecordingError.cannotConfigureSession
        }
        session.addOutput(dataOutput)

        // Setup AVAssetWriter
        // For Bluetooth devices, use WAV format (passthrough) since AAC encoding often fails
        // For regular devices, use AAC for smaller files
        let isBluetooth = isBluetoothDevice(device)

        let url: URL
        let writer: AVAssetWriter
        let writerInput: AVAssetWriterInput
        try FileManager.default.createDirectory(
            at: transientRecordingDirectory,
            withIntermediateDirectories: true
        )

        if isBluetooth {
            // Use WAV format for Bluetooth - more compatible with 16-bit LPCM input
            url = transientRecordingDirectory
                .appendingPathComponent("dictation_\(UUID().uuidString).wav")
            writer = try AVAssetWriter(url: url, fileType: .wav)

            // PCM settings matching the Bluetooth input format
            let audioSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]

            print("[AudioRecorder] Output settings: 16000Hz WAV (Bluetooth compatible)")
            writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        } else {
            // Use AAC for non-Bluetooth devices (smaller files)
            url = transientRecordingDirectory
                .appendingPathComponent("dictation_\(UUID().uuidString).m4a")
            writer = try AVAssetWriter(url: url, fileType: .m4a)

            // AAC encoding - use 48kHz for high sample rate mics, 44.1kHz otherwise
            let outputSampleRate = deviceSampleRate > 44100 ? 48000 : 44100

            let audioSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: outputSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 64000
            ]

            print("[AudioRecorder] Output settings: \(outputSampleRate)Hz AAC")
            writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        }

        writerInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(writerInput) else {
            print("[AudioRecorder] Cannot add writer input")
            throw RecordingError.cannotConfigureSession
        }
        writer.add(writerInput)
        writer.startWriting()

        // Start session
        session.startRunning()

        // Verify session is actually running
        if !session.isRunning {
            print("[AudioRecorder] Warning: Session did not start running!")
        }

        self.captureSession = session
        self.assetWriter = writer
        self.assetWriterInput = writerInput
        self.currentRecordingURL = url
        self.isWriterStarted = false
        self.sampleCount = 0

        DispatchQueue.main.async {
            self.isRecording = true
        }

        print("[AudioRecorder] Started recording (Bluetooth: \(isBluetoothDevice(device)))")
        return url
    }

    /// Crash leftovers have no history row and cannot be retried. Keep them in
    /// an app-owned temporary directory and remove only files that have aged
    /// past the same seven-day ceiling used by the default audio policy.
    private func cleanupStaleTransientRecordings() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        guard let files = try? fileManager.contentsOfDirectory(
            at: transientRecordingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            guard let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
            values.isRegularFile == true,
            (values.contentModificationDate ?? .distantPast) <= cutoff else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }

    func stopRecording() -> URL? {
        captureSession?.stopRunning()
        captureSession = nil

        let url = currentRecordingURL
        currentRecordingURL = nil

        // Finish writing
        assetWriterInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        assetWriter?.finishWriting {
            semaphore.signal()
        }
        // Wait up to 1 second for writer to finish
        _ = semaphore.wait(timeout: .now() + 1.0)

        assetWriter = nil
        assetWriterInput = nil
        isWriterStarted = false

        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0
        }

        print("[AudioRecorder] Stopped recording")
        return url
    }

    // MARK: - Errors

    enum RecordingError: LocalizedError {
        case permissionNotRequested  // Need to show permission prompt
        case noPermission            // User denied permission
        case noDeviceAvailable
        case cannotConfigureSession

        var errorDescription: String? {
            switch self {
            case .permissionNotRequested: return "Microphone permission needed"
            case .noPermission: return "Microphone permission not granted"
            case .noDeviceAvailable: return "No microphone available"
            case .cannotConfigureSession: return "Cannot configure audio capture"
            }
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioRecorderService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

        // Start writer session on first sample and log format info
        if !isWriterStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter?.startSession(atSourceTime: timestamp)
            isWriterStarted = true
            firstSampleHostTime = CMTimeGetSeconds(timestamp)

            // Log the actual format we're receiving (helpful for debugging Bluetooth)
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                    let sampleRate = asbd.pointee.mSampleRate
                    let channels = asbd.pointee.mChannelsPerFrame
                    let bitsPerChannel = asbd.pointee.mBitsPerChannel
                    let formatID = asbd.pointee.mFormatID

                    // Convert format ID to readable string
                    let formatChars = [
                        Character(UnicodeScalar((formatID >> 24) & 0xFF)!),
                        Character(UnicodeScalar((formatID >> 16) & 0xFF)!),
                        Character(UnicodeScalar((formatID >> 8) & 0xFF)!),
                        Character(UnicodeScalar(formatID & 0xFF)!)
                    ]
                    let formatString = String(formatChars)

                    print("[AudioRecorder] Receiving audio: \(sampleRate)Hz, \(channels)ch, \(bitsPerChannel)bit, format: \(formatString)")
                }
            }

            print("[AudioRecorder] Writer started, receiving samples...")
        }

        // Write audio data
        if let writerInput = assetWriterInput, writerInput.isReadyForMoreMediaData {
            let success = writerInput.append(sampleBuffer)
            if !success && sampleCount < 5 {
                print("[AudioRecorder] Warning: Failed to append sample buffer")
                if let error = assetWriter?.error {
                    print("[AudioRecorder] Writer error: \(error.localizedDescription)")
                }
            }
        }

        // Calculate audio level for UI (every few samples to reduce overhead)
        sampleCount += 1
        if sampleCount % 3 == 0, let level = getAudioLevel(from: sampleBuffer) {
            DispatchQueue.main.async {
                self.audioLevel = level
            }
        }
    }

    private func getAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard status == kCMBlockBufferNoErr, let data = dataPointer, totalLength > 0 else { return nil }

        // Get the format to determine sample type
        var isFloat32 = true
        var bytesPerSample = 4

        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            bytesPerSample = Int(asbd.pointee.mBytesPerFrame / asbd.pointee.mChannelsPerFrame)
            // Check if it's integer format (common in Bluetooth HFP)
            isFloat32 = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        }

        if isFloat32 && bytesPerSample == 4 {
            // Float32 samples (most common on macOS)
            let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: totalLength / 4)
            let count = totalLength / 4

            guard count > 0 else { return nil }

            var sum: Float = 0
            for i in 0..<min(count, 1024) {
                let sample = floatPtr[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(min(count, 1024)))
            let scaled = min(1.0, rms * 8.0)
            return pow(scaled, 0.6)
        } else if bytesPerSample == 2 {
            // Int16 samples (common in Bluetooth HFP)
            let int16Ptr = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: totalLength / 2)
            let count = totalLength / 2

            guard count > 0 else { return nil }

            var sum: Float = 0
            for i in 0..<min(count, 1024) {
                let sample = Float(int16Ptr[i]) / 32768.0  // Normalize to -1...1
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(min(count, 1024)))
            let scaled = min(1.0, rms * 8.0)
            return pow(scaled, 0.6)
        }

        // Fallback: assume float32
        let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: totalLength / 4)
        let count = totalLength / 4
        guard count > 0 else { return nil }

        var sum: Float = 0
        for i in 0..<min(count, 1024) {
            let sample = floatPtr[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(min(count, 1024)))
        let scaled = min(1.0, rms * 8.0)
        return pow(scaled, 0.6)
    }
}

// MARK: - Audio Device Model

struct AudioDevice: Identifiable {
    let id: String
    let name: String
}
