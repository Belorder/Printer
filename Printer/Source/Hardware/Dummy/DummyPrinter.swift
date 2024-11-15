//
//  Dummy.swift
//  Printer
//
//  Created by Geoffrey Desbrosses on 12/09/2024.
//  Copyright © 2024 Belorder. All rights reserved.
//
import Foundation

public class DummyPrinter {
    
    public init() {}
    
    public func print(_ value: ESCPOSCommandsCreator) {
        let data = value.data(using: .utf8)
        for d in data {
            debugPrint(d.reduce("", { $0 + String(format: "%d ", $1)}))
        }
    }
}
