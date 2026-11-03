import Foundation
import Combine
import WatchConnectivity

/// Связь часов с iPhone. Часы не умеют Multipeer, поэтому идём через iPhone:
/// Watch → (WatchConnectivity) → iPhone → (Multipeer) → Mac.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    /// Имя Mac, к которому подключён iPhone (nil — не подключён)
    @Published private(set) var macName: String?
    /// iPhone-приложение открыто и на связи
    @Published private(set) var isReachable = false

    private let encoder = JSONEncoder()

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ message: FaceMessage) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable,
              let data = try? encoder.encode(message) else { return }
        session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }

    fileprivate func refresh() {
        let session = WCSession.default
        isReachable = session.isReachable
        let name = session.receivedApplicationContext["mac"] as? String ?? ""
        macName = name.isEmpty ? nil : name
    }

    fileprivate func setMac(_ name: String) {
        macName = name.isEmpty ? nil : name
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let name = applicationContext["mac"] as? String ?? ""
        DispatchQueue.main.async { MainActor.assumeIsolated { self.setMac(name) } }
    }
}
