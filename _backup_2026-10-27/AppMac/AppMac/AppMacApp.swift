import Combine
import SwiftUI
import AppKit
import ApplicationServices

@main
struct FaceMouseMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, settings: model.settings)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connectedName: String?
    @Published private(set) var phonePaused = false
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var debugYaw: Float = 0
    @Published private(set) var debugPitch: Float = 0
    @Published var enabled = true {
        didSet { cursor.enabled = enabled }
    }

    let settings: MouseSettings
    private let cursor: CursorController
    private let host: PeerHost
    private var axTimer: Timer?
    private var lastDebugUpdate: CFTimeInterval = 0

    var menuIcon: String {
        if !axTrusted { return "exclamationmark.triangle" }
        if connectedName == nil { return "face.dashed" }
        if phonePaused || !enabled { return "pause.circle" }
        return "face.smiling"
    }

    init() {
        let settings = MouseSettings()
        self.settings = settings
        cursor = CursorController(settings: settings)
        host = PeerHost(settings: settings)

        host.onMessage = { [weak self] message in
            self?.handle(message)
        }
        host.onConnectionChange = { [weak self] name in
            guard let self else { return }
            connectedName = name
            if name == nil {
                phonePaused = false
                cursor.reset()
            }
        }
        cursor.onDebug = { [weak self] yaw, pitch in
            guard let self else { return }
            let now = CACurrentMediaTime()
            guard now - lastDebugUpdate > 0.1 else { return }
            lastDebugUpdate = now
            debugYaw = yaw
            debugPitch = pitch
        }

        host.start()
        cursor.start()

        // Права «Универсальный доступ» могут выдать в любой момент — проверяем раз в 2 с
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let trusted = AXIsProcessTrusted()
                if trusted != self.axTrusted { self.axTrusted = trusted }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        axTimer = timer

        if !axTrusted { requestAccessibility() }
    }

    func disconnect() {
        host.disconnect()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ message: FaceMessage) {
        switch message {
        case let .media(command):
            // Медиа-жесты с часов работают, даже если курсор на паузе — но не при выключенном управлении.
            if enabled { MediaKeys.perform(command) }
        case let .state(paused):
            phonePaused = paused
            cursor.handle(message)
        default:
            cursor.handle(message)
        }
    }
}
