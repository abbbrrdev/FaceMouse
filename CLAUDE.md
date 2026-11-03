# FaceMouse

Управление курсором Mac лицом. iPhone (TrueDepth + ARKit) отслеживает голову и мимику, сам распознаёт жесты и шлёт на Mac только короткие команды. Mac-приложение в меню-баре двигает курсор и кликает через `CGEvent`.

Статус: рабочий прототип, оба приложения собираются и работают на реальных устройствах.

Общение с владельцем на русском, ответы короткие и по делу. При изменениях выдавать файлы целиком, а не диффы.

## Структура

```
FaceMouse/
├── CLAUDE.md
├── App/                       ← iOS-приложение (Xcode-проект App.xcodeproj, таргет App)
│   ├── App/                   ← исходники (synchronized folder)
│   │   ├── AppApp.swift       — @main, WindowGroup → ContentView
│   │   ├── ContentView.swift  — роутинг: нет Face ID / список Mac / трекинг
│   │   ├── TrackingView.swift — экран трекинга: AR-превью, калибровка, debug-полоски, кнопки
│   │   ├── FaceTracker.swift  — ARKit, калибровка, углы головы, детектор жестов
│   │   ├── PeerBrowser.swift  — MultipeerConnectivity: поиск Mac и отправка
│   │   └── FaceProtocol.swift — ОБЩИЙ протокол (копия в AppMac)
│   ├── Info.plist             — только NSBonjourServices (лежит ВНЕ synced folder намеренно)
│   └── project.pbxproj.backup — бэкап исходных настроек, можно удалить
└── AppMac/                    ← macOS-приложение (AppMac.xcodeproj, таргет AppMac)
    ├── AppMac/
    │   ├── AppMacApp.swift      — @main, MenuBarExtra + AppModel (связывает всё)
    │   ├── ContentView.swift    — содержит MenuView (окно меню-бара с настройками)
    │   ├── CursorController.swift — One Euro Filter, цикл 120 Гц, CGEvent: движение/клик/скролл
    │   ├── PeerHost.swift       — MultipeerConnectivity: advertiser, приём, NSAlert «Разрешить?»
    │   ├── Settings.swift       — MouseSettings (UserDefaults) + PointerMode
    │   └── FaceProtocol.swift   — ОБЩИЙ протокол (копия в App)
    ├── Info.plist
    └── project.pbxproj.backup
```

Каждый проект — отдельный git-репозиторий (`App/.git`, `AppMac/.git`).

## Архитектура

```
iPhone: ARSession (60 Гц) → FaceTracker.extract() → process()
          ├─ калибровка: средний кватернион за 3 с = «центр»
          ├─ углы yaw/pitch относительно центра (в системе координат лица)
          ├─ жесты по blendShapes → .leftClick / .rightClick / .state(paused:)
          └─ каждый кадр .pose(yaw, pitch, scrolling, freeze)
        → PeerBrowser.send()  (pose = unreliable, клики/пауза = reliable)
                    │  MultipeerConnectivity, Wi-Fi + Bluetooth, JSON
Mac:   PeerHost → AppModel.handle() → CursorController.handle()
          ├─ pose → One Euro Filter → yaw/pitch
          └─ Timer 120 Гц tick(): absolute | joystick | scroll → CGEvent
```

- Телефон «умный», Mac «тупой»: вся логика жестов на iPhone, Mac только исполняет.
- Если поз нет больше 0.3 с (лицо пропало, связь оборвалась), курсор стоит.
- `freeze`: пока один глаз прикрывается, курсор замирает, плюс 0.25 с после клика. Иначе клик уезжает.

### Протокол (`FaceProtocol.swift`)

```swift
enum FaceMessage: Codable {
    case pose(yaw: Float, pitch: Float, scrolling: Bool, freeze: Bool) // градусы; yaw>0 вправо, pitch>0 вверх
    case leftClick
    case rightClick
    case state(paused: Bool)
}
```
Service type: `facemouse` → Bonjour `_facemouse._tcp`, `_facemouse._udp`.
**Файл продублирован в обоих проектах и должен быть идентичным.** Меняешь в одном — копируй в другой.

### Жесты (пороги в `FaceTracker.Threshold`)

| Жест | Условие | Действие |
|---|---|---|
| Поворот головы | yaw/pitch от калибровки | курсор |
| Подмигнуть левым | eyeBlinkLeft > 0.6, правый < 0.3, держать 0.18 с | клик (2 подряд — двойной, на Mac через clickState) |
| Подмигнуть правым | зеркально | правый клик |
| Рот открыт | jawOpen > 0.35 | режим скролла, наклон головы = скорость |
| Брови вверх 1 с | browInnerUp > 0.5 | пауза / продолжить |

Моргание двумя глазами игнорируется (состояние `.blink`). Cooldown между кликами 0.3 с. `swapEyes` на iPhone меняет глаза местами, если ARKit путает стороны.

### Режимы курсора (Mac)
- **absolute**: угол = точка на главном дисплее, `range` градусов = до края экрана (по вертикали × 0.75).
- **joystick**: мёртвая зона `deadzone`, скорость `pow(excess/15, 1.6) * speed` px/с.
- Настройки: speed, range, deadzone, smoothing (→ One Euro minCutoff 3…0.3 Гц), invertX/Y, trustedPeers.

## Настройки проектов (не ломать)

- Xcode 26, deployment target iOS 26.5 / macOS 26.5, Swift 5 mode.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` и `SWIFT_APPROACHABLE_CONCURRENCY = YES`: всё по умолчанию @MainActor. Типы, которые используются вне главного потока (протокол, фильтр, сырые данные), помечены `nonisolated`. Делегаты ARKit и Multipeer — `nonisolated func` с переходом через `MainActor.assumeIsolated` / `DispatchQueue.main.async`.
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`: **импорты должны быть явными.** Если в файле есть `ObservableObject` или `@Published`, нужен `import Combine` (SwiftUI его не подтягивает). Уже ловили эту ошибку.
- Synchronized folders (objectVersion 77): любой .swift в `App/App` или `AppMac/AppMac` автоматически попадает в таргет, pbxproj трогать не нужно. Info.plist туда класть **нельзя**, будет «Multiple commands produce Info.plist».
- `GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_FILE = Info.plist` (сливаются). Строковые ключи через `INFOPLIST_KEY_*` в build settings, массивы (Bonjour) в Info.plist.
- iOS: `NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`, только Portrait на iPhone.
- macOS: `ENABLE_APP_SANDBOX = NO` (из песочницы CGEvent не работает), Hardened Runtime включён, `LSUIElement = YES` (нет иконки в Dock), `NSLocalNetworkUsageDescription`. Нужно разрешение «Универсальный доступ» (`AXIsProcessTrusted`). После пересборки macOS иногда сбрасывает его: удалить приложение из списка и добавить снова.
- Нужен iPhone с Face ID, в симуляторе не работает.

## Безопасность
Подключение к Mac только после подтверждения в NSAlert («Разрешить» / «Всегда разрешать» → `trustedPeers`). Не убирать: иначе любой iPhone рядом сможет управлять курсором. Сессия с `encryptionPreference: .required`.

## Идеи на будущее (не сделано)
- Взгляд (`ARFaceAnchor.lookAtPoint`) для быстрого прыжка курсора в область, голова для точной наводки.
- Поддержка нескольких мониторов в absolute-режиме (сейчас только главный дисплей).
- Экранная клавиатура / dwell-клик для accessibility (люди без рук, БАС).
- Медиа-жесты: пауза, перемотка, громкость (сценарий «лежу на диване, Mac подключён к ТВ»).
- Настройка порогов жестов с телефона вместо констант в коде.
- Направление продукта: hands-free / accessibility. Mousely и подобные — это «пульт для презентаций», другая ниша.

## Apple Watch (добавлено 2026-10-26, ещё не собиралось)

Цепочка: **Watch → (WatchConnectivity) → iPhone `WatchBridge` → (Multipeer) → Mac.** У часов нет Multipeer, поэтому iPhone-приложение должно быть открыто и подключено к Mac.

- Протокол: добавлен `case media(MediaCommand)` (playPause, next/previousTrack, volumeUp/Down, arrowLeft/Right). `FaceProtocol.swift` теперь в **трёх** копиях: App, AppMac, таргет часов.
- Mac: `MediaKeys.swift` жмёт системные медиа-клавиши (NSEvent systemDefined, subtype 8) и стрелки (CGEvent). `AppModel.handle` перехватывает `.media`, курсор не трогает.
- iPhone: `WatchBridge.swift` (WCSession) пересылает сообщения часов в `PeerBrowser.send`, отдаёт часам имя Mac через applicationContext. В `TrackingView` есть плашка часов и тумблер «Камера», чтобы выключить трекинг руки, когда управляешь только часами.
- Часы (`WristMotion.swift`): всё считается в координатах часов, вертикаль берётся из gravity, так что неважно, на какой руке часы.
  - **Жесты**: резкий взмах предплечьем (|ω·up| > 3.5 рад/с, cooldown 0.7 с) → ←/→; Double Tap (`.handGestureShortcut(.primaryAction)`) → Play/Pause; колёсико → громкость.
  - **Мышь**: интеграция гироскопа (yaw вокруг вертикали, pitch вокруг оси предплечье×вверх) → `.pose` 25 Гц; Double Tap → клик. Активна только при поднятой руке (scenePhase == .active), при поднятии автокалибровка.
- Не сделано: WKExtendedRuntimeSession (жесты с опущенной рукой), скролл колёсиком в режиме мыши.

## Apple Watch напрямую по Bluetooth (2026-10-27)

Таргет часов: `App/FaceMouseWatch Watch App` в проекте App (watch-only, `WKWatchOnly = YES`, bundle `abr.FaceMouseWatch.watchkitapp`).
Поскольку часы не companion для `abr.App`, WatchConnectivity с iPhone **не работает** — часы ходят на Mac только напрямую.
Старый путь через iPhone (`WatchBridge`, `_watch_sources/PhoneLink.swift`) пока не используется.

- Транспорт: CoreBluetooth. Mac — периферия (`AppMac/BLEHost.swift`, CBPeripheralManager), часы — central (`MacLink.swift`).
- UUID сервиса и характеристик — в `FaceMouse.BLE` (FaceProtocol.swift, по-прежнему 3 одинаковые копии):
  `hello` (write: WatchHello{id,name}), `command` (write с ответом: клики/медиа), `pose` (write without response, 25 Гц), `status` (read+notify: pending/ok/denied/bye).
- Порядок: часы подключаются → подписка на status → пишут hello → Mac показывает NSAlert «Разрешить / Всегда разрешать / Отклонить».
  «Всегда» сохраняется в `trustedPeers` как `watch:<id часов>`. Команды от неподтверждённых часов Mac игнорирует.
- Часы помнят последний Mac и при запуске подключаются сами; обрыв связи — автопереподключение. В настройках часов: «Отключиться», «Забыть Mac».
- Поза округляется до 0.1°, чтобы JSON влез в один BLE-пакет.
- Info: `NSBluetoothAlwaysUsageDescription` добавлен в обе сборки (часы и AppMac). Песочницы у AppMac нет — entitlement Bluetooth не нужен.
- Ограничения: работает, пока приложение на часах активно (рука поднята). Без шифрования BLE-уровня — защита только подтверждением на Mac.
- Папку `AppMac/Watch` (ошибочный App Intents таргет) можно удалить — в проекте она уже не участвует.
