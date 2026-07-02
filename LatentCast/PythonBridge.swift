//
//  PythonBridge.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import Combine
import CoreVideo
import PythonKit

/// Dedicated OS thread for executing all Python / PythonKit operations.
/// This guarantees that Python is always accessed from the exact same OS thread,
/// eliminating any GCD cross-thread GIL scheduling deadlocks and spin-locks.
class PythonThread: Thread, @unchecked Sendable {
    private var tasks: [() -> Void] = []
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    
    override func main() {
        print("[PythonThread] Dedicated Python execution thread active.")
        while !isCancelled {
            lock.lock()
            if tasks.isEmpty {
                lock.unlock()
                _ = semaphore.wait(timeout: .distantFuture)
                continue
            }
            let task = tasks.removeFirst()
            lock.unlock()
            
            task()
        }
        print("[PythonThread] Dedicated Python execution thread exiting.")
    }
    
    func async(execute task: @escaping () -> Void) {
        guard !isCancelled else { return }
        lock.lock()
        tasks.append(task)
        lock.unlock()
        semaphore.signal()
    }
    
    func stop() {
        cancel()
        semaphore.signal()
    }
}

// Thread-safe communication bridge with Python running in-process via PythonKit
class PythonBridge: ObservableObject, @unchecked Sendable {
    @Published var connectionStatus: String = "Initializing..."
    @Published var lastResponse: String = ""
    @Published var isProcessing: Bool = false
    @Published var liveTranscription: String = ""
    @Published var isVoiceActive: Bool = false
    @Published var silenceTimeoutMs: Double = 600.0
    @Published var fusionThreshold: Double = 0.00010
    @Published var selectedModel: String = "mlx-community/whisper-small-mlx"
    @Published var useCPU: Bool = false
    
    private var swiftAudioBuffer: [Float] = []
    
    private static var isEnvSetupDone = false
    private static let envLock = NSLock()
    
    private var pyEngine: PythonObject?
    private var safeSubtitle: String = ""
    
    struct SubtitleSegment: Sendable {
        let text: String
        let startTime: Double
        let endTime: Double
        let speaker: String
    }
    private var activeSubtitles: [SubtitleSegment] = []
    private var speakerMapping: [String: String] = [:]
    
    private struct PendingSegment {
        let startTime: Double
        let endTime: Double
        let speaker: String
    }
    private var pendingSegments: [PendingSegment] = []
    
    private let pythonThread = PythonThread()
    private let lock = NSLock()
    private var audioChunkCount = 0
    
    var currentSubtitle: String {
        lock.lock()
        defer { lock.unlock() }
        return safeSubtitle
    }
    
    func subtitle(for timestamp: Double, speaker: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        
        // If speaker name is empty (full frame view), return text with speaker prefix
        if speaker.isEmpty {
            if let match = activeSubtitles.first(where: { timestamp >= ($0.startTime - 0.2) && timestamp <= ($0.endTime + 0.8) }) {
                return "[\(match.speaker)]: \(match.text)"
            }
            return ""
        }
        
        // Otherwise, return clean text for target speaker panel
        if let match = activeSubtitles.first(where: { 
            $0.speaker == speaker && 
            timestamp >= ($0.startTime - 0.2) && 
            timestamp <= ($0.endTime + 0.8) 
        }) {
            return match.text
        }
        return ""
    }
    
    func speakerLabel(for faceId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return speakerMapping[faceId]
    }
    
    func changeWorkerConfig(modelName: String, useCPU: Bool) {
        lock.lock()
        let callback = whisperWorker?.onTranscriptionReceived
        whisperWorker?.stop()
        pendingSegments.removeAll()
        
        let deviceStr = useCPU ? "cpu" : "gpu"
        print("[PythonBridge] Restarting Whisper worker: model=\(modelName), device=\(deviceStr)")
        
        let newWorker = WhisperWorker(projectPath: projectPath, modelName: modelName, deviceType: deviceStr)
        newWorker.onTranscriptionReceived = callback
        whisperWorker = newWorker
        lock.unlock()
        
        Task { @MainActor in
            self.selectedModel = modelName
            self.useCPU = useCPU
        }
    }
    
    func changeModel(to modelName: String) {
        changeWorkerConfig(modelName: modelName, useCPU: self.useCPU)
    }
    
    // Whisper worker subprocess variables
    private var whisperWorker: WhisperWorker?
    private var pendingSpeakerLabels: [String] = []
    private let labelQueue = DispatchQueue(label: "com.latentcast.labelQueue")
    
    // Workspace Path
    private let projectPath: String
    
    // GIL (Global Interpreter Lock) Management Functions
    private typealias GILEnsureFunc = @convention(c) () -> Int32
    private typealias GILReleaseFunc = @convention(c) (Int32) -> Void
    private var gilEnsure: GILEnsureFunc?
    private var gilRelease: GILReleaseFunc?
    private var pythonLibHandle: UnsafeMutableRawPointer?
    
    init() {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        self.projectPath = projectRoot.path
        
        // Start the dedicated thread loop for all Python executions
        pythonThread.name = "com.latentcast.pythonThread"
        pythonThread.start()
        
        setupPythonEnvironment()
    }
    
    /// Dynamically loads PyGILState_Ensure/Release from libpython via dlsym
    private func setupGILFunctions(libPath: String) {
        guard let handle = dlopen(libPath, RTLD_LAZY | RTLD_GLOBAL) else {
            print("[GIL] Warning: Failed to open Python library at \(libPath)")
            return
        }
        self.pythonLibHandle = handle // Keep handle open so symbols remain valid
        
        if let ensureSym = dlsym(handle, "PyGILState_Ensure"),
           let releaseSym = dlsym(handle, "PyGILState_Release") {
            gilEnsure = unsafeBitCast(ensureSym, to: GILEnsureFunc.self)
            gilRelease = unsafeBitCast(releaseSym, to: GILReleaseFunc.self)
            print("[GIL] PyGILState_Ensure/Release loaded successfully from \(libPath)")
        } else {
            print("[GIL] Warning: Could not find PyGILState symbols in \(libPath) - GIL safety disabled")
        }
    }
    
    /// Executes a PythonKit operation while holding the Global Interpreter Lock
    @discardableResult
    private func withGIL<T>(_ body: () -> T) -> T {
        if let ensure = gilEnsure, let release = gilRelease {
            let state = ensure()
            defer { release(state) }
            return body()
        }
        return body()
    }
    
    /// Configures environments, dynamic libs, and imports python modules
    func setupPythonEnvironment() {
        print("[PythonBridge] Scheduling setupPythonEnvironment on background PythonThread...")
        
        pythonThread.async { [weak self] in
            guard let self = self else { return }
            
            // 1. Point PythonKit to Miniconda's shared library dynamically based on real home directory
            let homeDir: String
            if let pw = getpwuid(getuid()) {
                homeDir = String(cString: pw.pointee.pw_dir)
            } else {
                homeDir = NSHomeDirectory()
            }
            
            let pythonLibPath = "\(homeDir)/miniconda3/lib/libpython3.13.dylib"
            print("[PythonBridge] Resolved home directory: \(homeDir)")
            
            Self.envLock.lock()
            let needsSetup = !Self.isEnvSetupDone
            if needsSetup {
                print("[PythonBridge] Configuring process-global Python library paths...")
                print("[PythonBridge] Setting PYTHON_LIBRARY to: \(pythonLibPath)")
                
                if FileManager.default.fileExists(atPath: pythonLibPath) {
                    print("[PythonBridge] Success: Python library found at target path.")
                } else {
                    print("[PythonBridge] WARNING: Python library file does not exist at: \(pythonLibPath)")
                }
                
                setenv("PYTHON_LIBRARY", pythonLibPath, 1)
                setenv("PYTHON_LOADER_LOGGING", "TRUE", 1)
                setenv("PYTHONIOENCODING", "utf-8", 1)
                setenv("PYTHONUTF8", "1", 1)
                setenv("DISABLE_VIRTUAL_CAMERA", "1", 1)
                
                // Programmatically configure PythonKit to load the exact dylib target
                PythonLibrary.useLibrary(at: pythonLibPath)
                
                // 2. Set PYTHONPATH to locate the workspace and virtual environment dependencies dynamically
                let sitePackages = "\(self.projectPath)/.venv/lib/python3.13/site-packages"
                print("[PythonBridge] Setting PYTHONPATH to: \(self.projectPath):\(sitePackages)")
                setenv("PYTHONPATH", "\(self.projectPath):\(sitePackages)", 1)
                
                Self.isEnvSetupDone = true
            } else {
                print("[PythonBridge] Process-global Python library already configured.")
            }
            Self.envLock.unlock()
            
            do {
                print("[PythonBridge] Attempting to import bridge_logic module...")
                let bridgeLogic = try Python.attemptImport("bridge_logic")
                
                // Initialize GIL management functions now that Python library is loaded
                self.setupGILFunctions(libPath: pythonLibPath)
                
                // Initialize the Python engine with GIL held
                let engine = self.withGIL {
                    bridgeLogic.PythonBridgeEngine()
                }
                
                self.lock.lock()
                self.pyEngine = engine
                self.lock.unlock()
                
                Task { @MainActor in
                    self.connectionStatus = "Connected (Python 3.13 & Silero VAD)"
                    print("[PythonBridge] PythonBridgeEngine successfully loaded!")
                    
                    // Initialize the subprocess Whisper worker
                    let worker = WhisperWorker(projectPath: self.projectPath, modelName: self.selectedModel, deviceType: self.useCPU ? "cpu" : "gpu")
                    worker.onTranscriptionReceived = { [weak self] rawText in
                        guard let self = self else { return }
                        
                        guard let jsonData = rawText.data(using: .utf8),
                              let response = try? JSONDecoder().decode(MultiSpeakerWhisperResponse.self, from: jsonData) else {
                            print("[PythonBridge] Error: Failed to parse MultiSpeakerWhisperResponse from: \(rawText)")
                            return
                        }
                        
                        self.lock.lock()
                        let pending = self.pendingSegments.isEmpty == false ? self.pendingSegments.removeFirst() : nil
                        self.lock.unlock()
                        
                        var finalFullText = ""
                        var segmentsToRegister: [(text: String, start: Double, end: Double, speaker: String)] = []
                        
                        for res in response.results {
                            if res.text.isEmpty { continue }
                            if finalFullText.isEmpty {
                                finalFullText = "[\(res.speaker)]: \(res.text)"
                            } else {
                                finalFullText += "\n[\(res.speaker)]: \(res.text)"
                            }
                            
                            if let seg = pending {
                                if res.segments.isEmpty {
                                    segmentsToRegister.append((text: res.text, start: seg.startTime, end: seg.endTime, speaker: res.speaker))
                                } else {
                                    for subSeg in res.segments {
                                        let absStart = seg.startTime + subSeg.start
                                        let absEnd = seg.startTime + subSeg.end
                                        segmentsToRegister.append((text: subSeg.text, start: absStart, end: absEnd, speaker: res.speaker))
                                    }
                                }
                            }
                        }
                        
                        if !finalFullText.isEmpty {
                            self.lock.lock()
                            self.safeSubtitle = finalFullText
                            for item in segmentsToRegister {
                                self.activeSubtitles.append(SubtitleSegment(text: item.text, startTime: item.start, endTime: item.end, speaker: item.speaker))
                            }
                            if self.activeSubtitles.count > 200 {
                                self.activeSubtitles.removeFirst(self.activeSubtitles.count - 200)
                            }
                            self.lock.unlock()
                            
                            let textToPublish = finalFullText
                            Task { @MainActor in
                                self.liveTranscription = textToPublish
                            }
                        }
                    }
                    self.whisperWorker = worker
                }
            } catch {
                Task { @MainActor in
                    self.connectionStatus = "Failed to load Python: \(error.localizedDescription)"
                    print("[PythonBridge] Error initializing Python: \(error)")
                }
            }
        }
    }
    
    /// Sends a diagnostic test message to Python and updates UI with the reply
    func testCommunication(message: String) {
        pythonThread.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard let engine = self.pyEngine else {
                self.lock.unlock()
                Task { @MainActor in
                    self.lastResponse = "Error: Python engine not ready"
                }
                return
            }
            self.lock.unlock()
            
            let response = self.withGIL {
                String(engine.test_communication(message)) ?? "Failed to decode Python string response"
            }
            
            Task { @MainActor in
                self.lastResponse = response
            }
        }
    }
    
    /// Dynamically updates silence timeout and lip variance fusion threshold in the Python engine
    func updateParameters(silenceTimeoutMs: Double, fusionThreshold: Double) {
        pythonThread.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard let engine = self.pyEngine else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            
            self.withGIL {
                _ = engine.update_fusion_parameters(silenceTimeoutMs, fusionThreshold)
            }
        }
    }
    
    /// Feeds the processed BGRA frame buffer pointer directly to Python virtual camera
    func sendProcessedFrame(_ sendableBuffer: SendablePixelBuffer) {
        self.lock.lock()
        let isReady = self.pyEngine != nil
        self.lock.unlock()
        
        guard isReady else {
            print("[Swift Bridge] sendProcessedFrame: pyEngine is not ready, dropping frame")
            return
        }
        
        pythonThread.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard let engine = self.pyEngine else {
                self.lock.unlock()
                print("[Swift Bridge] sendProcessedFrame: pyEngine became nil inside queue, dropping frame")
                return
            }
            self.lock.unlock()
            
            let pixelBuffer = sendableBuffer.buffer
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let address = Int(bitPattern: baseAddress)
                let size = CVPixelBufferGetDataSize(pixelBuffer)
                
                print("[Swift Bridge] sendProcessedFrame: calling engine.send_frame_pointer(address=\(address), size=\(size))")
                self.withGIL {
                    _ = engine.send_frame_pointer(address, size)
                }
                print("[Swift Bridge] sendProcessedFrame: engine.send_frame_pointer finished successfully")
            } else {
                print("[Swift Bridge] sendProcessedFrame: Failed to get CVPixelBuffer base address")
            }
        }
    }
    
    // MARK: - Speaker Label Queue
    
    private func enqueueSpeakerLabel(_ label: String) {
        labelQueue.async {
            self.pendingSpeakerLabels.append(label)
        }
    }
    
    private func dequeueSpeakerLabel() -> String {
        var label = "Speaker"
        labelQueue.sync {
            if !self.pendingSpeakerLabels.isEmpty {
                label = self.pendingSpeakerLabels.removeFirst()
            }
        }
        return label
    }
    
    // MARK: - Real-time Audio Ingestion
    
    func pushAudioSamples(_ samples: [Float], activeFaces: [ActiveFaceInfo]) {
        self.lock.lock()
        let isReady = self.pyEngine != nil
        if !isReady {
            self.lock.unlock()
            return
        }
        
        swiftAudioBuffer.append(contentsOf: samples)
        
        // Only push to Python if we have accumulated at least 1024 samples (64ms of audio)
        guard swiftAudioBuffer.count >= 1024 else {
            self.lock.unlock()
            return
        }
        
        let samplesToPush = swiftAudioBuffer
        swiftAudioBuffer.removeAll(keepingCapacity: true)
        
        let count = samplesToPush.count
        
        // 1. Allocate a heap buffer and copy samples.
        // We pass the raw memory address to Python to bypass PythonKit conversion overhead.
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(from: samplesToPush, count: count)
        let address = Int(bitPattern: buffer)
        
        // 2. Pre-extract face IDs and variances into standard arrays
        let faceIds = activeFaces.map { $0.id.uuidString }
        let faceVariances = activeFaces.map { $0.lipVariance }
        self.lock.unlock()
        
        pythonThread.async { [weak self] in
            guard let pointer = UnsafeMutablePointer<Float>(bitPattern: address) else { return }
            defer {
                pointer.deinitialize(count: count)
                pointer.deallocate()
            }
            guard let self = self else { return }
            self.lock.lock()
            guard let engine = self.pyEngine else {
                self.lock.unlock()
                return
            }
            self.audioChunkCount += 1
            let currentChunk = self.audioChunkCount
            self.lock.unlock()
            
            if currentChunk % 50 == 0 || currentChunk <= 5 {
                print("[Swift Bridge] pushAudioSamples queue: Chunk #\(currentChunk) processing \(count) samples. Active faces: \(faceIds.count)")
            }
            
            self.withGIL {
                let response = engine.process_audio_chunk_ptr(address, count, faceIds, faceVariances)
                
                let isSpeaking = Bool(response["is_speaking"]) ?? false
                let wavPath = String(response["wav_path"]) ?? ""
                let speakerLabel = String(response["speaker_label"]) ?? ""
                let startTime = Double(response["start_time"]) ?? 0.0
                let endTime = Double(response["end_time"]) ?? 0.0
                
                let mapping = response["speaker_mapping"]
                if mapping != Python.None {
                    self.lock.lock()
                    self.speakerMapping.removeAll()
                    for key in mapping {
                        if let k = String(key), let v = String(mapping[key]) {
                            self.speakerMapping[k] = v
                        }
                    }
                    self.lock.unlock()
                }
                
                let faceEnvelopesPython = response["face_envelopes"]
                var faceEnvelopes: [String: [Double]] = [:]
                if faceEnvelopesPython != Python.None {
                    for key in faceEnvelopesPython {
                        if let k = String(key) {
                            var vals: [Double] = []
                            for val in faceEnvelopesPython[key] {
                                if let d = Double(val) {
                                    vals.append(d)
                                }
                            }
                            faceEnvelopes[k] = vals
                        }
                    }
                }
                
                if !wavPath.isEmpty {
                    let cleanLabel = speakerLabel.isEmpty ? "Unknown Speaker" : speakerLabel
                    print("[Swift Bridge] Speech segment detected: wavPath=\(wavPath), speaker=\(cleanLabel), start=\(startTime), end=\(endTime)")
                    
                    self.lock.lock()
                    self.pendingSegments.append(PendingSegment(startTime: startTime, endTime: endTime, speaker: cleanLabel))
                    let mappingCopy = self.speakerMapping
                    self.lock.unlock()
                    
                    let job: [String: Any] = [
                        "wav_path": wavPath,
                        "face_envelopes": faceEnvelopes,
                        "speaker_mapping": mappingCopy
                    ]
                    
                    if let jsonData = try? JSONSerialization.data(withJSONObject: job),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        self.whisperWorker?.transcribe(jobJson: jsonString)
                    }
                }
                
                Task { @MainActor in
                    self.isVoiceActive = isSpeaking
                }
            }
            if currentChunk % 50 == 0 || currentChunk <= 5 {
                print("[Swift Bridge] pushAudioSamples queue: Chunk #\(currentChunk) processing completed")
            }
        }
    }
    
    deinit {
        print("[PythonBridge] deinit called. Shutting down worker and thread.")
        whisperWorker?.stop()
        pythonThread.stop()
        if let handle = pythonLibHandle {
            dlclose(handle)
        }
    }
}

// MARK: - Whisper Subprocess Manager (Pure Swift — No Python)

class WhisperWorker: @unchecked Sendable {
    private let projectPath: String
    private let modelName: String
    private let deviceType: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let lock = NSLock()
    
    var onTranscriptionReceived: (@Sendable (String) -> Void)?
    
    init(projectPath: String, modelName: String, deviceType: String) {
        self.projectPath = projectPath
        self.modelName = modelName
        self.deviceType = deviceType
        startSubprocess()
    }
    
    func startSubprocess() {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        
        process.executableURL = URL(fileURLWithPath: "\(projectPath)/.venv/bin/python")
        process.arguments = ["-u", "\(projectPath)/transcribe_worker.py", "--model", modelName, "--device", deviceType]
        
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        // Setup stdout reader (runs on system background queue)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if trimmed.hasPrefix("ERROR:") {
                            print("[Swift-Whisper Error] \(trimmed)")
                        } else if trimmed.hasPrefix("[Worker]") {
                            print("[Swift-Whisper Info] \(trimmed)")
                        } else {
                            print("[Swift-Whisper] Transcribed: \(trimmed)")
                            self?.lock.lock()
                            let callback = self?.onTranscriptionReceived
                            self?.lock.unlock()
                            callback?(trimmed)
                        }
                    }
                }
            }
        }
        
        // Setup stderr reader
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        print("[Swift-Whisper Worker Stderr] \(trimmed)")
                    }
                }
            }
        }
        
        do {
            try process.run()
            print("[Swift-Whisper] Subprocess started successfully.")
        } catch {
            print("[Swift-Whisper] Failed to run subprocess: \(error)")
        }
    }
    
    func transcribe(jobJson: String) {
        lock.lock()
        let currentStdin = stdinPipe
        lock.unlock()
        guard let stdinPipe = currentStdin else { return }
        
        let inputLine = jobJson + "\n"
        if let data = inputLine.data(using: .utf8) {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                print("[Swift-Whisper] Wrote job JSON to worker stdin.")
            } catch {
                print("[Swift-Whisper] Failed to write job to worker: \(error)")
            }
        }
    }
    
    func stop() {
        lock.lock()
        let currentStdout = stdoutPipe
        let currentStderr = stderrPipe
        let currentProcess = process
        lock.unlock()
        
        currentStdout?.fileHandleForReading.readabilityHandler = nil
        currentStderr?.fileHandleForReading.readabilityHandler = nil
        if let process = currentProcess, process.isRunning {
            process.terminate()
            print("[Swift-Whisper] Subprocess terminated.")
        }
    }
    
    deinit {
        stop()
    }
}

struct MultiSpeakerWhisperResult: Codable {
    let speaker: String
    let text: String
    let segments: [WhisperSegment]
}

struct MultiSpeakerWhisperResponse: Codable {
    let results: [MultiSpeakerWhisperResult]
}

struct WhisperSegment: Codable {
    let start: Double
    let end: Double
    let text: String
}
