//
//  VideoDelegate.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import AVFoundation

// Decoupled from MainActor, runs entirely on background capture queues
actor VideoDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var frameCount = 0
    private var lastFPSUpdateTime = Date()
    private let onFPSUpdated: @Sendable (Double, Int) -> Void
    
    init(onFPSUpdated: @escaping @Sendable (Double, Int) -> Void) {
        self.onFPSUpdated = onFPSUpdated
        super.init()
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            Task {
                await self.updateFPS()
            }
        }
        
        private func updateFPS() {
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
