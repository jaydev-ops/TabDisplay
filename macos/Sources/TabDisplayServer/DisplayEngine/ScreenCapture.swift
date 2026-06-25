import Foundation
import ScreenCaptureKit
import QuartzCore

class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var frameCount: UInt64 = 0
    private var lastFpsTime: CFTimeInterval = 0
    private let captureQueue = DispatchQueue(label: "com.tabdisplay.capture", qos: .userInteractive)
    
    override init() {
        super.init()
        print("ScreenCapture engine initialized")
    }
    
    func startCapture(displayID: CGDirectDisplayID, width: Int, height: Int) {
        print("Initiating ScreenCaptureKit content query for Display ID: \(displayID)...")
        
        Task { [weak self] in
            guard let self = self else { return }
            
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                
                // Find target display
                guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    print("Error: Target display ID \(displayID) not found in shareable content displays.")
                    return
                }
                
                print("Target display found: \(targetDisplay.width)x\(targetDisplay.height). Creating filter...")
                
                // Setup filter targeting this virtual display
                let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
                
                // Configure stream properties for low latency H.264 matching
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12 format
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)         // Cap at 60 FPS
                config.queueDepth = 3
                config.showsCursor = true
                
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.stream = stream
                
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                
                try await stream.startCapture()
                self.frameCount = 0
                self.lastFpsTime = CACurrentMediaTime()
                print("=== ScreenCaptureKit Stream Active at \(width)x\(height) ===")
            } catch {
                print("Error: ScreenCaptureKit failed to start capture: \(error.localizedDescription)")
            }
        }
    }
    
    func stopCapture() {
        guard let stream = stream else {
            print("Capture stream already stopped.")
            return
        }
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await stream.stopCapture()
                print("=== ScreenCaptureKit Stream Stopped ===")
            } catch {
                print("Error stopping stream: \(error.localizedDescription)")
            }
            self.stream = nil
        }
    }
    
    // MARK: - SCStreamOutput
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        frameCount += 1
        
        // Output logs every 60 frames (roughly once per second at 60fps)
        if frameCount % 60 == 0 {
            let currentTime = CACurrentMediaTime()
            let elapsed = currentTime - lastFpsTime
            let realTimeFps = Double(60) / elapsed
            lastFpsTime = currentTime
            
            let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
            let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            print("Captured Frame: #\(frameCount) | Render Bounds: \(frameWidth)x\(frameHeight) | PTS: \(String(format: "%.3f", pts.seconds))s | FPS: \(String(format: "%.2f", realTimeFps))")
        }
        
        // TODO: Pass CVPixelBuffer to VideoEncoder pipeline
    }
    
    // MARK: - SCStreamDelegate
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SCStream terminated with error: \(error.localizedDescription)")
    }
}
