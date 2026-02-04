//
//  Block.swift
//  Printer
//
//  Created by Geoffrey Desbrosses on 03/02/2026.
//  Copyright © 2024 Belorder. All rights reserved.
//
import Foundation
import CoreBluetooth

// MARK: - String Encoding Extension

public extension String {
    struct GBEncoding {
        public static let GB_18030_2000 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
    }
}

// MARK: - Bluetooth Printer Model

public struct BluetoothPrinter: Equatable {

    public enum State {
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    public let name: String?
    public let identifier: UUID
    public var state: State

    public var isConnecting: Bool {
        return state == .connecting
    }

    init(peripheral: CBPeripheral, state: State = .disconnected) {
        self.name = peripheral.name
        self.identifier = peripheral.identifier
        self.state = state
    }

    init(peripheral: CBPeripheral, advertisedName: String?, state: State = .disconnected) {
        // Prefer advertised name (localName) over peripheral.name, fallback to "N/A"
        let peripheralName = peripheral.name ?? ""
        let advName = advertisedName ?? ""
        if !advName.isEmpty {
            self.name = advName
        } else if !peripheralName.isEmpty {
            self.name = peripheralName
        } else {
            self.name = "N/A" + " (\(peripheral.identifier))"
        }
        self.identifier = peripheral.identifier
        self.state = state
    }

    public func getName() -> String {
        return self.name ?? "N/A" + " (\(self.identifier))"
    }

    public func getIdentifier() -> String {
        return self.identifier.uuidString
    }

    public static func == (lhs: BluetoothPrinter, rhs: BluetoothPrinter) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}

// MARK: - Nearby Printer Change

public enum NearbyPrinterChange {
    case add(BluetoothPrinter)
    case update(BluetoothPrinter)
    case remove(UUID)
}

// MARK: - Printer Manager Delegate

public protocol PrinterManagerDelegate: AnyObject {
    func nearbyPrinterDidChange(_ change: NearbyPrinterChange)
}

// MARK: - Bluetooth Printer Manager

public class BluetoothPrinterManager: NSObject {

    // MARK: - Configuration

    /// Chunk size for BLE transmission - will be auto-adjusted based on MTU if autoAdjustChunkSize is true
    /// Smaller chunks = more reliable but slower
    public var chunkSize: Int = 20

    /// Delay between chunks in seconds (increase if printing is choppy)
    public var chunkDelay: TimeInterval = 0.05

    /// Connection timeout in seconds
    private let connectionTimeout: TimeInterval = 15.0

    /// Force write with response for better flow control (recommended for printers)
    public var forceWriteWithResponse: Bool = true

    /// Automatically adjust chunkSize based on negotiated MTU
    public var autoAdjustChunkSize: Bool = true

    /// Current negotiated MTU (read-only)
    public private(set) var currentMTU: Int = 20

    /// Known printer service UUIDs
    public static var specifiedServices: Set<String> = [
        // Generic printer services
        "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2",
        "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
        "18F0",
        "FF00",
        // Star Micronics printers
        "00001101-0000-1000-8000-00805F9B34FB",  // SPP UUID
        // Epson printers (TM series BLE)
        "00000001-0000-1000-8000-00805F9B34FB",
        "000018F0-0000-1000-8000-00805F9B34FB",
        "48454C50-4F4E-4543-4F4E-4E4543540000",  // Epson Connect
        "0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D",  // Epson proprietary
        // AURES printers
        "0000180F-0000-1000-8000-00805F9B34FB",  // Battery service (common)
        "0000180A-0000-1000-8000-00805F9B34FB",  // Device info
        // Citizen printers
        "A2F80000-1111-2222-3333-444455556666",
        // Brother printers
        "1820",
        // Generic BLE printers
        "FFF0",
        "FFE0",
        "FEE0",
        "1800",  // Generic Access
        "1801"   // Generic Attribute
    ]

    /// Known printer characteristic UUIDs
    public static var specifiedCharacteristics: Set<String>? = [
        "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F",
        "49535343-8841-43F4-A8D4-ECBE34729BB3",
        "2AF1",
        "FF02",
        // Additional common printer characteristics
        "FFF1",
        "FFF2",
        "FFE1",
        "FFE2",
        "FEE1",
        "1823",  // Brother
        "00002AF1-0000-1000-8000-00805F9B34FB"
    ]

    // MARK: - Properties

    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var advertisedNames: [UUID: String] = [:]  // Cache for advertised names (localName)
    private var knownServiceDevices: Set<UUID> = []  // Devices that advertise known printer services
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var connectionTimer: Timer?

    public weak var delegate: PrinterManagerDelegate?
    public var errorReport: ((PrinterError) -> Void)?

    /// Callbacks for connection events
    public var onConnectionReady: ((BluetoothPrinter) -> Void)?
    public var onConnectionLost: ((BluetoothPrinter?, PrinterError?) -> Void)?

    /// Currently connected printer UUID
    public private(set) var connectedPrinterUUID: UUID?

    // Data sending state
    private var dataQueue: [Data] = []
    private var isSending = false
    private var printCompletion: ((PrinterError?) -> Void)?

    // MARK: - Computed Properties

    public var nearbyPrinters: [BluetoothPrinter] {
        return discoveredPeripherals.values
            .map { peripheral -> BluetoothPrinter in
                var state: BluetoothPrinter.State = .disconnected
                if let connected = connectedPeripheral, connected.identifier == peripheral.identifier {
                    state = writeCharacteristic != nil ? .connected : .connecting
                }
                let advertisedName = advertisedNames[peripheral.identifier]
                return BluetoothPrinter(peripheral: peripheral, advertisedName: advertisedName, state: state)
            }
            .sorted { printer1, printer2 in
                // Sort priority:
                // 0: Has name + known service
                // 1: Has name + no known service
                // 2: No name + known service
                // 3: No name + no known service
                func priority(_ printer: BluetoothPrinter) -> Int {
                    let hasName = printer.name != nil && !printer.name!.hasPrefix("N/A")
                    let hasKnownService = knownServiceDevices.contains(printer.identifier)

                    if hasName && hasKnownService { return 0 }
                    if hasName && !hasKnownService { return 1 }
                    if !hasName && hasKnownService { return 2 }
                    return 3
                }
                return priority(printer1) < priority(printer2)
            }
    }

    public var canPrint: Bool {
        return connectedPeripheral != nil && writeCharacteristic != nil
    }

    // MARK: - Initialization

    public override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        debugPrint("[BluetoothPrinterManager] Initialized")
    }

    public init(delegate: PrinterManagerDelegate?) {
        super.init()
        self.delegate = delegate
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        debugPrint("[BluetoothPrinterManager] Initialized with delegate")
    }

    deinit {
        connectionTimer?.invalidate()
        disconnectAllPrinter()
    }

    // MARK: - Public Methods

    /// Start scanning for nearby printers
    public func startScan() -> PrinterError? {
        guard centralManager.state == .poweredOn else {
            debugPrint("[BluetoothPrinterManager] Cannot scan - Bluetooth not ready")
            return .deviceNotReady
        }

        guard !centralManager.isScanning else {
            debugPrint("[BluetoothPrinterManager] Already scanning")
            return nil
        }

        discoveredPeripherals.removeAll()
        advertisedNames.removeAll()
        knownServiceDevices.removeAll()

        // First, retrieve already connected peripherals (they don't appear in scan)
        let serviceUUIDs = BluetoothPrinterManager.specifiedServices.compactMap { CBUUID(string: $0) }
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: serviceUUIDs)
        for peripheral in connectedPeripherals {
            discoveredPeripherals[peripheral.identifier] = peripheral
            knownServiceDevices.insert(peripheral.identifier)
            debugPrint("[BluetoothPrinterManager] Found already connected: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
        }

        // Also include our currently connected peripheral if actually connected
        if let currentPeripheral = connectedPeripheral, currentPeripheral.state == .connected {
            discoveredPeripherals[currentPeripheral.identifier] = currentPeripheral
            debugPrint("[BluetoothPrinterManager] Added current connection: \(currentPeripheral.name ?? "Unknown")")
        }

        // Scan for all devices to find printers
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        debugPrint("[BluetoothPrinterManager] Started scanning")
        return nil
    }

    /// Stop scanning
    public func stopScan() {
        centralManager.stopScan()
        debugPrint("[BluetoothPrinterManager] Stopped scanning")
    }

    /// Check if a specific printer is connected and ready
    public func isConnectedAndReady(uuid: UUID) -> Bool {
        guard canPrint else { return false }
        return connectedPrinterUUID == uuid
    }

    /// Get printer by UUID
    public func getPrinter(uuid: UUID) -> BluetoothPrinter? {
        guard let peripheral = discoveredPeripherals[uuid] else { return nil }
        return BluetoothPrinter(peripheral: peripheral)
    }

    /// Connect to a printer
    public func connect(_ printer: BluetoothPrinter) {
        guard let peripheral = discoveredPeripherals[printer.identifier] else {
            debugPrint("[BluetoothPrinterManager] Printer not found: \(printer.identifier)")
            return
        }

        // Disconnect from current if different
        if let current = connectedPeripheral, current.identifier != peripheral.identifier {
            disconnect(BluetoothPrinter(peripheral: current))
        }

        debugPrint("[BluetoothPrinterManager] Connecting to: \(printer.name ?? "Unknown")")

        // Update state
        var updatedPrinter = printer
        updatedPrinter.state = .connecting
        notifyChange(.update(updatedPrinter))

        // Start connection timeout
        startConnectionTimeout(for: printer.identifier)

        // Connect
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    /// Connect with completion callback
    public func connect(_ printer: BluetoothPrinter, completion: @escaping (Bool, PrinterError?) -> Void) {
        // If already connected and ready, return immediately
        if isConnectedAndReady(uuid: printer.identifier) {
            completion(true, nil)
            return
        }

        // Store completion for later
        var didComplete = false
        let previousOnReady = onConnectionReady
        let previousOnLost = onConnectionLost

        onConnectionReady = { [weak self] connectedPrinter in
            previousOnReady?(connectedPrinter)
            guard !didComplete, connectedPrinter.identifier == printer.identifier else { return }
            didComplete = true
            self?.onConnectionReady = previousOnReady
            self?.onConnectionLost = previousOnLost
            completion(true, nil)
        }

        onConnectionLost = { [weak self] disconnectedPrinter, error in
            previousOnLost?(disconnectedPrinter, error)
            guard !didComplete else { return }
            if disconnectedPrinter?.identifier == printer.identifier || disconnectedPrinter == nil {
                didComplete = true
                self?.onConnectionReady = previousOnReady
                self?.onConnectionLost = previousOnLost
                completion(false, error ?? .connectFailed)
            }
        }

        connect(printer)
    }

    /// Disconnect from a printer
    public func disconnect(_ printer: BluetoothPrinter) {
        guard let peripheral = discoveredPeripherals[printer.identifier] else { return }

        debugPrint("[BluetoothPrinterManager] Disconnecting from: \(printer.name ?? "Unknown")")

        var updatedPrinter = printer
        updatedPrinter.state = .disconnecting
        notifyChange(.update(updatedPrinter))

        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Disconnect from all printers
    public func disconnectAllPrinter() {
        for peripheral in discoveredPeripherals.values {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    /// Print ESC/POS content (requires already connected)
    public func print(_ content: ESCPOSCommandsCreator, encoding: String.Encoding = .utf8, completeBlock: ((PrinterError?) -> Void)? = nil) {

        guard canPrint else {
            debugPrint("[BluetoothPrinterManager] Cannot print - not ready")
            completeBlock?(.deviceNotReady)
            return
        }

        // Get data from content
        let dataChunks = content.data(using: encoding)

        // Combine all data
        var allData = Data()
        for chunk in dataChunks {
            allData.append(chunk)
        }

        // Add paper cut command
        let paperCutCommand: [UInt8] = [0x1D, 0x56, 0x00]
        allData.append(Data(paperCutCommand))

        debugPrint("[BluetoothPrinterManager] Printing \(allData.count) bytes")

        // Print the data
        printData(allData, completion: completeBlock)
    }

    // MARK: - High-Level Print API

    /// Print to a specific printer by UUID - handles connection automatically
    /// This is the main method to use for printing
    public func printToDevice(
        uuid: String,
        content: ESCPOSCommandsCreator,
        encoding: String.Encoding = .utf8,
        completion: @escaping (PrinterError?) -> Void
    ) {
        guard let printerUUID = UUID(uuidString: uuid) else {
            debugPrint("[BluetoothPrinterManager] Invalid UUID: \(uuid)")
            completion(.deviceNotReady)
            return
        }

        debugPrint("[BluetoothPrinterManager] printToDevice: \(uuid)")

        // Already connected to this printer?
        if isConnectedAndReady(uuid: printerUUID) {
            debugPrint("[BluetoothPrinterManager] Already connected, printing directly")
            print(content, encoding: encoding, completeBlock: completion)
            return
        }

        // Try to find the printer in discovered peripherals first
        var printer = getPrinter(uuid: printerUUID)

        // If not found in discovered, try to retrieve it directly by UUID
        // This works for previously paired/connected devices without needing a scan
        if printer == nil {
            debugPrint("[BluetoothPrinterManager] Printer not in discovered list, trying to retrieve by UUID...")
            if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [printerUUID]).first {
                // Add to discovered peripherals for future use
                discoveredPeripherals[printerUUID] = peripheral
                printer = BluetoothPrinter(peripheral: peripheral, advertisedName: nil)
                debugPrint("[BluetoothPrinterManager] Retrieved peripheral: \(peripheral.name ?? "Unknown")")
            }
        }

        guard let printer = printer else {
            debugPrint("[BluetoothPrinterManager] Printer not found: \(uuid)")
            completion(.deviceNotReady)
            return
        }

        debugPrint("[BluetoothPrinterManager] Connecting to printer...")

        // Connect then print
        connect(printer) { [weak self] success, error in
            if success {
                debugPrint("[BluetoothPrinterManager] Connected, now printing...")
                self?.print(content, encoding: encoding, completeBlock: completion)
            } else {
                debugPrint("[BluetoothPrinterManager] Connection failed: \(error?.errorDescription ?? "unknown")")
                completion(error ?? .connectFailed)
            }
        }
    }

    /// Scan for printers and return results after specified duration
    public func scanForPrinters(duration: TimeInterval = 5.0, completion: @escaping ([BluetoothPrinter]) -> Void) {
        debugPrint("[BluetoothPrinterManager] Scanning for \(duration) seconds...")

        _ = startScan()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.stopScan()
            let printers = self?.nearbyPrinters ?? []
            debugPrint("[BluetoothPrinterManager] Found \(printers.count) printers")
            completion(printers)
        }
    }

    /// Print raw data
    public func printData(_ data: Data, completion: ((PrinterError?) -> Void)? = nil) {
        guard canPrint else {
            debugPrint("[BluetoothPrinterManager] Cannot print - not ready")
            completion?(.deviceNotReady)
            return
        }

        // Split into BLE-sized chunks
        dataQueue = splitIntoChunks(data)
        printCompletion = completion

        debugPrint("[BluetoothPrinterManager] Split into \(dataQueue.count) chunks of max \(chunkSize) bytes")

        // Start sending
        sendNextChunk()
    }

    // MARK: - Private Methods

    private func cleanup() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        connectedPeripheral = nil
        writeCharacteristic = nil
        connectedPrinterUUID = nil
        dataQueue.removeAll()
        isSending = false
    }

    private func startConnectionTimeout(for uuid: UUID) {
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            self?.handleConnectionTimeout(uuid: uuid)
        }
    }

    private func handleConnectionTimeout(uuid: UUID) {
        debugPrint("[BluetoothPrinterManager] Connection timeout for: \(uuid)")

        if let peripheral = discoveredPeripherals[uuid] {
            centralManager.cancelPeripheralConnection(peripheral)

            var printer = BluetoothPrinter(peripheral: peripheral)
            printer.state = .disconnected
            notifyChange(.update(printer))
        }

        cleanup()
        errorReport?(.connectFailed)
        onConnectionLost?(nil, .connectFailed)
    }

    private func splitIntoChunks(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        var offset = 0

        while offset < data.count {
            let length = min(chunkSize, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            chunks.append(chunk)
            offset += length
        }

        return chunks
    }

    private func sendNextChunk() {
        guard !dataQueue.isEmpty else {
            debugPrint("[BluetoothPrinterManager] All chunks sent")
            isSending = false
            printCompletion?(nil)
            printCompletion = nil
            return
        }

        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else {
            debugPrint("[BluetoothPrinterManager] Disconnected during print")
            isSending = false
            printCompletion?(.deviceNotReady)
            printCompletion = nil
            return
        }

        isSending = true
        let chunk = dataQueue.removeFirst()

        // Determine write type - prefer withResponse for better flow control with printers
        let writeType: CBCharacteristicWriteType
        if forceWriteWithResponse && characteristic.properties.contains(.write) {
            writeType = .withResponse
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else {
            writeType = .withResponse
        }

        peripheral.writeValue(chunk, for: characteristic, type: writeType)

        // If using writeWithoutResponse, manually pace with delay
        if writeType == .withoutResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + chunkDelay) { [weak self] in
                self?.sendNextChunk()
            }
        }
        // For .withResponse, sendNextChunk is called from didWriteValueFor
    }

    private func notifyChange(_ change: NearbyPrinterChange) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.nearbyPrinterDidChange(change)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothPrinterManager: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debugPrint("[BluetoothPrinterManager] Bluetooth state: \(central.state.rawValue)")

        if central.state == .poweredOff {
            cleanup()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {

        let name = peripheral.name ?? ""
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let displayName = !localName.isEmpty ? localName : name

        // Get advertised service UUIDs
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceUUIDStrings = Set(serviceUUIDs.map { $0.uuidString.uppercased() })

        // Check if this device advertises known printer services
        let hasKnownService = !serviceUUIDStrings.isDisjoint(with: BluetoothPrinterManager.specifiedServices.map { $0.uppercased() })

        // Check if already discovered
        let isNew = discoveredPeripherals[peripheral.identifier] == nil

        // Store peripheral and cache the advertised name
        discoveredPeripherals[peripheral.identifier] = peripheral
        if !localName.isEmpty {
            advertisedNames[peripheral.identifier] = localName
        }

        // Track if this device has known printer services
        if hasKnownService {
            knownServiceDevices.insert(peripheral.identifier)
        }

        // Notify delegate - use localName from advertisement if available
        let printer = BluetoothPrinter(peripheral: peripheral, advertisedName: advertisedNames[peripheral.identifier])
        if isNew {
            debugPrint("[BluetoothPrinterManager] Discovered: \(displayName.isEmpty ? "N/A" : displayName) (\(peripheral.identifier))")
            notifyChange(.add(printer))
        } else {
            notifyChange(.update(printer))
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        debugPrint("[BluetoothPrinterManager] Connected to: \(peripheral.name ?? "Unknown")")

        connectionTimer?.invalidate()
        connectionTimer = nil

        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        debugPrint("[BluetoothPrinterManager] Failed to connect: \(error?.localizedDescription ?? "Unknown")")

        connectionTimer?.invalidate()
        connectionTimer = nil

        var printer = BluetoothPrinter(peripheral: peripheral)
        printer.state = .disconnected
        notifyChange(.update(printer))

        cleanup()
        errorReport?(.connectFailed)
        onConnectionLost?(printer, .connectFailed)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        debugPrint("[BluetoothPrinterManager] Disconnected from: \(peripheral.name ?? "Unknown")")

        var printer = BluetoothPrinter(peripheral: peripheral)
        printer.state = .disconnected
        notifyChange(.update(printer))

        let wasConnected = connectedPrinterUUID == peripheral.identifier
        cleanup()

        if wasConnected {
            onConnectionLost?(printer, error != nil ? .connectFailed : nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothPrinterManager: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            debugPrint("[BluetoothPrinterManager] Service discovery error: \(error?.localizedDescription ?? "No services")")
            return
        }

        debugPrint("[BluetoothPrinterManager] Found \(services.count) services")

        for service in services {
            debugPrint("[BluetoothPrinterManager] Service: \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            debugPrint("[BluetoothPrinterManager] Characteristic: \(characteristic.uuid.uuidString) - Props: \(characteristic.properties.rawValue)")

            // Look for writable characteristic
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {

                let isKnown = BluetoothPrinterManager.specifiedCharacteristics?.contains(characteristic.uuid.uuidString) ?? false
                let serviceIsKnown = BluetoothPrinterManager.specifiedServices.contains(service.uuid.uuidString)

                // Only set writeCharacteristic if we don't have one yet
                // Don't change characteristic while printing or if already set
                let shouldUseThisCharacteristic = writeCharacteristic == nil ||
                    (isKnown && !BluetoothPrinterManager.specifiedCharacteristics!.contains(writeCharacteristic!.uuid.uuidString))

                if shouldUseThisCharacteristic && !isSending {
                    writeCharacteristic = characteristic
                    connectedPrinterUUID = peripheral.identifier

                    debugPrint("[BluetoothPrinterManager] Write characteristic found: \(characteristic.uuid.uuidString)")

                    // Get negotiated MTU and adjust chunk size
                    let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                    let mtu = peripheral.maximumWriteValueLength(for: writeType)
                    currentMTU = mtu
                    debugPrint("[BluetoothPrinterManager] Negotiated MTU: \(mtu) bytes")

                    if autoAdjustChunkSize && mtu > 0 {
                        // Use MTU minus a small margin for safety
                        // Cap at 180 bytes max - larger chunks can cause issues with some printers
                        chunkSize = min(180, max(20, mtu - 3))
                        debugPrint("[BluetoothPrinterManager] Auto-adjusted chunkSize to: \(chunkSize) bytes (MTU: \(mtu))")
                    }

                    // Notify that printer is ready
                    var printer = BluetoothPrinter(peripheral: peripheral)
                    printer.state = .connected
                    notifyChange(.update(printer))

                    DispatchQueue.main.async { [weak self] in
                        self?.onConnectionReady?(printer)
                    }
                } else {
                    debugPrint("[BluetoothPrinterManager] Skipping characteristic \(characteristic.uuid.uuidString) - already have one or printing in progress")
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            debugPrint("[BluetoothPrinterManager] Write error: \(error.localizedDescription)")
            dataQueue.removeAll()
            isSending = false
            printCompletion?(.unknownError)
            printCompletion = nil
            return
        }

        // Continue with next chunk after small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + chunkDelay) { [weak self] in
            self?.sendNextChunk()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Handle notifications from printer if needed
        if let value = characteristic.value {
            debugPrint("[BluetoothPrinterManager] Received: \(value.count) bytes")
        }
    }
}
