import AppKit
@preconcurrency import MultipeerConnectivity

nonisolated struct Unchecked<T>: @unchecked Sendable { let value: T }

/// Делает Mac видимым для iPhone и принимает команды.
@MainActor
final class PeerHost: NSObject {
    var onMessage: ((FaceMessage) -> Void)?
    /// Имя подключённого iPhone или nil
    var onConnectionChange: ((String?) -> Void)?

    private let settings: MouseSettings
    private let myPeer = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser

    init(settings: MouseSettings) {
        self.settings = settings
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: nil, serviceType: FaceMouse.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
    }

    func disconnect() {
        session.disconnect()
        onConnectionChange?(nil)
    }

    /// Чужой iPhone рядом не должен управлять твоим Mac без спроса.
    fileprivate func shouldAccept(_ peer: MCPeerID) -> Bool {
        let name = peer.displayName
        if settings.trustedPeers.contains(name) { return true }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "«\(name)» хочет управлять курсором"
        alert.informativeText = "Разреши, только если это твой iPhone."
        alert.addButton(withTitle: "Разрешить")
        alert.addButton(withTitle: "Всегда разрешать")
        alert.addButton(withTitle: "Отклонить")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            settings.trustedPeers.append(name)
            return true
        default:
            return false
        }
    }

    fileprivate var currentSession: MCSession { session }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerHost: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let box = Unchecked(value: (peerID, invitationHandler))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let (peer, handler) = box.value
                let accepted = self.shouldAccept(peer)
                handler(accepted, accepted ? self.currentSession : nil)
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        print("Advertising error: \(error.localizedDescription)")
    }
}

// MARK: - MCSessionDelegate

extension PeerHost: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let connectedName = session.connectedPeers.first?.displayName
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onConnectionChange?(connectedName) }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(FaceMessage.self, from: data) else { return }
        // DispatchQueue.main сохраняет порядок сообщений
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onMessage?(message) }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}
