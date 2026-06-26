//
//  PythonBridge.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import Combine
import PythonKit

// Thread-safe communication bridge with Python running in-process via PythonKit
class PythonBridge: ObservableObject, @unchecked Sendable {
    @Published var connectionStatus: String = "Initializing..."
    @Published var lastResponse: String = ""
    @Published var isProcessing: Bool = false
    @Published var liveTranscription: String = ""
    @Published var isVoiceActive: Bool = false
    @Published var silenceTimeoutMs: Double = 600.0
    @Published var fusionThreshold: Double = 0.00010
    
    private var pyEngine: PythonObject?
    private let pythonQueue = DispatchQueue(label: "com.latentcast.pythonQueue", qos: .userInitiated)
    private let lock = NSLock()
    
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
    
    init() {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        self.projectPath = projectRoot.path
        setupPythonEnvironment()
    }
    
    /// Dynamically loads PyGILState_Ensure/Release from libpython via dlsym
    private func setupGILFunctions() {
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            print("[GIL] Warning: Failed to open global symbol table")
            return
        }
        defer { dlclose(handle) }
        
        if let ensureSym = dlsym(handle, "PyGILState_Ensure"),
           let releaseSym = dlsym(handle, "PyGILState_Release") {
            gilEnsure = unsafeBitCast(ensureSym, to: GILEnsureFunc.self)
            gilRelease = unsafeBitCast(releaseSym, to: GILReleaseFunc.self)
            print("[GIL] PyGILState_Ensure/Release loaded successfully")
        } else {
            print("[GIL] Warning: Could not find PyGILState symbols - GIL safety disabled")
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
        print("[PythonBridge] Setting up Python environment...")
        
        // 1. Point PythonKit to Miniconda's shared library dynamically based on real home directory
        let homeDir: String
        if let pw = getpwuid(getuid()) {
            homeDir = String(cString: pw.pointee.pw_dir)
        } else {
            homeDir = NSHomeDirectory()
        }
        
        let pythonLibPath = "\(homeDir)/miniconda3/lib/libpython3.13.dylib"
        print("[PythonBridge] Resolved home directory: \(homeDir)")
        print("[PythonBridge] Setting PYTHON_LIBRARY to: \(pythonLibPath)")
        
        if FileManager.default.fileExists(atPath: pythonLibPath) {
            print("[PythonBridge] Success: Python library found at target path.")
        } else {
            print("[PythonBridge] WARNING: Python library file does not exist at: \(pythonLibPath)")
        }
        
        setenv("PYTHON_LIBRARY", pythonLibPath, 1)
        
        // 2. Set PYTHONPATH to locate the workspace and virtual environment dependencies dynamically
        let sitePackages = "\(projectPath)/.venv/lib/python3.13/site-packages"
        print("[PythonBridge] Setting PYTHONPATH to: \(projectPath):\(sitePackages)")
        setenv("PYTHONPATH", "\(projectPath):\(sitePackages)", 1)
        
        pythonQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                print("[PythonBridge] Attempting to import bridge_logic module...")
                let bridgeLogic = try Python.attemptImport("bridge_logic")
                
                // Initialize GIL management functions now that Python library is loaded
                self.setupGILFunctions()
                
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
                    let worker = WhisperWorker(projectPath: self.projectPath)
                    worker.onTranscriptionReceived = { [weak self] text in
                        guard let self = self else { return }
                        let speaker = self.dequeueSpeakerLabel()
                        let fullTranscription = "[\(speaker)]: \(text)"
                        Task { @MainActor in
                            self.liveTranscription = fullTranscription
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
        pythonQueue.async { [weak self] in
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
        pythonQueue.async { [weak self] in
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
        self.lock.unlock()
        guard isReady else { return }
        
        let count = samples.count
        guard count > 0 else { return }
        
        // 1. Allocate a heap buffer and copy samples.
        // We pass the raw memory address to Python to bypass PythonKit conversion overhead.
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(from: samples, count: count)
        let address = Int(bitPattern: buffer)
        
        // 2. Pre-extract face IDs and variances into standard arrays
        let faceIds = activeFaces.map { $0.id.uuidString }
        let faceVariances = activeFaces.map { $0.lipVariance }
        
        pythonQueue.async { [weak self] in
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
            self.lock.unlock()
            
            self.withGIL {
                let response = engine.process_audio_chunk_ptr(address, count, faceIds, faceVariances)
                
                let isSpeaking = Bool(response["is_speaking"]) ?? false
                let wavPath = String(response["wav_path"]) ?? ""
                let speakerLabel = String(response["speaker_label"]) ?? ""
                
                if !wavPath.isEmpty {
                    let cleanLabel = speakerLabel.isEmpty ? "Unknown Speaker" : speakerLabel
                    self.enqueueSpeakerLabel(cleanLabel)
                    self.whisperWorker?.transcribe(wavPath: wavPath)
                }
                
                Task { @MainActor in
                    self.isVoiceActive = isSpeaking
                }
            }
        }
    }
}

// MARK: - Whisper Subprocess Manager (Pure Swift — No Python)

class WhisperWorker: @unchecked Sendable {
    private let projectPath: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let lock = NSLock()
    
    var onTranscriptionReceived: (@Sendable (String) -> Void)?
    
    init(projectPath: String) {
        self.projectPath = projectPath
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
        process.arguments = ["\(projectPath)/transcribe_worker.py"]
        
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
    
    func transcribe(wavPath: String) {
        lock.lock()
        let currentStdin = stdinPipe
        lock.unlock()
        guard let stdinPipe = currentStdin else { return }
        
        let inputLine = wavPath + "\n"
        if let data = inputLine.data(using: .utf8) {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                print("[Swift-Whisper] Wrote path to worker stdin: \(wavPath)")
            } catch {
                print("[Swift-Whisper] Failed to write path to worker: \(error)")
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
