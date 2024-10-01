//
//  Block.swift
//  Ticket
//
//  Created by gix on 2019/6/30.
//  Copyright © 2019 gix. All rights reserved.
//

import Foundation

public protocol Printable {
    func data(using encoding: String.Encoding) -> Data
}

public protocol BlockDataProvider: Printable { }

public protocol Attribute {
    var attribute: [UInt8] { get }
}

public struct Block: Printable {

    public static var defaultFeedPoints: UInt8 = 70
    
    private enum DataProviderType {
          case single(BlockDataProvider)
          case multiple([BlockDataProvider])
      }
    
    private let feedPoints: UInt8
    private let dataProvider: DataProviderType

    public init(_ dataProvider: BlockDataProvider, feedPoints: UInt8 = Block.defaultFeedPoints) {
        self.feedPoints = feedPoints
        self.dataProvider = .single(dataProvider)
    }

    public init(_ dataProviders: [BlockDataProvider], feedPoints: UInt8 = Block.defaultFeedPoints) {
        self.feedPoints = feedPoints
        self.dataProvider = .multiple(dataProviders)
    }
    
    public func data(using encoding: String.Encoding) -> Data {
        switch dataProvider {
        case .single(let provider):
            return provider.data(using: encoding) + Data.print(feedPoints)
        case .multiple(let providers):
            let combinedData = providers.reduce(Data()) { (result, provider) in
                return result + provider.data(using: encoding)
            }
            return combinedData + Data.print(feedPoints)
        }
    }
}

public extension Block {
    // blank line
    static var blank = Block(Blank())
    
    static func blank(_ line: UInt8) -> Block {
        return Block(Blank(), feedPoints: Block.defaultFeedPoints * line)
    }
    
    // qr
    static func qr(_ content: String) -> Block {
        return Block(QRCode(content))
    }
    
    // title
    static func title(_ content: String) -> Block {
        return Block(Text.title(content))
    }
    
    // plain text
    static func plainText(_ content: String) -> Block {
        return Block(Text.init(content))
    }
    
    static func text(_ text: Text) -> Block {
        return Block(text)
    }
    
    // key    value
    static func kv(k: String, v: String) -> Block {
        return Block(Text.kv(k: k, v: v))
    }
    
    // dividing
    static func dividing(_ character: String, printDensity: Int = 384, fontDensity: Int = 12) -> Block {
        return Block(Dividing(provider: Character(character), printDensity: printDensity, fontDensity: fontDensity))
    }
    
    // image
    static func image(_ im: Image, attributes: TicketImage.PredefinedAttribute...) -> Block {
        return Block(TicketImage(im, attributes: attributes))
    }
    
}
