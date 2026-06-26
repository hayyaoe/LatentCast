//
//  ContentView.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var permissionManager = PermissionManager()
    @StateObject private var captureEngine = AVCaptureEngine()
    @StateObject private var faceEngine = VisionFaceEngine()
    @State private var logs: [String] = ["[Idle] Ready. Waiting for user interaction."]
    
    var body: some View {
        HStack(spacing: 20) {
            // Left Column: Camera Preview + Face Tracking Overlay
            VStack {
                if captureEngine.isSessionRunning {
                    CameraPreview(session: captureEngine.session)
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .overlay(
                            GeometryReader { geometry in
                                ForEach(faceEngine.activeTracks) { track in
                                    let bbox = track.boundingBox
                                    let w = bbox.size.width * geometry.size.width
                                    let h = bbox.size.height * geometry.size.height
                                    let x = bbox.origin.x * geometry.size.width + w / 2
                                    let y = (1.0 - bbox.origin.y - bbox.size.height) * geometry.size.height + h / 2
                                    
                                    // Bounding Box outline (neon green if speaking, white translucent if silent)
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(track.isActiveSpeaker ? Color.green : Color.white.opacity(0.4), lineWidth: track.isActiveSpeaker ? 3.0 : 1.5)
                                        .frame(width: w, height: h)
                                        .shadow(color: track.isActiveSpeaker ? Color.green.opacity(0.5) : Color.clear, radius: 6)
                                        .overlay(
                                            LandmarksMeshView(
                                                landmarks: track.landmarks,
                                                color: track.isActiveSpeaker ? Color.green.opacity(0.7) : Color.white.opacity(0.4)
                                            )
                                        )
                                        .position(x: x, y: y)
                                        .overlay(
                                            // Label overlayed above the box
                                            Group {
                                                if track.isActiveSpeaker {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: "waveform.and.mic")
                                                            .symbolEffect(.bounce, options: .repeating)
                                                        Text("SPEAKING")
                                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                    }
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Color.green)
                                                    .foregroundColor(.black)
                                                    .cornerRadius(4)
                                                    .position(x: x, y: y - (h / 2) - 14)
                                                }
                                            }
                                        )
                                }
                            }
                        )
                        .overlay(
                            HStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .symbolEffect(.pulse)
                                Text("LIVE")
                                    .font(.system(.caption2, design: .monospaced))
                                    .fontWeight(.bold)
                                Spacer()
                                Text(String(format: "FPS: %.1f", captureEngine.fps))
                                    .font(.system(.caption2, design: .monospaced))
                                    .fontWeight(.bold)
                            }
                            .padding(8)
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(6)
                            .padding(8),
                            alignment: .top
                        )
                } else {
                    // Placeholder when camera is off
                    VStack(spacing: 12) {
                        Image(systemName: "camera.metering.none")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Camera Offline")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(16/9, contentMode: .fit)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
            }
            .frame(maxWidth: .infinity)
            
            // Right Column: Controls & Console
            VStack(spacing: 20) {
                // Header / App Title
                HStack {
                    Image(systemName: "appletv.radio.broadcasting")
                        .font(.system(size: 28))
                        .foregroundColor(.purple)
                        .symbolEffect(.pulse, isActive: captureEngine.isSessionRunning)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LatentCast")
                            .font(.system(.title3, design: .rounded))
                            .fontWeight(.bold)
                        
                        Text("Active Speaker Detection")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                // Status Badges
                VStack(alignment: .leading, spacing: 10) {
                    StatusBadge(
                        title: "Camera Access",
                        icon: "camera.fill",
                        status: permissionManager.cameraStatus
                    )
                    
                    StatusBadge(
                        title: "Microphone Access",
                        icon: "mic.fill",
                        status: permissionManager.microphoneStatus
                    )
                }
                
                // Controller Button
                if permissionManager.hasBothPermissions {
                    Button(action: {
                        withAnimation {
                            if captureEngine.isSessionRunning {
                                captureEngine.stopSession()
                                faceEngine.activeTracks = []
                            } else {
                                captureEngine.startSession()
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: captureEngine.isSessionRunning ? "stop.fill" : "play.fill")
                            Text(captureEngine.isSessionRunning ? "Stop Session" : "Start Session")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(captureEngine.isSessionRunning ? Color.red.opacity(0.8) : Color.purple.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .shadow(color: captureEngine.isSessionRunning ? Color.red.opacity(0.2) : Color.purple.opacity(0.2), radius: 6, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        Task {
                            await permissionManager.requestPermissions()
                        }
                    }) {
                        HStack {
                            Image(systemName: "shield.fill")
                            Text("Grant Access")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .shadow(color: Color.blue.opacity(0.2), radius: 6, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                }
                
                // Audio Level VU Meter (shown when session is active)
                if captureEngine.isSessionRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Microphone Level")
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.1f %%", captureEngine.audioLevel * 100))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.green)
                        }
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.black.opacity(0.3))
                                    .frame(height: 6)
                                
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [.green, .yellow, .red],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: CGFloat(captureEngine.audioLevel) * geo.size.width, height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .transition(.opacity.combined(with: .scale))
                }
                
                // Live Console Area
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIVE CONSOLE")
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(0..<logs.count, id: \.self) { index in
                                    Text(logs[index])
                                        .id(index)
                                }
                            }
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .frame(height: 120)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(6)
                        .onChange(of: logs) {
                            if !logs.isEmpty {
                                proxy.scrollTo(logs.count - 1)
                            }
                        }
                    }
                }
            }
            .frame(width: 280)
        }
        .padding(20)
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onReceive(captureEngine.$lastLog) { logMsg in
            if !logMsg.isEmpty {
                appendLog(logMsg)
            }
        }
        .onReceive(faceEngine.$lastLog) { logMsg in
            if !logMsg.isEmpty {
                appendLog(logMsg)
            }
        }
        .onAppear {
            captureEngine.frameHandler.setCallback { [weak faceEngine] sendableBuffer in
                faceEngine?.processFrame(sendableBuffer)
            }
            
            // Set up audio callback to validate audio ingestion without flooding the logs
            let printer = ThrottledPrinter(limit: 100)
            captureEngine.audioHandler.setCallback { samples in
                if printer.shouldPrint() {
                    let maxVal = samples.map(abs).max() ?? 0.0
                    Task { @MainActor in
                        appendLog("[Audio] Captured \(samples.count) samples. Peak amplitude: \(String(format: "%.4f", maxVal))")
                    }
                }
            }
            
            appendLog("[Permission] Camera status: \(statusString(permissionManager.cameraStatus))")
            appendLog("[Permission] Microphone status: \(statusString(permissionManager.microphoneStatus))")
        }
    }
    
    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 50 {
            logs.removeFirst()
        }
    }
    
    private func statusString(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "AUTHORIZED"
        case .denied: return "DENIED"
        case .restricted: return "RESTRICTED"
        case .notDetermined: return "NOT DETERMINED"
        @unknown default: return "UNKNOWN"
        }
    }
}

// Visual Effect View for beautiful macOS blur (Glassmorphism)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Permission Status Badge View
struct StatusBadge: View {
    let title: String
    let icon: String
    let status: AVAuthorizationStatus
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(colorForStatus)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(textForStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(colorForStatus.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var colorForStatus: Color {
        switch status {
        case .authorized: return .green
        case .denied, .restricted: return .red
        case .notDetermined: return .orange
        @unknown default: return .gray
        }
    }
    
    private var textForStatus: String {
        switch status {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown"
        }
    }
}

@MainActor
class PermissionManager: ObservableObject {
    @Published var cameraStatus: AVAuthorizationStatus = .notDetermined
    @Published var microphoneStatus: AVAuthorizationStatus = .notDetermined
    
    var hasBothPermissions: Bool {
        cameraStatus == .authorized && microphoneStatus == .authorized
    }
    
    init() {
        checkPermissions()
    }
    
    func checkPermissions() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    
    func requestPermissions() async {
        // Request video (camera)
        if cameraStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        
        // Request audio (microphone)
        if microphoneStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        
        checkPermissions()
    }
}

#Preview {
    ContentView()
}

struct LandmarksMeshView: View {
    let landmarks: [String: [CGPoint]]
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            
            Path { path in
                for (key, points) in landmarks {
                    guard !points.isEmpty else { continue }
                    
                    let firstPt = mapPoint(points[0], to: size)
                    path.move(to: firstPt)
                    
                    for i in 1..<points.count {
                        path.addLine(to: mapPoint(points[i], to: size))
                    }
                    
                    if key.contains("Eye") || key.contains("Lips") {
                        path.closeSubpath()
                    }
                }
            }
            .stroke(color, lineWidth: 1.0)
            
            ForEach(Array(landmarks.keys), id: \.self) { key in
                if let points = landmarks[key] {
                    ForEach(0..<points.count, id: \.self) { index in
                        let pt = mapPoint(points[index], to: size)
                        Circle()
                            .fill(color)
                            .frame(width: 2.0, height: 2.0)
                            .position(pt)
                    }
                }
            }
        }
    }
    
    private func mapPoint(_ point: CGPoint, to size: CGSize) -> CGPoint {
        return CGPoint(
            x: point.x * size.width,
            y: (1.0 - point.y) * size.height
        )
    }
}

// Thread-safe counter class for throttling print statements in concurrently-executing callbacks
private final class ThrottledPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int
    
    init(limit: Int) {
        self.limit = limit
    }
    
    func shouldPrint() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count >= limit {
            count = 0
            return true
        }
        return false
    }
}
