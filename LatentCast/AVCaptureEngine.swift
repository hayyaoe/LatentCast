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
    
    nonisolated let session = AVCaptureSession()
    nonisolated private let videoOutput = AVCaptureVideoDataOutput()
    
    private let sessionQueue = DispatchQueue(label: "com.latentcast.sessionQueue", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.latentcast.videoQueue", qos: .userInitiated)
    private var videoDelegate: VideoDelegate?
    nonisolated let frameHandler = FrameHandler()
    
    override init() {
        super.init()
        setupSession()
    }
    
    private func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            
            // 1. Set preset to high quality (typically 1080p or 720p depending on camera)
            if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            }
            
            // 2. Discover default camera
            guard let camera = AVCaptureDevice.default(for: .video) else {
                self.updateLog("Error: No camera device found.")
                self.session.commitConfiguration()
                return
            }
            
            // 3. Add input
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
            
            // 4. Add video output with standard non-isolated delegate helper
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) // NV12
            ]
            
            let delegate = VideoDelegate(
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
            
            self.videoOutput.setSampleBufferDelegate(delegate, queue: self.videoQueue)
            
            // Save reference to prevent deallocation
            DispatchQueue.main.async {
                self.videoDelegate = delegate
            }
            
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
                self.updateLog("Video data output configured successfully.")
            } else {
                self.updateLog("Error: Could not add video output to session.")
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
