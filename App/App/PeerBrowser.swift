import Foundation
import UIKit
import Combine
@preconcurrency import MultipeerConnectivity

nonisolated struct Unchecked<T>: @unchecked Sendable { let value: T }

/// Ищет Mac рядом (Wi-Fi + Bluetooth через MultipeerConnectivity) и отправляет ему команды.
@MainActor
final class PeerBrowser: NSObject, ObservableObject {
    @Published private(set) var foundPeers: [MCPeerID] = []
    @Published private(set) var connectedPeer: MCPeerID?
    @Published private(set) var connectingPeer: MCPeerID?

    private let myPeer = MCPeerID(displayName: UIDevice.current.name)
    private let session: MCSession
    private let browser: MCNearbyServiceBrowser
    private let encoder = JSONEncoder()

    override init() {
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: FaceMouse.serviceType)
        super.init()
        session.delegate = self
        browser.delegate = self
    }

    func start() {
        browser.startBrowsingForPeers()
    }

    func connect(to peer: MCPeerID) {
        connectingPeer = peer
        // 30 с — чтобы успеть нажать «Разрешить» на Mac
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    func disconnect() {
        session.disconnect()
        connectedPeer = nil
        connectingPeer = nil
    }

    /// Позы — unreliable (быстро, потеря кадра не страшна), клики и пауза — reliable.
    func send(_ message: FaceMessage, reliable: Bool) {
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? encoder.encode(message) else { return }
        try? session.send(data, toPeers: peers, with: reliable ? .reliable : .unreliable)
    }

    fileprivate func peerFound(_ peer: MCPeerID) {
        // Mac после перезапуска приходит с новым MCPeerID, но тем же именем
        foundPeers.removeAll { $0.displayName == peer.displayName }
        foundPeers.append(peer)
    }

    fileprivate func peerLost(_ peer: MCPeerID) {
        foundPeers.removeAll { $0 == peer }
    }

    fileprivate func stateChanged(_ peer: MCPeerID, _ state: MCSessionState) {
        switch state {
        case .connected:
            connectedPeer = peer
            connectingPeer = nil
        case .connecting:
            connectingPeer = peer
        case .notConnected:
            if connectedPeer == peer { connectedPeer = nil }
            if connectingPeer == peer { connectingPeer = nil }
        @unknown default:
            break
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerBrowser: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let box = Unchecked(value: peerID)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.peerFound(box.value) } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let box = Unchecked(value: peerID)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.peerLost(box.value) } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        print("Browsing error: \(error.localizedDescription)")
    }
}

// MARK: - MCSessionDelegate

extension PeerBrowser: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let box = Unchecked(value: peerID)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.stateChanged(box.value, state) } }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}
