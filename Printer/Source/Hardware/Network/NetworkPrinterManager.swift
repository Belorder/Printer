//
//  NetworkPrinterManager.swift
//  Printer
//
//  Created by Geoffrey Desbrosses on 19/09/2024.
//  Copyright © 2024 Belorder. All rights reserved.
//
import Foundation
import Network
import MobileCoreServices

public enum TicketPrintError: Error {
    case printError(NWError)
    case connectionError(NWError)
    case notConnected
    case notReady
    case port
    case connectionTimeout
    case connectionStateTimeout(state: NWConnection.State)
    case unknownError
}

extension TicketPrintError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .printError(let nwError):
            return "Network error \(nwError.localizedDescription)"
        case .connectionError(let nwError):
            return "Connection error \(nwError.localizedDescription)"
        case .notConnected:
            return "You are not connected to the printer"
        case .notReady:
            return "The printer is not ready"
        case .port:
            return "Invalid port"
        case .connectionTimeout:
            return "We can't connect to the printer"
        case .connectionStateTimeout(let state):
            return "Bad state after timeout: \(state)"
        case .unknownError:
            return "An unknown error has occurred"
        }
    }
}

@available(iOS 12.0, *)
public class NetworkPrinterManager {
    private var networkConnection: NWConnection?
    private var ip: String?
    private var port: Int?

    public init() {}

    public var onConnectionStateChange: ((NWConnection.State) -> Void)?

    public func getNetworkConnection() -> NWConnection? {
        return self.networkConnection
    }
    
    public func getConnectionState() -> NWConnection.State? {
        return self.networkConnection?.state
    }
    
    public func getIp() -> String? {
        return self.ip
    }
    
    public func getPort() -> Int? {
        return self.port
    }
    
    /**
     * Async function to wait for the connection to be etablish
     */
    public func waitForConnectionReady(timeout: TimeInterval = 2, completion: @escaping (Result<Bool, TicketPrintError>) -> Void) {
        let startTime = Date()

        DispatchQueue.global().async {
            while true {
                if self.getConnectionState() == .ready {
                    completion(.success(true))
                    return
                } else if let currentState = self.getConnectionState(), currentState == .cancelled {
                    completion(.failure(.connectionStateTimeout(state: currentState)))
                    return
                }

                if Date().timeIntervalSince(startTime) > timeout {
                    completion(.failure(.connectionStateTimeout(state: self.getConnectionState() ?? .setup)))
                    return
                }

                usleep(100_000)
            }
        }
    }

    /**
     * Connect to the peripheral if needed
     */
    public func connect(ip: String, port: Int) throws {
        let shouldDisconnect = (self.ip != nil && self.port != nil) && (self.ip != ip || self.port != port)
        
        // Already connected to the right peripheral.
        if (self.networkConnection?.state == .ready && !shouldDisconnect) {
            return
        }

        // Init first connection
        if (self.networkConnection?.state != .ready && !shouldDisconnect) {
            return try self.initNewConnection(ip: ip, port: port)
        }

        // Change peripheral
        self.disconnect()
        try self.initNewConnection(ip: ip, port: port)
    }

    /**
     * Create a new connection from IP/Port
     */
    private func initNewConnection(ip: String, port: Int) throws {
        guard let PORT = NWEndpoint.Port("\(port)") else {
            throw TicketPrintError.port
        }

        let ipAddress = NWEndpoint.Host(ip)
        let queue = DispatchQueue(label: "TCP Client Queue")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        
        networkConnection = NWConnection(to: NWEndpoint.hostPort(host: ipAddress, port: PORT), using: params)
        networkConnection?.stateUpdateHandler = { [weak self] (newState) in
            self?.onConnectionStateChange?(newState)
            
            switch newState {
                case .ready:
                    self?.ip = ip
                    self?.port = port
                    UserDefaults.standard.set(true, forKey: "isConnected")
                default:
                    UserDefaults.standard.set(false, forKey: "isConnected")
            }
        }

        networkConnection?.start(queue: queue)
    }

    /**
     * Cancel the current connection
     */
    public func disconnect() {
        networkConnection?.cancel()
    }

    /**
     * Send message to print ticket
     */
    public func print(_ ticket: Ticket, completion: @escaping (Bool, Error?) -> Void) {
        guard let connection = networkConnection else {
            completion(false, TicketPrintError.notConnected)
            return
        }

        if connection.state != .ready {
            completion(false, TicketPrintError.notReady)
            return
        }

        let content = getTicketData(ticket)
        connection.send(content: content, isComplete: true, completion: NWConnection.SendCompletion.contentProcessed({ (nwError) in
            if let error = nwError {
                completion(false, TicketPrintError.printError(error))
            } else {
                completion(true, nil)
            }
        }))
    }

    /**
     * Get data to send to the printer
     */
    private func getTicketData(_ ticket: Ticket) -> Data {
        var combinedData = Data()
        
        for data in ticket.data(using: .utf8) {
            combinedData.append(data)
        }

        let paperCutCommand: [UInt8] = [0x1D, 0x56, 0x00]
        combinedData.append(contentsOf: paperCutCommand)

        return combinedData
    }
}
