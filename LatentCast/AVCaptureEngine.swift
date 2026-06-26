//
//  AVCaptureEngine.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import AVFoundation
import Combine

@MainActor
class AVCaptureEngine: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var fps: Double = 0.0
    @Published var lastLog: String = ""
    @Published var audioLevel: Float = 0.0
    
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
            if let camera = AVCaptureDevice.default(for: .video) {
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
