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
    
    // Smooth split-screen divider position (defaults to full width)
    private var currentSplitX: CGFloat = 1920
    private var targetSplitX: CGFloat = 1920
    
    // Smooth crop rects for left and right panels
    private var currentCropLeft = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private var targetCropLeft = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    private var currentCropRight = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private var targetCropRight = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    // Track current mode for smooth transitions
    private var currentMode: ZoomMode = .fullFrame
    
    var lerpAlpha: CGFloat = 0.08  // Smoothing factor (approx 300ms transition time)
    
    private var pixelBufferPool: CVPixelBufferPool?
    private let poolWidth = 1920
    private let poolHeight = 1080
    
    enum ZoomMode {
        case fullFrame      // 0 or 3+ speakers
        case singleSpeaker  // 1 speaker
        case dualSpeaker    // 2 speakers
    }
    
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
    
    /// Calculates a crop rect centered on a face bounding box with padding matching the target aspect ratio
    /// `speakerBox` is in normalized Apple Vision coordinates (0,0 = bottom-left, range [0,1])
    private func cropRect(for speakerBox: CGRect, frameWidth: CGFloat, frameHeight: CGFloat, targetAspect: CGFloat) -> CGRect {
        let faceX = speakerBox.origin.x * frameWidth
        let faceY = speakerBox.origin.y * frameHeight
        let faceW = speakerBox.size.width * frameWidth
        let faceH = speakerBox.size.height * frameHeight
        
        // Pad the crop window: height = 3.2x face height
        var cropH = min(frameHeight, faceH * 3.2)
        var cropW = cropH * targetAspect
        
        // Prevent crop box from being narrower than the face itself
        if cropW < faceW {
            cropW = faceW
            cropH = cropW / targetAspect
        }
        
        // If crop window is too wide for the frame, scale down cropH to fit cropW
        if cropW > frameWidth {
            cropW = frameWidth
            cropH = cropW / targetAspect
        }
        
        // If crop window is too tall for the frame, scale down cropW to fit cropH
        if cropH > frameHeight {
            cropH = frameHeight
            cropW = cropH * targetAspect
        }
        
        // Center crop around the face
        var cropX = faceX + (faceW / 2.0) - (cropW / 2.0)
        var cropY = faceY + (faceH / 2.0) - (cropH / 2.0)
        
        // Clamp within frame bounds
        cropX = max(0, min(frameWidth - cropW, cropX))
        cropY = max(0, min(frameHeight - cropH, cropY))
        
        return CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
    }
    
    /// Applies lerp interpolation to smoothly transition between crop rects
    private func lerp(_ current: inout CGRect, toward target: CGRect) {
        current.origin.x += lerpAlpha * (target.origin.x - current.origin.x)
        current.origin.y += lerpAlpha * (target.origin.y - current.origin.y)
        current.size.width += lerpAlpha * (target.size.width - current.size.width)
        current.size.height += lerpAlpha * (target.size.height - current.size.height)
    }
    
    /// Crops, translates, and scales a CIImage region to a target pixel size
    private func cropAndScale(_ source: CIImage, rect: CGRect, targetWidth: CGFloat, targetHeight: CGFloat) -> CIImage {
        var cropped = source.cropped(to: rect)
        let translation = CGAffineTransform(translationX: -cropped.extent.origin.x, y: -cropped.extent.origin.y)
        cropped = cropped.transformed(by: translation)
        
        let extentWidth = cropped.extent.width > 0 ? cropped.extent.width : 1
        let extentHeight = cropped.extent.height > 0 ? cropped.extent.height : 1
        let scaleX = targetWidth / extentWidth
        let scaleY = targetHeight / extentHeight
        cropped = cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        return cropped.cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    }
    
    func processFrame(
        pixelBuffer: CVPixelBuffer,
        activeSpeakers: [(id: UUID, box: CGRect)],
        leftSubtitle: String,
        rightSubtitle: String
    ) -> CompositorOutput? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let fullFrameRect = CGRect(x: 0, y: 0, width: width, height: height)
        
        lock.lock()
        
        // Initialize crop rects on first frame
        if !isInitialized {
            currentCropLeft = fullFrameRect
            targetCropLeft = fullFrameRect
            currentCropRight = fullFrameRect
            targetCropRight = fullFrameRect
            currentSplitX = 1920
            targetSplitX = 1920
            isInitialized = true
            print("[VideoCompositor] Dynamic crop rects initialized to frame size: \(Int(width))x\(Int(height))")
        }
        
        // Determine zoom mode
        let mode: ZoomMode
        switch activeSpeakers.count {
        case 1: mode = .singleSpeaker
        case 2: mode = .dualSpeaker
        default: mode = .fullFrame  // 0 or 3+ speakers
        }
        
        var modeChanged = false
        if mode != currentMode {
            currentMode = mode
            modeChanged = true
        }
        
        // Update target split and crops
        switch mode {
        case .singleSpeaker:
            targetSplitX = 1920
            currentSplitX = targetSplitX
            
            let speaker = activeSpeakers[0].box
            let leftAspect = currentSplitX / 1080.0
            targetCropLeft = cropRect(for: speaker, frameWidth: width, frameHeight: height, targetAspect: leftAspect)
            
            // Right panel is unused, target crop goes to full frame
            targetCropRight = fullFrameRect
            
        case .dualSpeaker:
            targetSplitX = 960
            currentSplitX = targetSplitX
            
            let sorted = activeSpeakers.sorted { $0.box.origin.x < $1.box.origin.x }
            
            let leftAspect = currentSplitX / 1080.0
            targetCropLeft = cropRect(for: sorted[0].box, frameWidth: width, frameHeight: height, targetAspect: leftAspect)
            
            let rightW = max(50.0, 1920.0 - currentSplitX)
            let rightAspect = rightW / 1080.0
            targetCropRight = cropRect(for: sorted[1].box, frameWidth: width, frameHeight: height, targetAspect: rightAspect)
            
        case .fullFrame:
            targetSplitX = 1920
            currentSplitX = targetSplitX
            
            targetCropLeft = fullFrameRect
            targetCropRight = fullFrameRect
        }
        
        if modeChanged {
            currentCropLeft = targetCropLeft
            currentCropRight = targetCropRight
        } else {
            // Lerp crops smoothly for panning/zooming inside panels
            lerp(&currentCropLeft, toward: targetCropLeft)
            lerp(&currentCropRight, toward: targetCropRight)
        }
        
        let activeSplitX = currentSplitX
        let activeCropLeft = currentCropLeft
        let activeCropRight = currentCropRight
        
        lock.unlock()
        
        // Render panels
        let leftW = max(1.0, activeSplitX)
        let rightW = max(1.0, 1920.0 - activeSplitX)
        
        // Left Panel
        let leftPanel = cropAndScale(sourceImage, rect: activeCropLeft, targetWidth: leftW, targetHeight: 1080)
        var finalImage = leftPanel
        
        // Render left subtitle directly onto the left panel
        if let leftCG = subtitleRenderer.render(text: leftSubtitle, width: Int(leftW)) {
            var leftCI = CIImage(cgImage: leftCG)
            let flipTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(leftCG.height))
            leftCI = leftCI.transformed(by: flipTransform)
            finalImage = leftCI.composited(over: finalImage)
        }
        
        // Right Panel (only draw if visible)
        if rightW > 10.0 {
            let rightPanel = cropAndScale(sourceImage, rect: activeCropRight, targetWidth: rightW, targetHeight: 1080)
            
            var processedRight = rightPanel
            // Render right subtitle directly onto the right panel
            if let rightCG = subtitleRenderer.render(text: rightSubtitle, width: Int(rightW)) {
                var rightCI = CIImage(cgImage: rightCG)
                let flipTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(rightCG.height))
                rightCI = rightCI.transformed(by: flipTransform)
                processedRight = rightCI.composited(over: processedRight)
            }
            
            let shiftedRight = processedRight.transformed(by: CGAffineTransform(translationX: leftW, y: 0))
            
            // Overlay right panel over left panel
            let composite = shiftedRight.composited(over: finalImage)
            
            // Draw vertical divider line
            let dividerWidth: CGFloat = 3
            let dividerRect = CGRect(x: leftW - dividerWidth / 2, y: 0, width: dividerWidth, height: 1080)
            let dividerColor = CIColor(red: 1, green: 1, blue: 1, alpha: 0.4)
            let dividerImage = CIImage(color: dividerColor).cropped(to: dividerRect)
            
            finalImage = dividerImage.composited(over: composite)
        }
        
        // Clamp to full size
        finalImage = finalImage.cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        
        // Render into output CVPixelBuffer
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
        return CompositorOutput(pixelBuffer: outBuffer)
    }
}

// SubtitleRenderer handles text strip rendering via CoreText / CoreGraphics (thread-safe for background queue)
class SubtitleRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let height = 120
    
    func render(text: String, width: Int) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        
        if text.isEmpty {
            return nil
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // Draw semi-transparent background
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // Centered paragraph text styling
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        // Use CTFont instead of NSFont for thread-safe background rendering
        let ctFont = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 30, nil)
        
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
        let textRect = CGRect(x: 40, y: (CGFloat(height) - 48) / 2.0, width: CGFloat(width - 80), height: 60)
        let path = CGPath(rect: textRect, transform: nil)
        
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attributedString.length), path, nil)
        CTFrameDraw(frame, context)
        
        context.restoreGState()
        
        return context.makeImage()
    }
}
