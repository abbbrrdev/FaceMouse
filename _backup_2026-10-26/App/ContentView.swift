import SwiftUI
import UIKit
import AVFoundation
import MultipeerConnectivity

struct ContentView: View {
    @StateObject private var peers = PeerBrowser()
    @StateObject private var tracker = HandTracker()
    @State private var authorization = CameraFeed.authorizationStatus()

    var body: some View {
        Group {
            if !HandTracker.isSupported() {
                NoCameraView()
            } else {
                switch authorization {
                case .authorized:
                    if let mac = peers.connectedPeer {
                        TrackingView(macName: mac.displayName, peers: peers, tracker: tracker)
                    } else {
                        DeviceListView(peers: peers)
                    }
                case .notDetermined:
                    CameraPermissionView {
                        let granted = await CameraFeed.requestAccess()
                        authorization = granted ? .authorized : .denied
                    }
                default:
                    CameraDeniedView()
                }
            }
        }
        .onAppear {
            peers.start()
            tracker.onMessage = { [weak peers] message, reliable in
                peers?.send(message, reliable: reliable)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Пользователь мог включить доступ в Настройках и вернуться назад.
            authorization = CameraFeed.authorizationStatus()
        }
    }
}

// MARK: - Список Mac рядом

struct DeviceListView: View {
    @ObservedObject var peers: PeerBrowser

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if peers.foundPeers.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Ищу Mac рядом…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(peers.foundPeers, id: \.self) { peer in
                        Button {
                            peers.connect(to: peer)
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(peer.displayName)
                                Spacer()
                                if peers.connectingPeer == peer {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(peers.connectingPeer != nil)
                    }
                } footer: {
                    Text("Открой FaceMouse на Mac. Оба устройства должны быть рядом, с включёнными Wi-Fi и Bluetooth. После выбора нажми «Разрешить» на Mac.")
                }
            }
            .navigationTitle("FaceMouse")
        }
    }
}

// MARK: - Доступ к камере

struct CameraPermissionView: View {
    let request: () async -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised")
                .font(.system(size: 48))
            Text("Нужен доступ к камере")
                .font(.headline)
            Text("FaceMouse следит за рукой через фронтальную камеру прямо на телефоне — видео никуда не отправляется.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Разрешить доступ") {
                Task { await request() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct CameraDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Доступ к камере запрещён", systemImage: "camera.fill")
        } description: {
            Text("Включи камеру для FaceMouse в Настройках, чтобы управлять курсором рукой.")
        } actions: {
            Button("Открыть настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}

struct NoCameraView: View {
    var body: some View {
        ContentUnavailableView(
            "Нет фронтальной камеры",
            systemImage: "camera.fill",
            description: Text("FaceMouse нужен iPhone с фронтальной камерой.")
        )
    }
}
