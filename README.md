
# ESC/POS Printer Driver for Swift

# Description
Swift ticket printer framework for ESC/POS-compatible thermal printers


### Features
* Supports connect bluetooth printer.
* Create printable ticket easily.

## Requirements
* iOS 12.0+
* Swift 5.0

## Installation
### CocoaPods
#### iOS 12 and newer
Printer is available on CocoaPods. Simply add the following line to your podfile:

```
# For latest release in cocoapods
pod 'Printer', :git => 'https://github.com/Belorder/Printer.git', :branch => 'master'
```

### Carthage

```
original github "KevinGong2013/Printer"
our github "Belorder/Printer"
```

## Getting Started
### Import

```swift
import Printer

```

### Create ESC/POS Ticket

``` swift 

var ticket = Ticket()
ticket.add(block: .qr("https://google.com"))
ticket.add(block: .blank(1))

```

### Write Ticket to Hardware

``` swift

// connect your pirnter&print ticket.
private let bluetoothPrinterManager = BluetoothPrinterManager()
private let dummyPrinter = DummyPrinter()

 if bluetoothPrinterManager.canPrint {
    bluetoothPrinterManager.print(ticket)
  }
dummyPrinter.print(ticket)

```
