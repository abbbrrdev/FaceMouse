import Foundation
import Combine
import WatchConnectivity

/// Мост Apple Watch → iPhone → Mac.
/// Часы шлют FaceMessage (JSON) через WatchConnectivity, мы пересылаем его на Mac через Multipeer.
/// Обратно сообщаем часам, к какому Mac подключены (applicationContext).
@MainActor
final class WatchBridge: NSObject, ObservableObject {
    @Published private(set) var isWatchReachable = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var lastCommand = ""

    /// (сообщение, надёжная доставка)
    var onMessage: ((FaceMessage, Bool) -> Void)?

    private let decoder = JSONDecoder()
    private var lastMacName: String?

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Говорим часам, к какому Mac подключены (nil — не подключены).
    func updateMac(_ name: String?) {
        lastMacName = name
        pushContext()
    }

    private func pushContext() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired else { return }
        try? session.updateApplicationContext(["mac": lastMacName ?? ""])
    }

    fileprivate func received(_ data: Data) {
        guard let message = try? decoder.decode(FaceMessage.self, from: data) else { return }
        let reliable: Bool
        if case .pose = message { reliable = false } else { reliable = true }
        onMessage?(message, reliable)
        if case let .media(command) = message { lastCommand = command.rawValue }
    }

    fileprivate func refreshState() {
        let session = WCSession.default
        isWatchReachable = session.isReachable
        isWatchAppInstalled = session.isPaired && session.isWatchAppInstalled
        pushContext()
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshState() } }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Пользователь сменил часы — активируем сессию заново.
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshState() } }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshState() } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        // DispatchQueue.main сохраняет порядок сообщений
        DispatchQueue.main.async { MainActor.assumeIsolated { self.received(messageData) } }
    }
}
