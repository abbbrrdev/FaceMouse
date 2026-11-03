import Foundation
import Combine
@preconcurrency import CoreBluetooth
import WatchKit

/// Прямая связь часов с Mac по Bluetooth LE — без iPhone.
///
/// Часы — central: ищут Mac по сервису FaceMouse.BLE.service, подключаются,
/// подписываются на status, представляются (WatchHello) и ждут «Разрешить» на Mac.
/// Последний Mac запоминается, при следующем запуске подключаемся к нему сами.
@MainActor
final class MacLink: NSObject, ObservableObject {
    enum State: Equatable {
        case bluetoothOff
        case unauthorized
        case idle
        case scanning
        case connecting(String)
        case waitingApproval(String)
        case connected(String)
        case denied(String)
    }

    struct FoundMac: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var found: [FoundMac] = []

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var macName: String? {
        switch state {
        case let .connecting(name), let .waitingApproval(name), let .connected(name), let .denied(name):
            return name
        default:
            return nil
        }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var commandCharacteristic: CBCharacteristic?
    private var poseCharacteristic: CBCharacteristic?
    private var helloCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    /// Пользователь сам нажал «Отключить» — не переподключаемся
    private var userDisconnected = false
    private var pendingScan = false

    private let encoder = JSONEncoder()

    private let serviceUUID = CBUUID(string: FaceMouse.BLE.service)
    private let helloUUID = CBUUID(string: FaceMouse.BLE.hello)
    private let commandUUID = CBUUID(string: FaceMouse.BLE.command)
    private let poseUUID = CBUUID(string: FaceMouse.BLE.pose)
    private let statusUUID = CBUUID(string: FaceMouse.BLE.status)

    private enum Key {
        static let lastMac = "lastMacID"
        static let lastMacName = "lastMacName"
        static let watchID = "watchID"
    }

    /// Постоянный id часов — по нему Mac помнит «Всегда разрешать»
    private var watchID: String {
        if let id = UserDefaults.standard.string(forKey: Key.watchID) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Key.watchID)
        return id
    }

    // MARK: - Публичное

    /// Поднимаем Bluetooth и пробуем подключиться к последнему Mac.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Кнопка «Подключиться к Mac»: ищем все Mac рядом.
    func scan() {
        userDisconnected = false
        guard let central, central.state == .poweredOn else {
            pendingScan = true
            start()
            return
        }
        found = []
        state = .scanning
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    func stopScan() {
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ mac: FoundMac) {
        guard let central, let target = peripherals[mac.id] else { return }
        central.stopScan()
        userDisconnected = false
        UserDefaults.standard.set(mac.id.uuidString, forKey: Key.lastMac)
        UserDefaults.standard.set(mac.name, forKey: Key.lastMacName)
        open(target, name: mac.name)
    }

    func disconnect() {
        userDisconnected = true
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetCharacteristics()
        peripheral = nil
        state = .idle
    }

    /// Забыть Mac (больше не подключаться автоматически).
    func forget() {
        UserDefaults.standard.removeObject(forKey: Key.lastMac)
        UserDefaults.standard.removeObject(forKey: Key.lastMacName)
        disconnect()
    }

    /// Клики и медиа — с подтверждением доставки, поза — «выстрелил и забыл».
    func send(_ message: FaceMessage) {
        guard isConnected, let peripheral else { return }
        let rounded: FaceMessage
        if case let .pose(yaw, pitch, scrolling, freeze) = message {
            // Короче JSON — меньше пакет по Bluetooth
            rounded = .pose(yaw: (yaw * 10).rounded() / 10, pitch: (pitch * 10).rounded() / 10,
                            scrolling: scrolling, freeze: freeze)
        } else {
            rounded = message
        }
        guard let data = try? encoder.encode(rounded) else { return }

        if case .pose = rounded {
            guard let characteristic = poseCharacteristic,
                  peripheral.canSendWriteWithoutResponse,
                  data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else { return }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            guard let characteristic = commandCharacteristic else { return }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    // MARK: - Подключение

    private func open(_ target: CBPeripheral, name: String) {
        guard let central else { return }
        resetCharacteristics()
        peripheral = target
        target.delegate = self
        state = .connecting(name)
        central.connect(target, options: nil)
    }

    private func resetCharacteristics() {
        commandCharacteristic = nil
        poseCharacteristic = nil
        helloCharacteristic = nil
        statusCharacteristic = nil
    }

    private func reconnectToLast() {
        guard let central, peripheral == nil, !userDisconnected,
              let idString = UserDefaults.standard.string(forKey: Key.lastMac),
              let id = UUID(uuidString: idString),
              let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        let name = UserDefaults.standard.string(forKey: Key.lastMacName) ?? "Mac"
        peripherals[id] = target
        open(target, name: name)
    }

    // MARK: - События (уже на главном потоке)

    fileprivate func centralStateChanged(_ newState: CBManagerState) {
        switch newState {
        case .poweredOn:
            if case .bluetoothOff = state { state = .idle }
            if case .unauthorized = state { state = .idle }
            if pendingScan {
                pendingScan = false
                scan()
            } else {
                reconnectToLast()
            }
        case .unauthorized:
            state = .unauthorized
        default:
            resetCharacteristics()
            peripheral = nil
            state = .bluetoothOff
        }
    }

    fileprivate func discovered(_ target: CBPeripheral, name: String, rssi: Int) {
        peripherals[target.identifier] = target
        if let index = found.firstIndex(where: { $0.id == target.identifier }) {
            found[index].rssi = rssi
        } else {
            found.append(FoundMac(id: target.identifier, name: name, rssi: rssi))
        }
        found.sort { $0.rssi > $1.rssi }
    }

    fileprivate func didConnect(_ target: CBPeripheral) {
        guard target == peripheral else { return }
        target.discoverServices([serviceUUID])
    }

    fileprivate func didDisconnect(_ target: CBPeripheral) {
        guard target == peripheral else { return }
        let name = macName ?? "Mac"
        resetCharacteristics()
        if userDisconnected {
            peripheral = nil
            state = .idle
            return
        }
        if case .denied = state {
            peripheral = nil
            return
        }
        // Связь оборвалась (ушёл далеко, Mac уснул) — connect() без таймаута дождётся Mac
        WKInterfaceDevice.current().play(.failure)
        open(target, name: name)
    }

    fileprivate func didFailToConnect(_ target: CBPeripheral) {
        guard target == peripheral else { return }
        peripheral = nil
        state = .idle
    }

    fileprivate func didDiscoverServices(_ target: CBPeripheral) {
        guard let service = target.services?.first(where: { $0.uuid == serviceUUID }) else {
            disconnect()
            return
        }
        target.discoverCharacteristics([helloUUID, commandUUID, poseUUID, statusUUID], for: service)
    }

    fileprivate func didDiscoverCharacteristics(_ target: CBPeripheral, _ characteristics: [CBCharacteristic]) {
        for characteristic in characteristics {
            switch characteristic.uuid {
            case helloUUID: helloCharacteristic = characteristic
            case commandUUID: commandCharacteristic = characteristic
            case poseUUID: poseCharacteristic = characteristic
            case statusUUID: statusCharacteristic = characteristic
            default: break
            }
        }
        guard let status = statusCharacteristic else {
            disconnect()
            return
        }
        // Сначала подписываемся на статус, «привет» отправим, когда подписка включится
        target.setNotifyValue(true, for: status)
    }

    fileprivate func notifyStateChanged(_ target: CBPeripheral, isNotifying: Bool) {
        guard isNotifying, let hello = helloCharacteristic else { return }
        let message = WatchHello(id: watchID, name: WKInterfaceDevice.current().name)
        guard let data = try? encoder.encode(message) else { return }
        state = .waitingApproval(macName ?? "Mac")
        target.writeValue(data, for: hello, type: .withResponse)
    }

    fileprivate func statusReceived(_ raw: String) {
        let name = macName ?? "Mac"
        switch BLEStatus(rawValue: raw) {
        case .ok:
            if !isConnected { WKInterfaceDevice.current().play(.success) }
            state = .connected(name)
        case .pending:
            state = .waitingApproval(name)
        case .denied:
            state = .denied(name)
            WKInterfaceDevice.current().play(.failure)
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            UserDefaults.standard.removeObject(forKey: Key.lastMac)
        case .bye:
            disconnect()
        case nil:
            break
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MacLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        MainActor.assumeIsolated { self.centralStateChanged(newState) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Mac"
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { self.discovered(peripheral, name: name, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.didConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated { self.didDisconnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated { self.didFailToConnect(peripheral) }
    }
}

// MARK: - CBPeripheralDelegate

extension MacLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated { self.didDiscoverServices(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let characteristics = service.characteristics ?? []
        MainActor.assumeIsolated { self.didDiscoverCharacteristics(peripheral, characteristics) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let isNotifying = characteristic.isNotifying
        MainActor.assumeIsolated { self.notifyStateChanged(peripheral, isNotifying: isNotifying) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let data = characteristic.value, let raw = String(data: data, encoding: .utf8) else { return }
        MainActor.assumeIsolated { self.statusReceived(raw) }
    }
}
