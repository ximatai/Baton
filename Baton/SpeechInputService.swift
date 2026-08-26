import AVFAudio
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
            case .preparing: "正在准备本地听写…"
            case .downloadingModel: "正在下载本地语音模型…"
            case .recording: "正在听写（音频不会离开此设备）"
            case .finishing: "正在完成转写…"
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

    private func start(sessionID: UUID) async {
        do {
            guard await requestPermissions(), isCurrent(sessionID) else {
                if isCurrent(sessionID) { state = .unavailable("需要允许麦克风和语音识别权限，才能使用本地听写。") }
                return
            }
            guard SpeechTranscriber.isAvailable else {
                state = .unavailable("此设备当前不支持本地语音转文字。")
                return
            }

            let requestedLocale = Locale.autoupdatingCurrent
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
                state = .unavailable("当前语言（\(requestedLocale.identifier)）没有可用的本地语音模型。")
                return
            }
            guard isCurrent(sessionID) else { return }

            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let modules: [any SpeechModule] = [transcriber]
            try await ensureAssets(for: modules, sessionID: sessionID)
            guard isCurrent(sessionID) else { return }

            guard try await AssetInventory.reserve(locale: locale) else {
                state = .unavailable("无法为当前语言保留本地语音模型，请稍后重试。")
                return
            }
            reservedLocale = locale
            guard isCurrent(sessionID) else { return }

            try configureAudioSession()
            let inputNode = audioEngine.inputNode
            let naturalFormat = inputNode.inputFormat(forBus: 0)
            guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            ) else {
                state = .unavailable("此麦克风的音频格式不支持本地语音转文字。")
                await tearDown()
                return
            }

            let analyzer = SpeechAnalyzer(modules: modules)
            try await analyzer.prepareToAnalyze(in: audioFormat)
            guard isCurrent(sessionID) else { return }

            let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: audioFormat) { buffer, _ in
                continuation.yield(AnalyzerInput(buffer: buffer))
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

private enum SpeechInputError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "当前语言的本地语音模型不可用或下载失败。"
        }
    }
}
