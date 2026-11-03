import SwiftUI
import WatchKit

struct ContentView: View {
    @StateObject private var link = MacLink()
    @StateObject private var motion = WristMotion()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if link.isConnected {
                    ControlView(link: link, motion: motion)
                } else {
                    ConnectView(link: link)
                }
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
}

// MARK: - Подключение

struct ConnectView: View {
    @ObservedObject var link: MacLink

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.applewatch")
                    .font(.title2)
                    .foregroundStyle(.tint)

                status

                switch link.state {
                case .scanning:
                    if link.found.isEmpty {
                        ProgressView()
                        Text("Открой FaceMouse на Mac")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(link.found) { mac in
                        Button {
                            link.connect(mac)
                        } label: {
                            Label(mac.name, systemImage: "laptopcomputer")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Button("Отмена") { link.stopScan() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                case .connecting, .waitingApproval:
                    ProgressView()
                    Button("Отмена") { link.disconnect() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                case .bluetoothOff, .unauthorized:
                    EmptyView()

                default:
                    Button {
                        link.scan()
                    } label: {
                        Label("Подключиться к Mac", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .tint(.blue)
                    .handGestureShortcut(.primaryAction)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var status: some View {
        Group {
            switch link.state {
            case .bluetoothOff:
                Text("Включи Bluetooth на часах").foregroundStyle(.orange)
            case .unauthorized:
                Text("Разреши Bluetooth: Настройки → Конфиденциальность").foregroundStyle(.orange)
            case .idle:
                Text("Напрямую, без iPhone")
            case .scanning:
                Text("Ищу Mac рядом…")
            case let .connecting(name):
                Text("Подключаюсь к \(name)…")
            case let .waitingApproval(name):
                Text("Нажми «Разрешить» на \(name)").foregroundStyle(.yellow)
            case let .denied(name):
                Text("\(name) отклонил подключение").foregroundStyle(.red)
            case let .connected(name):
                Text(name).foregroundStyle(.green)
            }
        }
        .font(.caption2)
        .multilineTextAlignment(.center)
    }
}

// MARK: - Управление

struct ControlView: View {
    @ObservedObject var link: MacLink
    @ObservedObject var motion: WristMotion

    @State private var crown: Double = 0
    @State private var crownApplied: Double = 0
    @State private var showSettings = false

    /// Сколько «единиц» колёсика = один шаг громкости
    private let crownStep: Double = 2

    var body: some View {
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
            SettingsView(link: link, motion: motion)
        }
    }

    private var statusLine: some View {
        Group {
            if !motion.lastGesture.isEmpty {
                Text(motion.lastGesture).font(.headline)
            } else if let mac = link.macName {
                Label(mac, systemImage: "laptopcomputer").foregroundStyle(.green)
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
    @ObservedObject var link: MacLink
    @ObservedObject var motion: WristMotion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Toggle("Поменять ⬅︎ ➡︎", isOn: $motion.invertSwipes)
            Toggle("Мышь: инверсия ↕", isOn: $motion.invertPitch)
            Section("Mac") {
                Button("Отключиться") {
                    link.disconnect()
                    dismiss()
                }
                Button("Забыть Mac", role: .destructive) {
                    link.forget()
                    dismiss()
                }
            }
            Section("Как управлять") {
                Text("Жесты: резкий взмах рукой влево/вправо — ←/→ (YouTube ±5 с, слайды). Щелчок пальцами (Double Tap) — пауза. Колёсико — громкость.")
                Text("Мышь: указывай рукой на экран, щелчок пальцами — клик. Опустил руку — курсор стоит, поднял — центр там, куда указываешь.")
            }
            .font(.caption2)
        }
    }
}
