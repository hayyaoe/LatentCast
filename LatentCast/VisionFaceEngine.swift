//
//  VisionFaceEngine.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import Vision
import AVFoundation
import Combine

// Data structure for UI consumption
struct ActiveFaceInfo: Identifiable, Sendable {
    let id: UUID
    let boundingBox: CGRect // Normalized Apple Vision coordinates (0,0 is bottom-left)
    let lipVariance: Double
    let isActiveSpeaker: Bool
    let landmarks: [String: [CGPoint]]
}

// Thread-safe internal tracking model
private struct FaceTrack: Identifiable, Sendable {
    let id: UUID
    var lastCentroid: CGPoint
    var lastActiveTime: Date
    var lipHeights: [CGFloat]
}

class VisionFaceEngine: ObservableObject, @unchecked Sendable {
    @Published var activeTracks: [ActiveFaceInfo] = []
    @Published var lastLog: String = ""
    
    private let visionQueue = DispatchQueue(label: "com.latentcast.visionQueue", qos: .userInitiated)
    private var isProcessing = false
    private let lock = NSLock()
    
    // Internal tracking parameters (protected by lock)
    private var tracks: [FaceTrack] = []
    private var safeTracksCache: [ActiveFaceInfo] = []
    private let maxHistoryLength = 60    // ~1s of frames at 30fps
    private let trackingThreshold: CGFloat = 0.15 // Centroid distance threshold
    private let trackTimeout: TimeInterval = 1.5   // Delete track if inactive for > 1.5s
    private let speakThreshold: Double = 0.0003   // Variance above this = speaking
    
    // Thread-safe access to current tracked faces (for audio processing queue)
    var safeActiveTracks: [ActiveFaceInfo] {
        lock.lock()
        defer { lock.unlock() }
        return safeTracksCache
    }
    
    nonisolated func processFrame(_ sendableBuffer: SendablePixelBuffer) {
        visionQueue.async {
            self.lock.lock()
            if self.isProcessing {
                self.lock.unlock()
                return // Drop frame to prevent queue build-up and ANE overload
            }
            self.isProcessing = true
            self.lock.unlock()
            
            defer {
                self.lock.lock()
                self.isProcessing = false
                self.lock.unlock()
            }
            
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: sendableBuffer.buffer, options: [:])
            let request = VNDetectFaceLandmarksRequest()
            
            // Vision automatically handles Neural Engine scheduling on Apple Silicon by default
            
            do {
                try requestHandler.perform([request])
                if let results = request.results {
                    self.handleVisionResults(results)
                }
            } catch {
                self.updateLog("Vision request error: \(error.localizedDescription)")
            }
        }
    }
    
    private func handleVisionResults(_ results: [VNFaceObservation]) {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        
        // 1. Clean up stale tracks (faces that left the frame)
        tracks.removeAll { now.timeIntervalSince($0.lastActiveTime) > trackTimeout }
        
        var currentFrameInfos: [ActiveFaceInfo] = []
        
        for face in results {
            let bbox = face.boundingBox
            let centroid = CGPoint(x: bbox.midX, y: bbox.midY)
            
            // 2. Extract outer lips points
            guard let landmarks = face.landmarks,
                  let outerLips = landmarks.outerLips else { continue }
            
            let points = outerLips.normalizedPoints
            let Ys = points.map { $0.y }
            let maxY = Ys.max() ?? 0.0
            let minY = Ys.min() ?? 0.0
            let lipHeight = maxY - minY
            
            // 3. Find matching track using centroid distance
            var matchedIndex: Int?
            var bestDistance = CGFloat.infinity
            
            for i in 0..<tracks.count {
                let dist = distance(centroid, tracks[i].lastCentroid)
                if dist < bestDistance && dist < trackingThreshold {
                    bestDistance = dist
                    matchedIndex = i
                }
            }
            
            let trackId: UUID
            var rollingHeights: [CGFloat] = []
            
            if let idx = matchedIndex {
                trackId = tracks[idx].id
                rollingHeights = tracks[idx].lipHeights
                rollingHeights.append(lipHeight)
                if rollingHeights.count > maxHistoryLength {
                    rollingHeights.removeFirst()
                }
                
                // Update existing track info
                tracks[idx].lastCentroid = centroid
                tracks[idx].lastActiveTime = now
                tracks[idx].lipHeights = rollingHeights
            } else {
                // Spawn a new track ID for newly entered face
                trackId = UUID()
                rollingHeights = [lipHeight]
                let newTrack = FaceTrack(
                    id: trackId,
                    lastCentroid: centroid,
                    lastActiveTime: now,
                    lipHeights: rollingHeights
                )
                tracks.append(newTrack)
            }
            
            // 4. Calculate temporal lip variance
            let variance = calculateVariance(rollingHeights)
            let isSpeaking = variance > speakThreshold
            
            var landmarksDict: [String: [CGPoint]] = [:]
            if let leftEye = landmarks.leftEye {
                landmarksDict["leftEye"] = leftEye.normalizedPoints
            }
            if let rightEye = landmarks.rightEye {
                landmarksDict["rightEye"] = rightEye.normalizedPoints
            }
            if let leftEyebrow = landmarks.leftEyebrow {
                landmarksDict["leftEyebrow"] = leftEyebrow.normalizedPoints
            }
            if let rightEyebrow = landmarks.rightEyebrow {
                landmarksDict["rightEyebrow"] = rightEyebrow.normalizedPoints
            }
            if let nose = landmarks.nose {
                landmarksDict["nose"] = nose.normalizedPoints
            }
            if let outerLips = landmarks.outerLips {
                landmarksDict["outerLips"] = outerLips.normalizedPoints
            }
            if let innerLips = landmarks.innerLips {
                landmarksDict["innerLips"] = innerLips.normalizedPoints
            }
            if let faceContour = landmarks.faceContour {
                landmarksDict["faceContour"] = faceContour.normalizedPoints
            }
            
            currentFrameInfos.append(
                ActiveFaceInfo(
                    id: trackId,
                    boundingBox: bbox,
                    lipVariance: variance,
                    isActiveSpeaker: isSpeaking,
                    landmarks: landmarksDict
                )
            )
        }
        
        // Update thread-safe cache
        self.safeTracksCache = currentFrameInfos
        
        // 5. Publish snapshot back to UI on MainActor
        let tracksSnapshot = currentFrameInfos
        let logText = results.isEmpty ? "" : "[Vision] Tracked \(results.count) faces. Active: \(tracksSnapshot.filter { $0.isActiveSpeaker }.count) (LipVar: \(String(format: "%.5f", tracksSnapshot.first?.lipVariance ?? 0)))"
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeTracks = tracksSnapshot
            if !logText.isEmpty {
                self.lastLog = logText
            }
        }
    }
    
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        return sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2))
    }
    
    private func calculateVariance(_ values: [CGFloat]) -> Double {
        guard values.count >= 2 else { return 0.0 }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let sumOfSquaredDiffs = values.reduce(0) { $0 + pow($1 - mean, 2) }
        return Double(sumOfSquaredDiffs / CGFloat(values.count))
    }
    
    nonisolated private func updateLog(_ message: String) {
        Task { @MainActor in
            self.lastLog = "[Vision] \(message)"
            print("[VisionFaceEngine] \(message)")
        }
    }
}
