//
//  TicketManager.swift
//  Printer
//
//  Created by Geoffrey Desbrosses on 04/02/2026.
//  Copyright © 2026 Belorder. All rights reserved.
//

import Foundation
import CoreGraphics

// MARK: - Enums

public enum TicketType: String {
    case barcode = "Barcode"
    case blank = "Blank"
    case column = "Column"
    case dividingLine = "DividingLine"
    case image = "Image"
    case qrCode = "QrCode"
    case text = "Text"
}

public enum AlignStyle: String {
    case left = "LEFT"
    case center = "CENTER"
    case right = "RIGHT"
}

public enum BackgroundColorStyle: String {
    case black = "BLACK"
    case white = "WHITE"
}

// MARK: - Style Structs

public struct BarcodeStyle {
    public let height: Int?
    public let width: Int?

    public init(height: Int? = nil, width: Int? = nil) {
        self.height = height
        self.width = width
    }
}

public struct DividingLineStyle {
    public init() {}
}

public struct ImageStyle {
    public let alignment: AlignStyle?

    public init(alignment: AlignStyle? = nil) {
        self.alignment = alignment
    }
}

public struct QRStyle {
    public let height: Int?
    public let width: Int?

    public init(height: Int? = nil, width: Int? = nil) {
        self.height = height
        self.width = width
    }
}

public struct TextStyle {
    public let alignment: AlignStyle?
    public let backgroundColor: BackgroundColorStyle?
    public let font: UInt8?
    public let isBold: Bool?
    public let isLight: Bool?
    public let scale: String?

    public init(
        alignment: AlignStyle? = nil,
        backgroundColor: BackgroundColorStyle? = nil,
        font: UInt8? = nil,
        isBold: Bool? = nil,
        isLight: Bool? = nil,
        scale: String? = nil
    ) {
        self.alignment = alignment
        self.backgroundColor = backgroundColor
        self.font = font
        self.isBold = isBold
        self.isLight = isLight
        self.scale = scale
    }
}

// MARK: - TicketLine

public struct TicketLine<T, U> {
    public let style: T?
    public let type: TicketType?
    public let value: U

    public init(style: T?, type: TicketType?, value: U) {
        self.style = style
        self.type = type
        self.value = value
    }
}

// MARK: - TicketManager

public class TicketManager {

    // MARK: - Constants

    public static let defaultFeedPoint: UInt8 = 30

    // MARK: - Properties

    private var ticket: Ticket = Ticket()
    private var charsPerLine: Int = 48

    /// Closure to resolve image names to CGImage (must be set by the app)
    public var imageResolver: ((String) -> CGImage?)?

    // MARK: - Initialization

    public init(charsPerLine: Int = 48) {
        self.charsPerLine = charsPerLine
    }

    // MARK: - Public API

    /// Set the number of characters per line
    public func setCharsPerLine(_ count: Int) {
        self.charsPerLine = count
    }

    /// Create a ticket from dictionary array (from React Native)
    public func createTicket(from items: [[String: Any]], printLogo: Bool = false, logoImageName: String? = nil) -> Ticket {
        self.ticket = Ticket()
        self.ticket.feedLinesOnHead = 0
        self.ticket.feedLinesOnTail = 3
        Block.defaultFeedPoints = TicketManager.defaultFeedPoint

        for item in items {
            if let typeString = item["type"] as? String,
               let type = TicketType(rawValue: typeString) {

                switch type {
                case .barcode:
                    if let value = item["value"] as? String {
                        addBarcode(TicketLine(style: nil, type: type, value: value))
                    }

                case .blank:
                    addBlank()

                case .column:
                    if let valueArray = item["value"] as? [[String: Any]] {
                        var ticketLines: [TicketLine<TextStyle, String>] = []
                        for valueItem in valueArray {
                            if let ticketLine = parseTextTicketLine(from: valueItem) {
                                ticketLines.append(ticketLine)
                            }
                        }
                        addColumns(ticketLines)
                    }

                case .dividingLine:
                    if let value = item["value"] as? String {
                        addDividingLine(TicketLine(style: nil, type: type, value: value))
                    }

                case .image:
                    if let value = item["value"] as? String {
                        addImage(TicketLine<ImageStyle, String>(style: nil, type: .image, value: value))
                    }

                case .qrCode:
                    if let value = item["value"] as? String {
                        addQRCode(TicketLine(style: nil, type: type, value: value))
                    }

                case .text:
                    if let ticketLine = parseTextTicketLine(from: item) {
                        addText(ticketLine)
                    }
                }
            }
        }

        if printLogo, let logoName = logoImageName {
            addImage(TicketLine<ImageStyle, String>(
                style: ImageStyle(alignment: .center),
                type: .image,
                value: logoName
            ))
        }

        addBlank()

        return self.ticket
    }

    /// Create an empty ticket (for connection testing)
    public func createEmptyTicket() -> Ticket {
        self.ticket = Ticket()
        self.ticket.feedLinesOnHead = 0
        self.ticket.feedLinesOnTail = 3
        Block.defaultFeedPoints = TicketManager.defaultFeedPoint

        addBlank()

        return self.ticket
    }

    /// Create a test/dummy ticket
    public func createDummyTicket(logoImageName: String? = nil) -> Ticket {
        self.ticket = Ticket()
        self.ticket.feedLinesOnHead = 0
        self.ticket.feedLinesOnTail = 3
        Block.defaultFeedPoints = TicketManager.defaultFeedPoint

        addText(TicketLine(
            style: TextStyle(
                alignment: .center,
                backgroundColor: .black,
                font: 0,
                isBold: true,
                isLight: false,
                scale: "l1"
            ),
            type: .text,
            value: "Super test note"
        ))
        addBlank()
        addDividingLine(TicketLine(style: nil, type: .dividingLine, value: "-"))
        addText(TicketLine(style: nil, type: .text, value: "Test"))
        addDividingLine(TicketLine(style: nil, type: .dividingLine, value: "-"))

        if let logoName = logoImageName {
            addImage(TicketLine<ImageStyle, String>(
                style: ImageStyle(alignment: .center),
                type: .image,
                value: logoName
            ))
        }

        return self.ticket
    }

    // MARK: - Block Addition Methods

    /// Add a barcode to the ticket
    public func addBarcode(_ item: TicketLine<BarcodeStyle, String>) {
        // TODO: Implement barcode support
    }

    /// Add a blank line to the ticket
    public func addBlank() {
        self.ticket.add(block: .blank(1))
    }

    /// Add multiple columns of text
    public func addColumns(_ items: [TicketLine<TextStyle, String>]) {
        self.ticket.add(block: Block(items.map { createText(from: $0) }))
    }

    /// Add a dividing line
    public func addDividingLine(_ item: TicketLine<DividingLineStyle, String>) {
        self.ticket.add(block: .dividing(
            item.value,
            printDensity: self.charsPerLine,
            fontDensity: 1
        ))
    }

    /// Add an image by name
    public func addImage(_ item: TicketLine<ImageStyle, String>) {
        guard let resolver = imageResolver,
              let cgImage = resolver(item.value) else {
            debugPrint("[TicketManager] Image not found or resolver not set: \(item.value)")
            return
        }

        self.ticket.add(block: .image(
            Image(cgImage),
            attributes: TicketImage.PredefinedAttribute.alignment(.center)
        ))
    }

    /// Add an image from CGImage directly
    public func addImage(_ cgImage: CGImage, alignment: AlignStyle = .center) {
        let ticketAlignment: NSTextAlignment
        switch alignment {
        case .left:
            ticketAlignment = .left
        case .center:
            ticketAlignment = .center
        case .right:
            ticketAlignment = .right
        }

        self.ticket.add(block: .image(
            Image(cgImage),
            attributes: TicketImage.PredefinedAttribute.alignment(ticketAlignment)
        ))
    }

    /// Add a QR code
    public func addQRCode(_ item: TicketLine<QRStyle, String>) {
        self.ticket.add(block: .qr(item.value))
    }

    /// Add text
    public func addText(_ item: TicketLine<TextStyle, String>) {
        self.ticket.add(block: Block(
            createText(from: item),
            feedPoints: TicketManager.defaultFeedPoint
        ))
    }

    // MARK: - Private Helpers

    /// Create a Text object from a TicketLine
    private func createText(from item: TicketLine<TextStyle, String>) -> Text {
        var predefined: [Text.PredefinedAttribute] = []

        if let alignment = item.style?.alignment {
            switch alignment {
            case .left:
                predefined.append(.alignment(.left))
            case .right:
                predefined.append(.alignment(.right))
            case .center:
                predefined.append(.alignment(.center))
            }
        }

        if let isBold = item.style?.isBold, isBold {
            predefined.append(.bold)
        }

        if let font = item.style?.font {
            predefined.append(.font(font))
        }

        if let isLight = item.style?.isLight, isLight {
            predefined.append(.light)
        }

        if let scale = item.style?.scale {
            switch scale {
            case "l0": predefined.append(.scale(.l0))
            case "l1": predefined.append(.scale(.l1))
            case "l2": predefined.append(.scale(.l2))
            case "l3": predefined.append(.scale(.l3))
            case "l4": predefined.append(.scale(.l4))
            case "l5": predefined.append(.scale(.l5))
            case "l6": predefined.append(.scale(.l6))
            case "l7": predefined.append(.scale(.l7))
            case "l8": predefined.append(.scale(.l8))
            default: predefined.append(.scale(.l0))
            }
        }

        if let backgroundColor = item.style?.backgroundColor {
            switch backgroundColor {
            case .black:
                predefined.append(.blackBg)
            case .white:
                predefined.append(.whiteBg)
            }
        }

        return Text(item.value, attributes: predefined)
    }

    /// Parse a TextStyle from a dictionary
    private func parseTextStyle(from dict: [String: Any]) -> TextStyle? {
        let alignment = (dict["alignment"] as? String).flatMap { AlignStyle(rawValue: $0) }
        let backgroundColor = (dict["backgroundColor"] as? String).flatMap { BackgroundColorStyle(rawValue: $0) }
        let font = dict["font"] as? UInt8
        let isBold = dict["isBold"] as? Bool
        let isLight = dict["isLight"] as? Bool
        let scale = dict["scale"] as? String

        return TextStyle(
            alignment: alignment,
            backgroundColor: backgroundColor,
            font: font,
            isBold: isBold,
            isLight: isLight,
            scale: scale
        )
    }

    /// Parse a TicketLine<TextStyle, String> from a dictionary
    private func parseTextTicketLine(from dict: [String: Any]) -> TicketLine<TextStyle, String>? {
        guard let styleDict = dict["style"] as? [String: Any],
              let style = parseTextStyle(from: styleDict),
              let type = dict["type"] as? String,
              let value = dict["value"] as? String else {
            return nil
        }

        return TicketLine(style: style, type: TicketType(rawValue: type), value: value)
    }
}
