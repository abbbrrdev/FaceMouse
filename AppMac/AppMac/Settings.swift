import Foundation
import Combine

enum PointerMode: String, CaseIterable, Identifiable {
    case absolute
    case joystick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .absolute: return "Прямой"
        case .joystick: return "Джойстик"
        }
    }

    var hint: String {
        switch self {
        case .absolute: return "Куда повернул голову — туда и курсор."
        case .joystick: return "Отклонил голову — курсор едет, пока держишь. Удобнее лёжа."
        }
    }
}

@MainActor
final class MouseSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var mode: PointerMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    /// Джойстик: максимальная скорость, px/с
    @Published var speed: Double { didSet { defaults.set(speed, forKey: Key.speed) } }
    /// Прямой режим: на сколько градусов повернуть голову, чтобы дойти до края экрана
    @Published var range: Double { didSet { defaults.set(range, forKey: Key.range) } }
    /// Джойстик и скролл: сколько градусов игнорировать вокруг центра
    @Published var deadzone: Double { didSet { defaults.set(deadzone, forKey: Key.deadzone) } }
    /// 0 — быстро, но дрожит; 1 — плавно, но с задержкой
    @Published var smoothing: Double { didSet { defaults.set(smoothing, forKey: Key.smoothing) } }
    @Published var invertX: Bool { didSet { defaults.set(invertX, forKey: Key.invertX) } }
    @Published var invertY: Bool { didSet { defaults.set(invertY, forKey: Key.invertY) } }
    /// Устройства, которым разрешено подключаться без вопроса
    @Published var trustedPeers: [String] { didSet { defaults.set(trustedPeers, forKey: Key.trusted) } }

    private enum Key {
        static let mode = "mode"
        static let speed = "speed"
        static let range = "range"
        static let deadzone = "deadzone"
        static let smoothing = "smoothing"
        static let invertX = "invertX"
        static let invertY = "invertY"
        static let trusted = "trustedPeers"
    }

    init() {
        defaults.register(defaults: [
            Key.mode: PointerMode.absolute.rawValue,
            Key.speed: 1200.0,
            Key.range: 12.0,
            Key.deadzone: 2.5,
            Key.smoothing: 0.5,
            Key.invertX: false,
            Key.invertY: false,
        ])
        mode = PointerMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .absolute
        speed = defaults.double(forKey: Key.speed)
        range = defaults.double(forKey: Key.range)
        deadzone = defaults.double(forKey: Key.deadzone)
        smoothing = defaults.double(forKey: Key.smoothing)
        invertX = defaults.bool(forKey: Key.invertX)
        invertY = defaults.bool(forKey: Key.invertY)
        trustedPeers = defaults.stringArray(forKey: Key.trusted) ?? []
    }
}
