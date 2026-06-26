//
//  VideoDelegate.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import AVFoundation

// A thread-safe wrapper to pass CVPixelBuffer across Sendable boundaries
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

// Decoupled from MainActor, runs entirely on background capture queues
class VideoDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var frameCount = 0
    private var lastFPSUpdateTime = Date()
    private let onFPSUpdated: @Sendable (Double, Int) -> Void
    private let onFrameCaptured: @Sendable (SendablePixelBuffer) -> Void
    
    init(onFPSUpdated: @escaping @Sendable (Double, Int) -> Void,
         onFrameCaptured: @escaping @Sendable (SendablePixelBuffer) -> Void) {
        self.onFPSUpdated = onFPSUpdated
        self.onFrameCaptured = onFrameCaptured
        super.init()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 1. Pass frame buffer forward if valid
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            onFrameCaptured(SendablePixelBuffer(buffer: imageBuffer))
        }
        
        // 2. Measure FPS
        frameCount += 1
        let now = Date()
        let timeInterval = now.timeIntervalSince(lastFPSUpdateTime)
        
        if timeInterval >= 1.0 {
            let calculatedFPS = Double(frameCount) / timeInterval
            onFPSUpdated(calculatedFPS, frameCount)
            
            frameCount = 0
            lastFPSUpdateTime = now
        }
    }
}
