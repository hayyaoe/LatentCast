//
//  VideoCompositor.swift
//  LatentCast
//
//  Created by Antigravity on 26/06/26.
//

import Foundation
import CoreImage
import CoreVideo
import CoreGraphics
import AppKit
import CoreText

struct CompositorOutput: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let cgImage: CGImage
}

class VideoCompositor: @unchecked Sendable {
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])
    
    private let subtitleRenderer = SubtitleRenderer()
    
    // Lerp state for smooth panning/zooming (protected by local lock)
    private let lock = NSLock()
    private var isInitialized = false
    private var currentCropRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private var targetCropRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    var lerpAlpha: CGFloat = 0.08  // Smoothing factor (approx 300ms transition time)
    
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 1920
    private var poolHeight = 1080
    
    init() {
        setupPixelBufferPool()
    }
    
    private func setupPixelBufferPool() {
        let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: 10] as CFDictionary
        let pixelBufferAttrs = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: poolWidth,
            kCVPixelBufferHeightKey as String: poolHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ] as CFDictionary
        
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, pixelBufferAttrs, &pixelBufferPool)
        if status != kCVReturnSuccess {
            print("[VideoCompositor] ERROR: CVPixelBufferPoolCreate failed with status: \(status)")
        } else {
            print("[VideoCompositor] Success: CVPixelBufferPool created successfully.")
        }
    }
    
    func processFrame(pixelBuffer: CVPixelBuffer, activeSpeakerBox: CGRect?, subtitle: String) -> CompositorOutput? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        lock.lock()
        // 0. Initialize crop rects dynamically on first frame based on actual frame size
        if !isInitialized {
            currentCropRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            targetCropRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            isInitialized = true
            print("[VideoCompositor] Success: Dynamic crop rects initialized to frame size: \(width)x\(height)")
        }
        
        // 1. Calculate Target Crop Box based on Active Speaker
        if let speakerBox = activeSpeakerBox {
            // Vision coordinates have origin at bottom-left, range [0, 1]
            let faceX = speakerBox.origin.x * CGFloat(width)
            let faceY = speakerBox.origin.y * CGFloat(height)
            let faceW = speakerBox.size.width * CGFloat(width)
            let faceH = speakerBox.size.height * CGFloat(height)
            
            // Pad the crop window to make it a pleasant portrait/landscape shot
            // We want the height of the crop to be 3.2x of the face height
            var cropH = min(CGFloat(height), faceH * 3.2)
            var cropW = cropH * (16.0 / 9.0)  // Maintain 16:9 ratio
            
            // Guard aspect ratio against narrow bounds (e.g. 4:3 inputs or side borders)
            if cropW > CGFloat(width) {
                cropW = CGFloat(width)
                cropH = cropW * (9.0 / 16.0)
            }
            
            // Center the crop window around the face
            var cropX = faceX + (faceW / 2.0) - (cropW / 2.0)
            var cropY = faceY + (faceH / 2.0) - (cropH / 2.0)
            
            // Keep bounds within original frame
            cropX = max(0, min(CGFloat(width) - cropW, cropX))
            cropY = max(0, min(CGFloat(height) - cropH, cropY))
            
            targetCropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        } else {
            // No active speaker -> zoom back to full frame
            targetCropRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        }
        
        // 2. Perform Lerp Interpolation for smooth panning/zooming
        currentCropRect.origin.x += lerpAlpha * (targetCropRect.origin.x - currentCropRect.origin.x)
        currentCropRect.origin.y += lerpAlpha * (targetCropRect.origin.y - currentCropRect.origin.y)
        currentCropRect.size.width += lerpAlpha * (targetCropRect.size.width - currentCropRect.size.width)
        currentCropRect.size.height += lerpAlpha * (targetCropRect.size.height - currentCropRect.size.height)
        
        let activeCropRect = currentCropRect
        lock.unlock()
        
        // 3. Crop and Scale back to 1080p
        var croppedImage = sourceImage.cropped(to: activeCropRect)
        
        // Translate origin to (0,0) before scaling so scale transform aligns correctly
        let translation = CGAffineTransform(translationX: -croppedImage.extent.origin.x, y: -croppedImage.extent.origin.y)
        croppedImage = croppedImage.transformed(by: translation)
        
        // Scale transform to 1920x1080
        let scaleX = CGFloat(poolWidth) / croppedImage.extent.width
        let scaleY = CGFloat(poolHeight) / croppedImage.extent.height
        croppedImage = croppedImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // Clean extent to avoid infinite bounds errors
        let scaledExtent = CGRect(x: 0, y: 0, width: CGFloat(poolWidth), height: CGFloat(poolHeight))
        croppedImage = croppedImage.cropped(to: scaledExtent)
        
        // 4. Burn Subtitles (translucent background text strip at bottom)
        var finalImage = croppedImage
        if let subtitleCG = subtitleRenderer.render(text: subtitle) {
            var subtitleCI = CIImage(cgImage: subtitleCG)
            // Flip vertically to align with Core Image's bottom-left origin
            let flipTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(subtitleCG.height))
            subtitleCI = subtitleCI.transformed(by: flipTransform)
            // Composite text overlay on top of scaled cropped frame (sits at bottom-left naturally)
            finalImage = subtitleCI.composited(over: croppedImage)
        }
        
        // 5. Render into output CVPixelBuffer
        guard let pool = pixelBufferPool else {
            print("[VideoCompositor] ERROR: pixelBufferPool is nil")
            return nil
        }
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        
        guard status == kCVReturnSuccess, let outBuffer = outputBuffer else {
            print("[VideoCompositor] ERROR: CVPixelBufferPoolCreatePixelBuffer failed with status: \(status)")
            return nil
        }
        
        ciContext.render(finalImage, to: outBuffer)
        
        // Create CGImage from finalImage for UI preview
        guard let cgImage = ciContext.createCGImage(finalImage, from: finalImage.extent) else {
            print("[VideoCompositor] ERROR: createCGImage failed. extent: \(finalImage.extent)")
            return nil
        }
        
        return CompositorOutput(pixelBuffer: outBuffer, cgImage: cgImage)
    }
}

// SubtitleRenderer handles text strip rendering via CoreText / CoreGraphics (thread-safe for background queue)
class SubtitleRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var cgContext: CGContext?
    private let width = 1920
    private let height = 120
    
    init() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        cgContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
    
    func render(text: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let context = cgContext else { return nil }
        
        // Clear context
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        
        if text.isEmpty {
            return nil
        }
        
        // Draw semi-transparent background
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // Centered paragraph text styling
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        // Use CTFont instead of NSFont for thread-safe background rendering
        let ctFont = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 34, nil)
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1), // white
            .paragraphStyle: paragraphStyle
        ]
        
        let attributedString = NSAttributedString(string: text, attributes: attrs)
        
        // Save graphics state and draw text in CoreText
        context.saveGState()
        
        // Flip the coordinate system for CoreText (origin is bottom-left)
        context.textMatrix = .identity
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        
        // Text drawing rectangle (centered vertically)
        // Flip the text rect since coordinate system is flipped
        let textRect = CGRect(x: 80, y: (CGFloat(height) - 48) / 2.0, width: CGFloat(width - 160), height: 50)
        let path = CGPath(rect: textRect, transform: nil)
        
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attributedString.length), path, nil)
        CTFrameDraw(frame, context)
        
        context.restoreGState()
        
        return context.makeImage()
    }
}
