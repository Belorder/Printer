//
//  PrinterError.swift
//  Printer
//
//  Created by Geoffrey Desbrosses on 12/09/2024.
//  Copyright © 2024 Belorder. All rights reserved.
//
import Foundation
import Network

public enum PrinterError: Error {
    case printError(NWError)
    case connectionError(NWError)
    case notConnected
    case notReady
    case port
    case connectionTimeout
    case connectionStateTimeout(state: NWConnection.State)
    case deviceNotReady
    case connectFailed
    case unknownError
}

extension PrinterError: LocalizedError {
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
        case .deviceNotReady:
            return "Device is not ready"
        case .connectFailed:
            return "Connection failed"
        case .unknownError:
            return "An unknown error has occurred"
        }
    }
}
