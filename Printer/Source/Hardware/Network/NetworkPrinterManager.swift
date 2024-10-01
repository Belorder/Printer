//
//  NetworkPrinterManager.swift
//  Printer
//
//  Created by Geoffrey Desbrosses on 19/09/2024.
//  Copyright © 2024 Kevin. All rights reserved.
//
import Foundation
import Network
import MobileCoreServices

@available(iOS 12.0, *)
public class NetworkPrinterManager {
    private var networkConnection: NWConnection?
    private var ip: String?
    private var port: Int?

    public init() {}

    public enum TicketPrintError: Error {
        case networkError(NWError)
        case notConnected
        case unknownError
        case port
        case connection(NWError)
    }

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
    
    public func waitForConnectionReady(timeout: TimeInterval = 2, completion: @escaping (Bool) -> Void) {
        let startTime = Date()

        DispatchQueue.global().async {
            while true {
                if self.getConnectionState() == .ready {
                    completion(true)
                    return
                } else if self.getConnectionState() == .cancelled {
                    completion(false)
                    return
                }

                if Date().timeIntervalSince(startTime) > timeout {
                    completion(false)
                    return
                }

                usleep(100_000)
            }
        }
    }

    public func connect(ip: String, port: Int) throws {
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
                case .failed:
                    UserDefaults.standard.set(false, forKey: "isConnected")
                case .cancelled:
                    UserDefaults.standard.set(false, forKey: "isConnected")
                case .preparing:
                    UserDefaults.standard.set(false, forKey: "isConnected")
                default:
                    UserDefaults.standard.set(false, forKey: "isConnected")
            }
        }

        networkConnection?.start(queue: queue)
    }
    
    public func disconnect(completion: @escaping () -> Void) {
        guard let connection = networkConnection else {
            completion()
            return
        }

        connection.stateUpdateHandler = { newState in
            if newState == .cancelled {
                connection.stateUpdateHandler = nil
                completion()
            }
        }

        connection.cancel()
    }

    public func print(_ ticket: Ticket) throws {
        guard let connection = networkConnection else {
            throw TicketPrintError.notConnected
        }

        if connection.state != .ready {
            throw TicketPrintError.notConnected
        }
        
        var printError: Error?
        let content = getTicketData(ticket)
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()

        connection.send(content: content, completion: NWConnection.SendCompletion.contentProcessed({ (nwError) in
            if let error = nwError {
                printError = TicketPrintError.networkError(error)
            }
            dispatchGroup.leave()
        }))

        dispatchGroup.wait()

        if let error = printError {
            throw error
        }
    }
    
    private func getTicketData(_ ticket: Ticket) -> Data {
        var combinedData = Data()
        let ticketData = ticket.data(using: .utf8)
        for dataPart in ticketData {
            combinedData.append(dataPart)
        }

        let paperCutCommand: [UInt8] = [0x1D, 0x56, 0x00]
        combinedData.append(contentsOf: paperCutCommand)

        return combinedData
    }
}
