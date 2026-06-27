import Foundation
import Network

class ServerNetwork {

    // MARK: - UDP Wi-Fi mode
    private var udpListener: NWListener?
    private var udpConnection: NWConnection?
    private let sendQueue = DispatchQueue(label: "com.tabdisplay.udpsend", qos: .userInteractive)

    // MARK: - TCP USB mode
    private var tcpListener: NWListener?
    private var tcpConnection: NWConnection?
    private let tcpSendQueue = DispatchQueue(label: "com.tabdisplay.tcpsend", qos: .userInteractive)
    private var tcpFrameCount = 0

    // MARK: - Shared state
    private(set) var isUsbMode = false
    private let retransmitBuffer = RetransmitBuffer() // Only used in UDP mode
    private var frameIndex: UInt32 = 0
    private let mtuSize = 1200 // Max H.264 slice size per UDP payload

    init() {
        print("ServerNetwork initialized")
    }

    deinit {
        stopStreaming()
    }

    // MARK: - Start / Stop

    /// Start in UDP mode (Wi-Fi) — default.
    func startStreaming(port: UInt32) {
        stopStreaming()
        isUsbMode = false

        let semaphore = DispatchSemaphore(value: 0)

        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVideo
        let listenerPort = NWEndpoint.Port(rawValue: UInt16(port))!
        
        guard let listener = try? NWListener(using: parameters, on: listenerPort) else {
            print("Error: Failed to create UDP listener")
            return
        }
        self.udpListener = listener

        listener.stateUpdateHandler = { (state: NWListener.State) in
            switch state {
            case .ready:
                print("ServerNetwork UDP Listener active on port \(port)")
                semaphore.signal()
            case .failed(let error):
                print("ServerNetwork UDP Listener failed with error: \(error)")
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            print("ServerNetwork: incoming UDP connection detected from \(connection.endpoint)")
            self?.handleIncomingUDPPing(connection)
        }

        listener.start(queue: DispatchQueue.global(qos: .userInteractive))
        _ = semaphore.wait(timeout: .now() + 1.0)
    }

    /// Start in TCP mode (USB ADB tunnel). Android connects to 127.0.0.1:port.
    func startTCPStreaming(port: UInt32) {
        stopStreaming()
        isUsbMode = true

        let semaphore = DispatchSemaphore(value: 0)

        let parameters = NWParameters.tcp
        parameters.serviceClass = .interactiveVideo
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        let listenerPort = NWEndpoint.Port(rawValue: UInt16(port))!
        
        guard let listener = try? NWListener(using: parameters, on: listenerPort) else {
            print("Error: Failed to create TCP video listener")
            return
        }
        self.tcpListener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("ServerNetwork TCP Video Listener active on port \(port) (USB mode)")
                semaphore.signal()
            case .failed(let error):
                print("ServerNetwork TCP Video Listener failed: \(error)")
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            if self.tcpConnection != nil {
                print("ServerNetwork: Refusing duplicate TCP video client, already connected.")
                connection.cancel()
                return
            }
            print("ServerNetwork: TCP video client connected via USB: \(connection.endpoint)")
            self.tcpConnection = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    print("ServerNetwork: TCP video connection closed.")
                    self?.tcpConnection = nil
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInteractive))
        }

        listener.start(queue: DispatchQueue.global(qos: .userInteractive))
        _ = semaphore.wait(timeout: .now() + 1.0)
    }

    func stopStreaming() {
        // UDP
        if let conn = udpConnection {
            print("Closing active UDP streaming connection...")
            conn.cancel()
            udpConnection = nil
        }
        if let list = udpListener {
            print("Stopping UDP listener...")
            list.cancel()
            udpListener = nil
        }
        // TCP
        if let conn = tcpConnection {
            print("Closing TCP video connection (USB mode)...")
            conn.cancel()
            tcpConnection = nil
        }
        if let list = tcpListener {
            print("Stopping TCP video listener (USB mode)...")
            list.cancel()
            tcpListener = nil
        }
        retransmitBuffer.clear()
        frameIndex = 0
        isUsbMode = false
    }

    // MARK: - UDP Helpers

    private func handleIncomingUDPPing(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self = self else { return }
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
        if udpConnection === connection {
            print("UDP stream connection closed.")
            udpConnection = nil
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

            self.receivePackets(connection)
        }
    }

    private func parseIncomingPacket(_ data: Data, connection: NWConnection) {
        let magic = data[0]

        // 1. Endpoint Discovery Ping
        if magic == 0xFF {
            if udpConnection == nil {
                print("Received client UDP hole-punch ping. UDP stream target set to: \(connection.endpoint)")
                udpConnection = connection
            }
            return
        }

        guard connection === udpConnection else { return }

        // 2. NACK Retransmit Request: 0xFD (1) + frameIndex (4) + fragmentIndex (2)
        if magic == 0xFD && data.count >= 7 {
            let frameIdx = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let fragmentIdx = data.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }

            if let retransmitPacket = retransmitBuffer.get(frameIndex: frameIdx, fragmentIndex: fragmentIdx) {
                sendQueue.async { [weak self] in
                    self?.sendUDPPacket(retransmitPacket)
                }
            }
        }
    }

    // MARK: - Frame Sending

    /// Fragment and stream an H.264 video frame over UDP (Wi-Fi) or TCP (USB).
    func sendFrame(data: Data, isKeyframe: Bool) {
        if isUsbMode {
            sendFrameViaTCP(data: data)
        } else {
            sendFrameViaUDP(data: data, isKeyframe: isKeyframe)
        }
    }

    private func sendFrameViaTCP(data: Data) {
        guard let connection = tcpConnection else { return }
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let payloadSize = 8 + data.count
        var length = UInt32(payloadSize).bigEndian
        var frameData = Data(bytes: &length, count: 4)
        var tsBig = timestamp.bigEndian
        frameData.append(Data(bytes: &tsBig, count: 8))
        frameData.append(data)
        let toSend = frameData
        
        tcpFrameCount += 1
        if tcpFrameCount <= 5 {
            print("ServerNetwork: Sending TCP frame #\(tcpFrameCount) | payload size: \(payloadSize) bytes")
        }
        
        tcpSendQueue.async {
            connection.send(content: toSend, completion: .contentProcessed({ error in
                if let error = error {
                    print("Error: TCP video send failed: \(error)")
                }
            }))
        }
    }

    private func sendFrameViaUDP(data: Data, isKeyframe: Bool) {
        guard udpConnection != nil else { return }

        frameIndex += 1
        let currentFrameIndex = frameIndex
        let totalLength = data.count
        let frameType: UInt8 = isKeyframe ? 1 : 0

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let totalFragments = UInt16(ceil(Double(totalLength) / Double(mtuSize)))

        for i in 0..<totalFragments {
            let fragmentIndex = UInt16(i)
            let offset = Int(fragmentIndex) * mtuSize
            let size = min(mtuSize, totalLength - offset)

            let slicePayload = data.subdata(in: offset..<(offset + size))

            var packet = Data()
            packet.appendBigEndian(currentFrameIndex)
            packet.appendBigEndian(fragmentIndex)
            packet.appendBigEndian(totalFragments)
            packet.appendBigEndian(UInt16(size))
            packet.append(frameType)
            packet.append(0)
            packet.appendBigEndian(timestamp)
            packet.append(slicePayload)

            retransmitBuffer.cache(frameIndex: currentFrameIndex, fragmentIndex: fragmentIndex, packet: packet)

            let packetToSend = packet
            sendQueue.async { [weak self] in
                self?.sendUDPPacket(packetToSend)
            }
        }
    }

    private func sendUDPPacket(_ data: Data) {
        guard let connection = udpConnection else { return }
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
    private let maxCachedFrames = 5
    private let lock = NSLock()

    func cache(frameIndex: UInt32, fragmentIndex: UInt16, packet: Data) {
        lock.lock()
        defer { lock.unlock() }

        if buffer[frameIndex] == nil {
            buffer[frameIndex] = [:]
            frameHistory.append(frameIndex)

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
