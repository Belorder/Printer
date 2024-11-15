//
//  Blank.swift
//  Printer
//
//  Created by Geoffrey Desbrosses on 12/09/2024.
//  Copyright © 2024 Belorder. All rights reserved.
//
import Foundation

struct Blank: BlockDataProvider {
    func data(using encoding: String.Encoding) -> Data {
        return Data()
    }
}
