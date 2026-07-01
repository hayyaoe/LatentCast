//
//  LatentCastApp.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import SwiftUI
import CoreGraphics
import Combine

class CleanFeedCoordinator: ObservableObject, @unchecked Sendable {
    static let shared = CleanFeedCoordinator()
    
    private let lock = NSLock()
    private var _isWindowOpen = false
    
    var isWindowOpen: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isWindowOpen
        }
        set {
            lock.lock()
            _isWindowOpen = newValue
            lock.unlock()
        }
    }
    
    @Published var processedFrame: CGImage? = nil
}

@main
struct LatentCastApp: App {
    @StateObject private var captureEngine = AVCaptureEngine()
    
    init() {
        print("[LatentCastApp] init() called - App struct created")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(captureEngine: captureEngine)
        }
        
        Window("Clean Feed", id: "clean-feed") {
            CleanFeedView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct CleanFeedView: View {
    @ObservedObject var coordinator = CleanFeedCoordinator.shared
    
    var body: some View {
        Group {
            if let cgImage = coordinator.processedFrame {
                Image(cgImage, scale: 1.0, orientation: .up, label: Text("Clean Feed"))
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fit)
            } else {
                Color.black
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        Text("Waiting for video feed...")
                            .foregroundColor(.gray)
                    )
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        .background(Color.black)
        .onAppear {
            coordinator.isWindowOpen = true
        }
        .onDisappear {
            coordinator.isWindowOpen = false
            coordinator.processedFrame = nil
        }
    }
}
