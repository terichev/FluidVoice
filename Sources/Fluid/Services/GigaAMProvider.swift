import AppKit
import Foundation

// MARK: - GigaAM Server Controller

/// Manages the lifecycle of a local gigastt server (https://github.com/ekhodzitsky/gigastt)
/// that runs Sber's GigaAM v3 Russian ASR models fully offline via ONNX Runtime
/// (CoreML/ANE-accelerated on Apple Silicon).
///
/// The controller survives provider resets so the server process is not restarted
/// every time the user switches models in settings.
final actor GigaAMServerController {
    static let shared = GigaAMServerController()

    /// UserDefaults key for pointing FluidVoice at an already-running gigastt server
    /// (e.g. one managed by `brew services` or running on another port).
    static let serverURLDefaultsKey = "gigaamServerURL"

    private static let defaultServerURL = URL(string: "http://127.0.0.1:9876") ?? URL(fileURLWithPath: "/dev/null")

    private static let binaryCandidatePaths = [
        "/opt/homebrew/bin/gigastt",
        "/usr/local/bin/gigastt",
        NSHomeDirectory() + "/.cargo/bin/gigastt",
    ]

    /// Holds the managed process outside the actor so the app-termination observer
    /// can stop it synchronously before the process table is torn down.
    private final class ManagedProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func store(_ process: Process?) {
            self.lock.withLock { self.process = process }
        }

        func current() -> Process? {
            self.lock.withLock { self.process }
        }

        func terminateIfRunning() {
            let process = self.lock.withLock { () -> Process? in
                defer { self.process = nil }
                return self.process
            }
            if let process, process.isRunning {
                process.terminate()
            }
        }
    }

    private let managedProcessBox = ManagedProcessBox()
    private var terminationObserver: NSObjectProtocol?

    enum ServerError: LocalizedError {
        case binaryNotFound
        case failedToLaunch(String)
        case serverNotReady

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "GigaAM requires the gigastt engine. Install it with:\n" +
                    "brew tap ekhodzitsky/gigastt https://github.com/ekhodzitsky/gigastt && brew install gigastt"
            case let .failedToLaunch(reason):
                return "Failed to start the gigastt server: \(reason)"
            case .serverNotReady:
                return "The gigastt server did not become ready in time. Try running 'gigastt serve' manually."
            }
        }
    }

    static var serverURL: URL {
        if let custom = UserDefaults.standard.string(forKey: serverURLDefaultsKey),
           let url = URL(string: custom), url.host != nil
        {
            return url
        }
        return self.defaultServerURL
    }

    /// Fast synchronous installation check for UI (no network access).
    nonisolated static var isInstalled: Bool {
        if UserDefaults.standard.string(forKey: serverURLDefaultsKey) != nil {
            // A custom server URL counts as installed; prepare() verifies reachability.
            return true
        }
        return self.installedBinaryPath() != nil
    }

    nonisolated static func installedBinaryPath() -> String? {
        self.binaryCandidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Ensures a gigastt server is present (launching a managed process when needed)
    /// and waits until it reports ready. On a fresh install the server downloads the
    /// model bundle at startup, so readiness can take a while; the poll reports an
    /// indeterminate download phase through `progressRelay`.
    func ensureServerReady(progressRelay: ModelPreparationProgressRelay) async throws {
        if await Self.serverIsReady() {
            return
        }

        if await Self.serverResponds() {
            // A server is already up (possibly user-managed) but still loading models.
        } else if let process = self.managedProcessBox.current(), process.isRunning {
            // Managed process is starting; fall through to the readiness poll.
        } else {
            guard let binaryPath = Self.installedBinaryPath() else {
                throw ServerError.binaryNotFound
            }
            try self.launchServer(at: binaryPath)
        }

        // No fraction available: the server downloads its model bundle on its own.
        progressRelay.report(ModelPreparationProgress(phase: .downloading))
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            if await Self.serverIsReady() {
                return
            }
            if let process = self.managedProcessBox.current(), !process.isRunning {
                throw ServerError.failedToLaunch("process exited with status \(process.terminationStatus)")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ServerError.serverNotReady
    }

    private func launchServer(at binaryPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        // e2e_rnnt emits punctuation, casing, and number normalization — the right
        // head for dictation. A user-managed server keeps whatever variant it runs.
        process.arguments = ["serve", "--model-variant", "e2e_rnnt"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            DebugLogger.shared.info(
                "GigaAM: managed gigastt server exited with status \(process.terminationStatus)",
                source: "GigaAMProvider"
            )
        }

        do {
            try process.run()
        } catch {
            throw ServerError.failedToLaunch(error.localizedDescription)
        }

        DebugLogger.shared.info(
            "GigaAM: launched managed gigastt server (pid \(process.processIdentifier))",
            source: "GigaAMProvider"
        )
        self.managedProcessBox.store(process)
        self.registerTerminationObserverIfNeeded()
    }

    /// Terminates the managed server when the app quits. A server the user started
    /// themselves is never touched.
    private func registerTerminationObserverIfNeeded() {
        guard self.terminationObserver == nil else { return }
        let box = self.managedProcessBox
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            box.terminateIfRunning()
        }
    }

    /// Whether anything is answering HTTP on the server URL (even while loading models).
    static func serverResponds() async -> Bool {
        await self.fetchHealth() != nil
    }

    /// Whether the server has finished loading models and can transcribe.
    /// gigastt answers /health with 200 immediately, reporting {"model": "loading"}
    /// while the bundle is still downloading/loading and the model name once ready.
    static func serverIsReady() async -> Bool {
        guard let health = await self.fetchHealth() else { return false }
        return health.statusCode == 200 && health.model != "loading"
    }

    private static func fetchHealth() async -> (statusCode: Int, model: String?)? {
        var request = URLRequest(url: self.serverURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse
        else {
            return nil
        }
        let model = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["model"] as? String }
        return (httpResponse.statusCode, model)
    }
}

// MARK: - GigaAM Provider

/// TranscriptionProvider for Sber GigaAM v3 (Russian) backed by a local gigastt server.
/// Audio never leaves the machine: the provider posts PCM WAV chunks to the
/// OpenAI-compatible endpoint at 127.0.0.1 and returns the decoded text.
final class GigaAMProvider: TranscriptionProvider {
    let name = "GigaAM v3 (gigastt)"

    /// The e2e variant emits punctuation and casing natively, which suits dictation.
    /// If the server rejects it (older gigastt build), we retry with the server default.
    private static let preferredModelVariant = "e2e_rnnt"
    private static let sampleRate = 16_000

    private(set) var isReady: Bool = false
    private var modelVariantSupported = true

    var isAvailable: Bool { true }
    var shouldClearCacheAfterCancellation: Bool { false }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }
        let progressRelay = ModelPreparationProgressRelay(progressHandler)
        progressRelay.report(.preparingDownload)

        try await GigaAMServerController.shared.ensureServerReady(progressRelay: progressRelay)
        try Task.checkCancellation()

        // Warm up with a short silent buffer so the first real dictation is fast.
        progressRelay.report(.loading)
        let warmupSamples = [Float](repeating: 0, count: Self.sampleRate / 2)
        _ = try await self.performTranscription(warmupSamples, timeout: 120)
        try Task.checkCancellation()

        self.isReady = true
        DebugLogger.shared.info("GigaAM: provider ready", source: "GigaAMProvider")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let text = try await self.performTranscription(samples, timeout: 120)
        return ASRTranscriptionResult(text: text)
    }

    func modelsExistOnDisk() -> Bool {
        // The gigastt server owns its model cache; the binary being present is the
        // closest synchronous equivalent of "installed".
        self.isReady || GigaAMServerController.isInstalled
    }

    func clearCache() async throws {
        // Models are managed by gigastt (`gigastt download` / its own cache directory);
        // FluidVoice does not delete files owned by another tool.
        self.isReady = false
    }

    // MARK: - HTTP Transcription

    private enum TranscriptionError: LocalizedError {
        case serverError(statusCode: Int, body: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case let .serverError(statusCode, body):
                return "gigastt server error (HTTP \(statusCode)): \(body.prefix(300))"
            case .invalidResponse:
                return "gigastt returned an unreadable transcription response."
            }
        }
    }

    private func performTranscription(_ samples: [Float], timeout: TimeInterval) async throws -> String {
        let wavData = Self.encodeWAV(samples)
        let modelVariant = self.modelVariantSupported ? Self.preferredModelVariant : nil

        do {
            return try await self.postTranscription(wavData, modelVariant: modelVariant, timeout: timeout)
        } catch let TranscriptionError.serverError(statusCode, body) where (400 ..< 500).contains(statusCode) && modelVariant != nil {
            DebugLogger.shared.warning(
                "GigaAM: server rejected model variant '\(Self.preferredModelVariant)' (HTTP \(statusCode): \(body.prefix(120))), falling back to server default",
                source: "GigaAMProvider"
            )
            self.modelVariantSupported = false
            return try await self.postTranscription(wavData, modelVariant: nil, timeout: timeout)
        }
    }

    private func postTranscription(_ wavData: Data, modelVariant: String?, timeout: TimeInterval) async throws -> String {
        let url = GigaAMServerController.serverURL.appendingPathComponent("v1/audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        let boundary = "fluidvoice-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ string: String) {
            body.append(Data(string.utf8))
        }
        if let modelVariant {
            appendField("--\(boundary)\r\n")
            appendField("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
            appendField("\(modelVariant)\r\n")
        }
        appendField("--\(boundary)\r\n")
        appendField("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        appendField("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        appendField("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TranscriptionError.serverError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String
        {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw TranscriptionError.invalidResponse
    }

    // MARK: - WAV Encoding

    /// Encodes 16 kHz mono float samples as a PCM16 WAV file.
    static func encodeWAV(_ samples: [Float]) -> Data {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            pcm[index] = Int16(max(-1.0, min(1.0, sample)) * Float(Int16.max))
        }

        let dataChunkSize = pcm.count * MemoryLayout<Int16>.size
        let sampleRate = UInt32(self.sampleRate)
        let byteRate = sampleRate * 2
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(Data("RIFF".utf8))
        append(UInt32(36 + dataChunkSize))
        header.append(Data("WAVE".utf8))
        header.append(Data("fmt ".utf8))
        append(UInt32(16)) // PCM fmt chunk size
        append(UInt16(1)) // PCM format
        append(UInt16(1)) // mono
        append(sampleRate)
        append(byteRate)
        append(UInt16(2)) // block align
        append(UInt16(16)) // bits per sample
        header.append(Data("data".utf8))
        append(UInt32(dataChunkSize))

        var result = header
        pcm.withUnsafeBytes { result.append(contentsOf: $0) }
        return result
    }
}
