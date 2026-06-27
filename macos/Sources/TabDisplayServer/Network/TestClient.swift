import Foundation
import Network
import SwiftProtobuf

/// Executes a self-contained local loopback verification test of the TCP Control and UDP Video/ARQ network stack
func runTestClient() {
    print("\n=== STARTING TABDISPLAY LOCAL LOOPBACK TEST CLIENT ===")
    
    let tcpConnection = NWConnection(host: "127.0.0.1", port: 5001, using: .tcp)
    
    tcpConnection.stateUpdateHandler = { (state: NWConnection.State) in
        switch state {
        case .ready:
            print("TestClient: TCP connection established to 127.0.0.1:5001")
            sendHandshakeRequest(tcpConnection)
        case .failed(let error):
            print("TestClient: TCP connection failed: \(error)")
            exit(1)
        case .cancelled:
            print("TestClient: TCP connection cancelled")
        default:
            break
        }
    }
    
    tcpConnection.start(queue: DispatchQueue.global())
    
    // Hold main thread open for test execution
    dispatchMain()
}

private func sendHandshakeRequest(_ connection: NWConnection) {
    print("TestClient: Sending HandshakeRequest...")
    var handshake = TDHandshakeRequest()
    handshake.clientDeviceName = "Local Loopback Mock Tablet"
    handshake.preferredWidth = 1920
    handshake.preferredHeight = 1080
    handshake.targetFps = 60
    
    var packet = TDControlPacket()
    packet.handshakeRequest = handshake
    
    do {
        let serialized = try packet.serializedData()
        var length = UInt32(serialized.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let fullPacket = lengthData + serialized
        
        connection.send(content: fullPacket, completion: .contentProcessed({ error in
            if let error = error {
                print("TestClient: Error sending handshake: \(error)")
                exit(1)
            }
            receiveHandshakeResponse(connection)
        }))
    } catch {
        print("TestClient: Failed to serialize handshake packet: \(error)")
        exit(1)
    }
}

private func receiveHandshakeResponse(_ connection: NWConnection) {
    connection.receiveExactLength(4) { data, error in
        if let error = error {
            print("TestClient: Error receiving handshake response length: \(error.localizedDescription)")
            exit(1)
        }
        
        guard let lengthData = data else { return }
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        connection.receiveExactLength(Int(length)) { payloadData, payloadError in
            if let payloadError = payloadError {
                print("TestClient: Error receiving handshake response payload: \(payloadError.localizedDescription)")
                exit(1)
            }
            
            guard let payload = payloadData else { return }
            do {
                let packet = try TDControlPacket(serializedBytes: payload)
                guard case .handshakeResponse(let response)? = packet.payload else {
                    print("TestClient: Received unexpected packet type, expecting HandshakeResponse")
                    exit(1)
                }
                
                print("TestClient: Handshake accepted by server: '\(response.serverName)'")
                print("TestClient: Allocated Resolution: \(response.allocatedWidth)x\(response.allocatedHeight) @ \(response.negotiatedFps) FPS")
                print("TestClient: Target UDP Video Stream Port: \(response.videoStreamPort)")
                
                // Transition to UDP video streaming test
                startUDPStreamingTest(port: UInt16(response.videoStreamPort))
            } catch {
                print("TestClient: Failed to parse HandshakeResponse: \(error)")
                exit(1)
            }
        }
    }
}

private func startUDPStreamingTest(port: UInt16) {
    print("TestClient: Initiating UDP client on port \(port)...")
    let udpConnection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
    
    udpConnection.stateUpdateHandler = { (state: NWConnection.State) in
        switch state {
        case .ready:
            print("TestClient: UDP connection established. Starting periodic ping timer...")
            startUDPPingTimer(udpConnection)
            receiveUDPVideoPackets(udpConnection)
        case .failed(let error):
            print("TestClient: UDP connection failed: \(error)")
            exit(1)
        default:
            break
        }
    }
    
    udpConnection.start(queue: DispatchQueue.global())
}

private func startUDPPingTimer(_ connection: NWConnection) {
    let queue = DispatchQueue(label: "com.tabdisplay.pingtimer")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250))
    timer.setEventHandler {
        sendUDPPing(connection)
    }
    pingTimer = timer
    timer.resume()
}

private func sendUDPPing(_ connection: NWConnection) {
    let pingPacket = Data([0xFF])
    connection.send(content: pingPacket, completion: .contentProcessed({ error in
        if let error = error {
            print("TestClient: Failed to send UDP ping: \(error)")
            exit(1)
        }
        print("TestClient: Sent UDP hole-punch ping (0xFF)")
    }))
}

// Global mutable test state
private var nackSent = false
private var targetNackFrameIndex: UInt32 = 0
private var targetNackFragmentIndex: UInt16 = 0
private var testSuccessCount = 0
private var pingTimer: DispatchSourceTimer?

private func receiveUDPVideoPackets(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, isComplete, error in
        if let error = error {
            print("TestClient: UDP receive error: \(error)")
            exit(1)
        }
        
        if let packet = data, packet.count >= 20 {
            if pingTimer != nil {
                pingTimer?.cancel()
                pingTimer = nil
                print("TestClient: Video stream packet received. Deactivating UDP ping timer.")
            }
            // Parse 20-byte video header
            let frameIndex = packet.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let fragmentIndex = packet.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let totalFragments = packet.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let payloadSize = packet.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let frameType = packet[10]
            let timestamp = packet.subdata(in: 12..<20).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            
            let frameTypeStr = frameType == 1 ? "Keyframe" : "Delta"
            
            // Check if this is the retransmitted fragment we NACKed
            if nackSent && frameIndex == targetNackFrameIndex && fragmentIndex == targetNackFragmentIndex {
                print("=================================================================")
                print("🎉 SUCCESS: Received retransmitted fragment via Selective Repeat ARQ!")
                print("  -> Frame: #\(frameIndex) | Fragment: \(fragmentIndex)/\(totalFragments) | Type: \(frameTypeStr)")
                print("=================================================================")
                print("\nVerification successful! TabDisplay network pipeline matches specification.")
                print("Stopping loopback tests...\n")
                exit(0)
            }
            
            testSuccessCount += 1
            if testSuccessCount % 30 == 0 {
                print("TestClient: Recv Video Packet | Frame #\(frameIndex) | Frag \(fragmentIndex)/\(totalFragments) | Type: \(frameTypeStr) | Payload: \(payloadSize) bytes | Latency: \(Date().timeIntervalSince1970 * 1000 - Double(timestamp))ms")
            }
            
            // Inject NACK test around frame 10
            if !nackSent && frameIndex >= 10 && fragmentIndex == 0 {
                nackSent = true
                targetNackFrameIndex = frameIndex
                targetNackFragmentIndex = fragmentIndex
                
                print("\n=================================================================")
                print("🛠️ SIMULATING PACKET LOSS: Injecting NACK request for:")
                print("  -> Frame: #\(targetNackFrameIndex) | Fragment: \(targetNackFragmentIndex)")
                print("=================================================================")
                
                sendNack(connection, frameIndex: targetNackFrameIndex, fragmentIndex: targetNackFragmentIndex)
            }
        }
        
        // Always listen recursively for subsequent UDP video datagrams
        receiveUDPVideoPackets(connection)
    }
}

private func sendNack(_ connection: NWConnection, frameIndex: UInt32, fragmentIndex: UInt16) {
    var nackPacket = Data()
    nackPacket.append(0xFD) // Magic NACK byte
    
    var fIdx = frameIndex.bigEndian
    withUnsafeBytes(of: &fIdx) { nackPacket.append(contentsOf: $0) }
    
    var fragIdx = fragmentIndex.bigEndian
    withUnsafeBytes(of: &fragIdx) { nackPacket.append(contentsOf: $0) }
    
    connection.send(content: nackPacket, completion: .contentProcessed({ error in
        if let error = error {
            print("TestClient: Failed to transmit Nack: \(error)")
            exit(1)
        }
        print("TestClient: Dispatched Nack packet to server UDP receiver successfully.")
    }))
}
