import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: MouseSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !model.axTrusted {
                accessibilityWarning
            }

            Toggle("Управление включено", isOn: $model.enabled)
                .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $settings.mode) {
                    ForEach(PointerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.mode.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.mode == .joystick {
                slider("Скорость", value: $settings.speed, in: 300...3000) { String(format: "%.0f px/с", $0) }
            } else {
                slider("Поворот до края экрана", value: $settings.range, in: 5...30) { String(format: "±%.0f°", $0) }
            }
            slider("Мёртвая зона", value: $settings.deadzone, in: 0...8) { String(format: "%.1f°", $0) }
            slider("Плавность", value: $settings.smoothing, in: 0...1) { String(format: "%.0f%%", $0 * 100) }

            Toggle("Инвертировать ↔", isOn: $settings.invertX)
            Toggle("Инвертировать ↕", isOn: $settings.invertY)

            Divider()

            Text(String(format: "Голова  ↔ %+.1f°   ↕ %+.1f°", model.debugYaw, model.debugPitch))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if !settings.trustedPeers.isEmpty {
                HStack {
                    Text("Доверенные: \(settings.trustedPeers.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Сбросить") { settings.trustedPeers = [] }
                        .font(.caption)
                }
            }

            HStack {
                if model.connectedName != nil {
                    Button("Отключить iPhone") { model.disconnect() }
                }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuIcon)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("FaceMouse")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard let name = model.connectedName else { return "Жду iPhone… Открой FaceMouse на телефоне" }
        if model.phonePaused { return "\(name) · пауза (подними брови)" }
        return "\(name) · подключён"
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Нужен доступ к «Универсальному доступу»", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Без него macOS не даст двигать курсор. Включи FaceMouse в списке и вернись сюда.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Открыть настройки") {
                model.requestAccessibility()
                model.openAccessibilitySettings()
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
