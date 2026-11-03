import Foundation
import SwiftUI
import Combine
import simd

/// Значения для debug-панели и skeleton-оверлея.
nonisolated struct HandDebug: Sendable {
    var tracked = false
    var yaw: Float = 0
    var pitch: Float = 0
    var pinchIndex: Float = 0
    var pinchMiddle: Float = 0
    var openness: Float = 0
    var spread: Float = 0
    var pose: HandPose = .point
    var points: [HandJoint: SIMD2<Float>] = [:]
}

@MainActor
final class HandTracker: NSObject, ObservableObject {

    nonisolated static func isSupported() -> Bool { CameraFeed.hasFrontCamera() }

    // MARK: - Состояние для UI

    @Published private(set) var debug = HandDebug()
    @Published private(set) var isPaused = false
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationProgress: Double = 0
    @Published private(set) var lastGesture = ""
    /// Если курсор едет в обратную от руки сторону по горизонтали — включи.
    @Published var mirrorX = UserDefaults.standard.bool(forKey: "mirrorX") {
        didSet { UserDefaults.standard.set(mirrorX, forKey: "mirrorX") }
    }

    let camera = CameraFeed()
    /// (сообщение, надёжная доставка)
    var onMessage: ((FaceMessage, Bool) -> Void)?

    // MARK: - Калибровка (нейтральная позиция руки + масштаб ладони)

    private var calibratedCenter: SIMD2<Float>?
    private var handScaleRef: Float = 1
    private var calibrationBaseScale: Float = 1
    private var calibrationAnchors: [SIMD2<Float>] = []
    private var calibrationScales: [Float] = []
    private var calibrationStart: Date?

    // MARK: - Состояние жестов

    private enum PoseState {
        case steady(HandPose)
        case changing(from: HandPose, to: HandPose, since: Date)
    }
    private var poseState: PoseState = .steady(.point)
    private var lastClick = Date.distantPast
    private var fistSince: Date?
    private var fistHandled = false
    private var scrollOrigin: Float?
    private var lostSince: Date?
    private var lastAnchor: SIMD2<Float>?
    private var lastDebugUpdate = Date.distantPast

    private var currentPose: HandPose {
        switch poseState {
        case .steady(let p): return p
        case .changing(let from, _, _): return from
        }
    }

    private var isChangingToGesture: Bool {
        if case .changing(_, let to, _) = poseState, to != .point { return true }
        return false
    }

    // MARK: - Управление

    func start() {
        camera.onHand = { [weak self] raw in
            self?.process(raw)
        }
        camera.start()
        isPaused = false
        poseState = .steady(.point)
        calibrate()
    }

    func stop() {
        camera.stop()
        isCalibrating = false
        calibrationStart = nil
    }

    /// Калибровка начинается с первого кадра с рукой и длится Threshold.calibrationDuration,
    /// учитывая только кадры с явной позой "указка" — иначе центр и масштаб собьются случайным жестом.
    func calibrate() {
        calibrationAnchors.removeAll()
        calibrationScales.removeAll()
        calibrationStart = nil
        calibrationProgress = 0
        isCalibrating = true
    }

    func togglePause() {
        isPaused.toggle()
        poseState = .steady(.point)
        fistSince = nil
        fistHandled = false
        scrollOrigin = nil
        onMessage?(.state(paused: isPaused), true)
        show(isPaused ? "⏸ Пауза" : "▶️ Трекинг включён")
    }

    // MARK: - Обработка кадра

    private func process(_ raw: RawHand?) {
        let now = Date()

        guard let raw, let m = handMetrics(from: raw) else {
            handleLost(now: now)
            return
        }
        lostSince = nil

        // Защита от перескока на вторую руку/шумовой выброс: кадр слишком далеко от предыдущего — пропускаем.
        if let last = lastAnchor, simd_distance(m.anchor, last) > HandThreshold.maxJump {
            return
        }
        lastAnchor = m.anchor

        if isCalibrating {
            runCalibration(raw, m, now: now)
            return
        }

        updateScaleRef(m.handScale)

        let pose = classifyHandPose(m, previous: currentPose)
        advance(to: pose, now: now)

        if case .steady(.fist) = poseState, !fistHandled, let since = fistSince,
           now.timeIntervalSince(since) >= HandThreshold.fistHold {
            fistHandled = true
            togglePause()
        }

        let (yaw, pitch) = pointer(m.anchor)
        updateDebug(raw, m: m, pose: pose, yaw: yaw, pitch: pitch, now: now)

        guard !isPaused else { return }

        if case .steady(.palm) = poseState {
            sendScroll(m, yaw: yaw, now: now)
        } else {
            let freeze = m.pinchIndex < HandThreshold.pinchArm
                || m.pinchMiddle < HandThreshold.pinchArm
                || isChangingToGesture
            onMessage?(.pose(yaw: yaw, pitch: pitch, scrolling: false, freeze: freeze), false)
        }
    }

    private func handleLost(now: Date) {
        if lostSince == nil { lostSince = now }
        // Короткие пропуски детекции (1-2 кадра) не сбрасывают автомат — иначе на возврате
        // руки в кадр прилетит фантомный клик (переход .none -> .pinchIndex читается как новый).
        if now.timeIntervalSince(lostSince ?? now) > HandThreshold.lostGrace {
            poseState = .steady(.point)
            fistSince = nil
            fistHandled = false
            scrollOrigin = nil
            lastAnchor = nil
            // Паузу при потере руки НЕ снимаем.
        }
        if now.timeIntervalSince(lastDebugUpdate) > 0.1 {
            debug.tracked = false
            lastDebugUpdate = now
        }
    }

    // MARK: - Калибровка

    private func runCalibration(_ raw: RawHand, _ m: HandMetrics, now: Date) {
        if calibrationStart == nil { calibrationStart = now }
        let pose = classifyHandPose(m, previous: .point)
        if pose == .point && raw.confidence > 0.5 {
            calibrationAnchors.append(m.anchor)
            calibrationScales.append(m.handScale)
        }
        let progress = now.timeIntervalSince(calibrationStart ?? now) / HandThreshold.calibrationDuration
        calibrationProgress = min(progress, 1)
        updateDebug(raw, m: m, pose: pose, yaw: 0, pitch: 0, now: now)

        guard progress >= 1 else { return }
        if calibrationAnchors.count >= HandThreshold.calibrationMinSamples {
            finishCalibration()
        } else {
            // Руку не держали ровно — пробуем ещё раз.
            calibrationStart = now
            calibrationAnchors.removeAll()
            calibrationScales.removeAll()
        }
    }

    private func finishCalibration() {
        guard !calibrationScales.isEmpty else { return }

        let baseScale = calibrationScales.sorted()[calibrationScales.count / 2]
        var mean = calibrationAnchors.reduce(SIMD2<Float>(0, 0), +) / Float(calibrationAnchors.count)
        let filtered = calibrationAnchors.filter {
            simd_distance($0, mean) / baseScale < HandThreshold.calibrationOutlier
        }
        if filtered.count >= HandThreshold.calibrationMinSamples / 2 {
            mean = filtered.reduce(SIMD2<Float>(0, 0), +) / Float(filtered.count)
        }

        calibratedCenter = mean
        handScaleRef = baseScale
        calibrationBaseScale = baseScale
        isCalibrating = false
        calibrationStart = nil
        calibrationAnchors.removeAll()
        calibrationScales.removeAll()
        show("✅ Калибровка готова")
    }

    /// Медленная EMA-адаптация "единицы" размера ладони — компенсирует изменение расстояния
    /// до камеры, но не ловит мгновенный шум от поворота кисти (иначе курсор дёргается).
    private func updateScaleRef(_ scale: Float) {
        let alpha = HandThreshold.scaleAlpha
        handScaleRef = (1 - alpha) * handScaleRef + alpha * scale
        handScaleRef = clamp(
            handScaleRef,
            calibrationBaseScale * HandThreshold.scaleClampLow,
            calibrationBaseScale * HandThreshold.scaleClampHigh
        )
    }

    // MARK: - Указка -> градусы под Mac

    private func pointer(_ anchor: SIMD2<Float>) -> (yaw: Float, pitch: Float) {
        guard let center = calibratedCenter else { return (0, 0) }
        let u = (anchor - center) / max(handScaleRef, 0.0001)
        var yaw = clamp(u.x / HandThreshold.spanX, -HandThreshold.clampOvershoot, HandThreshold.clampOvershoot)
            * HandThreshold.fullScaleX
        // Vision: y растёт вверх (origin внизу слева) — совпадает с протоколом (pitch>0 = вверх), без инверсии.
        let pitch = clamp(u.y / HandThreshold.spanY, -HandThreshold.clampOvershoot, HandThreshold.clampOvershoot)
            * HandThreshold.fullScaleX * HandThreshold.verticalCompensation
        if mirrorX { yaw = -yaw }
        return (yaw, pitch)
    }

    private func sendScroll(_ m: HandMetrics, yaw: Float, now: Date) {
        guard let center = calibratedCenter else { return }
        let uY = (m.anchor.y - center.y) / max(handScaleRef, 0.0001)
        if scrollOrigin == nil { scrollOrigin = uY }
        let delta = uY - (scrollOrigin ?? uY)
        let pitch = clamp(delta / HandThreshold.spanScrollY, -HandThreshold.clampOvershoot, HandThreshold.clampOvershoot)
            * HandThreshold.fullScaleX * HandThreshold.verticalCompensation
        onMessage?(.pose(yaw: yaw, pitch: pitch, scrolling: true, freeze: false), false)
    }

    // MARK: - Жесты

    private func advance(to candidate: HandPose, now: Date) {
        switch poseState {
        case .steady(let current):
            guard candidate != current else { return }
            poseState = .changing(from: current, to: candidate, since: now)

        case .changing(let from, let to, let since):
            guard candidate == to else {
                // Цель жеста изменилась на полпути — считаем заново.
                poseState = candidate == from ? .steady(from) : .changing(from: from, to: candidate, since: now)
                return
            }
            guard now.timeIntervalSince(since) >= holdTime(for: to) else { return }
            poseState = .steady(to)
            onEnterSteady(to, now: now)
        }
    }

    private func holdTime(for pose: HandPose) -> TimeInterval {
        switch pose {
        case .pinchIndex, .pinchMiddle: return HandThreshold.pinchHold
        default: return HandThreshold.modeHold
        }
    }

    private func onEnterSteady(_ pose: HandPose, now: Date) {
        switch pose {
        case .pinchIndex where !isPaused:
            fire(.leftClick, label: "🖱 Клик", now: now)
        case .pinchMiddle where !isPaused:
            fire(.rightClick, label: "🖱 Правый клик", now: now)
        case .palm:
            scrollOrigin = nil
        case .fist:
            fistSince = now
            fistHandled = false
        default:
            break
        }
    }

    private func fire(_ message: FaceMessage, label: String, now: Date) {
        guard now.timeIntervalSince(lastClick) >= HandThreshold.clickCooldown else { return }
        lastClick = now
        onMessage?(message, true)
        show(label)
    }

    private func show(_ text: String) {
        lastGesture = text
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if lastGesture == text { lastGesture = "" }
        }
    }

    private func updateDebug(_ raw: RawHand, m: HandMetrics, pose: HandPose, yaw: Float, pitch: Float, now: Date) {
        guard now.timeIntervalSince(lastDebugUpdate) > 0.1 else { return } // ~10 раз в секунду
        lastDebugUpdate = now
        debug = HandDebug(
            tracked: true, yaw: yaw, pitch: pitch,
            pinchIndex: m.pinchIndex, pinchMiddle: m.pinchMiddle,
            openness: m.openness, spread: m.spread,
            pose: pose, points: raw.points
        )
    }
}

private func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
    min(max(value, lo), hi)
}
