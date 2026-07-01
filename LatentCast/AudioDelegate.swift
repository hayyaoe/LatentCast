//
//  AudioDelegate.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import AVFoundation

// Background delegate for audio capture and format conversion
class AudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onAudioSamples: @Sendable ([Float]) -> Void
    private var printedFormat = false
    private var sampleBlockCount = 0
    
    init(onAudioSamples: @escaping @Sendable ([Float]) -> Void) {
        self.onAudioSamples = onAudioSamples
        super.init()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 1. Get raw PCM audio block buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let rawData = dataPointer else { return }
        
        // 2. Fetch format description and stream properties
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }
        
        // Debug format once to console
        if !printedFormat {
            print("[Audio Delegate Format] SampleRate: \(asbd.mSampleRate), FormatID: \(asbd.mFormatID), BitsPerChannel: \(asbd.mBitsPerChannel), Flags: \(asbd.mFormatFlags), BytesPerFrame: \(asbd.mBytesPerFrame)")
            printedFormat = true
        }
        
        var samples: [Float] = []
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = asbd.mBitsPerChannel
        
        // 3. Extract and normalize PCM samples to Float32 range [-1.0, 1.0]
        if isFloat && bitsPerChannel == 32 {
            // Float32 PCM
            let sampleCount = length / MemoryLayout<Float>.size
            rawData.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPointer in
                samples = Array(UnsafeBufferPointer(start: floatPointer, count: sampleCount))
            }
        } else if !isFloat && bitsPerChannel == 16 {
            // Int16 PCM
            let sampleCount = length / MemoryLayout<Int16>.size
            rawData.withMemoryRebound(to: Int16.self, capacity: sampleCount) { intPointer in
                let intBuffer = UnsafeBufferPointer(start: intPointer, count: sampleCount)
                samples = intBuffer.map { Float($0) / 32768.0 }
            }
        } else if !isFloat && bitsPerChannel == 32 {
            // Int32 PCM
            let sampleCount = length / MemoryLayout<Int32>.size
            rawData.withMemoryRebound(to: Int32.self, capacity: sampleCount) { intPointer in
                let intBuffer = UnsafeBufferPointer(start: intPointer, count: sampleCount)
                samples = intBuffer.map { Float($0) / 2147483648.0 }
            }
        } else {
            print("[Audio Delegate] Warning: Unsupported audio format. Float=\(isFloat), Bits=\(bitsPerChannel)")
            return
        }
        
        if !samples.isEmpty {
            // Apply 6.0x gain boost to ensure quiet microphones register clearly with Silero VAD
            let gain: Float = 6.0
            samples = samples.map { max(-1.0, min(1.0, $0 * gain)) }
            
            sampleBlockCount += 1
            if sampleBlockCount % 100 == 0 || sampleBlockCount <= 5 {
                let maxVal = samples.map(abs).max() ?? 0.0
                print("[Audio Delegate] Block #\(sampleBlockCount) processed \(samples.count) samples. Max amplitude: \(String(format: "%.5f", maxVal)) (Gain boosted)")
            }
            onAudioSamples(samples)
        }
    }
}
