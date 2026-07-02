//
//  AVCaptureEngine.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import AVFoundation
import Combine
import CoreImage

@MainActor
class AVCaptureEngine: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var fps: Double = 0.0
    @Published var lastLog: String = ""
    @Published var audioLevel: Float = 0.0
    @Published var videoDelay: Double = 4.0 {
        didSet {
            pipelineRefs.videoDelay = videoDelay
        }
    }
    
    nonisolated let session = AVCaptureSession()
    nonisolated private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated private let audioOutput = AVCaptureAudioDataOutput()
    
    private let sessionQueue = DispatchQueue(label: "com.latentcast.sessionQueue", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.latentcast.videoQueue", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.latentcast.audioQueue", qos: .userInitiated)
    
    private var videoDelegate: VideoDelegate?
    private var audioDelegate: AudioDelegate?
    
    nonisolated let frameHandler = FrameHandler()
    nonisolated let audioHandler = AudioHandler()
    nonisolated private let compositor = VideoCompositor()
    nonisolated private let cloner = PixelBufferCloner()
    

    
    nonisolated private let pipelineRefs = PipelineReferences()
    
    nonisolated var faceEngine: VisionFaceEngine? {
        get { pipelineRefs.faceEngine }
        set { pipelineRefs.faceEngine = newValue }
    }
    
    nonisolated var pythonBridge: PythonBridge? {
        get { pipelineRefs.pythonBridge }
        set {
            print("[AVCaptureEngine] pythonBridge property set to: \(newValue != nil ? "non-nil" : "nil")")
            pipelineRefs.pythonBridge = newValue
        }
    }
    
    override init() {
        super.init()
        setupSession()
    }
    
    private func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            
            // 1. Set preset to high quality
            if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            }
            
            // 2. Add Video Input (Camera)
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            ).devices
            
            let selectedCamera: AVCaptureDevice?
            if let physicalBuiltIn = devices.first(where: { $0.deviceType == .builtInWideAngleCamera && !$0.localizedName.lowercased().contains("virtual") }) {
                selectedCamera = physicalBuiltIn
            } else if let physicalExternal = devices.first(where: { !$0.localizedName.lowercased().contains("virtual") && !$0.localizedName.lowercased().contains("obs") && !$0.localizedName.lowercased().contains("streamlabs") }) {
                selectedCamera = physicalExternal
            } else {
                selectedCamera = AVCaptureDevice.default(for: .video)
            }
            
            if let camera = selectedCamera {
                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.updateLog("Camera input configured: \(camera.localizedName)")
                    } else {
                        self.updateLog("Error: Could not add camera input to session.")
                    }
                } catch {
                    self.updateLog("Error configuring camera input: \(error.localizedDescription)")
                }
            } else {
                self.updateLog("Error: No camera device found.")
            }
            
            // 3. Add Audio Input (Microphone)
            if let microphone = AVCaptureDevice.default(for: .audio) {
                do {
                    let input = try AVCaptureDeviceInput(device: microphone)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.updateLog("Microphone input configured: \(microphone.localizedName)")
                    } else {
                        self.updateLog("Error: Could not add microphone input to session.")
                    }
                } catch {
                    self.updateLog("Error configuring microphone input: \(error.localizedDescription)")
                }
            } else {
                self.updateLog("Error: No microphone device found.")
            }
            
            // 4. Add Video Output (NV12)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
            
            let vDelegate = VideoDelegate(
                onFPSUpdated: { [weak self] calculatedFPS, totalFrames in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.fps = calculatedFPS
                        self.lastLog = "[Camera] Captured \(totalFrames) frames (FPS: \(String(format: "%.1f", calculatedFPS)))"
                    }
                },
                onFrameCaptured: { [weak self] sendableBuffer in
                    guard let self = self else { return }
                    
                    // 1. Run face tracking asynchronously on the raw frame (needed for VAD and UI overlay)
                    let fEngine = self.faceEngine
                    fEngine?.processFrame(sendableBuffer)
                    
                    // If the Clean Feed window is closed, bypass the heavy video compositing pipeline
                    guard CleanFeedCoordinator.shared.isWindowOpen else {
                        self.frameHandler.handle(sendableBuffer)
                        return
                    }
                    
                    // 2. Fetch the current active speaker bounding boxes and UUIDs via spatial association tracking
                    let tracks = fEngine?.safeActiveTracks ?? []
                    let activeSpeakers = self.pipelineRefs.updateActiveSpeakers(with: tracks)
                    
                    // 3. Deep-copy the pixel buffer from our reusable cloner pool to avoid memory allocations
                    guard let clonedBuffer = self.cloner.clone(sendableBuffer.buffer) else {
                        self.frameHandler.handle(sendableBuffer)
                        return
                    }
                    
                    // 4. Enqueue in the delay buffer
                    let now = Date()
                    let delayedFrame = DelayedFrame(pixelBuffer: clonedBuffer, activeSpeakers: activeSpeakers, timestamp: now)
                    
                    self.pipelineRefs.appendFrame(delayedFrame)
                    let frameToProcess = self.pipelineRefs.popFrameIfReady()
                    
                    // If we haven't buffered enough frames yet, bypass processing (but keep the raw flow going)
                    guard let targetFrame = frameToProcess else {
                        self.frameHandler.handle(sendableBuffer)
                        return
                    }
                    
                    // 5. Fetch subtitles specifically for the speakers at the target frame's timestamp
                    var leftSubtitle = ""
                    var rightSubtitle = ""
                    
                    let pyBridge = self.pythonBridge
                    let frameTimestamp = targetFrame.timestamp.timeIntervalSince1970
                    
                    if targetFrame.activeSpeakers.count == 1 {
                        let id = targetFrame.activeSpeakers[0].id
                        let speakerLabel = pyBridge?.speakerLabel(for: id.uuidString) ?? ""
                        leftSubtitle = pyBridge?.subtitle(for: frameTimestamp, speaker: speakerLabel) ?? ""
                    } else if targetFrame.activeSpeakers.count == 2 {
                        let sorted = targetFrame.activeSpeakers.sorted { $0.box.origin.x < $1.box.origin.x }
                        
                        let leftId = sorted[0].id
                        let leftSpeakerLabel = pyBridge?.speakerLabel(for: leftId.uuidString) ?? ""
                        leftSubtitle = pyBridge?.subtitle(for: frameTimestamp, speaker: leftSpeakerLabel) ?? ""
                        
                        let rightId = sorted[1].id
                        let rightSpeakerLabel = pyBridge?.speakerLabel(for: rightId.uuidString) ?? ""
                        rightSubtitle = pyBridge?.subtitle(for: frameTimestamp, speaker: rightSpeakerLabel) ?? ""
                    } else {
                        leftSubtitle = pyBridge?.subtitle(for: frameTimestamp, speaker: "") ?? ""
                    }
                    
                    // 6. Pass the delayed frame to the compositor
                    if let output = self.compositor.processFrame(
                        pixelBuffer: targetFrame.pixelBuffer,
                        activeSpeakers: targetFrame.activeSpeakers,
                        leftSubtitle: leftSubtitle,
                        rightSubtitle: rightSubtitle
                    ) {
                        let sendableFrame = SendablePixelBuffer(buffer: output.pixelBuffer)
                        Task { @MainActor in
                            CleanFeedCoordinator.shared.processedFrame = sendableFrame
                        }
                        
                        // Send to Python Virtual Camera
                        if ProcessInfo.processInfo.environment["DISABLE_VIRTUAL_CAMERA"] != "1" {
                            if let pyBridge = self.pythonBridge {
                                pyBridge.sendProcessedFrame(SendablePixelBuffer(buffer: output.pixelBuffer))
                            }
                        }
                    }
                    
                    self.frameHandler.handle(sendableBuffer)
                }
            )
            
            self.videoOutput.setSampleBufferDelegate(vDelegate, queue: self.videoQueue)
            
            // 5. Add Audio Output (16kHz Mono Float32 PCM)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            self.audioOutput.audioSettings = audioSettings
            
            let aDelegate = AudioDelegate(
                onAudioSamples: { [weak self] samples in
                    guard let self = self else { return }
                    self.audioHandler.handle(samples)
                    
                    // Compute decibels level for UI VU Meter
                    let sampleCount = samples.count
                    guard sampleCount > 0 else { return }
                    var sumSq: Float = 0.0
                    for s in samples {
                        sumSq += s * s
                    }
                    let rms = sqrt(sumSq / Float(sampleCount))
                    let level = rms > 0 ? 20 * log10(rms) : -100.0
                    
                    Task { @MainActor in
                        // Map -60dB -> 0dB to 0.0 -> 1.0 range
                        self.audioLevel = max(0.0, min(1.0, (level + 60.0) / 60.0))
                    }
                }
            )
            
            self.audioOutput.setSampleBufferDelegate(aDelegate, queue: self.audioQueue)
            
            // Save references on MainActor to prevent deallocation
            DispatchQueue.main.async {
                self.videoDelegate = vDelegate
                self.audioDelegate = aDelegate
            }
            
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
                self.updateLog("Video data output configured successfully.")
            } else {
                self.updateLog("Error: Could not add video output to session.")
            }
            
            if self.session.canAddOutput(self.audioOutput) {
                self.session.addOutput(self.audioOutput)
                self.updateLog("Audio data output configured successfully.")
            } else {
                self.updateLog("Error: Could not add audio output to session.")
            }
            
            self.session.commitConfiguration()
        }
    }
    
    func startSession() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            
            DispatchQueue.main.async {
                self.isSessionRunning = true
                self.lastLog = "[System] Video capture session started."
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            
            DispatchQueue.main.async {
                self.isSessionRunning = false
                self.fps = 0.0
                self.audioLevel = 0.0
                self.lastLog = "[System] Video capture session stopped."
            }
        }
    }
    
    nonisolated private func updateLog(_ message: String) {
        Task { @MainActor in
            self.lastLog = message
            print("[AVCaptureEngine] \(message)")
        }
    }
}

// Thread-safe frame callback router
class FrameHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (SendablePixelBuffer) -> Void)?
    
    func setCallback(_ callback: @escaping @Sendable (SendablePixelBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.callback = callback
    }
    
    func handle(_ frame: SendablePixelBuffer) {
        lock.lock()
        let currentCallback = self.callback
        lock.unlock()
        currentCallback?(frame)
    }
}

// Thread-safe audio callback router
class AudioHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable ([Float]) -> Void)?
    
    func setCallback(_ callback: @escaping @Sendable ([Float]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.callback = callback
    }
    
    func handle(_ samples: [Float]) {
        lock.lock()
        let currentCallback = self.callback
        lock.unlock()
        currentCallback?(samples)
    }
}

fileprivate struct DelayedFrame {
    let pixelBuffer: CVPixelBuffer
    let activeSpeakers: [(id: UUID, box: CGRect)]
    let timestamp: Date
}

// Thread-safe wrapper to hold pipeline references outside MainActor class context
private final class PipelineReferences: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _faceEngine: VisionFaceEngine?
    private weak var _pythonBridge: PythonBridge?
    private var _videoDelay: Double = 4.0
    private var _delayedFrames: [DelayedFrame] = []
    
    var videoDelay: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _videoDelay
        }
        set {
            lock.lock()
            _videoDelay = newValue
            lock.unlock()
        }
    }
    
    var faceEngine: VisionFaceEngine? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _faceEngine
        }
        set {
            lock.lock()
            _faceEngine = newValue
            lock.unlock()
        }
    }
    
    var pythonBridge: PythonBridge? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _pythonBridge
        }
        set {
            lock.lock()
            _pythonBridge = newValue
            lock.unlock()
        }
    }
    
    func appendFrame(_ frame: DelayedFrame) {
        lock.lock()
        _delayedFrames.append(frame)
        lock.unlock()
    }
    
    func popFrameIfReady() -> DelayedFrame? {
        lock.lock()
        defer { lock.unlock() }
        
        // Limit buffer memory growth to prevent leaks under extreme stalls (max 150 frames)
        while _delayedFrames.count > 150 {
            _ = _delayedFrames.removeFirst()
        }
        
        let now = Date()
        if let first = _delayedFrames.first, now.timeIntervalSince(first.timestamp) >= _videoDelay {
            return _delayedFrames.removeFirst()
        }
        return nil
    }
    
    // Stateful active speakers
    private var activeSpeakers: [ActiveSpeakerState] = []
    
    func updateActiveSpeakers(with tracks: [ActiveFaceInfo]) -> [(id: UUID, box: CGRect)] {
        let now = Date()
        
        // Helper to calculate centroid distance
        func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
            let dx = p1.x - p2.x
            let dy = p1.y - p2.y
            return sqrt(dx*dx + dy*dy)
        }
        
        // 1. Match tracks to existing speakers spatially
        for track in tracks {
            let trackCentroid = CGPoint(x: track.boundingBox.midX, y: track.boundingBox.midY)
            
            var matchedIndex: Int? = nil
            var bestDistance = CGFloat.infinity
            
            for i in 0..<activeSpeakers.count {
                let speakerCentroid = CGPoint(x: activeSpeakers[i].lastKnownBox.midX, y: activeSpeakers[i].lastKnownBox.midY)
                let dist = distance(trackCentroid, speakerCentroid)
                if dist < bestDistance && dist < 0.25 {
                    bestDistance = dist
                    matchedIndex = i
                }
            }
            
            if let idx = matchedIndex {
                // Update existing speaker
                activeSpeakers[idx].lastKnownBox = track.boundingBox
                activeSpeakers[idx].lastTimeDetected = now
                if track.isActiveSpeaker {
                    activeSpeakers[idx].lastTimeSpoke = now
                }
            } else if track.isActiveSpeaker {
                // Add new speaker
                let newSpeaker = ActiveSpeakerState(
                    id: track.id,
                    lastKnownBox: track.boundingBox,
                    lastTimeDetected: now,
                    lastTimeSpoke: now
                )
                activeSpeakers.append(newSpeaker)
            }
        }
        
        // 2. Clean up stale speakers (not detected for 1.2s OR stopped speaking for 3.0s)
        activeSpeakers.removeAll { speaker in
            let notDetected = now.timeIntervalSince(speaker.lastTimeDetected) > 1.2
            let stoppedSpeaking = now.timeIntervalSince(speaker.lastTimeSpoke) > 3.0
            return notDetected || stoppedSpeaking
        }
        
        // 3. Fallback: if no active speakers, but 1 face is currently tracked, keep focus on them
        if activeSpeakers.isEmpty {
            if tracks.count == 1 {
                return [(id: tracks[0].id, box: tracks[0].boundingBox)]
            }
            return []
        }
        
        return activeSpeakers.map { ($0.id, $0.lastKnownBox) }
    }
}

fileprivate struct ActiveSpeakerState {
    var id: UUID
    var lastKnownBox: CGRect
    var lastTimeDetected: Date
    var lastTimeSpoke: Date
}

/// Helper class to clone/deep-copy a CVPixelBuffer using a GPU-accelerated CIContext to avoid high-frequency CPU locks and copies
class PixelBufferCloner: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: OSType = 0
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: true
    ])
    
    func clone(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        
        lock.lock()
        if pool == nil || poolWidth != width || poolHeight != height || poolFormat != format {
            poolWidth = width
            poolHeight = height
            poolFormat = format
            
            let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: 150] as CFDictionary
            let bufferAttrs = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true
            ] as CFDictionary
            
            var newPool: CVPixelBufferPool? = nil
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, bufferAttrs, &newPool)
            if status == kCVReturnSuccess {
                pool = newPool
                print("[PixelBufferCloner] Re-created GPU-compatible CVPixelBufferPool: \(width)x\(height)")
            } else {
                print("[PixelBufferCloner] Failed to create CVPixelBufferPool status: \(status)")
                lock.unlock()
                return nil
            }
        }
        
        guard let currentPool = pool else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        
        var dst: CVPixelBuffer? = nil
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, currentPool, &dst)
        guard status == kCVReturnSuccess, let output = dst else { return nil }
        
        // GPU copy via Core Image (no CPU cache synchronization or lock overhead)
        let ciImage = CIImage(cvPixelBuffer: src)
        ciContext.render(ciImage, to: output)
        return output
    }
}
