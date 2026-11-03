import Foundation

// Общий протокол между iPhone, Mac и Apple Watch.
// Этот файл должен быть ОДИНАКОВЫМ во всех трёх проектах/таргетах.

nonisolated enum FaceMouse {
    /// Bonjour service type: до 15 символов, только a-z, 0-9 и дефис.
    /// В Info.plist обоих приложений должны быть _facemouse._tcp и _facemouse._udp.
    static let serviceType = "facemouse"
}

/// Медиа-команды и «стрелки» — то, что шлют жесты часов.
nonisolated enum MediaCommand: String, Codable, Sendable {
    case playPause      // медиа-клавиша Play/Pause (YouTube, Музыка, Spotify)
    case nextTrack      // медиа-клавиша «следующий»
    case previousTrack  // медиа-клавиша «предыдущий»
    case volumeUp
    case volumeDown
    case arrowRight     // → во фронтальном приложении: YouTube +5 с, следующий слайд
    case arrowLeft      // ← : YouTube −5 с, предыдущий слайд
}

nonisolated enum FaceMessage: Codable, Sendable {
    /// Позиция указателя относительно калибровки, в условных градусах.
    /// Источник — палец (камера iPhone) или направление предплечья (Apple Watch, «аэромышь»).
    /// yaw > 0 — правее центра, pitch > 0 — выше центра.
    /// scrolling — режим скролла (pitch = скорость/смещение).
    /// freeze — формируется жест, курсор должен замереть, чтобы клик попал куда надо.
    case pose(yaw: Float, pitch: Float, scrolling: Bool, freeze: Bool)
    /// Щипок большим и указательным / Double Tap на часах в режиме мыши.
    case leftClick
    /// Щипок большим и средним пальцем.
    case rightClick
    /// Трекинг на паузе (удержание кулака / кнопка на телефоне).
    case state(paused: Bool)
    /// Медиа-команда (жесты Apple Watch).
    case media(MediaCommand)
}
