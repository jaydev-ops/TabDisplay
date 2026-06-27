import Foundation
import Network
import SwiftProtobuf

class ControlServer {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    
    // Callbacks to communicate with AppDelegate
    var onHandshakeRequest: ((TDHandshakeRequest, @escaping (TDHandshakeResponse) -> Void) -> Void)?
    var onInputEvent: ((TDInputEvent) -> Void)?
    var onTelemetryFeedback: ((TDTelemetryFeedback) -> Void)?
    var onClientDisconnected: (() -> Void)?
    
    init() {
        print("ControlServer initialized")
    }
    
    deinit {
        stopListener()
    }
    
    func startListener(port: UInt32) {
        stopListener()
        
        do {
            let parameters = NWParameters.tcp
            parameters.serviceClass = .responsiveData
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
            }
            let listenerPort = NWEndpoint.Port(rawValue: UInt16(port))!
            let listener = try NWListener(using: parameters, on: listenerPort)
            self.listener = listener
            
            listener.stateUpdateHandler = { (state: NWListener.State) in
                switch state {
                case .ready:
                    print("ControlServer TCP Listener active on port \(port)")
                case .failed(let error):
                    print("ControlServer TCP Listener failed with error: \(error)")
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener.start(queue: DispatchQueue.global(qos: .userInteractive))
        } catch {
            print("Error: Failed to create TCP listener: \(error)")
        }
    }
    
    func stopListener() {
        if let conn = activeConnection {
            print("Closing active TCP client connection...")
            conn.cancel()
            activeConnection = nil
        }
        if let list = listener {
            print("Stopping TCP listener...")
            list.cancel()
            listener = nil
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        if let oldConnection = activeConnection {
            print("Warning: New connection received while a client is already connected. Closing old connection.")
            closeConnection(oldConnection)
        }
        
        print("Accepted new TCP client connection from: \(connection.endpoint)")
        activeConnection = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receiveNextPacket(connection)
            case .failed(let error):
                print("TCP connection error: \(error)")
                self.closeConnection(connection)
            case .cancelled:
                print("TCP connection cancelled")
                self.closeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInteractive))
    }
    
    private func closeConnection(_ connection: NWConnection) {
        connection.cancel()
        if activeConnection === connection {
            print("TCP connection closed.")
            activeConnection = nil
            onClientDisconnected?()
        }
    }
    
    private func receiveNextPacket(_ connection: NWConnection) {
        // 1. Read 4-byte length prefix
        connection.receiveExactLength(4) { [weak self] data, error in
            guard let self = self else { return }
            if let error = error {
                print("Error reading packet length prefix: \(error.localizedDescription)")
                self.closeConnection(connection)
                return
            }
            
            guard let lengthData = data else { return }
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            guard length > 0 && length < 1024 * 1024 else {
                print("Error: Invalid packet length \(length)")
                self.closeConnection(connection)
                return
            }
            
            // 2. Read exact payload bytes
            connection.receiveExactLength(Int(length)) { payloadData, payloadError in
                if let payloadError = payloadError {
                    print("Error reading packet payload: \(payloadError.localizedDescription)")
                    self.closeConnection(connection)
                    return
                }
                
                guard let payload = payloadData else { return }
                self.parseControlPacket(payload, connection: connection)
                
                // Read next packet recursively
                self.receiveNextPacket(connection)
            }
        }
    }
    
    private func parseControlPacket(_ data: Data, connection: NWConnection) {
        do {
            let packet = try TDControlPacket(serializedBytes: data)
            switch packet.payload {
            case .handshakeRequest(let request):
                print("Received Handshake Request from client device: '\(request.clientDeviceName)'")
                if let handler = onHandshakeRequest {
                    handler(request) { [weak self] response in
                        var responsePacket = TDControlPacket()
                        responsePacket.handshakeResponse = response
                        self?.sendPacket(responsePacket)
                    }
                }
            case .keepAlive(let keepAlive):
                // Echo KeepAlive heartbeat straight back
                var responsePacket = TDControlPacket()
                responsePacket.keepAlive = keepAlive
                sendPacket(responsePacket)
            case .inputEvent(let inputEvent):
                onInputEvent?(inputEvent)
            case .telemetry(let telemetry):
                onTelemetryFeedback?(telemetry)
            default:
                break
            }
        } catch {
            print("Error parsing incoming TDControlPacket: \(error.localizedDescription)")
        }
    }
    
    /// Sends a control packet to the connected client
    func sendPacket(_ packet: TDControlPacket) {
        guard let connection = activeConnection else {
            print("Warning: Cannot send packet; no active TCP connection exists.")
            return
        }
        
        do {
            let data = try packet.serializedData()
            var length = UInt32(data.count).bigEndian
            let lengthData = Data(bytes: &length, count: 4)
            let fullData = lengthData + data
            
            connection.send(content: fullData, completion: .contentProcessed({ error in
                if let error = error {
                    print("Error writing TCP control packet: \(error)")
                }
            }))
        } catch {
            print("Error serializing TDControlPacket: \(error)")
        }
    }
}

// MARK: - NWConnection Extensions

extension NWConnection {
    /// Reads exactly the specified number of bytes from the connection
    func receiveExactLength(_ length: Int, completion: @escaping (Data?, Error?) -> Void) {
        self.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
            if let error = error {
                completion(nil, error)
                return
            }
            if isComplete && (data == nil || data?.count != length) {
                completion(nil, NSError(domain: "ControlServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection closed prematurely"]))
                return
            }
            guard let data = data, data.count == length else {
                completion(nil, NSError(domain: "ControlServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to read requested byte count"]))
                return
            }
            completion(data, nil)
        }
    }
}
