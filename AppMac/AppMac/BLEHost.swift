import AppKit
import Foundation
@preconcurrency import CoreBluetooth

/// Прямое подключение Apple Watch к Mac по Bluetooth LE (без iPhone).
///
/// Mac — периферия: рекламирует сервис FaceMouse.BLE.service под своим именем.
/// Часы подключаются, подписываются на status и пишут WatchHello.
/// Дальше, как и с iPhone, нужен «Разрешить» на Mac (или «Всегда разрешать» по id часов).
/// Команды от неподтверждённых часов игнорируются.
@MainActor
final class BLEHost: NSObject {
    var onMessage: ((FaceMessage) -> Void)?
    /// Имя подключённых часов или nil
    var onConnectionChange: ((String?) -> Void)?

    private let settings: MouseSettings
    private var manager: CBPeripheralManager?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var isServiceAdded = false

    /// Часы, которым разрешено управлять (по CBCentral.identifier)
    private var approved: Set<UUID> = []
    private var helloByCentral: [UUID: WatchHello] = [:]
    private var subscribed: [UUID: CBCentral] = [:]
    private var statusByCentral: [UUID: BLEStatus] = [:]
    private var alertShowing = false

    private let decoder = JSONDecoder()

    private let serviceUUID = CBUUID(string: FaceMouse.BLE.service)
    private let helloUUID = CBUUID(string: FaceMouse.BLE.hello)
    private let commandUUID = CBUUID(string: FaceMouse.BLE.command)
    private let poseUUID = CBUUID(string: FaceMouse.BLE.pose)
    private let statusUUID = CBUUID(string: FaceMouse.BLE.status)

    init(settings: MouseSettings) {
        self.settings = settings
        super.init()
    }

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    /// Отключить часы со стороны Mac: часы получают «bye» и сами рвут соединение.
    func disconnect() {
        for id in approved {
            send(.bye, to: id)
        }
        approved.removeAll()
        onConnectionChange?(nil)
    }

    // MARK: - Сервис

    fileprivate func poweredOn() {
        guard let manager, !isServiceAdded else {
            startAdvertising()
            return
        }
        let hello = CBMutableCharacteristic(
            type: helloUUID, properties: [.write], value: nil, permissions: [.writeable])
        let command = CBMutableCharacteristic(
            type: commandUUID, properties: [.write], value: nil, permissions: [.writeable])
        let pose = CBMutableCharacteristic(
            type: poseUUID, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        let status = CBMutableCharacteristic(
            type: statusUUID, properties: [.read, .notify], value: nil, permissions: [.readable])
        statusCharacteristic = status

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [hello, command, pose, status]
        manager.add(service)
    }

    fileprivate func serviceAdded(error: (any Error)?) {
        if let error {
            print("BLE: не удалось добавить сервис: \(error.localizedDescription)")
            return
        }
        isServiceAdded = true
        startAdvertising()
    }

    private func startAdvertising() {
        guard let manager, isServiceAdded, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: Host.current().localizedName ?? "Mac",
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
        ])
    }

    fileprivate func poweredOff() {
        approved.removeAll()
        subscribed.removeAll()
        helloByCentral.removeAll()
        statusByCentral.removeAll()
        isServiceAdded = false
        statusCharacteristic = nil
        onConnectionChange?(nil)
    }

    // MARK: - Подписки = факт подключения

    fileprivate func subscribe(_ central: CBCentral) {
        subscribed[central.identifier] = central
        // Если часы уже представились — сразу сообщаем текущий статус
        if let status = statusByCentral[central.identifier] {
            send(status, to: central.identifier)
        }
    }

    /// Отписка от status приходит и при обрыве связи — считаем это отключением.
    fileprivate func unsubscribe(_ id: UUID) {
        subscribed[id] = nil
        statusByCentral[id] = nil
        let wasApproved = approved.remove(id) != nil
        helloByCentral[id] = nil
        if wasApproved {
            onConnectionChange?(currentName)
        }
    }

    private var currentName: String? {
        approved.compactMap { helloByCentral[$0]?.name }.first
    }

    // MARK: - Запись от часов

    fileprivate func handleWrites(_ requests: [CBATTRequest]) {
        guard let manager, let first = requests.first else { return }
        var result: CBATTError.Code = .success
        var needsResponse = false

        for request in requests {
            let id = request.central.identifier
            let uuid = request.characteristic.uuid
            let data = request.value ?? Data()

            if uuid == helloUUID {
                needsResponse = true
                guard let hello = try? decoder.decode(WatchHello.self, from: data) else {
                    result = .unlikelyError
                    continue
                }
                helloByCentral[id] = hello
                // Ответ на запись отдаём сразу, а вопрос пользователю — после
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.authorize(id) }
                }
            } else if uuid == commandUUID {
                needsResponse = true
                guard approved.contains(id) else {
                    result = .insufficientAuthorization
                    continue
                }
                if let message = try? decoder.decode(FaceMessage.self, from: data) {
                    onMessage?(message)
                }
            } else if uuid == poseUUID {
                guard approved.contains(id),
                      let message = try? decoder.decode(FaceMessage.self, from: data) else { continue }
                onMessage?(message)
            }
        }

        // На write without response отвечать не нужно
        if needsResponse {
            manager.respond(to: first, withResult: result)
        }
    }

    fileprivate func handleRead(_ request: CBATTRequest) {
        guard let manager else { return }
        let status = statusByCentral[request.central.identifier] ?? .pending
        let data = Data(status.rawValue.utf8)
        guard request.offset <= data.count else {
            manager.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        manager.respond(to: request, withResult: .success)
    }

    // MARK: - Разрешение

    /// Чужие часы рядом не должны управлять твоим Mac без спроса.
    private func authorize(_ id: UUID) {
        guard let hello = helloByCentral[id] else { return }
        let trustKey = "watch:\(hello.id)"

        if settings.trustedPeers.contains(trustKey) {
            approve(id)
            return
        }
        guard !alertShowing else { return }
        send(.pending, to: id)

        alertShowing = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "«\(hello.name)» хочет управлять Mac"
        alert.informativeText = "Apple Watch подключается напрямую по Bluetooth. Разреши, только если это твои часы."
        alert.addButton(withTitle: "Разрешить")
        alert.addButton(withTitle: "Всегда разрешать")
        alert.addButton(withTitle: "Отклонить")
        let response = alert.runModal()
        alertShowing = false

        // Пока висело окно, часы могли отключиться
        guard helloByCentral[id] != nil else { return }

        switch response {
        case .alertFirstButtonReturn:
            approve(id)
        case .alertSecondButtonReturn:
            settings.trustedPeers.append(trustKey)
            approve(id)
        default:
            send(.denied, to: id)
        }
    }

    private func approve(_ id: UUID) {
        approved.insert(id)
        send(.ok, to: id)
        onConnectionChange?(currentName)
    }

    private func send(_ status: BLEStatus, to id: UUID) {
        statusByCentral[id] = status
        guard let manager, let characteristic = statusCharacteristic,
              let central = subscribed[id] else { return }
        // Если очередь полна, часы всё равно прочитают статус при следующей подписке/чтении
        _ = manager.updateValue(Data(status.rawValue.utf8), for: characteristic, onSubscribedCentrals: [central])
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEHost: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated {
            if state == .poweredOn { self.poweredOn() } else { self.poweredOff() }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        MainActor.assumeIsolated { self.serviceAdded(error: error) }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        if let error { print("BLE: реклама не запустилась: \(error.localizedDescription)") }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { self.subscribe(central) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let id = central.identifier
        MainActor.assumeIsolated { self.unsubscribe(id) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated { self.handleWrites(requests) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated { self.handleRead(request) }
    }
}
