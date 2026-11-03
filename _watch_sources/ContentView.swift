import SwiftUI
import WatchKit

struct ContentView: View {
    @StateObject private var link = PhoneLink()
    @StateObject private var motion = WristMotion()
    @Environment(\.scenePhase) private var scenePhase

    @State private var crown: Double = 0
    @State private var crownApplied: Double = 0
    @State private var showSettings = false

    /// Сколько «единиц» колёсика = один шаг громкости
    private let crownStep: Double = 2

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                statusLine
                mainButton
                HStack(spacing: 6) {
                    smallButton("backward.end.fill") { send(.media(.previousTrack), "⏮") }
                    smallButton(motion.mode == .gestures ? "hand.wave.fill" : "cursorarrow.motionlines") {
                        motion.mode = motion.mode == .gestures ? .mouse : .gestures
                        motion.show(motion.mode == .gestures ? "Жесты" : "Мышь")
                    }
                    smallButton("forward.end.fill") { send(.media(.nextTrack), "⏭") }
                }
                if motion.mode == .mouse {
                    Button("Центр") { motion.calibrate(); motion.show("Центр") }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 4)
            .focusable()
            .digitalCrownRotation(
                $crown, from: -100_000, through: 100_000, by: 1,
                sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
            )
            .onChange(of: crown) { _, value in handleCrown(value) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(motion: motion)
            }
        }
        .onAppear {
            link.start()
            motion.onMessage = { [weak link] message in link?.send(message) }
            motion.start()
        }
        .onChange(of: scenePhase) { _, phase in
            motion.setActive(phase == .active)
        }
    }

    // MARK: - Части экрана

    private var statusLine: some View {
        Group {
            if !motion.lastGesture.isEmpty {
                Text(motion.lastGesture).font(.headline)
            } else if !link.isReachable {
                Text("Открой FaceMouse на iPhone").foregroundStyle(.orange)
            } else if let mac = link.macName {
                Label(mac, systemImage: "laptopcomputer").foregroundStyle(.green)
            } else {
                Text("На iPhone подключи Mac").foregroundStyle(.yellow)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .frame(height: 18)
    }

    /// Главная кнопка — её же нажимает системный жест Double Tap (щелчок пальцами).
    private var mainButton: some View {
        Button {
            if motion.mode == .gestures {
                send(.media(.playPause), "⏯")
            } else {
                send(.leftClick, "Клик")
            }
        } label: {
            Label(motion.mode == .gestures ? "Пауза" : "Клик",
                  systemImage: motion.mode == .gestures ? "playpause.fill" : "cursorarrow.click")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .handGestureShortcut(.primaryAction)
        .tint(motion.mode == .gestures ? .blue : .purple)
    }

    private func smallButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Действия

    private func send(_ message: FaceMessage, _ label: String) {
        link.send(message)
        WKInterfaceDevice.current().play(.click)
        motion.show(label)
    }

    /// Колёсико = громкость Mac.
    private func handleCrown(_ value: Double) {
        let steps = Int((value - crownApplied) / crownStep)
        guard steps != 0 else { return }
        crownApplied += Double(steps) * crownStep
        let command: MediaCommand = steps > 0 ? .volumeUp : .volumeDown
        for _ in 0..<min(abs(steps), 4) {
            link.send(.media(command))
        }
        motion.show(steps > 0 ? "🔊" : "🔉")
    }
}

struct SettingsView: View {
    @ObservedObject var motion: WristMotion

    var body: some View {
        List {
            Toggle("Поменять ⬅︎ ➡︎", isOn: $motion.invertSwipes)
            Toggle("Мышь: инверсия ↕", isOn: $motion.invertPitch)
            Section("Как управлять") {
                Text("Жесты: резкий взмах рукой влево/вправо — ←/→ (YouTube ±5 с, слайды). Щелчок пальцами (Double Tap) — пауза. Колёсико — громкость.")
                Text("Мышь: указывай рукой на экран, щелчок пальцами — клик. Опустил руку — курсор стоит, поднял — центр там, куда указываешь.")
            }
            .font(.caption2)
        }
    }
}
