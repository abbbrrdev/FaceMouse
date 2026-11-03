import Foundation

// Общий протокол между iPhone и Mac.
// Этот файл должен быть ОДИНАКОВЫМ в обоих проектах.

nonisolated enum FaceMouse {
    /// Bonjour service type: до 15 символов, только a-z, 0-9 и дефис.
    /// В Info.plist обоих приложений должны быть _facemouse._tcp и _facemouse._udp.
    static let serviceType = "facemouse"
}

nonisolated enum FaceMessage: Codable, Sendable {
    /// Позиция указательного пальца относительно калибровки, в условных градусах
    /// (как если бы это был угол поворота — так их можно напрямую скормить тем же
    /// фильтрам/режимам курсора, что раньше работали с углами головы).
    /// yaw > 0 — палец правее центра, pitch > 0 — палец выше центра.
    /// scrolling — раскрытая ладонь (режим скролла, pitch = смещение руки от начала жеста).
    /// freeze — формируется щипок или другой жест, курсор должен замереть, чтобы клик попал куда надо.
    case pose(yaw: Float, pitch: Float, scrolling: Bool, freeze: Bool)
    /// Щипок большим и указательным пальцем.
    case leftClick
    /// Щипок большим и средним пальцем.
    case rightClick
    /// Трекинг на паузе (удержание кулака / кнопка на телефоне).
    case state(paused: Bool)
}
