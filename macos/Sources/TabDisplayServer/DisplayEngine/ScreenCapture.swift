import Foundation
import ScreenCaptureKit
import QuartzCore
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var frameCount: UInt64 = 0
    private var lastFpsTime: CFTimeInterval = 0
    private let captureQueue = DispatchQueue(label: "com.tabdisplay.capture", qos: .userInteractive)

    private var firstFrameReceived = false

    // ── PHASE 5 DIAGNOSTIC ───────────────────────────────────────────────────
    // Observe: Save first captured CVPixelBuffer as PNG. Zero behavior change.
    private var firstFrameSaved = false
    private let firstFramePath = "/Users/jayeshyadav/.gemini/antigravity-ide/brain/252065d2-6aac-472b-a8af-d234840d2fbe/first_frame.png"

    private func saveFirstFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !firstFrameSaved else { return }
        firstFrameSaved = true

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        print("[P5] Saving first frame PNG | dimensions: \(w)x\(h) | path: \(firstFramePath)")

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let url = URL(fileURLWithPath: firstFramePath)

        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, nil)
                let success = CGImageDestinationFinalize(dest)
                print("[P5] First frame PNG saved: \(success) | path: \(firstFramePath)")
            } else {
                print("[P5] ERROR: Could not create CGImageDestination for \(firstFramePath)")
            }
        } else {
            print("[P5] ERROR: CIContext.createCGImage returned nil for first frame")
        }
    }
    // ── END PHASE 5 DIAGNOSTIC ───────────────────────────────────────────────

    // Callback invoked when a pixel buffer is captured from the stream
    var onPixelBufferCaptured: ((CVPixelBuffer, CMTime) -> Void)?
    var onFirstFrameReceived: (() -> Void)?


    override init() {
        super.init()
        print("ScreenCapture engine initialized")
    }

    func startCapture(displayID: CGDirectDisplayID, width: Int, height: Int) {
        firstFrameReceived = false
        let tStart = Int64(Date().timeIntervalSince1970 * 1000)
        print("[\(tStart) ms] [SCK] startCapture initiated for Display ID: \(displayID)")
        
        Task { [weak self] in
            guard let self = self else { return }

            do {
                let tQueryStart = Int64(Date().timeIntervalSince1970 * 1000)
                print("[\(tQueryStart) ms] [SCK] Querying SCShareableContent...")
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let tQueryEnd = Int64(Date().timeIntervalSince1970 * 1000)
                print("[\(tQueryEnd) ms] [SCK] SCShareableContent returned (took \(tQueryEnd - tQueryStart) ms)")

                // ── PHASE 2 DIAGNOSTIC ───────────────────────────────────────────
                // Observe: Whether SCShareableContent independently sees the virtual display.
                // NO behavior changes. Pure observation.
                print("[P2] SCShareableContent returned \(content.displays.count) displays, \(content.windows.count) windows, \(content.applications.count) apps")
                for d in content.displays {
                    let marker = d.displayID == displayID ? " ← TARGET" : ""
                    print("[P2]   SCDisplay ID=\(d.displayID) \(d.width)x\(d.height)\(marker)")
                }
                let targetFoundInSCK = content.displays.contains { $0.displayID == displayID }
                print("[P2] Virtual display \(displayID) found in SCShareableContent: \(targetFoundInSCK)")
                // ── END PHASE 2 DIAGNOSTIC ───────────────────────────────────────

                // Find target display
                guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    print("[P2] FAILURE: Target display ID \(displayID) not found in shareable content displays.")
                    return
                }

                print("Target display found: \(targetDisplay.width)x\(targetDisplay.height). Creating filter...")


                // ── STEP 1 FIX ───────────────────────────────────────────────────────────
                // Changed from: SCContentFilter(display: targetDisplay, excludingWindows: [])
                // Reason: excludingWindows:[] on an empty virtual display falls back to the
                // primary display framebuffer during the initial compositor pass (confirmed
                // by first_frame.png showing Safari/primary display content).
                // The excludingApplications:exceptingWindows: initializer correctly scopes
                // the filter to this specific display's composited output.
                let tFilterStart = Int64(Date().timeIntervalSince1970 * 1000)
                let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
                let tFilterEnd = Int64(Date().timeIntervalSince1970 * 1000)
                print("[\(tFilterEnd) ms] [SCK] SCContentFilter created (took \(tFilterEnd - tFilterStart) ms)")
                // ── END STEP 1 FIX ───────────────────────────────────────────────────────


                // Configure stream properties for low latency H.264 matching
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12 format
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)         // Cap at 60 FPS
                config.queueDepth = 2
                config.showsCursor = true
                config.colorSpaceName = CGColorSpace.sRGB
                config.scalesToFit = false
                config.capturesAudio = false

                let tStreamStart = Int64(Date().timeIntervalSince1970 * 1000)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.stream = stream
                let tStreamEnd = Int64(Date().timeIntervalSince1970 * 1000)
                print("[\(tStreamEnd) ms] [SCK] SCStream created (took \(tStreamEnd - tStreamStart) ms)")

                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)

                let tCaptureStart = Int64(Date().timeIntervalSince1970 * 1000)
                try await stream.startCapture()
                let tCaptureEnd = Int64(Date().timeIntervalSince1970 * 1000)
                print("[\(tCaptureEnd) ms] [SCK] stream.startCapture completed (took \(tCaptureEnd - tCaptureStart) ms)")
                
                self.frameCount = 0
                self.firstFrameReceived = false
                self.firstFrameSaved = false
                self.lastFpsTime = CACurrentMediaTime()
                print("=== ScreenCaptureKit Stream Active at \(width)x\(height) ===")

                // ── PHASE 3 DIAGNOSTIC ───────────────────────────────────────────
                // Schedule a 5-second timeout watchdog: if no first frame has arrived
                // by then, log a warning. Pure observation — no stream changes.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self = self else { return }
                    if !self.firstFrameReceived {
                        print("[P3] WATCHDOG: No frame received in first 5 seconds after stream start.")
                        print("[P3] WATCHDOG: This indicates SCStream started but produces zero output.")
                    } else {
                        print("[P3] WATCHDOG: First frame confirmed received within 5 seconds. ✓")
                    }
                }
                // ── END PHASE 3 DIAGNOSTIC ───────────────────────────────────────

            } catch {
                print("Error: ScreenCaptureKit failed to start capture: \(error.localizedDescription)")
            }
        }
    }

    func stopCapture(completion: (() -> Void)? = nil) {
        guard let stream = stream else {
            print("Capture stream already stopped.")
            completion?()
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
            completion?()
        }
    }

    func updateResolution(width: Int, height: Int) {
        guard let stream = stream else {
            print("ScreenCapture: Cannot update resolution, stream is nil.")
            return
        }

        print("ScreenCapture: Dynamically updating SCStream configuration to \(width)x\(height)...")
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12 format
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)         // Cap at 60 FPS
        config.queueDepth = 2
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = false
        config.capturesAudio = false

        Task {
            do {
                try await stream.updateConfiguration(config)
                print("ScreenCapture: SCStream configuration updated successfully.")
            } catch {
                print("Error updating SCStream configuration: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {

        // ── PHASE 3 DIAGNOSTIC ───────────────────────────────────────────────
        // Observe: SCFrameStatus on incoming sample buffers.
        // 0=complete, 1=idle, 2=blank, 3=suspended, 4=started, 5=stopped
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachment = attachmentsArray.first,
           let statusRaw = attachment[.status] as? Int {
            let status = SCFrameStatus(rawValue: statusRaw)
            if frameCount <= 5 || frameCount % 60 == 0 {
                let statusName: String
                switch status {
                case .complete:   statusName = "complete"
                case .idle:       statusName = "idle"
                case .blank:      statusName = "blank"
                case .suspended:  statusName = "suspended"
                case .started:    statusName = "started"
                case .stopped:    statusName = "stopped"
                default:          statusName = "unknown(\(statusRaw))"
                }
                print("[P3] Frame #\(frameCount) SCFrameStatus: \(statusName)")
            }
        }
        // ── END PHASE 3 DIAGNOSTIC ───────────────────────────────────────────

        if !firstFrameReceived {
            firstFrameReceived = true
            print("ScreenCapture: First sample buffer received from SCStream! Type: \(type.rawValue)")
            onFirstFrameReceived?()
        }
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // ── PHASE 5 DIAGNOSTIC ───────────────────────────────────────────────
        // Observe: Save the very first CVPixelBuffer as PNG for visual inspection.
        saveFirstFrame(pixelBuffer)
        // ── END PHASE 5 DIAGNOSTIC ───────────────────────────────────────────

        frameCount += 1

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if frameCount <= 5 {
            print("ScreenCapture: Captured frame #\(frameCount) at PTS \(pts.seconds)")
        }

        // Output logs every 60 frames (roughly once per second at 60fps)
        if frameCount % 60 == 0 {
            let currentTime = CACurrentMediaTime()
            let elapsed = currentTime - lastFpsTime
            let realTimeFps = Double(60) / elapsed
            lastFpsTime = currentTime

            let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
            let frameHeight = CVPixelBufferGetHeight(pixelBuffer)

            print("Captured Frame: #\(frameCount) | Render Bounds: \(frameWidth)x\(frameHeight) | PTS: \(String(format: "%.3f", pts.seconds))s | FPS: \(String(format: "%.2f", realTimeFps))")
        }

        onPixelBufferCaptured?(pixelBuffer, pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // ── PHASE 3 DIAGNOSTIC ───────────────────────────────────────────────
        print("[P3] FATAL: SCStream stopped with error: \(error.localizedDescription)")
        print("[P3] SCStream error code: \((error as NSError).code) | domain: \((error as NSError).domain)")
        // ── END PHASE 3 DIAGNOSTIC ───────────────────────────────────────────
    }

    // ── PHASE 3 DIAGNOSTIC ───────────────────────────────────────────────────
    // Observe: Whether WindowServer signals SCStream as inactive.
    // An inactive stream means ScreenCaptureKit found no capturable content.
    @available(macOS 13.0, *)
    func streamDidBecomeInactive(_ stream: SCStream) {
        print("[P3] WARNING: SCStream became INACTIVE.")
        print("[P3] This means WindowServer has no composited content to deliver on this display.")
        print("[P3] Frames received before inactivation: \(frameCount)")
    }
    // ── END PHASE 3 DIAGNOSTIC ───────────────────────────────────────────────
}
