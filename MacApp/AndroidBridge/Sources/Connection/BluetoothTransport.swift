import Foundation
import CoreBluetooth
import os

/// Bluetooth-LE fallback link on the Mac side (central). Scans for the phone's
/// Nordic-UART-style service, subscribes to its notify characteristic, and carries
/// the SAME length-prefixed protobuf Envelope stream as Wi-Fi — so notifications,
/// SMS and calls keep working when there's no Wi-Fi. Big payloads never travel here.
///
/// NOTE: needs the Mac and phone to be in BLE range and the app granted Bluetooth
/// permission. This is a first version and wants on-device testing.
final class BluetoothTransport: NSObject {

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Bluetooth")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?      // write: Mac → phone
    private var txChar: CBCharacteristic?      // notify: phone → Mac

    private var writeMTU = 20
    private var rxBuffer = Data()
    private var expectedLen = -1

    private var sendQueue: [Data] = []
    private var writing = false
    private let bleQueue = DispatchQueue(label: "com.androidbridge.ble")

    // Duty-cycled scanning: scan for a short window, then idle, so we don't keep the
    // Bluetooth radio pegged (continuous BLE scanning contends with AirPods audio).
    private var scanTimer: DispatchSourceTimer?
    private let scanWindow: TimeInterval = 6     // scan for 6s…
    private let scanIdle: TimeInterval = 30      // …then rest for 30s before trying again
    private var wantScanning = false

    /// Called (on the BLE queue) with each fully-reassembled Envelope from the phone.
    var onEnvelope: ((ABEnvelope) -> Void)?
    /// Called when the BLE link comes up (true) or drops (false).
    var onLinkChange: ((Bool) -> Void)?

    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write to phone
    private let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify from phone

    private let maxMessage = 24 * 1024

    var isLinked: Bool { peripheral?.state == .connected && rxChar != nil && txChar != nil }

    func start() {
        bleQueue.async {
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.bleQueue)
            } else {
                self.startScanning()
            }
        }
    }

    func stop() {
        bleQueue.async {
            self.wantScanning = false
            self.scanTimer?.cancel(); self.scanTimer = nil
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.central?.stopScan()
            self.peripheral = nil
            self.rxChar = nil
            self.txChar = nil
            self.sendQueue.removeAll()
            self.writing = false
            self.rxBuffer.removeAll()
            self.expectedLen = -1
        }
    }

    /// Frame + chunk + write an Envelope to the phone over BLE.
    func send(_ env: ABEnvelope) {
        bleQueue.async {
            guard self.isLinked, self.rxChar != nil else { return }
            guard let body = try? env.serializedData(), body.count <= self.maxMessage else { return }

            var framed = Data(capacity: 4 + body.count)
            let len = UInt32(body.count)
            framed.append(UInt8((len >> 24) & 0xFF))
            framed.append(UInt8((len >> 16) & 0xFF))
            framed.append(UInt8((len >> 8) & 0xFF))
            framed.append(UInt8(len & 0xFF))
            framed.append(body)

            var off = 0
            while off < framed.count {
                let end = min(off + self.writeMTU, framed.count)
                self.sendQueue.append(framed.subdata(in: off..<end))
                off = end
            }
            self.drain()
        }
    }

    private func drain() {
        guard !writing, let peripheral = peripheral, let rx = rxChar, !sendQueue.isEmpty else { return }
        writing = true
        let chunk = sendQueue.removeFirst()
        peripheral.writeValue(chunk, for: rx, type: .withResponse)
    }

    /// Begin (or resume) duty-cycled scanning: a short scan window, then a long idle,
    /// looping until we link. This keeps the Bluetooth radio mostly free so it doesn't
    /// stutter AirPods audio.
    private func startScanning() {
        wantScanning = true
        scanBurst()
    }

    private func scanBurst() {
        guard wantScanning, peripheral == nil, central?.state == .poweredOn else { return }
        logger.info("BLE scan window (\(Int(self.scanWindow))s)")
        central?.scanForPeripherals(withServices: [serviceUUID], options: nil)

        scanTimer?.cancel()
        let stopTimer = DispatchSource.makeTimerSource(queue: bleQueue)
        stopTimer.schedule(deadline: .now() + scanWindow)
        stopTimer.setEventHandler { [weak self] in
            guard let self, self.peripheral == nil else { return }
            self.central?.stopScan()                       // rest the radio
            let idleTimer = DispatchSource.makeTimerSource(queue: self.bleQueue)
            idleTimer.schedule(deadline: .now() + self.scanIdle)
            idleTimer.setEventHandler { [weak self] in self?.scanBurst() }
            idleTimer.resume()
            self.scanTimer = idleTimer
        }
        stopTimer.resume()
        scanTimer = stopTimer
    }

    private func stopScanning() {
        wantScanning = false
        scanTimer?.cancel(); scanTimer = nil
        central?.stopScan()
    }

    private func handleIncoming(_ data: Data) {
        rxBuffer.append(data)
        while true {
            if expectedLen < 0 {
                guard rxBuffer.count >= 4 else { return }
                let b = [UInt8](rxBuffer.prefix(4))
                expectedLen = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
                if expectedLen <= 0 || expectedLen > maxMessage {
                    logger.warning("Bad BLE frame length \(self.expectedLen) — resetting")
                    rxBuffer.removeAll(); expectedLen = -1; return
                }
            }
            guard rxBuffer.count >= 4 + expectedLen else { return }
            let body = rxBuffer.subdata(in: 4..<(4 + expectedLen))
            rxBuffer.removeSubrange(0..<(4 + expectedLen))
            expectedLen = -1
            if let env = try? ABEnvelope(serializedData: body) {
                onEnvelope?(env)
            } else {
                logger.warning("Bad BLE envelope")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff, .unauthorized, .unsupported:
            logger.info("BLE unavailable: \(String(describing: central.state.rawValue))")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        logger.info("BLE discovered phone — connecting")
        self.peripheral = peripheral
        stopScanning()   // found it — stop the scan cycle while we connect
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("BLE connected — discovering service")
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.warning("BLE connect failed — rescanning")
        self.peripheral = nil
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("BLE disconnected — rescanning")
        self.peripheral = nil
        self.rxChar = nil
        self.txChar = nil
        self.sendQueue.removeAll()
        self.writing = false
        self.rxBuffer.removeAll()
        self.expectedLen = -1
        onLinkChange?(false)
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == rxUUID { rxChar = char }
            if char.uuid == txUUID {
                txChar = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
        writeMTU = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        if rxChar != nil && txChar != nil {
            logger.info("BLE link ready (writeMTU=\(self.writeMTU))")
            onLinkChange?(true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == txUUID, let data = characteristic.value else { return }
        handleIncoming(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        drain()
    }
}
