import Foundation

// Общий протокол между iPhone, Mac и Apple Watch.
// Этот файл должен быть ОДИНАКОВЫМ во всех трёх проектах/таргетах.

nonisolated enum FaceMouse {
    /// Bonjour service type: до 15 символов, только a-z, 0-9 и дефис.
    /// В Info.plist обоих приложений должны быть _facemouse._tcp и _facemouse._udp.
    static let serviceType = "facemouse"

    /// Bluetooth LE: прямое подключение Apple Watch к Mac, без iPhone.
    /// Mac — периферия (рекламирует сервис), часы — central (ищут и подключаются).
    nonisolated enum BLE {
        static let service = "6E5A0001-7C3B-4D2F-9A1E-FACE0000F001"
        /// write (с ответом): WatchHello — кто подключается
        static let hello = "6E5A0002-7C3B-4D2F-9A1E-FACE0000F001"
        /// write (с ответом): FaceMessage — клики, медиа, пауза (доставка гарантирована)
        static let command = "6E5A0003-7C3B-4D2F-9A1E-FACE0000F001"
        /// write without response: FaceMessage.pose — 25 Гц, потеря кадра не страшна
        static let pose = "6E5A0004-7C3B-4D2F-9A1E-FACE0000F001"
        /// read + notify: статус для часов — BLEStatus
        static let status = "6E5A0005-7C3B-4D2F-9A1E-FACE0000F001"
    }
}

/// Первое сообщение часов после подключения по Bluetooth.
nonisolated struct WatchHello: Codable, Sendable {
    /// Постоянный UUID часов (хранится в UserDefaults часов) — по нему Mac помнит «Всегда разрешать»
    let id: String
    /// Имя часов, его увидит пользователь в окне «Разрешить?»
    let name: String
}

/// Что Mac отвечает часам в характеристике status.
nonisolated enum BLEStatus: String, Sendable {
    case pending  // ждём, пока на Mac нажмут «Разрешить»
    case ok       // можно управлять
    case denied   // отклонено
    case bye      // Mac отключил часы сам
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
