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
    var lastSpeakTime: Date?
}

class VisionFaceEngine: ObservableObject, @unchecked Sendable {
    @Published var activeTracks: [ActiveFaceInfo] = []
    @Published var lastLog: String = ""
    
    private let visionQueue = DispatchQueue(label: "com.latentcast.visionQueue", qos: .userInitiated)
    private var isProcessing = false
    private var frameCounter = 0
    private let lock = NSLock()
    
    // Internal tracking parameters (protected by lock)
    private var tracks: [FaceTrack] = []
    private var safeTracksCache: [ActiveFaceInfo] = []
    private let maxHistoryLength = 15    // Shortened for faster responsiveness (~1.5s at 10fps)
    private let trackingThreshold: CGFloat = 0.25 // Centroid distance matching threshold
    private let trackTimeout: TimeInterval = 1.5   // Delete track if inactive for > 1.5s
    private var speakThresholdInternal: Double = 0.00015   // Lowered threshold (now VAD-gated)
    private let speakDebounceDuration: TimeInterval = 3.0  // 3-second debounce hangover
    private var isVoiceActiveInternal = false
    
    var isVoiceActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return isVoiceActiveInternal
        }
        set {
            lock.lock()
            isVoiceActiveInternal = newValue
            lock.unlock()
        }
    }
    
    // Thread-safe public property for adjusting sensitivity from the UI
    var speakThreshold: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return speakThresholdInternal
        }
        set {
            lock.lock()
            speakThresholdInternal = newValue
            lock.unlock()
        }
    }
    
    // Thread-safe access to current tracked faces (for audio processing queue)
    var safeActiveTracks: [ActiveFaceInfo] {
        lock.lock()
        defer { lock.unlock() }
        return safeTracksCache
    }
    
    nonisolated func processFrame(_ sendableBuffer: SendablePixelBuffer) {
        self.lock.lock()
        self.frameCounter += 1
        let currentCount = self.frameCounter
        
        // Throttle landmarks detection to 10 FPS (1 out of 3 frames)
        // This cuts Neural Engine computation by 67% and completely removes UI video lag.
        if self.isProcessing || currentCount % 3 != 0 {
            self.lock.unlock()
            return
        }
        self.isProcessing = true
        self.lock.unlock()
        
        visionQueue.async {
            defer {
                self.lock.lock()
                self.isProcessing = false
                self.lock.unlock()
            }
            
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: sendableBuffer.buffer, options: [:])
            let request = VNDetectFaceLandmarksRequest()
            
            do {
                try requestHandler.perform([request])
                let results = request.results ?? []
                self.handleVisionResults(results)
            } catch {
                print("[Swift Vision] Request error: \(error.localizedDescription)")
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
            
            // 2. Extract outer lips points if available, otherwise fallback to 0.0
            var lipHeight: CGFloat = 0.0
            if let landmarks = face.landmarks,
               let outerLips = landmarks.outerLips {
                let points = outerLips.normalizedPoints
                let Ys = points.map { $0.y }
                let maxY = Ys.max() ?? 0.0
                let minY = Ys.min() ?? 0.0
                lipHeight = maxY - minY
            }
            
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
                    lipHeights: rollingHeights,
                    lastSpeakTime: nil
                )
                tracks.append(newTrack)
            }
            
            // 4. Calculate temporal lip variance and speaking state with neural VAD gate
            let variance = calculateVariance(rollingHeights)
            let rawSpeaking = self.isVoiceActiveInternal && (variance > speakThresholdInternal)
            
            // Update last speak time
            if rawSpeaking {
                if let idx = matchedIndex {
                    tracks[idx].lastSpeakTime = now
                } else if var lastTrack = tracks.last, lastTrack.id == trackId {
                    lastTrack.lastSpeakTime = now
                    tracks[tracks.count - 1] = lastTrack
                }
            }
            
            var isSpeaking = rawSpeaking
            if !rawSpeaking {
                let lastSpeak: Date?
                if let idx = matchedIndex {
                    lastSpeak = tracks[idx].lastSpeakTime
                } else {
                    lastSpeak = tracks.last?.lastSpeakTime
                }
                
                if let lastSpeakDate = lastSpeak, now.timeIntervalSince(lastSpeakDate) < speakDebounceDuration {
                    isSpeaking = true
                }
            }
            
            var landmarksDict: [String: [CGPoint]] = [:]
            if let landmarks = face.landmarks {
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
        
        if !logText.isEmpty {
            // Print to Xcode console only to keep SwiftUI layout pipeline quiet
            print("[VisionDebug] \(logText)")
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeTracks = tracksSnapshot
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
