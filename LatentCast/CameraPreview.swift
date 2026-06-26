//
//  CameraPreview.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import SwiftUI
import AVFoundation

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    
    func makeNSView(context: Context) -> VideoPreviewNSView {
        return VideoPreviewNSView(session: session)
    }
    
    func updateNSView(_ nsView: VideoPreviewNSView, context: Context) {
        // Layout updates are handled automatically by layout() override in NSView
    }
}

class VideoPreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        self.wantsLayer = true
        
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer?.addSublayer(layer)
        self.previewLayer = layer
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        previewLayer?.frame = self.bounds
    }
}
