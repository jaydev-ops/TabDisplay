import Foundation
import Network

class ServerNetwork {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let sendQueue = DispatchQueue(label: "com.tabdisplay.udpsend", qos: .userInteractive)
    
    // Custom retransmit cache storing recently sent fragments
    private let retransmitBuffer = RetransmitBuffer()
    
    private var frameIndex: UInt32 = 0
    private let mtuSize = 1200 // Max H.264 slice size per UDP payload to fit in standard MTU safely
    
    init() {
        print("ServerNetwork initialized")
    }
    
    deinit {
        stopStreaming()
    }
    
    func startStreaming(port: UInt32) {
        stopStreaming()
        
        do {
            let parameters = NWParameters.udp
            let listenerPort = NWEndpoint.Port(rawValue: UInt16(port))!
            let listener = try NWListener(using: parameters, on: listenerPort)
            self.listener = listener
            
            listener.stateUpdateHandler = { (state: NWListener.State) in
                switch state {
                case .ready:
                    print("ServerNetwork UDP Listener active on port \(port)")
                case .failed(let error):
                    print("ServerNetwork UDP Listener failed with error: \(error)")
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                print("ServerNetwork: incoming UDP connection detected from \(connection.endpoint)")
                self?.handleIncomingUDPPing(connection)
            }
            
            listener.start(queue: DispatchQueue.global(qos: .userInteractive))
        } catch {
            print("Error: Failed to create UDP listener: \(error)")
        }
    }
    
    func stopStreaming() {
        if let conn = activeConnection {
            print("Closing active UDP streaming connection...")
            conn.cancel()
            activeConnection = nil
        }
        if let list = listener {
            print("Stopping UDP listener...")
            list.cancel()
            listener = nil
        }
        retransmitBuffer.clear()
        frameIndex = 0
    }
    
    private func handleIncomingUDPPing(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self = self else { return }
            print("ServerNetwork: UDP connection to \(connection.endpoint) changed state to \(state)")
            switch state {
            case .ready:
                self.receivePackets(connection)
            case .failed(let error):
                print("UDP connection flow error: \(error)")
                self.closeUDPConnection(connection)
            case .cancelled:
                self.closeUDPConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInteractive))
    }
    
    private func closeUDPConnection(_ connection: NWConnection) {
        connection.cancel()
        if activeConnection === connection {
            print("UDP stream connection closed.")
            activeConnection = nil
        }
    }
    
    private func receivePackets(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("UDP receive error: \(error)")
                self.closeUDPConnection(connection)
                return
            }
            
            if let data = data, !data.isEmpty {
                self.parseIncomingPacket(data, connection: connection)
            }
            
            // Always keep listening for the next UDP datagram
            self.receivePackets(connection)
        }
    }
    
    private func parseIncomingPacket(_ data: Data, connection: NWConnection) {
        let magic = data[0]
        
        // 1. Endpoint Discovery Ping
        if magic == 0xFF {
            if activeConnection == nil {
                print("Received client UDP hole-punch ping. UDP stream target set to: \(connection.endpoint)")
                activeConnection = connection
            }
            return
        }
        
        // Ensure packet is from the active client
        guard connection === activeConnection else { return }
        
        // 2. NACK Retransmit Request: 0xFD (1) + frameIndex (4) + fragmentIndex (2)
        if magic == 0xFD && data.count >= 7 {
            let frameIdx = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let fragmentIdx = data.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            
            if let retransmitPacket = retransmitBuffer.get(frameIndex: frameIdx, fragmentIndex: fragmentIdx) {
                sendQueue.async { [weak self] in
                    self?.sendPacket(retransmitPacket)
                }
            }
        }
    }
    
    /// Fragment and stream an H.264 video frame over UDP
    func sendFrame(data: Data, isKeyframe: Bool) {
        guard activeConnection != nil else { return }
        
        frameIndex += 1
        let currentFrameIndex = frameIndex
        let totalLength = data.count
        let frameType: UInt8 = isKeyframe ? 1 : 0
        
        // Monotonic presentation time mapping
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        
        let totalFragments = UInt16(ceil(Double(totalLength) / Double(mtuSize)))
        
        for i in 0..<totalFragments {
            let fragmentIndex = UInt16(i)
            let offset = Int(fragmentIndex) * mtuSize
            let size = min(mtuSize, totalLength - offset)
            
            let slicePayload = data.subdata(in: offset..<(offset + size))
            
            // Build custom 20-byte packet header
            var packet = Data()
            packet.appendBigEndian(currentFrameIndex)
            packet.appendBigEndian(fragmentIndex)
            packet.appendBigEndian(totalFragments)
            packet.appendBigEndian(UInt16(size))
            packet.append(frameType)
            packet.append(0) // reserved
            packet.appendBigEndian(timestamp)
            
            packet.append(slicePayload)
            
            // Cache fragment for ARQ Selective Repeat retransmissions
            retransmitBuffer.cache(frameIndex: currentFrameIndex, fragmentIndex: fragmentIndex, packet: packet)
            
            let packetToSend = packet
            // Dispatch asynchronously to prevent encoder thread block
            sendQueue.async { [weak self] in
                self?.sendPacket(packetToSend)
            }
        }
    }
    
    private func sendPacket(_ data: Data) {
        guard let connection = activeConnection else { return }
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("Error: UDP send failed: \(error)")
            }
        }))
    }
}

// MARK: - Thread-safe Retransmit Buffer Cache

fileprivate class RetransmitBuffer {
    private var buffer: [UInt32: [UInt16: Data]] = [:]
    private var frameHistory: [UInt32] = []
    private let maxCachedFrames = 5 // Sliding window cache limit
    private let lock = NSLock()
    
    func cache(frameIndex: UInt32, fragmentIndex: UInt16, packet: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        if buffer[frameIndex] == nil {
            buffer[frameIndex] = [:]
            frameHistory.append(frameIndex)
            
            // Evict oldest frame
            if frameHistory.count > maxCachedFrames {
                let evictedFrame = frameHistory.removeFirst()
                buffer.removeValue(forKey: evictedFrame)
            }
        }
        buffer[frameIndex]?[fragmentIndex] = packet
    }
    
    func get(frameIndex: UInt32, fragmentIndex: UInt16) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return buffer[frameIndex]?[fragmentIndex]
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
        frameHistory.removeAll()
    }
}

// MARK: - Big Endian Helpers

fileprivate extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var val = value.bigEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }
    
    mutating func appendBigEndian(_ value: UInt16) {
        var val = value.bigEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }
    
    mutating func appendBigEndian(_ value: UInt64) {
        var val = value.bigEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }
}
