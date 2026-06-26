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
    @State private var isRunning = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Header / App Title
            HStack {
                Image(systemName: "appletv.radio.broadcasting")
                    .font(.system(size: 32))
                    .foregroundColor(.purple)
                    .symbolEffect(.pulse, isActive: isRunning)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("LatentCast")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                    
                    Text("Active Speaker Auto-Cropping & Subtitles")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 8)
            
            // Status Card
            VStack(alignment: .leading, spacing: 16) {
                Text("SYSTEM STATUS")
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 20) {
                    // Camera Permission Indicator
                    StatusBadge(
                        title: "Camera Access",
                        icon: "camera.fill",
                        status: permissionManager.cameraStatus
                    )
                    
                    // Microphone Permission Indicator
                    StatusBadge(
                        title: "Microphone Access",
                        icon: "mic.fill",
                        status: permissionManager.microphoneStatus
                    )
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            
            // Controller Section
            VStack(spacing: 16) {
                if permissionManager.hasBothPermissions {
                    Button(action: {
                        withAnimation {
                            isRunning.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                            Text(isRunning ? "Stop Session" : "Start Session")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isRunning ? Color.red.opacity(0.8) : Color.purple.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .shadow(color: isRunning ? Color.red.opacity(0.3) : Color.purple.opacity(0.3), radius: 8, x: 0, y: 4)
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
                            Text("Grant Hardware Access")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    
                    Text("Please grant camera and microphone access to proceed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Console / Live Log Area
            VStack(alignment: .leading, spacing: 8) {
                Text("LIVE CONSOLE")
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("[Permission] Camera status: \(statusString(permissionManager.cameraStatus))")
                        Text("[Permission] Microphone status: \(statusString(permissionManager.microphoneStatus))")
                        if isRunning {
                            Text("[System] Starting video compositor...")
                            Text("[System] Initializing camera and mic streams...")
                            Text("[Python] Bridge initialized.")
                        } else {
                            Text("[Idle] Ready. Waiting for user interaction.")
                        }
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.green.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .frame(height: 100)
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
            }
        }
        .padding(24)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
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
