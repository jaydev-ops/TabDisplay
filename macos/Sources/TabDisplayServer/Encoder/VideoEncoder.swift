import Foundation
import VideoToolbox
import CoreMedia

class VideoEncoder {
    private var session: VTCompressionSession?
    private var encodedFrameCount = 0
    
    // Callback invoked when a complete H.264 Annex B frame is produced
    var onEncodedFrame: ((Data, Bool) -> Void)?
    
    init() {
        print("VideoEncoder initialized")
    }
    
    deinit {
        stopSession()
    }
    
    /// Starts an H.264 compression session with the specified width, height, and target framerate
    func startSession(width: Int, height: Int, fps: Int = 60) {
        stopSession()
        
        print("Starting video compression session for: \(width)x\(height) @ \(fps) FPS")
        
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
            guard status == noErr else {
                print("Error: VTCompressionSession callback status is: \(status)")
                return
            }
            guard let sampleBuffer = sampleBuffer else {
                print("Error: VTCompressionSession callback sampleBuffer is nil")
                return
            }
            guard let refCon = outputCallbackRefCon else { return }
            
            // Cast refcon back to VideoEncoder instance
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.processFrame(sampleBuffer: sampleBuffer)
        }
        
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var sessionOut: VTCompressionSession?
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refCon,
            compressionSessionOut: &sessionOut
        )
        
        guard status == noErr, let session = sessionOut else {
            print("Error: VTCompressionSessionCreate failed: \(status)")
            return
        }
        
        self.session = session
        configureSession(fps: fps)
        
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus != noErr {
            print("Warning: VTCompressionSessionPrepareToEncodeFrames failed: \(prepareStatus)")
        } else {
            print("VTCompressionSession successfully prepared and active")
        }
    }
    
    /// Stops the current compression session and releases VT resources
    func stopSession() {
        guard let session = session else { return }
        print("Stopping video compression session")
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
    
    /// Configures session properties for real-time low-latency remote desktop streaming
    private func configureSession(fps: Int) {
        guard let session = session else { return }
        
        // 1. Enable real-time compression
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        // 2. Profile Level: H.264 Main AutoLevel for better compression and quality with CABAC
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        
        // 3. Disable frame reordering (strictly no B-frames for zero latency)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        // 4. Set average bitrate (5 Mbps = 5,000,000 bits/sec)
        let defaultBitrate = 5_000_000
        setBitrate(defaultBitrate)
        
        // 5. Set framerate expected behavior
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        
        // 6. Max Key Frame Interval: 60 frames (1 keyframe per second at 60fps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        
        // 7. Prevent encoder buffering and pipeline delay (key to latency control)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        
        // 8. Enable temporal compression
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        
        // 9. Prioritize encoding speed over quality for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        
        // 10. Enable CABAC entropy coding for 10-15% better compression efficiency over CAVLC
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC as CFTypeRef)
    }
    
    /// Adjusts encoder average and limit bitrates on the fly
    func setBitrate(_ bitrate: Int) {
        guard let session = session else { return }
        
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        if status != noErr {
            print("Warning: Could not set average bitrate to \(bitrate): \(status)")
        }
        
        // Limit peak rate to average bitrate * 1.2 over 1 second window to prevent massive network spikes
        let limitBytes = Double(bitrate) * 1.2 / 8.0
        let dataLimits: [Any] = [limitBytes, 1.0]
        let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataLimits as CFArray)
        if limitStatus != noErr {
            print("Warning: Could not set data rate limits: \(limitStatus)")
        }
        
        print("Encoder bitrate updated to: \(bitrate) bps (Peak: \(Int(limitBytes * 8)) bps)")
    }
    
    /// Compresses a raw image frame
    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime = .invalid) {
        guard let session = session else { return }
        
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        
        if status != noErr {
            print("Error: VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }
    
    /// Processes compressed frame buffer, extracting SPS/PPS on keyframes, and converting to Annex B byte format
    private func processFrame(sampleBuffer: CMSampleBuffer) {
        var isKeyframe = false
        
        // Check if sample buffer contains a sync keyframe
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false), CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let notSync = CFDictionaryGetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            isKeyframe = (notSync == nil)
        }
        
        var packetData = Data()
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        
        // 1. If keyframe, we extract Sequence Parameter Set (SPS) and Picture Parameter Set (PPS)
        if isKeyframe {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                print("Error: Failed to obtain format description from keyframe sample buffer.")
                return
            }
            
            var parameterSetCount = 0
            var nalHeaderLength: Int32 = 0
            var dummyPointer: UnsafePointer<UInt8>?
            var dummySize = 0
            
            var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &dummyPointer,
                parameterSetSizeOut: &dummySize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalHeaderLength
            )
            
            if status == noErr {
                for i in 0..<parameterSetCount {
                    var paramPointer: UnsafePointer<UInt8>?
                    var paramSize = 0
                    var dummyCount = 0
                    var dummyHeaderLength: Int32 = 0
                    
                    status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        formatDescription,
                        parameterSetIndex: i,
                        parameterSetPointerOut: &paramPointer,
                        parameterSetSizeOut: &paramSize,
                        parameterSetCountOut: &dummyCount,
                        nalUnitHeaderLengthOut: &dummyHeaderLength
                    )
                    
                    if status == noErr, let pointer = paramPointer {
                        packetData.append(startCode)
                        packetData.append(pointer, count: paramSize)
                    }
                }
            } else {
                print("Warning: CMVideoFormatDescriptionGetH264ParameterSetAtIndex failed: \(status)")
            }
        }
        
        // 2. Extract frame slices and convert length-prefixed format (AVCC) to Annex B (start-coded)
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("Error: Failed to get block buffer from sample buffer.")
            return
        }
        
        var contiguousBuffer: CMBlockBuffer?
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            let status = CMBlockBufferCreateContiguous(
                allocator: kCFAllocatorDefault,
                sourceBuffer: blockBuffer,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: 0,
                flags: 0,
                blockBufferOut: &contiguousBuffer
            )
            guard status == noErr else {
                print("Error: CMBlockBufferCreateContiguous failed: \(status)")
                return
            }
        } else {
            contiguousBuffer = blockBuffer
        }
        
        guard let buffer = contiguousBuffer else { return }
        
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            buffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let basePointer = dataPointer else {
            print("Error: CMBlockBufferGetDataPointer failed: \(status)")
            return
        }
        
        var offset = 0
        let nalLengthHeaderBytes = 4 // AVCC length header size is typically 4 bytes
        
        while offset < totalLength - nalLengthHeaderBytes {
            // Read 4-byte length prefix (big-endian)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, basePointer.advanced(by: offset), nalLengthHeaderBytes)
            nalLength = CFSwapInt32BigToHost(nalLength)
            
            if nalLength > 0 {
                // Prepend Annex B start code
                packetData.append(startCode)
                // Append the NAL unit payload
                let nalPayloadStart = basePointer.advanced(by: offset + nalLengthHeaderBytes)
                packetData.append(UnsafeRawPointer(nalPayloadStart).assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
            }
            
            offset += nalLengthHeaderBytes + Int(nalLength)
        }
        
        if !packetData.isEmpty {
            encodedFrameCount += 1
            if encodedFrameCount <= 5 {
                print("VideoEncoder: Encoded H.264 frame #\(encodedFrameCount) | size: \(packetData.count) bytes | keyframe: \(isKeyframe)")
            }
            onEncodedFrame?(packetData, isKeyframe)
        }
    }
}
