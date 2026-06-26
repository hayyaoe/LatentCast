//
//  PythonBridge.swift
//  LatentCast
//
//  Created by Hayya U on 26/06/26.
//

import Foundation
import Combine
import PythonKit

// Thread-safe communication bridge with Python running in-process via PythonKit
class PythonBridge: ObservableObject, @unchecked Sendable {
    @Published var connectionStatus: String = "Initializing..."
    @Published var lastResponse: String = ""
    @Published var isProcessing: Bool = false
    
    private var pyEngine: PythonObject?
    private let pythonQueue = DispatchQueue(label: "com.latentcast.pythonQueue", qos: .userInitiated)
    private let lock = NSLock()
    
    // GIL (Global Interpreter Lock) Management Functions
    private typealias GILEnsureFunc = @convention(c) () -> Int32
    private typealias GILReleaseFunc = @convention(c) (Int32) -> Void
    private var gilEnsure: GILEnsureFunc?
    private var gilRelease: GILReleaseFunc?
    
    init() {
        setupPythonEnvironment()
    }
    
    /// Dynamically loads PyGILState_Ensure/Release from libpython via dlsym
    private func setupGILFunctions() {
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            print("[GIL] Warning: Failed to open global symbol table")
            return
        }
        defer { dlclose(handle) }
        
        if let ensureSym = dlsym(handle, "PyGILState_Ensure"),
           let releaseSym = dlsym(handle, "PyGILState_Release") {
            gilEnsure = unsafeBitCast(ensureSym, to: GILEnsureFunc.self)
            gilRelease = unsafeBitCast(releaseSym, to: GILReleaseFunc.self)
            print("[GIL] PyGILState_Ensure/Release loaded successfully")
        } else {
            print("[GIL] Warning: Could not find PyGILState symbols - GIL safety disabled")
        }
    }
    
    /// Executes a PythonKit operation while holding the Global Interpreter Lock
    @discardableResult
    private func withGIL<T>(_ body: () -> T) -> T {
        if let ensure = gilEnsure, let release = gilRelease {
            let state = ensure()
            defer { release(state) }
            return body()
        }
        return body()
    }
    
    /// Configures environments, dynamic libs, and imports python modules
    func setupPythonEnvironment() {
        print("[PythonBridge] Setting up Python environment...")
        
        // 1. Point PythonKit to Miniconda's shared library
        setenv("PYTHON_LIBRARY", "/Users/hayyau/miniconda3/lib/libpython3.13.dylib", 1)
        
        // 2. Set PYTHONPATH to locate the workspace and virtual environment dependencies
        let projectPath = "/Users/hayyau/documents/projects/ai-ml/challange-1/audio"
        let sitePackages = "\(projectPath)/.venv/lib/python3.13/site-packages"
        setenv("PYTHONPATH", "\(projectPath):\(sitePackages)", 1)
        
        pythonQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                print("[PythonBridge] Attempting to import bridge_logic module...")
                let bridgeLogic = try Python.attemptImport("bridge_logic")
                
                // Initialize GIL management functions now that Python library is loaded
                self.setupGILFunctions()
                
                // Initialize the Python engine with GIL held
                let engine = self.withGIL {
                    bridgeLogic.PythonBridgeEngine()
                }
                
                self.lock.lock()
                self.pyEngine = engine
                self.lock.unlock()
                
                Task { @MainActor in
                    self.connectionStatus = "Connected (Python 3.13 & Silero VAD)"
                    print("[PythonBridge] PythonBridgeEngine successfully loaded!")
                }
            } catch {
                Task { @MainActor in
                    self.connectionStatus = "Failed to load Python: \(error.localizedDescription)"
                    print("[PythonBridge] Error initializing Python: \(error)")
                }
            }
        }
    }
    
    /// Sends a diagnostic test message to Python and updates UI with the reply
    func testCommunication(message: String) {
        pythonQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard let engine = self.pyEngine else {
                self.lock.unlock()
                Task { @MainActor in
                    self.lastResponse = "Error: Python engine not ready"
                }
                return
            }
            self.lock.unlock()
            
            let response = self.withGIL {
                String(engine.test_communication(message)) ?? "Failed to decode Python string response"
            }
            
            Task { @MainActor in
                self.lastResponse = response
            }
        }
    }
}
