@preconcurrency import AVFAudio
import Combine
import Foundation
import Speech

/// Keeps microphone capture and on-device transcription separate from the
/// conversation transport. Audio buffers are passed only to Apple's local
/// `SpeechAnalyzer`; this service never persists or uploads audio.
@MainActor
final class SpeechInputService: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case downloadingModel
        case recording
        case finishing
        case unavailable(String)
        case failed(String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isWorking: Bool {
            switch self {
            case .preparing, .downloadingModel, .recording, .finishing: true
            default: false
            }
        }

        var message: String? {
            switch self {
            case .preparing: String(localized: "正在准备本地听写…")
            case .downloadingModel: String(localized: "正在下载本地语音模型…")
            case .recording: String(localized: "正在听写，松开即可转写（音频不会离开此设备）")
            case .finishing: String(localized: "正在完成转写…")
            case .unavailable(let message), .failed(let message): message
            case .idle: nil
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var startTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var reservedLocale: Locale?
    private var activeSessionID: UUID?
    private var prefix = ""
    private var hasInstalledTap = false

    deinit {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    func start(initialText: String) {
        guard !state.isWorking else { return }

        let sessionID = UUID()
        activeSessionID = sessionID
        prefix = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = prefix
        state = .preparing
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.start(sessionID: sessionID)
        }
    }

    func stop() {
        guard state.isWorking else { return }
        startTask?.cancel()

        guard let sessionID = activeSessionID else {
            state = .idle
            return
        }

        if state.isRecording {
            state = .finishing
            stopCapturingAudio()
            Task { [weak self] in
                await self?.finish(sessionID: sessionID)
            }
        } else {
            activeSessionID = nil
            Task { [weak self] in
                await self?.tearDown()
            }
            state = .idle
        }
    }

    func dismissIssue() {
        guard !state.isWorking else { return }
        state = .idle
    }

    /// A sent message owns the current transcript. Invalidate the active
    /// session before clearing the composer so a late on-device result cannot
    /// repopulate text that the user has already sent.
    func discardTranscript() {
        let needsTearDown = activeSessionID != nil || state.isWorking || reservedLocale != nil
        activeSessionID = nil
        startTask?.cancel()
        resultsTask?.cancel()
        prefix = ""
        transcript = ""
        state = .idle
        if needsTearDown { Task { [weak self] in await self?.tearDown() } }
    }

    private func start(sessionID: UUID) async {
        do {
            guard await requestPermissions(), isCurrent(sessionID) else {
                if isCurrent(sessionID) { state = .unavailable(String(localized: "需要允许麦克风和语音识别权限，才能使用本地听写。")) }
                return
            }
            guard SpeechTranscriber.isAvailable else {
                state = .unavailable(String(localized: "此设备当前不支持本地语音转文字。"))
                return
            }

            let requestedLocale = SpeechTranscriptionLocaleResolver.preferredRequestLocale()
            guard let locale = await SpeechTranscriptionLocaleResolver.resolveSupportedLocale(
                requested: requestedLocale
            ) else {
                state = .unavailable(
                    String(format: String(localized: "当前语言（%@）没有可用的本地语音模型。"), locale: .current, requestedLocale.identifier)
                )
                return
            }
            guard isCurrent(sessionID) else { return }

            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let modules: [any SpeechModule] = [transcriber]
            // Reserve before requesting installation. Apple's installation
            // request auto-reserves a locale when needed; doing it afterward
            // makes reserve return false (already reserved), which is not an
            // error and previously blocked every first use.
            let reservedNow = try await AssetInventory.reserve(locale: locale)
            if reservedNow { reservedLocale = locale }
            try await ensureAssets(for: modules, sessionID: sessionID)
            guard isCurrent(sessionID) else { return }

            try configureAudioSession()
            let inputNode = audioEngine.inputNode
            let naturalFormat = inputNode.inputFormat(forBus: 0)
            guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            ) else {
                state = .unavailable(String(localized: "此麦克风的音频格式不支持本地语音转文字。"))
                await tearDown()
                return
            }
            guard let converter = AVAudioConverter(from: naturalFormat, to: audioFormat) else {
                state = .unavailable(String(localized: "无法将此麦克风的音频转换为本地听写格式。"))
                await tearDown()
                return
            }

            let analyzer = SpeechAnalyzer(modules: modules)
            try await analyzer.prepareToAnalyze(in: audioFormat)
            guard isCurrent(sessionID) else { return }

            let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation
            // An input node renders in the microphone's hardware format. It
            // cannot be retuned by a tap (for example, 48 kHz Float32 to the
            // analyzer's 16 kHz Int16), so capture natively and convert here.
            inputNode.installTap(onBus: 0, bufferSize: 4_800, format: nil) { buffer, _ in
                guard let converted = Self.convert(buffer, with: converter, to: audioFormat) else { return }
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            hasInstalledTap = true
            try await analyzer.start(inputSequence: inputStream)
            guard isCurrent(sessionID) else { return }

            self.analyzer = analyzer
            self.transcriber = transcriber
            resultsTask = Task { [weak self, transcriber] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        self?.receive(result.text, sessionID: sessionID)
                    }
                } catch is CancellationError {
                    // Stopping a recording cancels the result sequence normally.
                } catch {
                    await self?.fail(error, sessionID: sessionID)
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            guard isCurrent(sessionID) else { return }
            state = .recording
        } catch is CancellationError {
            if isCurrent(sessionID) {
                activeSessionID = nil
                state = .idle
                await tearDown()
            }
        } catch {
            await fail(error, sessionID: sessionID)
        }
    }

    private func ensureAssets(for modules: [any SpeechModule], sessionID: UUID) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .supported:
            state = .downloadingModel
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                throw SpeechInputError.modelUnavailable
            }
            try await request.downloadAndInstall()
        case .downloading:
            state = .downloadingModel
            while await AssetInventory.status(forModules: modules) == .downloading {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(500))
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw SpeechInputError.modelUnavailable
            }
        case .unsupported:
            throw SpeechInputError.modelUnavailable
        @unknown default:
            throw SpeechInputError.modelUnavailable
        }
        guard isCurrent(sessionID) else { throw CancellationError() }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw SpeechInputError.modelUnavailable
        }
    }

    private func finish(sessionID: UUID) async {
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            await fail(error, sessionID: sessionID)
            return
        }
        await resultsTask?.value
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        await tearDown()
        state = .idle
    }

    private func receive(_ text: AttributedString, sessionID: UUID) {
        guard isCurrent(sessionID) else { return }
        let recognizedText = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognizedText.isEmpty else { return }
        transcript = prefix.isEmpty ? recognizedText : "\(prefix)\n\(recognizedText)"
    }

    private func fail(_ error: Error, sessionID: UUID) async {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        stopCapturingAudio()
        await tearDown()
        state = .failed(error.localizedDescription)
    }

    private func stopCapturingAudio() {
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
    }

    private func tearDown() async {
        stopCapturingAudio()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        if let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
    }

    private nonisolated static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = max(1, AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status == .haveData, output.frameLength > 0 else { return nil }
        return output
    }

    private func requestPermissions() async -> Bool {
        let microphoneGranted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphoneGranted = true
        case .undetermined:
            microphoneGranted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        case .denied:
            microphoneGranted = false
        @unknown default:
            microphoneGranted = false
        }
        guard microphoneGranted else { return false }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func isCurrent(_ sessionID: UUID) -> Bool {
        activeSessionID == sessionID && !Task.isCancelled
    }
}

/// Resolves the system's preferred dictation locale before asking Apple for an
/// equivalent on-device model. `Locale.autoupdatingCurrent` can describe the
/// device's region rather than the user's first language; for Simplified
/// Chinese we therefore begin with `Locale.preferredLanguages` and keep a
/// small set of equivalent language/script/region candidates.
enum SpeechTranscriptionLocaleResolver {
    static func preferredRequestLocale(
        currentLocale: Locale = .autoupdatingCurrent,
        preferredLanguageIdentifiers: [String] = Locale.preferredLanguages
    ) -> Locale {
        guard let firstPreferredLanguage = preferredLanguageIdentifiers.first else {
            return currentLocale
        }

        let preferredLocale = Locale(identifier: firstPreferredLanguage)
        return isSimplifiedChinese(preferredLocale) ? preferredLocale : currentLocale
    }

    static func resolveSupportedLocale(requested: Locale) async -> Locale? {
        for candidate in candidates(for: requested) {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return supported
            }
        }
        return nil
    }

    static func candidates(for requested: Locale) -> [Locale] {
        guard isSimplifiedChinese(requested) else { return [requested] }

        let language = "zh"
        let region = requested.region?.identifier.uppercased()
        let identifiers = [
            requested.identifier,
            region.map { "\(language)-Hans-\($0)" },
            region.map { "\(language)-\($0)" },
            "zh-Hans-CN",
            "zh-Hans",
            "zh-CN"
        ].compactMap { $0 }

        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let locale = Locale(identifier: identifier)
            return seen.insert(locale.identifier.lowercased()).inserted ? locale : nil
        }
    }

    private static func isSimplifiedChinese(_ locale: Locale) -> Bool {
        guard locale.language.languageCode?.identifier.lowercased() == "zh" else { return false }

        let script = locale.language.script?.identifier.lowercased()
        let region = locale.region?.identifier.uppercased()
        if script == "hant" || ["HK", "MO", "TW"].contains(region) { return false }
        return script == "hans" || ["CN", "SG"].contains(region) || (script == nil && region == nil)
    }
}

private enum SpeechInputError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: String(localized: "当前语言的本地语音模型不可用或下载失败。")
        }
    }
}
