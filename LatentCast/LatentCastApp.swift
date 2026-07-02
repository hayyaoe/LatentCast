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
    
    @Published var processedFrame: SendablePixelBuffer? = nil
}

@main
struct LatentCastApp: App {
    @StateObject private var captureEngine = AVCaptureEngine()
    
    init() {
        print("[LatentCastApp] init() called - App struct created")
        // Force the app to activate after the run loop starts
        DispatchQueue.main.async {
            print("[LatentCastApp] Activating app and ordering windows front...")
            NSApp.activate()
            for window in NSApp.windows {
                print("[LatentCastApp] Window: \(window.title), isVisible: \(window.isVisible), frame: \(window.frame)")
                window.makeKeyAndOrderFront(nil)
            }
        }
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
            if let buffer = coordinator.processedFrame {
                GPUPixelBufferView(pixelBuffer: buffer)
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

struct GPUPixelBufferView: NSViewRepresentable {
    let pixelBuffer: SendablePixelBuffer?
    
    func makeNSView(context: Context) -> GPUPixelBufferNSView {
        let view = GPUPixelBufferNSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }
    
    func updateNSView(_ nsView: GPUPixelBufferNSView, context: Context) {
        nsView.updateBuffer(pixelBuffer?.buffer)
    }
}

class GPUPixelBufferNSView: NSView {
    func updateBuffer(_ buffer: CVPixelBuffer?) {
        // Direct GPU-to-screen composition via CoreAnimation layer content binding
        self.layer?.contents = buffer
    }
}
